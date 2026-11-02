#Reusable model-loading, audio preprocessing, and prediction logic
#abc defines the interface that all tone backends must follow
#time measures latency in the backend predictions
#Path handles audio file paths cleanly (can be removed if proven unnecessary)
#Numpy is used to convert and process audio files
#torch loads and runs the NN
#Scipy resample audio when sample rate differs from 16,000 Hz
#Wav2Vec2Model prepares raw audio for the model
#Wav2Vec2PreTrainedModel provides the HuggingFace base class which our architecture builds on

import time
from abc import ABC, abstractmethod

import numpy as np
import torch
import torch.nn as nn
from scipy.signal import resample_poly
from transformers import Wav2Vec2Processor
from transformers.models.wav2vec2.modeling_wav2vec2 import (
    Wav2Vec2Model,
    Wav2Vec2PreTrainedModel,
)

MODEL_NAME = "audeering/wav2vec2-large-robust-12-ft-emotion-msp-dim"

#Thresholds used to map model scores to tone labels
EXCITED_AROUSAL_THRESHOLD = 0.64
EXCITED_VALENCE_THRESHOLD = 0.45
UPSET_AROUSAL_THRESHOLD = 0.47
UPSET_VALENCE_THRESHOLD = 0.4
CALM_AROUSAL_MIN = 0.38
CALM_AROUSAL_MAX = 0.48
CALM_VALENCE_THRESHOLD = 0.45

#maps model's arousal and valence scores into "excited", "upset", "calm", or None
def map_tag(arousal: float, valence: float) -> str | None:
    if (
        arousal > EXCITED_AROUSAL_THRESHOLD
        and valence > EXCITED_VALENCE_THRESHOLD
    ):
        return "excited"
    elif (
        arousal > UPSET_AROUSAL_THRESHOLD
        and valence < UPSET_VALENCE_THRESHOLD
    ):
        return "upset"
    elif (
        CALM_AROUSAL_MIN < arousal < CALM_AROUSAL_MAX
        and valence > CALM_VALENCE_THRESHOLD
    ):
        return "calm"

    return None

class ToneBackend(ABC):
    """Interface for tone backends."""

    @abstractmethod
    #Abstract method for predicting tone from audio input.
    #self: the instance of the ToneBackend class.
    #audio: the audio input to be analyzed.
    #sample_rate: the sample rate of the audio input.
    #returns: the predicted tone result.
    def predict(self, audio, sample_rate):
        """Predict tone from the audio and return the result."""
        pass

#Purpose: test rest of the code without loading in the real AI model
class MockToneBackend(ToneBackend):
    """Backend for testing without loading a real model"""

    #Constructor for the MockToneBackend class.
    #self: the instance of the MockToneBackend class.
    #tag: an optional tag to identify the backend instance.
    #returns: None
    def __init__(self, tag: str | None = None) -> None:
        self.tag = tag

    #Implements ToneBackend's abstract predict method
    #Accepts audio and sample rate (akin to real model)
    #Mock isn't analyzing audio, so labeled as "None"
    #Latency is set to 0.0 for the mock backend because no model inference time
    def predict(self, audio, sample_rate):
        return {
            "tag": self.tag,
            "arousal": None,
            "valence": None,
            "dominance": None,
            "model_version": "mock",
            "latency_ms": 0.0,
        }

class AudeeringBackend(ToneBackend):
    """Tone prediction backend using the audEERING model"""
    #constructor for the AudeeringBackend class
    #device-selection code
    def _select_device(self) -> torch.device:
        """Select the best available inference device."""
        # Check if NVIDIA GPU acceleration is available
        if torch.cuda.is_available():
            return torch.device("cuda")

        # Check if Apple's Metal Performance Shaders is available
        if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            return torch.device("mps")

        # Fall back to CPU
        return torch.device("cpu")


    #Creating the backend loads the model once and multiple audio clips can reuse to save memory
    def __init__(self) -> None:
        self.device = self._select_device()
        self.processor = Wav2Vec2Processor.from_pretrained(MODEL_NAME) #handles formatting
        self.model = EmotionModel.from_pretrained(MODEL_NAME)
        #Moves the model to the selected device
        self.model.to(self.device)
        self.model.eval()

    #Internal helper method that handles audio preprocessing to ensure format compliance
    def _prepare_audio(self, audio, sample_rate: int):
        #converts the input into a NumPy array of a 32-bit floating point numbers
        audio = np.asarray(audio, dtype=np.float32)

        #Convert stereo audio to mono when needed
        if audio.ndim == 2:
            audio = audio.mean(axis=1)
        #Resample audio to 16,000 Hz rate expected by the model
        if sample_rate != 16000:
            audio = resample_poly(audio, 16000, sample_rate)
            sample_rate = 16000
        return audio, sample_rate

    #Internal helper methethod that handles audio conversion
    def predict(self, audio, sample_rate: int) -> dict:
        audio, sample_rate = self._prepare_audio(audio, sample_rate)

        #Converts audio array into the input representation expected by Wav2Vec2
        inputs = self.processor (
            audio,
            sampling_rate=sample_rate,
            return_tensors="pt",
            padding=True,
        )

        #Move input tensor to the same device as the model; else device mismatch error
        input_values = inputs.input_values.to(self.device)

        #Measure the model's inference time
        start = time.perf_counter()

        #we disregard hidden features and only retain scores
        with torch.inference_mode():
            _, outputs = self.model(input_values)
        latency_ms = (time.perf_counter() - start) * 1000

        arousal, dominance, valence = outputs[0].tolist()
        tag = map_tag(arousal, valence)

        return {
            "tag": tag,
            "arousal": arousal,
            "valence": valence,
            "dominance": dominance,
            "model_version": MODEL_NAME,
            "latency_ms": latency_ms,
        }

#NN head used by the audEERING model
#outputs three values: arousal, dominance, and valence
class RegressionHead(nn.Module):
    def __init__(self, config):
        super().__init__()
        #Linear Layer #1 transforms the Wav2Vec2 representation
        self.dense = nn.Linear(config.hidden_size, config.hidden_size)
        #dropout reduces unnecessary dependence on the individual features
        self.dropout = nn.Dropout(config.final_dropout)
        #Final Linear Layer produces the three emotion dimensions
        self.out_proj = nn.Linear(config.hidden_size, config.num_labels)

    def forward(self, features):
        #dropout for the input features
        x = self.dropout(features)
        #pass the features through Linear Layer #1
        x = self.dense(x)
        #tanh activation function
        #This recreates the architecture from the pretrained audEERING model,
        # #which provides the weights used by this implementation
        x = torch.tanh(x)
        #dropout applied again before the Final Linear Layer
        x = self.dropout(x)
        #Produce the model's three output values
        return self.out_proj(x)

#Systems Architecture Part 2: emotional model
#inherit Hugging Face's pre-trained model infrastructure
#returns the pooled hidden features + 3 regression score
#maintains the architecture expected by the pretrained audEERING checkpoint
class EmotionModel(Wav2Vec2PreTrainedModel):
    """Wav2Vec2 model with the audEERING regression head for emotion prediction."""

    def __init__(self, config):
        super().__init__(config)
        # Load the Wav2Vec2 audio model
        self.wav2vec2 = Wav2Vec2Model(config)
        # Attach the pretrained audEERING regression head (names must match)
        self.classifier = RegressionHead(config)
        # Initialize the model structure before loading pretrained weights
        self.post_init()

    def forward(self, input_values):
        # Send the processed audio through Wav2Vec2
        outputs = self.wav2vec2(input_values)
        # Get the hidden representation produced by Wav2Vec2
        hidden_states = outputs[0]
        # Average the hidden states across the time dimension
        hidden_states = torch.mean(hidden_states, dim=1)
        # Use the regression head to produce emotion scores
        logits = self.classifier(hidden_states)
        return hidden_states, logits
