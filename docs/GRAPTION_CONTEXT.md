# Graption: Implementation Context

> Source of truth for anyone (human or agent) implementing Graption's semester-one MVP.
> If code and this doc disagree, raise it; don't silently diverge.

---

## 1. What we're building

Graption is a real-time accessibility app for Deaf and hard-of-hearing (DHH) users. Point an iPhone at a conversation and get **live captions that show who is speaking, how they sound (tone), and important non-speech sounds** (doorbell, alarm, siren).

Example output:
> **Sarah** 😃 *excited*: "Did someone ring the doorbell?!"   🔔 **Doorbell**

**Semester-one goal:** a working, development-only MVP with two custom-trained ML models. The architecture separates sensors, models, and UI with timestamped events so a wearable (smart glasses) can replace the iPhone camera later.

### Hard constraints
- **Minimal budget.** Requested: Apple Developer Program ($99), OpenAI API credits ($50), cloud credits ($100). Build everything so it works **without** them; they only unlock user testing and benchmarking.
- **Dev-first.** The core is a local dev setup. The only cloud piece is an optional hosted tone server for remote user testing.
- **iOS only.** No Android.
- **Training compute:** the team's M-series Macs (PyTorch on `mps`). Training is never part of the live app.
- **Live inference:** the iPhone, plus one M-series MacBook on the same Wi-Fi (tone model only).
- **Offline requirement:** captions, speaker highlighting, and sound alerts must work with no network. Only tone tags may depend on a server (Mac or cloud).
- **User testing:** DHH testers use the app on their own phones at home via TestFlight. Their phones can't reach the dev Mac, which is why the tone server must also run in the cloud (or behind a tunnel).

### Non-goals (semester one)
Android, public App Store release, user accounts, pose and hand landmarks, learned fusion, streaming partial captions (stretch goal), cloud hosting of anything other than the tone server.

---

## 2. Architecture

The system lives in three places:

| Zone | Role | Runs |
|---|---|---|
| **iPhone** (Swift app) | Everything live and per-frame; works offline | Capture, MediaPipe, speaker model, VAD, WhisperKit, SoundAnalysis, fusion, UI |
| **MacBook** (M-series, same Wi-Fi) | Tone model while it's still being iterated on | FastAPI tone server, WavLM + tone head, SQLite logging |
| **Cloud (optional)** | Same tone server, for remote/TestFlight testers | Docker container on GCP Cloud Run (or Mac + Cloudflare Tunnel as the $0 fallback) |
| **Team Macs** (offline) | Training only | Data prep, training, evaluation, export |

```
iPHONE ────────────────────────────────────────────────────────────────
 Camera(15fps) → Vision face detector + MediaPipe FaceLandmarker → FaceTracker → FeatureBuilder
                                                            ↓ (15-frame window per face)
 Mic ─┬→ Loudness ─────────────────────────────────→ SpeakerModel (Core ML GRU)
      │                                                     ↓ score per face
      │                                              ScoreBuffer (last 10s)
      ├→ VAD → sentence segment ─┬→ WhisperKit → caption(text, t0, t1, id)
      │                          │                          ↓
      │                          │                        Fusion ← ScoreBuffer
      │                          └→ ToneClient ──WS──┐       ↓
      └→ SoundAnalysis → sound alerts ────────────── │ ──→ Caption UI
                                                     │       ↑ tone tag (by caption id)
MAC ─────────────────────────────────────────────────┼───────┘
 FastAPI /ws/session → WavLM(frozen) → layer-mix → mean-pool → ToneHead → TagMapper
                     → Logger → SQLite
```

### One sentence through the system
1. The camera sees 3 faces. MediaPipe outputs landmarks and blendshapes per face, and the tracker assigns stable IDs.
2. Every frame, each face's last 15 frames of features plus mic loudness go into the speaker model, which outputs `p(speaking)`.
3. VAD detects the end of a sentence and emits an audio segment with an ID and start and end times.
4. WhisperKit transcribes the segment into a caption.
5. Fusion picks the face with the highest average speaking score during that time window and attaches the caption to it.
6. At the same time, the segment audio goes to the Mac. The tone model returns a tag for that caption ID, and the UI adds it.
7. SoundAnalysis independently raises alerts such as "Doorbell."

**Rule:** tone never blocks captions. Captions render immediately, and tone arrives later as an update.

### Tone server deployment modes
The same server code runs in three places. The app just points at a different URL.

| Mode | URL | When |
|---|---|---|
| `local` | `ws://<mac-lan-ip>:8000` | Day-to-day development (the Mac joins the test phone's hotspot) |
| `tunnel` | `wss://<name>.trycloudflare.com` | $0 remote testing while the Mac is on |
| `cloud` | `wss://<service>.run.app` | Always-on remote/TestFlight testing (uses cloud credits) |

Long-term, the tone model moves on-device (Core ML), which removes the server entirely.

---

## 3. Tech stack

| Area | Choice |
|---|---|
| iOS app | Swift, SwiftUI, AVFoundation (capture), Core ML, URLSessionWebSocketTask |
| Face features | MediaPipe Face Landmarker (iOS SDK in the app, `mediapipe` Python on PACE), installed from the Google MediaPipe Swift package, **same `.task` model file in both** |
| Transcription | WhisperKit (on-device Whisper). Start with `base.en`, benchmark `small.en` |
| VAD | Energy-based first; upgrade to Silero VAD |
| Sound events | Apple SoundAnalysis built-in classifier (`SNClassifySoundRequest`, `.version1`) |
| Speaker model | PyTorch GRU, exported with `coremltools` to `.mlpackage` |
| Tone model | `microsoft/wavlm-base-plus` (frozen) + custom MLP head, PyTorch on Mac (`mps`) |
| Tone baseline | `audeering/wav2vec2-large-robust-12-ft-emotion-msp-dim` (non-commercial license) |
| Tone server | Python 3.11+, `uv`, FastAPI + uvicorn, SQLite, Docker (one image for Mac and cloud) |
| Cloud (optional) | GCP Cloud Run (CPU container) + a Cloud Storage bucket for logs; Cloudflare Tunnel as the free fallback |
| Distribution | TestFlight (Apple Developer Program) for testers; Xcode direct install for developers |
| Training | Team M-series Macs (`mps`), PyTorch, Weights & Biases (free/academic tier) |
| Data storage | Team shared Google Drive folder (datasets, team recordings) |
| Labeling | Label Studio (own recordings) |
| Schema | JSON Schema → Pydantic (`datamodel-code-generator`) + Swift (`quicktype`) |
| LLM (summaries, Platform team) | Target: Apple Foundation Models (on-device, free). Benchmark: OpenAI API (small models). Prototyping: Ollama |
| CI | GitHub Actions: ruff, pytest, SwiftLint |

---

## 4. Repo layout

```
graption/
├── apps/ios/
│   ├── Graption.xcodeproj    # committed Xcode project (no generator)
│   ├── Graption/             # thin app target: entry point + wiring only
│   ├── Config/               # Base.xcconfig (shared) + Local.xcconfig (gitignored: team ID, secrets)
│   └── Packages/             # local Swift packages (see section 14)
│       ├── GraptionCore/     # generated event types, protocols, mocks, runtime model loader
│       ├── GraptionVision/   # camera capture, MediaPipe wrapper, FaceTracker, FeatureBuilder, SpeakerModel
│       ├── GraptionAudio/    # mic capture, Loudness, VAD, WhisperKit wrapper, SoundAnalysis
│       ├── GraptionFusion/   # ScoreBuffer, Fusion
│       ├── GraptionNetwork/  # ToneClient
│       └── GraptionUI/       # caption views, alerts, past-meetings dashboard, debug recorder UI
├── server/                   # tone server (FastAPI): Mac, tunnel, or cloud
│   ├── app/{main.py, ws.py, tone.py, tags.py, db.py, config.py, auth.py}
│   └── Dockerfile
├── ml/
│   ├── common/features.py    # CANONICAL feature spec (Swift mirrors it)
│   ├── asd/                  # speaker model: extract, dataset, train, eval, export
│   └── tone/                 # embed, train_head, eval, baseline
├── language/                 # summary/notes prototypes + OpenAI benchmark scripts (Platform)
├── schemas/events.schema.json
└── docs/                     # this file, diagrams, latency results
```

Datasets and model weights **never go in git**. Keep them in the team's shared Google Drive folder and log model artifacts to W&B.

The repo starts with only READMEs in most folders; each team creates the files above as they build.

### Teams

| Team | Owns | iOS packages |
|---|---|---|
| **Vision** | `ml/common/`, `ml/asd/` | `GraptionVision` |
| **Audio** | `ml/tone/`, the tone backend in `server/app/tone.py` | `GraptionAudio` |
| **Platform** | `server/`, `language/`, `schemas/`, CI, the app target | `GraptionCore`, `GraptionNetwork`, `GraptionFusion`, past-meetings dashboard + AI summaries |
| **UI/UX** | design | `GraptionUI` (captions, highlights, tone chips, alerts) |

---

## 5. Shared contracts

### Clock
All timestamps are **seconds since session start, measured on the phone's monotonic host clock**. Convert camera and audio `CMSampleBuffer` presentation timestamps to host time. The Mac never generates timestamps used for alignment.

### Event schema (`schemas/events.schema.json`)
Every event includes `type`, `session_id`, and `schema_version` (currently `"1.2"`).

**On-device (Swift types, generated from the schema):**
```jsonc
// speaker_scores: emitted per video frame
{ "type":"speaker_scores", "t":12.40, "faces":[{"face_id":"f2","p":0.94,"bbox":[x,y,w,h]}] }

// caption: emitted when WhisperKit finishes a segment
{ "type":"caption", "caption_id":"uuid", "t_start":11.2, "t_end":13.8,
  "text":"...", "speaker_id":"f2" | "unknown", "model_versions":{"asr":"whisperkit-base.en","asd":"asd-v3"} }

// sound_event
{ "type":"sound_event", "t":12.9, "label":"doorbell", "confidence":0.87 }
```

**Phone → tone server (WebSocket `<TONE_URL>/ws/session?session_id=...`):**
- `TONE_URL` comes from the app's settings (see the deployment modes in section 2).
- Non-local modes require an `Authorization: Bearer <TONE_TOKEN>` header on the WebSocket handshake. The server rejects connections without it.
```jsonc
// tone_request: one per VAD segment
{ "type":"tone_request", "caption_id":"uuid", "t_start":11.2, "t_end":13.8,
  "sample_rate":16000, "audio_b64":"<PCM16 mono little-endian>" }

// caption_log: final fused caption, for evaluation
{ "type":"caption_log", "caption": { ...caption event... }, "tone_tag":"excited"|null }
```

**Tone server → phone:**
```jsonc
{ "type":"tone_result", "caption_id":"uuid", "tag":"happy"|null,
  "probs":{"anger":0.05,"disgust":0.02,"fear":0.03,"happy":0.72,"neutral":0.15,"sad":0.03},
  "model_version":"tone-head-v2", "latency_ms":{"recv_to_send":180} }
```

**Malformed request → client (schema v1.1):**
```json
{
  "type": "session_error",
  "session_id": "demo",
  "schema_version": "1.2",
  "code": "invalid_json",
  "message": "Invalid JSON at line 1, column 1: Expecting value",
  "request": "not json",
  "request_encoding": "text",
  "model_version": "tone-stub-v1"
}
```
The connection stays open after request errors, so the client can correct and resend.
`request` is the exact received text, including any audio supplied; unsupported binary
frames are echoed as base64 with `request_encoding: "base64"`. These replies are sent
only to the originating client and must never enter server logs or storage. Authentication
failures still reject the handshake. Version 1.1 adds `session_error`; clients must use
`schema_version: "1.2"` in all events. Pydantic types live in `server/app/events.py` and
Swift types in `apps/ios/Packages/GraptionCore/Sources/GraptionCore/Events.swift`, generated with
`npx quicktype@23.2.6 -s schema schemas/events.schema.json --lang swift --top-level Events --access-level public
--density normal -o apps/ios/Packages/GraptionCore/Sources/GraptionCore/Events.swift`.

Base64 JSON is fine for the MVP (~130 KB for a 3s segment). Binary frames are a later optimization.

---

## 6. iOS app spec

**Capture**
- Camera: `AVCaptureSession`, 15 fps, 720p is plenty. Back camera by default. The preview has a flip control for the front camera. The front-camera preview and the analyzed frames are both mirrored, so face boxes stay on the face.
- Orientation: portrait and landscape. The analyzed buffers are rotated to the preview's horizon-level angle (`AVCaptureDevice.RotationCoordinator`), so faces are always upright and landmarks are in on-screen coordinates. The frame's aspect ratio therefore changes with orientation (9:16 or 16:9), so features must not depend on it (see FeatureBuilder).
- Mic: `AVAudioEngine` tap, resampled to **16 kHz mono float32**, in ~20 ms buffers.

**Face detection (Apple Vision)**
- `VNDetectFaceRectanglesRequest` (revision 3) on every frame, up to 4 faces, largest first. These boxes drive the tracker.
- Why not MediaPipe's detector: `face_landmarker.task` bundles the *short-range* BlazeFace, which downsamples the whole frame to 128 px and misses faces beyond roughly arm's length. Vision is free, offline, runs on the Neural Engine, and finds faces across a room.

**MediaPipe Face Landmarker: two modes, face crops currently selected**

For now the app has two ways to get landmarks, chosen by `LandmarkMode`. **`faceCrops` is currently selected.** Both use the Vision boxes above for detection and tracking; they differ only in what MediaPipe sees.

| Mode | What MediaPipe runs on | Far faces | Cost |
|---|---|---|---|
| `faceCrops` (**selected**) | A 256×256 crop, 2.2× the face size, around each Vision face. `IMAGE` mode, `numFaces = 2`, keep the mesh nearest the crop center | Boxes **and** landmarks | One small MediaPipe run per face |
| `fullFrame` | The whole frame, once. `VIDEO` mode (synchronous `LIVE_STREAM`, same cross-frame tracking), `numFaces = 4`; each mesh is attached to the Vision box containing its nose tip | Boxes only, no landmarks | One MediaPipe run per frame |

- In both modes landmarks are returned in full-frame normalized coordinates, so FeatureBuilder and everything downstream are unaffected by the choice.
- `outputFaceBlendshapes` and `outputFacialTransformationMatrixes` stay off until FeatureBuilder consumes them.
- **Training must match the selected mode.** With `faceCrops` selected, `ml/asd` extraction must crop the same way (2.2×, 256 px) around the AVA face boxes instead of running on full frames (see §8). Until it does, train/test landmarks differ slightly. Features are nose-centered and divided by inter-ocular distance, so the expected drift is small, but it hasn't been measured. Head pose from the transformation matrix assumes the full camera view, so compute pose from full-frame landmarks (or crop identically in training) before enabling matrices.
- **Switching modes:** edit one line in `CameraController` in `apps/ios/Graption/CameraView.swift`, `FaceCaptureEngine(landmarkMode: .faceCrops)` → `.fullFrame` (or back), rebuild, and update this section and the extraction to match.

**FaceTracker** (`GraptionVision/FaceTracker.swift`, unit-tested with `swift test`)
- Greedy IoU matching of the current frame's faces to existing tracks (IoU ≥ 0.3), then a centroid-distance fallback (within 1.5× the face size) for fast movers.
- Boxes are smoothed with a One Euro filter. A missed face coasts on its last velocity and is still shown for 2 frames, without landmarks.
- Drop a track after 2s unseen; until then a returning face gets its old ID back. (Was 1s; on-device testing showed turning the head away and back often takes longer, and the face came back with a new ID. Tradeoff: someone new stepping into the same spot within 2s inherits the ID.) IDs are `f1`, `f2`, … per session, never reused; they restart when the camera stops. Rotating the phone forgets all tracks (their boxes are in the old orientation), so faces get new IDs.

**Speaker guess (until SpeakerModel ships)**
- `LargestFaceScorer` implements the `SpeakerScorer` protocol: the largest face gets `p = 1`, the rest `0`. The camera view labels that face "talking" and draws it green. The Core ML model replaces it behind the same protocol.

**FeatureBuilder**
Must match `ml/common/features.py` exactly: same order, same normalization. It produces one vector per face per frame:

| Block | Size | Details |
|---|---|---|
| Lip landmarks | 80 | MediaPipe `FACEMESH_LIPS` indices (40 pts) × (x, y). Subtract the nose-tip landmark and divide by the inter-ocular distance |
| Mouth blendshapes | 12 | `jawOpen, mouthClose, mouthFunnel, mouthPucker, mouthLowerDownLeft, mouthLowerDownRight, mouthUpperUpLeft, mouthUpperUpRight, mouthStretchLeft, mouthStretchRight, mouthRollLower, mouthRollUpper` |
| Head pose | 3 | yaw, pitch, roll (radians) from the transformation matrix |
| Loudness | 1 | RMS dBFS of mic audio over the frame's ~67 ms, minus the session's rolling 30s median |
| **Total** | **96** | Plus a per-face ring buffer of the last 15 frames, giving model input `[1, 15, 96]` |

**SpeakerModel**
- Runs the Core ML model per face per frame, once that face's buffer has 15 frames.
- Output `p` is smoothed with an average of the last 5 predictions, then pushed to ScoreBuffer (10s ring).
- Load models via `MLModel.compileModel(at:)` from app documents, so new versions can be AirDropped in without rebuilding.

**VAD**
- Emits segments with `caption_id` (UUID) and `t_start`/`t_end`.
- End a segment after 500 ms of silence; force-split at 10s.
- Keep up to 300 ms of preceding idle audio in memory and prepend it on activation
  to preserve quieter word beginnings. Move t_start back by the retained sample duration;
  the 10-second cap includes pre-roll. Clear the buffer on segment completion, Stop,
  reset, or calibration; never emit an idle-only segment. This cannot recover speech
  missed entirely by the energy threshold.
- Start energy-based, then switch to Silero.
- Tapping listen calibrates automatically for 3 seconds. A centered countdown says "Calibrating",
  shows 3, 2, 1, and "Keep the room quiet", then captions start. Threshold = max(0.001, 2 × the 90th-percentile RMS of fixed 20 ms windows)
  from that stretch. At least 2 seconds of audio are required; otherwise the previous threshold
  is kept. Calibration emits no segments, stores no audio, and applies only for the current app
  instance. This provisional energy heuristic can miss quiet speech and does not distinguish
  speech from noise.

**WhisperKit**
- First launch with no local model shows a blank Install base.en page that says Wi-Fi is needed. Later launches load the local copy and caption offline.
- Transcribes each segment with word timestamps enabled.
- Emits a `caption` with `speaker_id` pending.
- Stretch goal: streaming partial captions.

**Fusion** (plain code, no ML)
```
for caption [t0, t1]:
    for each face: mean smoothed p over frames in [t0, t1]
    best, second = top-2 means
    speaker = best.face_id if best.p >= 0.5 and best.p - second.p >= 0.15 else "unknown"
```
- `"unknown"` means off-screen or ambiguous. Show it as "Someone."
- When a `tone_result` arrives, attach its tag to the caption by `caption_id`.

**SoundAnalysis**
- Filter to an allowlist: doorbell, knock, smoke/fire alarm, siren, dog bark, baby cry, laughter, phone ring.
- Confidence ≥ 0.7, with a 3s cooldown per label.
- Verify the exact label strings from `knownClassifications`.
  The verified mapping (Apple identifier → alert label) lives in `SoundAlertFilter.labels`, and a test checks it.
- The combined A2/A3 demo uses one microphone capture: continuous converted samples
  feed SoundAnalysis independently of VAD; onSegment feeds transcription, while
  onSoundAlert feeds an alert-only presentation model. During calibration, sound
  classification may run but alert presentation/announcements are suppressed.
- Window 1 s with 50% overlap (Apple's default is 3 s, too slow for the ≤ 1 s alert lag target).

**ToneClient**
- Sends a `tone_request` per segment and receives `tone_result`.
- If disconnected, drop tone silently and retry the connection every 5s. This must never affect captions.

**UI**
- Live caption list, with the speaker name/color matching a highlight box drawn on that face.
- Combined A2/A3 demo places matching large Start/Stop listening and calibration
  controls above the caption feed, with sound banners, haptics, and accessibility
  announcements. Stop clears the current banner while pending captions finish.
- Temporary A2 demo shows newest completed captions first, in dark-grey cards with
  a consistent-width, Dynamic Type-scaled time column, caption text beside it, and
  small "Transcription latency" below the text (ASR duration, excluding queue/VAD wait).
  Hide [BLANK_AUDIO] markers from presentation, retaining raw ASR output in debugger logs;
  omit marker-only results regardless of duration. Empty ASR results from
  segments shorter than 1 second (including retained silence) are logged to the
  debugger but hidden on screen; short recognized speech remains visible. This is
  display filtering, not spike rejection or reliable no-speech detection.
- Tone tag chip; sound alert banners (visual plus haptic).
- Large and dynamic type, high contrast. Follow Apple's Accessibility HIG.

**Past-meetings dashboard** (Platform)
- Lists saved sessions. Each shows its caption log (speaker, text, tone tag) and an AI summary/notes (section 10).
- Stores caption text, speakers, tags, and timings **on-device only**. Never audio or video.
- Works offline. Summaries that need a model the device lacks are simply unavailable.
- **Caption persistence implemented (issue #29):** `GraptionCore.SessionRecorder` collects
  caption records and atomically saves a completed session through `SessionStore`.
  `FileSessionStore` uses one versioned JSON file per session in private Application Support
  (`Sessions/`), excluded from device/iCloud backups and protected while the phone is locked.
  Records contain session ID/date/duration and caption ID/text/speaker/tone/times/model versions;
  no audio, video, raw network events, or echoed error requests are accepted by this API.
  Tone is optional; late results update the same saved session by caption ID without delaying end.
  Save errors retain the transcript for retry. History loading reports corrupt or unsupported
  files as an error instead of silently returning an empty history.
- The app has a live ASR pipeline, but persistence is not yet wired to live capture.
  The **Saved sessions** sheet is available from the live and model-install screens.
  Debug builds provide **Start Fake Session**
  and **End Session & Save**, plus saved-transcript inspection/reload to verify persistence
  across termination. Future capture wiring must call `append`, `applyTone`, and `end` on the
  session recorder. The full dashboard and summaries remain later work.

**Debug mode**
- Records a session: video file, per-frame `FeatureBuilder` vectors (JSONL), audio WAV, and all events.
- This is the replay data for ML iteration and the MediaPipe parity check.

**Info.plist**
- `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSLocalNetworkUsageDescription`
- `NSAppTransportSecurity → NSAllowsLocalNetworking = YES` (plain `ws://` on the LAN only; tunnel and cloud modes use `wss://`, so no other ATS exceptions are needed)

**Build configurations**

| | Debug (developers) | TestFlight (testers) |
|---|---|---|
| Install | Xcode, free or team Apple ID | TestFlight |
| Tone server | Settings screen: pick `local`, `tunnel`, or `cloud`, or enter a URL | Fixed to `cloud` (or `tunnel`); URL and token set at build time via `.xcconfig`, never committed |
| Models | Bundled default; runtime override via `MLModel.compileModel(at:)` | Bundled only (testers can't sideload models) |
| Debug recorder | Available | **Disabled**. External testers' audio and video are never stored |
| Consent | n/a | First-launch screen explaining that sentence audio is sent to our server for tone detection and not stored. Tone can be turned off |

**TestFlight notes**
- The external-tester build needs Beta App Review and privacy details in App Store Connect. Allow a few days.
- Bump the build number every upload.
- Log the model versions in the build notes.

---

## 7. Mac tone server spec

- **Skeleton implemented:** `GET /health` returns plain text `ok`. The session endpoint
  replies to each schema-v1.1 `tone_request` with a matching `tone_result`, `tag: null`,
  zero probabilities (no prediction), and `model_version: "tone-stub-v1"` through
  `MockToneBackend`. `caption_log` is accepted and discarded until logging is implemented.
  Audio stays in memory only. `TONE_BACKEND=audeering` swaps in the real audEERING baseline
  (A6, `server/app/audeering.py`); the default is still the stub (`mock`). SQLite logging and
  deployment packaging remain later work.
  Invalid session messages return `session_error` and keep the connection open. Rejection
  warnings contain only a fixed rejection code, generated connection ID, and backend model version. The response
  echoes the received request to its originating client; it is never stored or logged.
- **Run (Mac):** `uv run uvicorn app.main:app --host 0.0.0.0 --port 8000`
- **Run (verbose, repo root):** `uv run --directory server python -m app --verbose`.
  The launcher defaults to `--host 0.0.0.0 --port 8000`; either option can be overridden.
  `--verbose` enables application diagnostics while leaving uvicorn frame logging at INFO.
- **Run (tunnel):** also run `cloudflared tunnel --url http://localhost:8000`, which gives a free `wss://…trycloudflare.com` URL.
- **Run (cloud):** build `server/Dockerfile` and deploy to Cloud Run.
  - CPU only, 2 vCPU / 4 GB, min instances 0 (scales to zero between sessions, which keeps credit use low).
  - Allow a WebSocket request timeout of at least 60 min.
  - Bake the WavLM and head weights into the image so cold starts don't download them.
- **Endpoint:** `/ws/session`. One connection per app session, handling `tone_request` and `caption_log`.
- **Auth:** if `TONE_TOKEN` is set, require a matching bearer token. Always set it outside `local` mode.
- **Pipeline** (device auto-select: `cuda` → `mps` → `cpu`; the code must run correctly on all three):
  1. Decode PCM16 and resample to 16 kHz if needed.
  2. WavLM-base+ (frozen), `output_hidden_states=True`, giving 13 layers × T × 768.
  3. Learned softmax-weighted sum over the 13 layers, then mean-pool over time, giving a 768-dim vector.
  4. Head: `Linear(768,256) → ReLU → Dropout(0.3) → Linear(256,6) → softmax`.
  5. Tag mapper: `tag = argmax` if `max prob ≥ 0.6` and the argmax isn't `neutral`; otherwise `null`.
- **Week-1 baseline mode** (`TONE_BACKEND=audeering`, implemented): the audEERING model outputs arousal, valence, and dominance in [0,1]. Map them with tunable thresholds (`AudeeringThresholds` in `server/app/tone.py`). These are the values tuned on team recordings in A4 (`ml/tone/DISCUSSION_LOG.md`), replacing the original 0.65/0.55/0.4/0.3 guesses:
  - arousal > 0.64 and valence > 0.45 → `excited`
  - arousal > 0.47 and valence < 0.4 → `upset`
  - 0.38 < arousal < 0.48 and valence > 0.45 → `calm`
  - otherwise `null`; segments under 0.5 s are always `null`
  - `probs` are all zero in this mode: the schema's 6 emotions don't apply to arousal/valence.
  - Weights load from the local Hugging Face cache (`uv run hf download audeering/wav2vec2-large-robust-12-ft-emotion-msp-dim`); torch, transformers, and scipy come from the uv workspace (`graption-ml`), not `graption-server`'s own dependencies.
- **Config (env vars):** `TONE_BACKEND` (`mock` default | `audeering` | `custom` later), `TONE_HEAD_PATH`, `TAG_THRESHOLD`, `TONE_TOKEN`, `DEPLOY_MODE` (`local` | `tunnel` | `cloud`), `LOG_EXPORT_BUCKET` (cloud only), `TONE_LOG_DIR` (default repo-root `logs/`).
- **CPU performance:** the audEERING baseline is the large wav2vec2 variant (~165M params) and may be slow on CPU. Benchmark per-sentence latency on Cloud Run before user testing. If it's over ~1s, use the custom WavLM-base head in cloud mode.
- **SQLite tables:** `sessions`, `captions` (from `caption_log`), `tone_results` (probs, model_version, latency).
  - Cloud Run disks are ephemeral, so in cloud mode, export the SQLite file to `LOG_EXPORT_BUCKET` at session end.
- **Privacy:** never write request audio to disk or logs in any mode. Only text, tags, probabilities, and timings are stored.
- **Logging:** application logs go to the console and a fresh gitignored repo-root
  `logs/server-<UTC-timestamp>-<unique-id>.jsonl` on each server start; the startup log prints
  the file path. Each run rotates at 5 MiB with three backups; previous runs are preserved. Startup/shutdown and warnings/errors are always logged.
  `--verbose` adds connection lifecycle, accepted tone/caption requests, frame/audio byte
  counts, receive-to-send/inference/send timings, and per-connection totals on disconnect.
  Entries include model versions and generated connection IDs. Never log raw frames,
  caller-provided session IDs, caption text, tokens, echoed requests, or exception details.
  UTC log timestamps are diagnostics only; alignment timestamps still come from the phone.
  Use the application verbose flag rather than uvicorn debug frame logging, which can expose audio.
- **Campus Wi-Fi** often blocks device-to-device traffic. Use a phone hotspot or a personal router.

---

## 8. ML: speaker detection (vision)

**Task:** binary classification of whether a face is speaking at the last frame of a 1s window.

**Data**
- **AVA-ActiveSpeaker:** about 3.65M labeled face frames from movies. Use the official train/val splits, which are **split by video** to avoid leakage.
  - Labels: `SPEAKING_AUDIBLE` → 1. `NOT_SPEAKING` → 0. Drop `SPEAKING_NOT_AUDIBLE`.
- **Team iPhone recordings** (debug mode), labeled in Label Studio. This is the **primary test set**, and possibly fine-tuning data later.

**Extraction (Mac)**
1. Resample the video to 15 fps and extract 16 kHz audio.
2. Run MediaPipe with the same `.task` file as the app, in the **same `LandmarkMode` as the app** (§6). With `faceCrops` (currently selected): crop 2.2× around each AVA face box, resize to 256×256, run `IMAGE` mode, map landmarks back to full-frame coordinates. With `fullFrame`: **VIDEO** mode on full frames.
3. Match each MediaPipe face to AVA boxes by IoU ≥ 0.5 and take that box's label. Drop unmatched faces.
4. Compute the 96-dim features via `ml/common/features.py`.
5. Build 15-frame windows (stride 1 for training).
6. Save as sharded `.npz` files.

**Model**
- `GRU(input=96, hidden=64, layers=2, dropout=0.2) → Linear(64,1) → sigmoid`, about 50k params.
- **Alternative:** 1D CNN with 3 × `Conv1d(k=3)` layers, then global average pooling, then a linear layer. Train both and keep the better one.
- **Baseline to beat:** logistic regression on per-window `std(jawOpen)` and `mean(loudness)`.

**Training**
- Loss: BCE with `pos_weight` set to the negative/positive ratio.
- Optimizer: Adam, lr 1e-3, batch 512, early stopping on validation mAP.
- Log everything to W&B.

**Evaluation:** AVA val mAP, plus accuracy and F1 on team recordings, plus end-to-end speaker attribution accuracy through fusion.

**Export**
1. `coremltools.convert` with a fixed input of `[1, 15, 96]` to produce an `.mlpackage`.
2. **Parity test:** same inputs through PyTorch and Core ML, requiring `max |Δp| < 1e-3`.
3. Name versions `asd-vN`.

**MediaPipe parity check (do this early):** record a clip in debug mode, run the Python extractor on the same video, and compare the feature vectors. They must closely match before serious training.

---

## 9. ML: tone (audio)

**Task:** 6-class emotion classification per sentence.

**Data**
- **CREMA-D** (free): about 7.4k clips, 91 actors, 12 sentences, 6 emotions (anger, disgust, fear, happy, neutral, sad).
- **Split by actor**, 70/15/15, fixed seed.
- The dataset is acted, so **team recordings are the real test set**.

**Pipeline (Mac)**
1. Run every clip through frozen WavLM **once**. Save mean-pooled hidden states from all 13 layers as a `[13, 768]` tensor per clip.
2. Train only the layer weights (13 params) and the MLP head (about 200k params) on those saved tensors. This takes minutes.
3. Loss: cross-entropy. Adam, lr 1e-3, early stopping on validation macro-F1.
4. Metrics: macro-F1 and unweighted accuracy on the test actors, plus agreement with human judgment on team recordings.
5. **Must beat or match** the audEERING baseline on team recordings (compare on arousal-style tags) before it replaces the baseline.
6. Export the head weights (`tone-head-vN.pt`) to the Mac. At end of semester, convert to Core ML and move on-device.

**Stretch (only if tests show gaps):** MSP-Podcast (natural speech, needs a GT-signed license) and openSMILE eGeMAPS features concatenated before the head.

---

## 10. AI summaries and notes (Platform team, non-blocking)

**Feature:** a post-session "catch me up" summary/notes built from the caption log (speaker + text + tone), shown in the past-meetings dashboard (section 6).
- **Target:** Apple Foundation Models on-device (iOS 26+, Apple Intelligence devices). Free and offline. Use `@Generable` for structured output.
- **Benchmark:** OpenAI API (a small, cheap model) run from Python scripts in `language/`, on exported caption logs. It sets the quality bar that the on-device version is measured against.
  - **Never** call OpenAI from the iOS app; the API key would ship inside the app.
  - Keep the key in a local `.env`, never committed.
  - Keep a small eval set of about 20 transcripts plus reference summaries, and score both systems on it.
- **Prototyping:** Ollama on the Mac.
- **Context limit** is about 4K tokens on-device, so chunk long transcripts and summarize hierarchically.
- Not on the critical path for the MVP.

---

## 11. Performance targets

Measure on the team's **oldest** supported iPhone.

| Metric | Target |
|---|---|
| Speaker highlight lag | ≤ 0.5 s |
| Sound alert lag | ≤ 1 s |
| Caption shown after sentence ends | ≤ 1.5 s |
| Tone tag after caption | ≤ 0.7 s |
| App frame processing | sustained 15 fps, no thermal throttling in a 10-min session |

If the device is overloaded, degrade in this order:
1. Smaller Whisper model
2. Speaker model every 2nd frame
3. `numFaces = 3`

---

## 12. Milestones

1. **Weeks 1–2, skeleton:** schema frozen. The app captures and runs WhisperKit to show captions. Stub speaker = largest face. SoundAnalysis working. Mac echo server reachable from the phone.
2. **Week 2, baselines:** audEERING tone baseline live through the Mac, and the heuristic speaker baseline in the app. This is the first end-to-end demo.
3. **Weeks 3–6, parallel:**
   - AVA extraction, then GRU/CNN training, then Core ML
   - CREMA-D embeddings, then head training
   - UI and fusion polish
   - Debug recorder and team data collection
4. **Weeks 7–9:** swap the custom models into the existing interfaces, benchmark on device, and evaluate on team recordings.
5. **Week 9–10, test infrastructure:** tone server Docker image deployed to Cloud Run (or the tunnel fallback), and a TestFlight build with the consent screen passing Beta App Review.
6. **Week 10+:** at-home user testing with DHH users via TestFlight, accessibility polish, and the past-meetings dashboard with AI summaries.

---

## 13. Conventions

- **Interfaces first.** Every model sits behind a protocol or class (`SpeakerScorer`, `ToneBackend`) with a stub implementation, so swapping models never touches the rest of the app.
- **Features are defined once** in `ml/common/features.py`. Swift mirrors it, with a unit test on a shared fixture file.
- **Every event and log** carries model versions.
- **Every training run** goes to W&B, with the config committed alongside it.
- **Branching:** PRs to `main`, and CI must pass. Add `CODEOWNERS` per team folder once reviews are enforced.
- **Secrets** (`TONE_TOKEN`, OpenAI key, cloud credentials) live in `.env` or `.xcconfig` files that are gitignored, never in code or the repo.
- **Cost control:** Cloud Run scales to zero. Set a billing budget alert at 50% and 90% of the credits. OpenAI keys get a hard monthly spend limit.
- **Licenses:** the audEERING model and MSP-Podcast are non-commercial. That's fine for this academic MVP, but flag it before any commercial use.

---

## 14. Dev workflow

- **One monorepo, two toolchains:**
  - `apps/ios/` uses **Xcode** (build, sign, run on device, Instruments). Mac required.
  - `server/`, `ml/`, and `language/` use any IDE (VS Code, Cursor, PyCharm) on any OS. Training runs on the team's M-series Macs.
- **Thin Xcode project** (committed as-is, no XcodeGen; Xcode 16+ synchronized folders mean adding files doesn't touch `.pbxproj`):
  - Put almost all Swift in local Swift packages (`apps/ios/Packages/GraptionCore`, `GraptionVision`, `GraptionAudio`, …).
  - The app target only wires up UI. This avoids `.pbxproj` merge conflicts and lets `swift test` run in CI.
- **Python:** a `uv` workspace at the root. `server/`, `ml/`, and `language/` are members, each with its own `pyproject.toml`. Torch and MediaPipe stay out of the server's dependencies.
- **Cross-language handoffs:**
  1. Event types are generated from `schemas/events.schema.json`.
  2. Feature parity: Python writes fixtures to `ml/common/fixtures/`, and a Swift unit test must reproduce them exactly.
  3. Models: the ML team exports the `.mlpackage` and runs the parity test; the iOS team bundles it.
- **Unblocking:**
  - `scripts/replay_client.py` streams recorded audio to the tone server, so server work needs no phone.
  - `MockToneBackend` and `MockSpeakerScorer` let the iOS UI be built with no models or server.
  - Debug-mode recordings feed the ML team.
- **CI:** Python jobs on Linux, path-filtered to `server/`, `ml/`, and `language/`. Swift `swift test` on a macOS runner, path-filtered to `apps/ios/` (macOS minutes are expensive).
- **Coding agents** verify Swift with `xcodebuild` or `swift test`, never "looks right."

---

## 15. Budget (requested)

| Item | Cost | Unlocks | If denied |
|---|---|---|---|
| Apple Developer Program | $99 | TestFlight for at-home DHH testing | Ask iOS Club for a team account; otherwise test in person on team phones |
| OpenAI API credits | $50 | Summary-quality benchmark | Compare against Ollama models only |
| Cloud credits | $100 | Always-on tone server for remote testers | Cloudflare Tunnel from the Mac, or free student credits (Azure for Students, GitHub Student Pack) |

**Deliberately not requested:**
- Router: use a phone hotspot.
- Tripods: handheld recordings are more realistic test data.
- Colab or GPU credits: the team's M-series Macs cover training (free Colab is the fallback).

---

## 16. Decision log (why things are the way they are)

- **Phone does all per-frame work; nothing streams video.** Latency, offline use, and privacy. Landmarks are tiny.
- **WhisperKit on-device:** captions work offline, and we don't modify Whisper, so there's no iteration cost.
- **Fusion on the phone:** speaker scores never leave the device, highlights are instant, and the server stays simple.
- **Speaker model on the phone from the start:** it's tiny and converts to Core ML trivially. Iteration happens offline on recorded replays, not live.
- **Tone model on the Mac for now:** WavLM → Core ML conversion is finicky, and Python iteration is fast. It moves on-device at end of semester.
- **Face only in v1:** multi-person pose and hands would overload the phone and add little for "who's talking."
- **No PACE; train on team Macs:** we don't have PACE access. The tone head trains on frozen WavLM embeddings in minutes, and the speaker GRU is about 50k params, so M-series Macs (`mps`) are enough. Datasets and recordings go in a shared Google Drive folder; AVA may need to be a subset.
- **CREMA-D, not MSP-Podcast; openSMILE dropped:** no license paperwork. The audEERING baseline (trained on MSP-Podcast) gives natural-speech coverage for free. Both remain stretch goals, used only if tests show gaps.
- **Tone never blocks captions,** and tone tags only show when confident. A wrong tag is worse than none for DHH users.
- **Recoverable request errors (schema v1.1):** return descriptive `session_error` messages with the received request so manual clients can correct mistakes without reconnecting. Never log or store the echoed payload.
- **Rule-based fusion before learned fusion:** it produces the logged data a learned version would need.
- **Toolchain baseline:** the project uses Xcode 16-compatible format (77), iOS 17+, and
  GraptionCore uses Swift tools 6.0 so it builds with the installed Xcode 26 toolchain.
- **Committed `.xcodeproj`, not XcodeGen:** synchronized folders plus per-team Swift packages already avoid most merge conflicts, and it saves every teammate a tool install. Signing is per developer via a gitignored `Local.xcconfig`, because free Apple IDs can't share a bundle ID.
- **Platform owns summaries and the dashboard:** there's no separate language team; it's non-blocking backend-style work that builds on the caption log Platform already moves around.
- **OpenAI only as an offline benchmark:** the target is free on-device Apple Foundation Models, and an API key must never ship in the app.

---

## 17. Open questions

- Does iOS Club have an Apple Developer team account Graption can use?
- AVA on a Mac: download status, and how large a subset we can extract and train on locally.
- Dashboard scope: summaries, notes, or both? How long are past meetings kept on-device?
- Oldest iPhone on the team (for performance benchmarks), and which team devices support Apple Intelligence (for Foundation Models).
- Budget approval outcome.

---

## 18. Companion files

- `graption-architecture-v4.drawio`: system diagram, including the cloud testing mode.
- `Graption-Team-Resources.docx`: per-subteam study links and first tasks.
- Resource and account links: see the resources doc and section 3.
