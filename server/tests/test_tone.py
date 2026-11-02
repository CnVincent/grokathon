"""Tone backends: tag rules, backend selection, and tags reaching the client."""

import base64
import json
import math
import os
import struct
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from jsonschema import Draft202012Validator, FormatChecker

from app.main import create_app
from app.tone import MockToneBackend, TonePrediction, create_backend, map_tag, no_probs

SCHEMA = json.loads(
    (Path(__file__).resolve().parents[2] / "schemas/events.schema.json").read_text()
)
VALIDATOR = Draft202012Validator(SCHEMA, format_checker=FormatChecker())
TAGS = {"excited", "upset", "calm", None}


@pytest.mark.parametrize(
    ("arousal", "valence", "tag"),
    [
        (0.80, 0.70, "excited"),
        (0.65, 0.46, "excited"),
        (0.64, 0.70, None),  # Arousal must be strictly above 0.64.
        (0.70, 0.30, "upset"),
        (0.48, 0.39, "upset"),
        (0.47, 0.30, None),
        (0.45, 0.60, "calm"),
        (0.38, 0.60, None),
        (0.45, 0.42, None),  # Neutral valence is no tag.
        (0.20, 0.50, None),
        (0.55, 0.50, None),
    ],
)
def test_map_tag_follows_a4_thresholds(arousal, valence, tag):
    assert map_tag(arousal, valence) == tag


def test_default_backend_is_mock(monkeypatch):
    monkeypatch.delenv("TONE_BACKEND", raising=False)
    assert isinstance(create_backend(), MockToneBackend)
    monkeypatch.setenv("TONE_BACKEND", " Mock ")
    assert isinstance(create_backend(), MockToneBackend)


def test_unknown_backend_fails_at_startup(monkeypatch):
    monkeypatch.setenv("TONE_BACKEND", "custom")
    with pytest.raises(ValueError, match="custom"):
        create_app()


def tone_request(audio: bytes = b"\0\0" * 16000) -> dict:
    return {
        "type": "tone_request",
        "session_id": "test-session",
        "schema_version": "1.1",
        "caption_id": str(uuid4()),
        "t_start": 0.0,
        "t_end": len(audio) / 2 / 16000,
        "sample_rate": 16000,
        "audio_b64": base64.b64encode(audio).decode("ascii"),
    }


def test_backend_tag_reaches_client(monkeypatch, tmp_path):
    class TaggingBackend:
        model_version = "tagging-test-v1"

        async def predict(self, audio, sample_rate):
            return TonePrediction(tag="excited", probs=no_probs(), model_version=self.model_version)

    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path))
    monkeypatch.delenv("TONE_BACKEND", raising=False)
    server = create_app()
    server.state.tone_backend = TaggingBackend()
    with TestClient(server) as client:
        with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
            request = tone_request()
            websocket.send_json(request)
            response = websocket.receive_json()
    VALIDATOR.validate(response)
    assert response["caption_id"] == request["caption_id"]
    assert response["tag"] == "excited"
    assert response["model_version"] == "tagging-test-v1"


def sine_pcm16(seconds: float, sample_rate: int = 16000) -> bytes:
    count = int(seconds * sample_rate)
    return b"".join(
        struct.pack("<h", int(8000 * math.sin(2 * math.pi * 220 * i / sample_rate)))
        for i in range(count)
    )


@pytest.mark.skipif(
    os.getenv("RUN_MODEL_TESTS") != "1",
    reason="Loads the ~1.2 GB audEERING model; set RUN_MODEL_TESTS=1 after downloading it.",
)
def test_audeering_backend_end_to_end(monkeypatch, tmp_path):
    monkeypatch.setenv("TONE_LOG_DIR", str(tmp_path))
    monkeypatch.setenv("TONE_BACKEND", "audeering")
    with TestClient(create_app()) as client:
        with client.websocket_connect("/ws/session?session_id=test-session") as websocket:
            for audio, expect_none in ((sine_pcm16(1.0), False), (sine_pcm16(0.2), True)):
                websocket.send_json(tone_request(audio))
                response = websocket.receive_json()
                VALIDATOR.validate(response)
                assert response["model_version"] == "audeering-msp-dim-a4"
                assert response["tag"] in TAGS
                if expect_none:
                    assert response["tag"] is None
