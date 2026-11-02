# P2 WAV replay client

Start P2 from the repository root in one terminal:

```bash
uv run --directory server python -m app
```

In another terminal, replay an uncompressed 16-bit PCM mono WAV ([sample](https://mauvecloud.net/sounds/pcm1608m.wav)):

```bash
uv run python scripts/replay_client.py /path/to/audio.wav
```

The client sends one-second chunks over a single WebSocket connection and prints
one JSON reply per chunk, including the final shorter chunk. It waits for each
reply before sending the next chunk; replay runs as fast as the server responds.
P2's mock backend returns `tone_result` with `tag: null`.

For a different server or chunk size:

```bash
uv run python scripts/replay_client.py /path/to/audio.wav \
  --url ws://127.0.0.1:8000/ws/session --chunk-seconds 0.5 --session-id demo
```

Use `wss://` for a remote server and set `TONE_TOKEN` in the client environment
when authentication is enabled. `--timeout` controls connection and per-reply
timeouts (default 30 seconds). Errors exit with a nonzero status.

Audio is read in chunks, without sending the WAV header or creating recordings.
The file's sample rate is sent unchanged; 16 kHz is recommended. Other bit depths,
stereo, and compressed WAV files must be converted first. Timestamps emulate a
phone session starting at zero using sample offsets. Keep recordings out of git.

# Tone accuracy evaluation

`eval_tone.py` runs a folder of labeled clips through the server's audEERING backend
(the same code as `TONE_BACKEND=audeering`) and prints accuracy, the wrong-tag rate,
missed tones, per-tag precision/recall, a confusion table, and mean arousal/valence per
label. Download the model first (see `server/README.md`).

Labels come from filenames: A4's prefixes (`excited_*`, `upset_*`, `calm_*`, `none_*` or
`neutral_*`) or CREMA-D names. Any soundfile format works (WAV, MP3, FLAC, OGG).

```bash
uv run python scripts/eval_tone.py path/to/clips --csv data/results.csv
```

For a public benchmark, download a CREMA-D sample (ODbL; acted speech) into the gitignored
`data/` folder. 20 actors is about 1,300 clips and 100 MB:

```bash
uv run python scripts/fetch_crema_d.py --actors 20
uv run python scripts/eval_tone.py data/crema-d --csv data/crema-d-results.csv
```

Only anger (upset), happy (excited), and neutral (none) are scored; sad, fear, and disgust
are reported but not scored, and CREMA-D has no calm. It is acted, so team recordings
remain the real test set. Keep clips and results out of git.
