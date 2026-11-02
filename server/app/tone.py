"""Replaceable tone backends. Model-backed ones import torch only when selected."""

import os
from dataclasses import dataclass
from typing import Protocol

EMOTIONS = ("anger", "disgust", "fear", "happy", "neutral", "sad")


@dataclass(frozen=True)
class TonePrediction:
    tag: str | None
    probs: dict[str, float]
    model_version: str


class ToneBackend(Protocol):
    model_version: str

    async def predict(self, audio: bytes, sample_rate: int) -> TonePrediction:
        """Infer from PCM16 mono little-endian audio without persisting it."""
        ...


def no_probs() -> dict[str, float]:
    # Zero probabilities signal that no 6-class prediction was made.
    return dict.fromkeys(EMOTIONS, 0.0)


class MockToneBackend:
    model_version = "tone-stub-v1"

    async def predict(self, audio: bytes, sample_rate: int) -> TonePrediction:
        return TonePrediction(tag=None, probs=no_probs(), model_version=self.model_version)


@dataclass(frozen=True)
class AudeeringThresholds:
    """Arousal/valence rules tuned on team recordings in A4 (ml/tone/DISCUSSION_LOG.md)."""

    excited_arousal: float = 0.64
    excited_valence: float = 0.45
    upset_arousal: float = 0.47
    upset_valence: float = 0.40
    calm_arousal_low: float = 0.38
    calm_arousal_high: float = 0.48
    calm_valence: float = 0.45


A4_THRESHOLDS = AudeeringThresholds()


def map_tag(
    arousal: float, valence: float, thresholds: AudeeringThresholds = A4_THRESHOLDS
) -> str | None:
    """Map audEERING scores to a tag; None unless a rule clearly applies."""
    t = thresholds
    if arousal > t.excited_arousal and valence > t.excited_valence:
        return "excited"
    if arousal > t.upset_arousal and valence < t.upset_valence:
        return "upset"
    if t.calm_arousal_low < arousal < t.calm_arousal_high and valence > t.calm_valence:
        return "calm"
    return None


def create_backend(name: str | None = None) -> ToneBackend:
    """Pick the backend from TONE_BACKEND: mock (default) or audeering."""
    name = (name or os.getenv("TONE_BACKEND") or "mock").strip().lower()
    if name == "mock":
        return MockToneBackend()
    if name == "audeering":
        # Imported here so torch never loads unless this backend is chosen.
        from app.audeering import AudeeringToneBackend

        return AudeeringToneBackend()
    raise ValueError(f"Unknown TONE_BACKEND {name!r}; expected 'mock' or 'audeering'.")
