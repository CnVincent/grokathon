"""Grok summary benchmark tests. No network."""

import json
from pathlib import Path

import pytest

from language.summarize import (
    DEFAULT_MODEL,
    WINDOW_SECONDS,
    CaptionLine,
    GrokSummaryBackend,
    MockSummaryBackend,
    lines_in_window,
    load_lines,
    summary_prompt,
)

FIXTURE = Path(__file__).resolve().parents[1] / "fixtures" / "sample_captions.json"


def test_lines_in_window_drops_older_and_keeps_edge() -> None:
    newest = 200.0
    lines = [
        CaptionLine("Alex", "too old", None, newest - WINDOW_SECONDS - 0.01),
        CaptionLine("Jordan", "exactly 120s back", "calm", newest - WINDOW_SECONDS),
        CaptionLine("Alex", "newest", None, newest),
    ]
    kept = lines_in_window(lines)
    assert kept == lines[1:]
    assert lines_in_window([]) == []


def test_mock_summary_is_stable_and_includes_tone() -> None:
    backend = MockSummaryBackend()
    assert backend.model_version == "summary-stub-v1"
    assert backend.summarize([]) == "Nothing was said in the last two minutes."
    lines = [
        CaptionLine("Alex", "We should start.", "calm", 10.0),
        CaptionLine("Jordan", "Agreed.", None, 12.0),
    ]
    assert (
        backend.summarize(lines)
        == "Last two minutes: Alex: We should start. [calm]; Jordan: Agreed."
    )


def test_grok_backend_sends_bearer_model_and_prompt(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("XAI_SUMMARY_MODEL", raising=False)
    captured: dict[str, object] = {}

    class FakeResponse:
        def read(self) -> bytes:
            return json.dumps(
                {"choices": [{"message": {"content": "Alex started the agenda."}}]}
            ).encode()

        def __enter__(self):
            return self

        def __exit__(self, *args: object) -> None:
            return None

    def fake_urlopen(request: object, timeout: object = None) -> FakeResponse:
        captured["request"] = request
        captured["timeout"] = timeout
        return FakeResponse()

    lines = [
        CaptionLine("Alex", "We should start with the agenda.", "calm", 12.5),
        CaptionLine("Jordan", "Sounds good.", None, 18.0),
    ]
    backend = GrokSummaryBackend(api_key="test-key", urlopen=fake_urlopen)
    assert backend.model_version == DEFAULT_MODEL
    assert backend.summarize(lines) == "Alex started the agenda."

    request = captured["request"]
    assert captured["timeout"] == 20
    assert request.full_url == "https://api.x.ai/v1/chat/completions"
    headers = {key.lower(): value for key, value in request.header_items()}
    assert headers["authorization"] == "Bearer test-key"
    body = json.loads(request.data.decode())
    assert body["model"] == "grok-3-mini"
    assert body["temperature"] == 0
    assert body["messages"] == [{"role": "user", "content": summary_prompt(lines)}]


def test_missing_api_key_raises_and_skips_transport(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("XAI_API_KEY", raising=False)
    calls: list[object] = []

    def fake_urlopen(*args: object, **kwargs: object) -> None:
        calls.append((args, kwargs))
        raise AssertionError("transport should not be called")

    backend = GrokSummaryBackend(urlopen=fake_urlopen)
    with pytest.raises(RuntimeError, match="XAI_API_KEY"):
        backend.summarize([CaptionLine("Alex", "Hi", None, 1.0)])
    assert calls == []


def test_load_lines_reads_fixture() -> None:
    lines = load_lines(FIXTURE)
    assert lines[0] == CaptionLine(
        speaker="Alex",
        text="We should start with the agenda.",
        tone="calm",
        t_end=12.5,
    )
    assert lines[1].speaker == "Jordan"
    assert lines[1].tone is None
    assert lines[1].t_end == 18.0
    assert len(lines) == 3
