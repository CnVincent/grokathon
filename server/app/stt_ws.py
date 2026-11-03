"""Optional online-caption WebSocket. Same handshake auth as /ws/session; never logs audio."""

from __future__ import annotations

import asyncio
import json
import logging
import os
from contextlib import suppress
from hmac import compare_digest

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from app.stt import (
    CREATED_TIMEOUT_S,
    INVALID_PCM16_MESSAGE,
    MOCK_MODEL_VERSION,
    UPSTREAM_ERROR_MESSAGE,
    UPSTREAM_TIMEOUT_MESSAGE,
    XAI_MODEL_VERSION,
    UpstreamSttError,
    build_xai_url,
    connect_xai,
    error_event,
    keyterms_from_start,
    map_upstream_event,
    mock_done,
    mock_partial,
    parse_client_text,
    ready_event,
    selected_stt_backend,
    unavailable_event,
    wait_for_transcript_created,
    xai_api_key,
)

router = APIRouter()
logger = logging.getLogger("graption.server")


def _handshake_rejected(websocket: WebSocket) -> bool:
    token = os.getenv("TONE_TOKEN", "")
    mode = os.getenv("DEPLOY_MODE", "local")
    authorization = websocket.headers.get("authorization", "")
    return (mode != "local" and not token) or (
        token and not compare_digest(authorization.encode(), f"Bearer {token}".encode())
    )


def _log_code(code: str) -> None:
    logger.warning("stt_error", extra={"event": "stt_error", "metadata": {"code": code}})


async def _send(websocket: WebSocket, payload: dict[str, object]) -> None:
    await websocket.send_text(json.dumps(payload))


async def _close(websocket: WebSocket, code: int) -> None:
    with suppress(Exception):
        await websocket.close(code=code)


@router.websocket("/ws/stt")
async def stt_session(websocket: WebSocket, session_id: str = Query(min_length=1)) -> None:
    if _handshake_rejected(websocket):
        _log_code("authentication")
        await websocket.close(code=1008)
        return

    await websocket.accept()
    backend = selected_stt_backend()
    try:
        if backend == "mock":
            await _run_mock(websocket, session_id)
            return
        if backend == "xai":
            await _run_xai(websocket, session_id)
            return
        _log_code("stt_unavailable")
        await _send(websocket, unavailable_event())
        await _close(websocket, 1008)
    except WebSocketDisconnect:
        return
    except Exception:
        _log_code("internal_error")
        await _close(websocket, 1011)


async def _run_mock(websocket: WebSocket, session_id: str) -> None:
    await _send(websocket, ready_event(session_id, MOCK_MODEL_VERSION))
    while True:
        kind, payload = await _next_phone_event(websocket)
        if kind == "disconnect":
            return
        if kind == "error":
            assert payload is not None
            _log_code(str(payload["code"]))
            await _send(websocket, payload)
            continue
        if kind == "stt.start":
            continue
        if kind == "pcm":
            if payload is not None:
                payload.clear()
            await _send(
                websocket,
                mock_partial(is_final=False, speech_final=False, language="hi"),
            )
            continue
        if kind == "audio.done":
            await _send(websocket, mock_done())
            continue
        if kind == "finalize":
            await _send(
                websocket,
                mock_partial(is_final=True, speech_final=True, language="en"),
            )


async def _run_xai(websocket: WebSocket, session_id: str) -> None:
    api_key = xai_api_key()
    if not api_key:
        _log_code("stt_unavailable")
        await _send(websocket, unavailable_event())
        await _close(websocket, 1008)
        return

    send_lock = asyncio.Lock()
    try:
        keyterms, replay = await _take_leading_start(websocket)
        async with connect_xai(build_xai_url(keyterms=keyterms), api_key) as upstream:
            try:
                await wait_for_transcript_created(upstream, timeout=CREATED_TIMEOUT_S)
            except TimeoutError:
                _log_code("upstream_error")
                await _send(websocket, error_event("upstream_error", UPSTREAM_TIMEOUT_MESSAGE))
                await _close(websocket, 1011)
                return
            except UpstreamSttError as error:
                _log_code("upstream_error")
                await _send(websocket, error_event("upstream_error", error.message))
                await _close(websocket, 1011)
                return

            await _send(websocket, ready_event(session_id, XAI_MODEL_VERSION))
            if replay is not None:
                await _forward_phone_event(websocket, upstream, send_lock, replay[0], replay[1])
            phone_task = asyncio.create_task(
                _pump_phone(websocket, upstream, send_lock), name="stt-phone"
            )
            upstream_task = asyncio.create_task(
                _pump_upstream(websocket, upstream, send_lock), name="stt-upstream"
            )
            done, pending = await asyncio.wait(
                {phone_task, upstream_task}, return_when=asyncio.FIRST_COMPLETED
            )
            for task in pending:
                task.cancel()
            for task in pending:
                try:
                    await task
                except asyncio.CancelledError:
                    pass
            for task in done:
                if task.cancelled():
                    continue
                exc = task.exception()
                if exc is None or isinstance(exc, WebSocketDisconnect):
                    continue
                _log_code("upstream_error")
                async with send_lock:
                    with suppress(Exception):
                        await _send(
                            websocket, error_event("upstream_error", UPSTREAM_ERROR_MESSAGE)
                        )
                await _close(websocket, 1011)
                return
    except WebSocketDisconnect:
        return
    except Exception:
        _log_code("upstream_error")
        with suppress(Exception):
            await _send(websocket, error_event("upstream_error", UPSTREAM_ERROR_MESSAGE))
        await _close(websocket, 1011)


async def _next_phone_event(websocket: WebSocket) -> tuple[str, dict[str, object] | None]:
    frame = await websocket.receive()
    if frame["type"] == "websocket.disconnect":
        return "disconnect", None
    if "bytes" in frame:
        pcm = frame["bytes"]
        if len(pcm) % 2:
            return "error", error_event("invalid_pcm16_length", INVALID_PCM16_MESSAGE)
        return "pcm", {"pcm": pcm}
    raw = frame.get("text", "")
    kind, payload = parse_client_text(raw)
    if kind == "error":
        return "error", payload
    if kind == "stt.start":
        return "stt.start", payload
    return kind, None


async def _take_leading_start(
    websocket: WebSocket,
) -> tuple[list[str], tuple[str, dict[str, object] | None] | None]:
    """Use an initial stt.start for upstream keyterms. Replay any other first frame."""
    kind, payload = await _next_phone_event(websocket)
    if kind == "disconnect":
        raise WebSocketDisconnect
    if kind == "error":
        assert payload is not None
        _log_code(str(payload["code"]))
        await _send(websocket, payload)
        return [], None
    if kind == "stt.start" and isinstance(payload, dict):
        return keyterms_from_start(payload), None
    return [], (kind, payload)


async def _forward_phone_event(
    websocket: WebSocket,
    upstream: object,
    send_lock: asyncio.Lock,
    kind: str,
    payload: dict[str, object] | None,
) -> None:
    if kind == "error":
        assert payload is not None
        _log_code(str(payload["code"]))
        async with send_lock:
            await _send(websocket, payload)
        return
    if kind == "stt.start":
        return
    if kind == "pcm":
        assert payload is not None
        pcm = payload.get("pcm")
        if isinstance(pcm, bytes | bytearray):
            await upstream.send(bytes(pcm))
        payload.clear()
        return
    if kind in ("audio.done", "finalize"):
        await upstream.send(json.dumps({"type": kind}))


async def _pump_phone(websocket: WebSocket, upstream: object, send_lock: asyncio.Lock) -> None:
    while True:
        kind, payload = await _next_phone_event(websocket)
        if kind == "disconnect":
            return
        await _forward_phone_event(websocket, upstream, send_lock, kind, payload)


async def _pump_upstream(websocket: WebSocket, upstream: object, send_lock: asyncio.Lock) -> None:
    async for message in upstream:
        if not isinstance(message, str):
            continue
        try:
            event = json.loads(message)
        except json.JSONDecodeError:
            _log_code("upstream_error")
            async with send_lock:
                await _send(websocket, error_event("upstream_error", UPSTREAM_ERROR_MESSAGE))
            return
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        if not isinstance(event_type, str):
            continue
        mapped = map_upstream_event(event)
        if mapped is None:
            continue
        async with send_lock:
            await _send(websocket, mapped)
        if event_type in ("transcript.done", "error"):
            if event_type == "error":
                _log_code("upstream_error")
            return
