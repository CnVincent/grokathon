"""Optional 'what did I miss?' summaries. Never log caption text or the summary body."""

import json
import os
import urllib.request
from hmac import compare_digest
from typing import Protocol

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

WINDOW_SECONDS = 120
GROK_URL = "https://api.x.ai/v1/chat/completions"
GROK_PROMPT = (
    "Write 2-4 short sentences for a Deaf user who looked away. Name speakers. "
    "Include tone tags when present. Do not invent facts. If nothing was said, "
    "say nothing was said in the last two minutes."
)


class CaptionLine(BaseModel):
    speaker: str
    text: str = Field(max_length=500)
    tone: str | None = None
    t_end: float


class SummaryRequest(BaseModel):
    lines: list[CaptionLine] = Field(max_length=40)


class SummaryResponse(BaseModel):
    summary: str
    model_version: str
    window_seconds: int = WINDOW_SECONDS


class SummaryBackend(Protocol):
    model_version: str

    def summarize(self, lines: list[CaptionLine]) -> str:
        """Return a short recap of windowed caption lines. Never persist them."""
        ...


class MockSummaryBackend:
    model_version = "summary-stub-v1"

    def summarize(self, lines: list[CaptionLine]) -> str:
        if not lines:
            return "Nothing was said in the last two minutes."
        parts = []
        for line in lines:
            part = f"{line.speaker}: {line.text}"
            if line.tone:
                part += f" [{line.tone}]"
            parts.append(part)
        return "Last two minutes: " + "; ".join(parts)


class GrokSummaryBackend:
    def __init__(self, api_key: str, model: str, opener=None) -> None:
        self.api_key = api_key
        self.model_version = model
        self.opener = opener or urllib.request.urlopen

    def summarize(self, lines: list[CaptionLine]) -> str:
        payload = {
            "model": self.model_version,
            "temperature": 0,
            "messages": [{"role": "user", "content": _user_message(lines)}],
        }
        request = urllib.request.Request(
            GROK_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with self.opener(request, timeout=20) as response:
            body = json.loads(response.read().decode("utf-8"))
        return body["choices"][0]["message"]["content"]


def _user_message(lines: list[CaptionLine]) -> str:
    if not lines:
        captions = "(none)"
    else:
        rendered = []
        for line in lines:
            part = f"{line.speaker}: {line.text}"
            if line.tone:
                part += f" [{line.tone}]"
            rendered.append(part)
        captions = "\n".join(rendered)
    return f"{GROK_PROMPT}\n\nCaptions:\n{captions}"


def lines_in_window(lines: list[CaptionLine]) -> list[CaptionLine]:
    if not lines:
        return []
    newest = max(line.t_end for line in lines)
    cutoff = newest - WINDOW_SECONDS
    return [line for line in lines if line.t_end >= cutoff]


def create_summary_backend(name: str | None = None) -> SummaryBackend | None:
    """Pick the backend from SUMMARY_BACKEND: mock (default) or grok. None if unavailable."""
    name = (name or os.getenv("SUMMARY_BACKEND") or "mock").strip().lower()
    if name == "mock":
        return MockSummaryBackend()
    if name == "grok":
        api_key = (os.getenv("XAI_API_KEY") or "").strip()
        if not api_key:
            return None
        model = (os.getenv("XAI_SUMMARY_MODEL") or "grok-3-mini").strip() or "grok-3-mini"
        return GrokSummaryBackend(api_key=api_key, model=model)
    return None


def _authorize(request: Request) -> None:
    token = os.getenv("TONE_TOKEN", "")
    mode = os.getenv("DEPLOY_MODE", "local")
    authorization = request.headers.get("authorization", "")
    if (mode != "local" and not token) or (
        token and not compare_digest(authorization.encode(), f"Bearer {token}".encode())
    ):
        raise HTTPException(status_code=401)


router = APIRouter()


@router.post("/summary", response_model=SummaryResponse)
def post_summary(request: Request, body: SummaryRequest) -> SummaryResponse:
    _authorize(request)
    backend: SummaryBackend | None = request.app.state.summary_backend
    if backend is None:
        raise HTTPException(status_code=503, detail="summary_unavailable")
    try:
        summary = backend.summarize(lines_in_window(body.lines))
    except Exception:
        raise HTTPException(status_code=503, detail="summary_unavailable") from None
    return SummaryResponse(summary=summary, model_version=backend.model_version)
