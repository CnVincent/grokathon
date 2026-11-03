"""Optional summary endpoint: windowing, auth, and injectable Grok HTTP."""

import json
from io import BytesIO
from unittest.mock import Mock

from fastapi.testclient import TestClient

from app.main import create_app


def _client(monkeypatch, tmp_path, **env):
    monkeypatch.setenv("DEPLOY_MODE", "local")
    monkeypatch.delenv("TONE_TOKEN", raising=False)
    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setenv("SUMMARY_BACKEND", "mock")
    monkeypatch.delenv("XAI_API_KEY", raising=False)
    for key, value in env.items():
        if value is None:
            monkeypatch.delenv(key, raising=False)
        else:
            monkeypatch.setenv(key, value)
    return TestClient(create_app())


def test_mock_summarizes_only_the_last_120s(monkeypatch, tmp_path):
    with _client(monkeypatch, tmp_path) as client:
        response = client.post(
            "/summary",
            json={
                "lines": [
                    {"speaker": "Old", "text": "Way earlier.", "tone": "Excited", "t_end": 10.0},
                    {"speaker": "Helena", "text": "Let's pause.", "tone": "Calm", "t_end": 200.0},
                    {"speaker": "Alex", "text": "Okay.", "t_end": 205.0},
                ]
            },
        )
    assert response.status_code == 200
    body = response.json()
    assert body["window_seconds"] == 120
    assert body["model_version"] == "summary-stub-v1"
    assert body["summary"] == (
        "Last two minutes: Helena: Let's pause. [Calm]; Alex: Okay."
    )
    assert "Way earlier" not in body["summary"]
    assert "Old" not in body["summary"]


def test_empty_lines_says_nothing_was_said(monkeypatch, tmp_path):
    with _client(monkeypatch, tmp_path) as client:
        response = client.post("/summary", json={"lines": []})
    assert response.status_code == 200
    body = response.json()
    assert body["summary"] == "Nothing was said in the last two minutes."
    assert body["model_version"] == "summary-stub-v1"
    assert body["window_seconds"] == 120


def test_configured_token_rejects_missing_header(monkeypatch, tmp_path):
    with _client(monkeypatch, tmp_path, TONE_TOKEN="test-token") as client:
        response = client.post("/summary", json={"lines": []})
    assert response.status_code == 401


def test_local_mode_without_token_succeeds(monkeypatch, tmp_path):
    with _client(monkeypatch, tmp_path, DEPLOY_MODE="local", TONE_TOKEN=None) as client:
        response = client.post(
            "/summary",
            json={"lines": [{"speaker": "Helena", "text": "Let's pause.", "t_end": 40.0}]},
        )
    assert response.status_code == 200
    assert response.json()["summary"] == "Last two minutes: Helena: Let's pause."


def test_grok_backend_uses_injected_opener(monkeypatch, tmp_path):
    calls = []

    def fake_opener(request, timeout=None):
        calls.append((request, timeout))
        assert timeout == 20
        assert request.full_url == "https://api.x.ai/v1/chat/completions"
        assert request.get_header("Authorization") == "Bearer test-xai-key"
        payload = json.loads(request.data.decode("utf-8"))
        assert payload["model"] == "grok-3-mini"
        assert payload["temperature"] == 0
        assert len(payload["messages"]) == 1
        assert payload["messages"][0]["role"] == "user"
        content = payload["messages"][0]["content"]
        assert "Helena" in content
        assert "Let's pause." in content
        assert "[Calm]" in content
        return BytesIO(
            json.dumps(
                {"choices": [{"message": {"content": "Helena calmly asked to pause."}}]}
            ).encode("utf-8")
        )

    monkeypatch.setenv("DEPLOY_MODE", "local")
    monkeypatch.delenv("TONE_TOKEN", raising=False)
    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setenv("SUMMARY_BACKEND", "grok")
    monkeypatch.setenv("XAI_API_KEY", "test-xai-key")
    app = create_app()
    app.state.summary_backend.opener = fake_opener
    with TestClient(app) as client:
        response = client.post(
            "/summary",
            json={
                "lines": [
                    {"speaker": "Helena", "text": "Let's pause.", "tone": "Calm", "t_end": 40.0}
                ]
            },
        )
    assert response.status_code == 200
    body = response.json()
    assert body["summary"] == "Helena calmly asked to pause."
    assert body["model_version"] == "grok-3-mini"
    assert body["window_seconds"] == 120
    assert len(calls) == 1


def test_grok_without_api_key_returns_503(monkeypatch, tmp_path):
    opener = Mock()
    monkeypatch.setenv("DEPLOY_MODE", "local")
    monkeypatch.delenv("TONE_TOKEN", raising=False)
    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path / "logs"))
    monkeypatch.setenv("SUMMARY_BACKEND", "grok")
    monkeypatch.delenv("XAI_API_KEY", raising=False)
    app = create_app()
    if app.state.summary_backend is not None:
        app.state.summary_backend.opener = opener
    with TestClient(app) as client:
        response = client.post(
            "/summary",
            json={"lines": [{"speaker": "Helena", "text": "Let's pause.", "t_end": 40.0}]},
        )
    assert response.status_code == 503
    assert response.json()["detail"] == "summary_unavailable"
    opener.assert_not_called()
