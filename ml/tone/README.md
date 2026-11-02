# ml/tone: tone model (Audio team)

The tone model assigns tone tags to speech recordings. The project includes a custom 6-class emotion model (anger, disgust, fear, happy, neutral, sad) and an audEERING baseline that predicts arousal, valence, and dominance. Spec: `docs/GRAPTION_CONTEXT.md` §7, §9.

## Project Context
The custom model utilizes 6 emotion classes: anger, disgust, fear, happy, neutral, and sad
The planned training pipeline uses CREMA-D with an actor disjoint 70/15/15 split and a fixed seed.
We will use team recordings as the real test set
The custom model must match or outperform the audEERING baseline before replacing it on the server in server/app/tone.py
Audio data and model weights are not going to be committed to Git.
Added project dependencies using uv add --package graption-ml <package>

## Audio Filename Format
Audio filenames must follow the label_speaker_NN convention, where:
- label is the intended tone category
- speaker identifies the speaker
- NN is the numeric clip identifier

## Run the Baseline
Run the following command from the repository root:
uv run python -m ml.tone.baseline ml/tone/test_audio --out ml/tone/results.csv

Replace ml/tone/test_audio with the path to your audio folder. The --out argument specifies where the results CSV will be saved.

The script loads the model, warms it up using one audio clip, processes the supported recordings, and writes the results to the specified CSV file.

## Audio Preprocessing
The baseline converts stereo audio to mono and resamples audio to 16 kHz when necessary. The processed audio is used for inference without saving modified audio files to disk

## CSV Output
File - Original audio filename
Speaker - Speaker identifier extracted from the filename
label - intended category extracted from the filename
arousal - predicted arousal score
valence - predicted valence score
dominance - predicted dominance score
tag - predicted tone tag including excited, upset, calm or no tag
latency_ms - model inference latency in milliseconds

When no tag meets the configured threshold, the backend returns None in Python which is represented as an empty field in the CSV

## Tone Tag Thresholds
The baseline maps arousal and valence scores to tone tags using the thresholds defined in ml/tone/backend.py
- Excited: arousal > 0.64 and valence > 0.45
- Upset: arousal > 0.47 and valence < 0.4
- Calm: 0.38 < arousal < 0.48 and valence > 0.45
- No Tag: none of the conditions above are met

Note: these thresholds should be evaluated against human-reviewed recordings

## A4.1 Backend and Schema
The reusable tone backend is implemented in ml/tone/backend.py. It provides a common prediction interface, an audEERING implementation, and a mock implementation for testing

The event schema in schemas/events.schema.json is version 1.2. Tone results can represent the custom model's six emotion probabilities through probs or audEERING's three emotion dimensions through scores containing arousal, valence, and dominance

## Verification
From the repo root run the test suite and lint checks:
uv run pytest
uv run ruff check .

To generate baseline results for a folder of recordings, run the baseline as aforementioned

Note that model weights and audio recordings are not included in the repo. Make sure to provide your own permitted test recordings when reproducing.
