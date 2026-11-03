"""Grok STT wire mapping. Audio and transcripts stay in memory and are never logged."""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import os
from collections.abc import AsyncIterator, Mapping
from contextlib import asynccontextmanager
from typing import Any
from urllib.parse import urlencode

import websockets

XAI_STT_URL = "wss://api.x.ai/v1/stt"
XAI_MODEL_VERSION = "grok-voice-transcribe-2.0"
MOCK_MODEL_VERSION = "stt-mock-v1"
CREATED_TIMEOUT_S = 10.0
UNAVAILABLE_MESSAGE = "Online captions are off. On-device captions still work."
INVALID_PCM16_MESSAGE = "PCM16 frames must have an even byte length."
UNSUPPORTED_EVENT_MESSAGE = (
    "Expected stt.start, audio.done, finalize, or a PCM16 binary frame."
)
UPSTREAM_ERROR_MESSAGE = "Speech-to-text upstream failed."
UPSTREAM_TIMEOUT_MESSAGE = "Speech-to-text upstream timed out."

_upstream_logger = logging.getLogger("graption.stt.upstream")
_upstream_logger.setLevel(logging.WARNING)


class UpstreamSttError(Exception):
    """Upstream failed; message is a short client-safe string with no payload."""

    def __init__(self, message: str = UPSTREAM_ERROR_MESSAGE) -> None:
        super().__init__(message)
        self.message = message


def selected_stt_backend() -> str:
    return (os.getenv("STT_BACKEND") or "mock").strip().lower() or "mock"


def xai_api_key() -> str:
    return (os.getenv("XAI_API_KEY") or "").strip()


def build_xai_url(*, sample_rate: int = 16000, keyterms: list[str] | None = None) -> str:
    params: list[tuple[str, str]] = [
        ("model", XAI_MODEL_VERSION),
        ("sample_rate", str(sample_rate)),
        ("encoding", "pcm"),
        ("interim_results", "true"),
        ("diarize", "true"),
    ]
    for term in keyterms or []:
        params.append(("keyterm", term))
    return f"{XAI_STT_URL}?{urlencode(params)}"


def ready_event(session_id: str, model_version: str) -> dict[str, str]:
    return {"type": "stt.ready", "session_id": session_id, "model_version": model_version}


def error_event(code: str, message: str) -> dict[str, str]:
    return {"type": "stt.error", "code": code, "message": message}


def unavailable_event() -> dict[str, str]:
    return error_event("stt_unavailable", UNAVAILABLE_MESSAGE)


def mock_words() -> list[dict[str, object]]:
    return [
        {"text": "online", "start": 0.0, "end": 0.2, "speaker": 0, "confidence": None},
        {"text": "caption", "start": 0.2, "end": 0.5, "speaker": 0, "confidence": None},
    ]


def mock_partial(*, is_final: bool, speech_final: bool, language: str) -> dict[str, object]:
    return {
        "type": "stt.partial",
        "text": "online caption",
        "language": language,
        "is_final": is_final,
        "speech_final": speech_final,
        "words": mock_words(),
    }


def mock_done() -> dict[str, object]:
    return {
        "type": "stt.done",
        "text": "online caption",
        "language": "en",
        "duration": 0.5,
        "words": mock_words(),
    }


def _as_number(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return float(value)


def map_word(word: Mapping[str, Any]) -> dict[str, object]:
    speaker = word.get("speaker")
    confidence = word.get("confidence")
    start = _as_number(word.get("start"))
    end = _as_number(word.get("end"))
    return {
        "text": word["text"] if isinstance(word.get("text"), str) else "",
        "start": 0.0 if start is None else start,
        "end": 0.0 if end is None else end,
        "speaker": speaker if isinstance(speaker, int) and not isinstance(speaker, bool) else None,
        "confidence": (
            float(confidence)
            if isinstance(confidence, int | float) and not isinstance(confidence, bool)
            else None
        ),
    }


def _map_words(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        return []
    return [map_word(item) for item in value if isinstance(item, Mapping)]


def map_partial(event: Mapping[str, Any]) -> dict[str, object]:
    language = event.get("language")
    return {
        "type": "stt.partial",
        "text": event["text"] if isinstance(event.get("text"), str) else "",
        "language": language if isinstance(language, str) else None,
        "is_final": bool(event.get("is_final", False)),
        "speech_final": bool(event.get("speech_final", False)),
        "words": _map_words(event.get("words")),
    }


def map_done(event: Mapping[str, Any]) -> dict[str, object]:
    language = event.get("language")
    return {
        "type": "stt.done",
        "text": event["text"] if isinstance(event.get("text"), str) else "",
        "language": language if isinstance(language, str) else None,
        "duration": _as_number(event.get("duration")),
        "words": _map_words(event.get("words")),
    }


def map_upstream_event(event: Mapping[str, Any]) -> dict[str, object] | None:
    event_type = event.get("type")
    if event_type == "transcript.partial":
        return map_partial(event)
    if event_type == "transcript.done":
        return map_done(event)
    if event_type == "error":
        return error_event("upstream_error", UPSTREAM_ERROR_MESSAGE)
    return None


def keyterms_from_start(message: Mapping[str, Any]) -> list[str]:
    keyterms = message.get("keyterms") or []
    if not isinstance(keyterms, list):
        return []
    return [item for item in keyterms if isinstance(item, str)]


def validate_stt_start(message: Mapping[str, Any]) -> dict[str, str] | None:
    if "sample_rate" in message and message["sample_rate"] != 16000:
        return error_event("invalid_sample_rate", "sample_rate must be 16000.")
    keyterms = message.get("keyterms")
    if keyterms is None:
        return None
    if not isinstance(keyterms, list) or len(keyterms) > 20:
        return error_event("invalid_keyterms", "keyterms must be a list of at most 20 strings.")
    if any(not isinstance(item, str) or len(item) > 50 for item in keyterms):
        return error_event(
            "invalid_keyterms",
            "Each keyterm must be a string of at most 50 characters.",
        )
    return None


def parse_client_text(raw: str) -> tuple[str, dict[str, Any] | None]:
    try:
        message = json.loads(raw)
    except json.JSONDecodeError:
        return "error", error_event("unsupported_event", UNSUPPORTED_EVENT_MESSAGE)
    if not isinstance(message, dict):
        return "error", error_event("unsupported_event", UNSUPPORTED_EVENT_MESSAGE)
    kind = message.get("type")
    if kind == "stt.start":
        invalid = validate_stt_start(message)
        return ("error", invalid) if invalid else ("stt.start", message)
    if kind in ("audio.done", "finalize"):
        return str(kind), None
    return "error", error_event("unsupported_event", UNSUPPORTED_EVENT_MESSAGE)


def connect_header_kwargs(api_key: str) -> dict[str, Any]:
    headers = {"Authorization": f"Bearer {api_key}"}
    kwargs: dict[str, Any] = {"logger": _upstream_logger}
    try:
        params = inspect.signature(websockets.connect).parameters
    except (TypeError, ValueError):
        params = {}
    if "additional_headers" in params:
        kwargs["additional_headers"] = headers
    elif "extra_headers" in params:
        kwargs["extra_headers"] = headers
    else:
        kwargs["additional_headers"] = headers
    return kwargs


@asynccontextmanager
async def connect_xai(url: str, api_key: str) -> AsyncIterator[Any]:
    kwargs = connect_header_kwargs(api_key)
    try:
        connection = websockets.connect(url, **kwargs)
    except TypeError:
        fallback = dict(kwargs)
        if "additional_headers" in fallback:
            fallback["extra_headers"] = fallback.pop("additional_headers")
        elif "extra_headers" in fallback:
            fallback["additional_headers"] = fallback.pop("extra_headers")
        connection = websockets.connect(url, **fallback)
    async with connection as socket:
        yield socket


async def wait_for_transcript_created(upstream: Any, timeout: float = CREATED_TIMEOUT_S) -> None:
    raw = await asyncio.wait_for(upstream.recv(), timeout=timeout)
    if not isinstance(raw, str):
        raise UpstreamSttError()
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        raise UpstreamSttError() from None
    if not isinstance(event, dict):
        raise UpstreamSttError()
    event_type = event.get("type")
    if event_type == "error":
        raise UpstreamSttError()
    if event_type != "transcript.created":
        raise UpstreamSttError()
