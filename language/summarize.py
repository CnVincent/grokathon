"""Grok (xAI) catch-up summary benchmark. Never call this from the iOS app."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

WINDOW_SECONDS = 120
XAI_CHAT_URL = "https://api.x.ai/v1/chat/completions"
DEFAULT_MODEL = "grok-3-mini"
REQUEST_TIMEOUT_SECONDS = 20


@dataclass(frozen=True)
class CaptionLine:
    speaker: str
    text: str
    tone: str | None
    t_end: float


def lines_in_window(
    lines: list[CaptionLine], window_seconds: float = WINDOW_SECONDS
) -> list[CaptionLine]:
    """Keep lines whose t_end is within window_seconds of the newest t_end. Empty in, empty out."""
    if not lines:
        return []
    newest = max(line.t_end for line in lines)
    cutoff = newest - window_seconds
    return [line for line in lines if line.t_end >= cutoff]


def summary_prompt(lines: list[CaptionLine]) -> str:
    """Ask for 2-4 short sentences for a Deaf user who looked away."""
    instructions = (
        "Write 2-4 short sentences that catch a Deaf or hard-of-hearing user up after they "
        "looked away. Name speakers. Include tone tags when they are present. Do not invent "
        "facts. If nothing was said, say nothing was said in the last two minutes."
    )
    if not lines:
        captions = "(nothing was said)"
    else:
        rendered: list[str] = []
        for line in lines:
            tone = f" [tone: {line.tone}]" if line.tone else ""
            rendered.append(f"{line.speaker}: {line.text}{tone}")
        captions = "\n".join(rendered)
    return f"{instructions}\n\nCaptions:\n{captions}"


class SummaryBackend(Protocol):
    model_version: str

    def summarize(self, lines: list[CaptionLine]) -> str: ...


class MockSummaryBackend:
    model_version = "summary-stub-v1"

    def summarize(self, lines: list[CaptionLine]) -> str:
        windowed = lines_in_window(lines)
        if not windowed:
            return "Nothing was said in the last two minutes."
        parts: list[str] = []
        for line in windowed:
            if line.tone:
                parts.append(f"{line.speaker}: {line.text} [{line.tone}]")
            else:
                parts.append(f"{line.speaker}: {line.text}")
        return "Last two minutes: " + "; ".join(parts)


class GrokSummaryBackend:
    """POST chat completions to xAI. Inject urlopen so tests never hit the network."""

    def __init__(
        self,
        *,
        api_key: str | None = None,
        model: str | None = None,
        urlopen: Callable[..., Any] | None = None,
    ) -> None:
        self._api_key = api_key
        self._model = model if model is not None else os.environ.get(
            "XAI_SUMMARY_MODEL", DEFAULT_MODEL
        )
        self._urlopen = urlopen or urllib.request.urlopen
        self.model_version = self._model

    def summarize(self, lines: list[CaptionLine]) -> str:
        api_key = self._api_key if self._api_key is not None else os.environ.get("XAI_API_KEY")
        if not api_key:
            raise RuntimeError(
                "XAI_API_KEY is missing. Set it in the repo-root .env; never call this from iOS."
            )
        windowed = lines_in_window(lines)
        payload = {
            "model": self._model,
            "temperature": 0,
            "messages": [{"role": "user", "content": summary_prompt(windowed)}],
        }
        request = urllib.request.Request(
            XAI_CHAT_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        raw = _read_urlopen(self._urlopen, request, timeout=REQUEST_TIMEOUT_SECONDS)
        return _content_from_response(raw)


def load_lines(path: Path) -> list[CaptionLine]:
    """JSON list of objects with speaker, text, optional tone, t_end."""
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise RuntimeError(f"expected a JSON list of caption objects in {path}")
    lines: list[CaptionLine] = []
    for item in data:
        if not isinstance(item, dict):
            raise RuntimeError(f"expected caption objects in {path}, got {item!r}")
        lines.append(
            CaptionLine(
                speaker=str(item["speaker"]),
                text=str(item["text"]),
                tone=item.get("tone"),
                t_end=float(item["t_end"]),
            )
        )
    return lines


def main(argv: list[str] | None = None) -> int:
    """CLI: python -m language.summarize path.json [--mock]"""
    parser = argparse.ArgumentParser(
        prog="language.summarize",
        description="Summarize a caption log with Grok (or --mock). Never call from iOS.",
    )
    parser.add_argument("path", type=Path, help="JSON caption log")
    parser.add_argument(
        "--mock",
        action="store_true",
        help="Use MockSummaryBackend instead of Grok",
    )
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        code = exc.code
        if code is None or code == 0:
            return 0
        return 2 if code != 2 else code

    _load_dotenv()
    path = args.path
    if not path.is_file():
        print(f"caption log not found: {path}", file=sys.stderr)
        return 2
    lines = load_lines(path)
    backend: SummaryBackend
    if args.mock:
        backend = MockSummaryBackend()
    else:
        backend = GrokSummaryBackend()
    print(backend.summarize(lines))
    return 0


def _load_dotenv() -> None:
    """Load KEY=VALUE from .env without overriding existing env vars. Stdlib only."""
    candidates = [Path.cwd() / ".env", Path(__file__).resolve().parents[1] / ".env"]
    seen: set[Path] = set()
    for path in candidates:
        resolved = path.resolve()
        if resolved in seen or not resolved.is_file():
            continue
        seen.add(resolved)
        for raw_line in resolved.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
                value = value[1:-1]
            os.environ.setdefault(key, value)


def _read_urlopen(
    urlopen: Callable[..., Any],
    request: urllib.request.Request,
    timeout: float,
) -> bytes:
    try:
        response = urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"xAI HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"xAI request failed: {exc.reason}") from exc
    except Exception as exc:
        raise RuntimeError(f"xAI request failed: {exc}") from exc

    if hasattr(response, "__enter__"):
        with response as opened:
            return opened.read()
    return response.read()


def _content_from_response(raw: bytes) -> str:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"xAI response was not JSON: {exc}") from exc
    try:
        content = payload["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(
            "unexpected xAI response: missing choices[0].message.content"
        ) from exc
    if not isinstance(content, str):
        raise RuntimeError("unexpected xAI response: content is not a string")
    return content


if __name__ == "__main__":
    raise SystemExit(main())
