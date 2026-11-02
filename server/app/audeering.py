"""audEERING arousal/valence baseline (TONE_BACKEND=audeering). Audio stays in memory.

The model classes mirror ml/tone/baseline.py (A4) so the checkpoint loads without
missing-weight warnings. torch, transformers, and scipy come from the uv workspace
(graption-ml); they are not graption-server dependencies.
"""

import asyncio
import threading

import numpy as np
import torch
import torch.nn as nn
from scipy.signal import resample_poly
from transformers import Wav2Vec2FeatureExtractor
from transformers.models.wav2vec2.modeling_wav2vec2 import (
    Wav2Vec2Model,
    Wav2Vec2PreTrainedModel,
)

from app.tone import A4_THRESHOLDS, AudeeringThresholds, TonePrediction, map_tag, no_probs

MODEL_NAME = "audeering/wav2vec2-large-robust-12-ft-emotion-msp-dim"
SAMPLE_RATE = 16_000
# Shorter clips carry too little speech to judge; a wrong tag is worse than none.
MIN_SECONDS = 0.5


class RegressionHead(nn.Module):
    def __init__(self, config):
        super().__init__()
        self.dense = nn.Linear(config.hidden_size, config.hidden_size)
        self.dropout = nn.Dropout(config.final_dropout)
        self.out_proj = nn.Linear(config.hidden_size, config.num_labels)

    def forward(self, features):
        x = self.dropout(features)
        x = torch.tanh(self.dense(x))
        x = self.dropout(x)
        return self.out_proj(x)


class EmotionModel(Wav2Vec2PreTrainedModel):
    def __init__(self, config):
        super().__init__(config)
        self.wav2vec2 = Wav2Vec2Model(config)
        self.classifier = RegressionHead(config)
        self.post_init()

    def forward(self, input_values):
        hidden_states = self.wav2vec2(input_values)[0].mean(dim=1)
        return self.classifier(hidden_states)


def pick_device() -> torch.device:
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def decode_pcm16(audio: bytes, sample_rate: int) -> np.ndarray:
    samples = np.frombuffer(audio, dtype="<i2").astype(np.float32) / 32768.0
    if sample_rate != SAMPLE_RATE:
        samples = resample_poly(samples, SAMPLE_RATE, sample_rate).astype(np.float32)
    return samples


class AudeeringToneBackend:
    model_version = "audeering-msp-dim-a4"

    def __init__(self, thresholds: AudeeringThresholds = A4_THRESHOLDS) -> None:
        try:
            self.extractor = Wav2Vec2FeatureExtractor.from_pretrained(
                MODEL_NAME, local_files_only=True
            )
            model = EmotionModel.from_pretrained(MODEL_NAME, local_files_only=True)
        except OSError as error:
            raise RuntimeError(
                f"{MODEL_NAME} is not downloaded. Run: uv run hf download {MODEL_NAME}"
            ) from error
        self.device = pick_device()
        self.model = model.to(self.device).eval()
        self.thresholds = thresholds
        # One inference at a time: the model is shared across connections.
        self.lock = threading.Lock()

    async def predict(self, audio: bytes, sample_rate: int) -> TonePrediction:
        # Off the event loop so other connections keep being served.
        tag = await asyncio.to_thread(self.infer_tag, audio, sample_rate)
        return TonePrediction(tag=tag, probs=no_probs(), model_version=self.model_version)

    def infer_tag(self, audio: bytes, sample_rate: int) -> str | None:
        arousal, valence = self.scores(audio, sample_rate)
        if arousal is None:
            return None
        return map_tag(arousal, valence, self.thresholds)

    def scores(self, audio: bytes, sample_rate: int) -> tuple[float | None, float | None]:
        """Return (arousal, valence) in about [0, 1], or (None, None) for too-short audio."""
        if len(audio) // 2 < MIN_SECONDS * sample_rate:
            return None, None
        samples = decode_pcm16(audio, sample_rate)
        inputs = self.extractor(samples, sampling_rate=SAMPLE_RATE, return_tensors="pt")
        with self.lock, torch.no_grad():
            outputs = self.model(inputs.input_values.to(self.device))
        # The checkpoint's output order is arousal, dominance, valence.
        arousal, _dominance, valence = outputs[0].tolist()
        return arousal, valence
