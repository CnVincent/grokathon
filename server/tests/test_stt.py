"""Online caption proxy: mock frames, auth, and xAI URL mapping."""

import json

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.main import app
from app.stt import build_xai_url, keyterms_from_start

PCM = b"\x00\x00\x01\x00"


@pytest.fixture
def client(monkeypatch, tmp_path):
    monkeypatch.setenv("DEPLOY_MODE", "local")
    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.delenv("TONE_TOKEN", raising=False)
    monkeypatch.delenv("STT_BACKEND", raising=False)
    monkeypatch.delenv("XAI_API_KEY", raising=False)
    with TestClient(app) as client:
        yield client


def test_mock_pcm_partial_then_audio_done(client, caplog):
    with client.websocket_connect("/ws/stt?session_id=test-session") as websocket:
        ready = websocket.receive_json()
        assert ready == {
            "type": "stt.ready",
            "session_id": "test-session",
            "model_version": "stt-mock-v1",
        }
        websocket.send_bytes(PCM)
        partial = websocket.receive_json()
        assert partial["type"] == "stt.partial"
        assert partial["text"] == "online caption"
        assert partial["language"] == "hi"
        assert partial["is_final"] is False
        assert partial["speech_final"] is False
        assert partial["words"] == [
            {"text": "online", "start": 0.0, "end": 0.2, "speaker": 0, "confidence": None},
            {"text": "caption", "start": 0.2, "end": 0.5, "speaker": 0, "confidence": None},
        ]
        websocket.send_text(json.dumps({"type": "audio.done"}))
        done = websocket.receive_json()
        assert done["type"] == "stt.done"
        assert done["text"] == "online caption"
        assert done["language"] == "en"
        assert done["duration"] == 0.5
        assert done["words"] == partial["words"]
    assert PCM not in caplog.text.encode("utf-8", "surrogateescape")
    assert str(PCM) not in caplog.text
    assert PCM.decode("latin-1") not in caplog.text


def test_odd_length_pcm_then_valid_frame(client):
    with client.websocket_connect("/ws/stt?session_id=test-session") as websocket:
        assert websocket.receive_json()["type"] == "stt.ready"
        websocket.send_bytes(b"\x00")
        error = websocket.receive_json()
        assert error == {
            "type": "stt.error",
            "code": "invalid_pcm16_length",
            "message": "PCM16 frames must have an even byte length.",
        }
        assert "request" not in error
        websocket.send_bytes(PCM)
        partial = websocket.receive_json()
        assert partial["type"] == "stt.partial"
        assert partial["language"] == "hi"
        assert len(partial["words"]) == 2


def test_xai_without_key_returns_unavailable(client, monkeypatch):
    monkeypatch.setenv("STT_BACKEND", "xai")
    monkeypatch.delenv("XAI_API_KEY", raising=False)
    with client.websocket_connect("/ws/stt?session_id=test-session") as websocket:
        response = websocket.receive_json()
    assert response["type"] == "stt.error"
    assert response["code"] == "stt_unavailable"
    assert "online captions are off" in response["message"].lower()
    assert "on-device captions still work" in response["message"].lower()


@pytest.mark.parametrize("authorization", [None, "Bearer wrong-token"])
def test_token_rejects_stt_without_ready(client, monkeypatch, authorization):
    monkeypatch.setenv("TONE_TOKEN", "test-token")
    headers = {"Authorization": authorization} if authorization else {}
    with pytest.raises(WebSocketDisconnect) as error:
        with client.websocket_connect("/ws/stt?session_id=test-session", headers=headers):
            pass
    assert error.value.code == 1008


def test_build_xai_url_includes_required_params_and_omits_language():
    terms = keyterms_from_start(
        {"type": "stt.start", "sample_rate": 16000, "keyterms": ["Graption", "Fulton"]}
    )
    url = build_xai_url(keyterms=terms)
    assert "model=grok-voice-transcribe-2.0" in url
    assert "interim_results=true" in url
    assert "diarize=true" in url
    assert "sample_rate=16000" in url
    assert "keyterm=Graption" in url
    assert "keyterm=Fulton" in url
    assert "language=" not in url
