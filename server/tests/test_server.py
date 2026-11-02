"""Exercise the real routes and their shared wire contract."""

import json
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator, FormatChecker
from starlette.websockets import WebSocketDisconnect

from app.main import app, create_app

SCHEMA = json.loads(
    (Path(__file__).resolve().parents[2] / "schemas/events.schema.json").read_text()
)
VALIDATOR = Draft202012Validator(SCHEMA, format_checker=FormatChecker())


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("DEPLOY_MODE", "local")
    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.delenv("TONE_TOKEN", raising=False)
    with TestClient(app) as client:
        yield client


def tone_request():
    return {
        "type": "tone_request",
        "session_id": "test-session",
        "schema_version": "1.2",
        "caption_id": str(uuid4()),
        "t_start": 1.0,
        "t_end": 1.1,
        "sample_rate": 16000,
        "audio_b64": "AAABAAIA",
    }


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.text == "ok"


def test_session_replies_to_multiple_audio_segments(client, caplog):
    with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
        for _ in range(2):
            request = tone_request()
            VALIDATOR.validate(request)
            websocket.send_json(request)
            response = websocket.receive_json()
            VALIDATOR.validate(response)
            assert response["type"] == "tone_result"
            assert response["caption_id"] == request["caption_id"]
            assert response["session_id"] == request["session_id"]
            assert response["tag"] is None
            assert response["model_version"] == "tone-stub-v1"
            assert set(response["probs"].values()) == {0.0}
            assert response["latency_ms"]["recv_to_send"] >= 0
    assert request["audio_b64"] not in caplog.text


def test_caption_log_does_not_interrupt_tone(client):
    request = tone_request()
    caption_log = {
        "type": "caption_log",
        "session_id": request["session_id"],
        "schema_version": "1.2",
        "tone_tag": None,
        "caption": {
            "type": "caption",
            "session_id": request["session_id"],
            "schema_version": "1.2",
            "caption_id": request["caption_id"],
            "t_start": 1.0,
            "t_end": 1.1,
            "text": "Hello",
            "speaker_id": "unknown",
            "model_versions": {"asr": "mock-asr-v1", "asd": "mock-asd-v1"},
        },
    }
    with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
        websocket.send_json(caption_log)
        websocket.send_json(request)
        assert websocket.receive_json()["caption_id"] == request["caption_id"]


@pytest.mark.parametrize(
    ("changes", "reason"),
    [
        ({"session_id": "another-session"}, "session_mismatch"),
        ({"schema_version": "2.0"}, "schema_validation_failed"),
        ({"audio_b64": "invalid base64!"}, "invalid_base64_audio"),
        ({"audio_b64": "AA=="}, "invalid_pcm16_length"),
        ({"t_end": 0.5}, "invalid_segment_times"),
        ({"caption_id": "not-a-uuid"}, "schema_validation_failed"),
        ({"type": "unknown"}, "unsupported_event"),
        ({"private_marker": "private-payload-do-not-log"}, "schema_validation_failed"),
    ],
)
def test_invalid_events_reply_and_allow_recovery(client, changes, reason, caplog):
    request = {**tone_request(), **changes}
    with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
        raw = json.dumps(request)
        websocket.send_text(raw)
        response = websocket.receive_json()
        VALIDATOR.validate(response)
        assert response["type"] == "session_error"
        assert response["code"] == reason
        assert response["message"]
        assert response["request"] == raw
        assert response["request_encoding"] == "text"
        assert response["session_id"] == "test-session"
        valid = tone_request()
        websocket.send_json(valid)
        assert websocket.receive_json()["caption_id"] == valid["caption_id"]
    assert f"Rejected WebSocket request: reason={reason}" in caplog.text
    assert "model_version=tone-stub-v1" in caplog.text
    assert request["audio_b64"] not in caplog.text
    assert "private-payload-do-not-log" not in caplog.text


@pytest.mark.parametrize("raw", ["not json", '{"type":', "[]", "null", '{"x": NaN}'])
def test_malformed_json_allows_recovery(client, caplog, raw):
    with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
        websocket.send_text(raw)
        response = websocket.receive_json()
        VALIDATOR.validate(response)
        assert response["type"] == "session_error"
        assert response["request"] == raw
        assert response["message"]
        websocket.send_json(tone_request())
        assert websocket.receive_json()["tag"] is None
    assert raw not in caplog.text


def test_missing_field_error_identifies_field_and_allows_recovery(client):
    request = tone_request()
    del request["sample_rate"]
    with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
        websocket.send_json(request)
        response = websocket.receive_json()
        assert response["code"] == "schema_validation_failed"
        assert "sample_rate: Field required" in response["message"]
        assert json.loads(response["request"]) == request
        websocket.send_json(tone_request())
        assert websocket.receive_json()["tag"] is None


@pytest.mark.parametrize("received", ["Test-session", "test-session ", "test-session\u200b"])
def test_session_mismatch_exposes_exact_values_without_logging_them(client, caplog, received):
    with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
        websocket.send_json({**tone_request(), "session_id": received})
        response = websocket.receive_json()
        assert response["code"] == "session_mismatch"
        assert "Expected 'test-session' (12 characters)" in response["message"]
        assert f"received {ascii(received)} ({len(received)} characters)" in response["message"]
        websocket.send_json(tone_request())
        assert websocket.receive_json()["tag"] is None
    assert received not in caplog.text


@pytest.mark.parametrize(
    ("url_id", "request_id", "expected_code"),
    [("demo%2Bphone", "demo+phone", "tone_result"), ("demo+phone", "demo+phone", "session_error")],
)
def test_session_ids_use_decoded_url_query(client, url_id, request_id, expected_code):
    with client.websocket_connect(f"/ws/session?session_id={url_id}") as websocket:
        websocket.send_json({**tone_request(), "session_id": request_id})
        response = websocket.receive_json()
        assert response["type"] == expected_code
        if expected_code == "session_error":
            assert "Expected 'demo phone'" in response["message"]
            assert "received 'demo+phone'" in response["message"]


def test_binary_frame_is_echoed_as_base64_and_allows_recovery(client, caplog):
    with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
        websocket.send_bytes(b"private audio")
        response = websocket.receive_json()
        VALIDATOR.validate(response)
        assert response["code"] == "expected_json_text_frame"
        assert response["request_encoding"] == "base64"
        assert response["request"] == "cHJpdmF0ZSBhdWRpbw=="
        websocket.send_json(tone_request())
        assert websocket.receive_json()["tag"] is None
    assert "private audio" not in caplog.text
    assert response["request"] not in caplog.text


@pytest.mark.parametrize("authorization", [None, "Bearer wrong-token"])
def test_configured_token_rejects_unauthorized_handshake(client, monkeypatch, authorization):
    monkeypatch.setenv("TONE_TOKEN", "test-token")
    headers = {"Authorization": authorization} if authorization else {}
    with pytest.raises(WebSocketDisconnect) as error:
        with client.websocket_connect("/ws/session?session_id=test-session", headers=headers):
            pass
    assert error.value.code == 1008


def test_authorized_handshake(client, monkeypatch):
    monkeypatch.setenv("TONE_TOKEN", "test-token")
    with client.websocket_connect(
        "/ws/session?session_id=test-session", headers={"Authorization": "Bearer test-token"}
    ) as websocket:
        websocket.send_json(tone_request())
        assert websocket.receive_json()["tag"] is None


@pytest.mark.parametrize("mode", ["tunnel", "cloud"])
def test_nonlocal_mode_requires_token(client, monkeypatch, mode):
    monkeypatch.setenv("DEPLOY_MODE", mode)
    with pytest.raises(WebSocketDisconnect) as error:
        with client.websocket_connect("/ws/session?session_id=test-session"):
            pass
    assert error.value.code == 1008


@pytest.mark.parametrize("verbose", ["false", "true"])
def test_log_files_verbose_metrics_and_payload_privacy(monkeypatch, tmp_path, caplog, verbose):
    monkeypatch.setenv("DEPLOY_MODE", "local")
    monkeypatch.delenv("TONE_TOKEN", raising=False)
    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path / "logs"))
    raw = json.dumps({**tone_request(), "private_marker": "never-save-this-request"})
    with TestClient(create_app(verbose=verbose == "true")) as client:
        with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
            request = tone_request()
            for _ in range(2):
                websocket.send_json(request)
                assert websocket.receive_json()["tag"] is None
            websocket.send_text(raw)
            assert websocket.receive_json()["request"] == raw
    content = next((tmp_path / "logs").glob("server-*.jsonl")).read_text()
    logs = [json.loads(line) for line in content.splitlines()]
    events = [entry["event"] for entry in logs]
    assert events.count("server_started") == 1
    assert events.count("server_stopped") == 1
    assert events.count("request_rejected") == 1
    assert all(entry["model_version"] == "tone-stub-v1" for entry in logs)
    for sensitive in [request["audio_b64"], "never-save-this-request", raw]:
        assert sensitive not in content
        assert sensitive not in caplog.text
    if verbose == "true":
        assert events.count("tone_request_valid") == 2
        assert events.count("tone_result_sent") == 2
        summary = next(entry for entry in logs if entry["event"] == "connection_closed")
        assert summary["received_messages"] == 3
        assert summary["tone_requests"] == 2
        assert summary["rejected_requests"] == 1
        assert summary["bytes_received"] > 0
        assert summary["bytes_sent"] > 0
        assert summary["inference_ms"] >= 0
        assert summary["send_ms"] >= 0
        assert summary["close_code"] == 1000
        connection_events = [entry for entry in logs if "connection_id" in entry]
        assert len({entry["connection_id"] for entry in connection_events}) == 1
    else:
        assert "tone_request_valid" not in events
        assert "connection_closed" not in events


def test_backend_failure_does_not_log_exception_payload(client, monkeypatch, tmp_path, caplog):
    class BrokenBackend:
        model_version = "broken-test-v1"

        async def predict(self, audio, sample_rate):
            raise RuntimeError("secret-audio-content-do-not-log")

    monkeypatch.setattr(app.state, "tone_backend", BrokenBackend())
    with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
        websocket.send_json(tone_request())
        with pytest.raises(WebSocketDisconnect) as error:
            websocket.receive_json()
        assert error.value.code == 1011
    content = next((tmp_path / "logs").glob("server-*.jsonl")).read_text()
    assert "connection_failed" in content
    assert "broken-test-v1" in content
    assert "secret-audio-content-do-not-log" not in content + caplog.text


def test_each_server_start_creates_a_new_log_file(monkeypatch, tmp_path):
    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path))
    for _ in range(2):
        with TestClient(create_app()) as client:
            assert client.get("/health").text == "ok"
    files = list(tmp_path.glob("server-*.jsonl"))
    assert len(files) == 2
    for path in files:
        entries = [json.loads(line) for line in path.read_text().splitlines()]
        assert [entry["event"] for entry in entries] == ["server_started", "server_stopped"]
        assert entries[0]["log_file"] == str(path)
