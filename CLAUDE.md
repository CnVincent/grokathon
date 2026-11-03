# Graption: agent instructions

Real-time, speaker-aware captioning iOS app for Deaf and hard-of-hearing users.
**Source of truth: [`docs/GRAPTION_CONTEXT.md`](docs/GRAPTION_CONTEXT.md).** Read the relevant
section before changing anything. If code and the doc disagree, or a request conflicts with the
doc, say so. Don't silently diverge. If a decision changes, update the doc in the same PR.

## Hard constraints
- Captions, speaker highlighting, and sound alerts work **fully offline** on the iPhone
  via WhisperKit. Tone tags and the optional online Grok caption boost may depend on a
  server. Online captions are off by default and require consent.
- **iOS only.** Minimal budget: everything must work without paid items (Apple dev account,
  OpenAI, cloud credits).
- **Tone never blocks captions.** Captions render immediately; tone arrives later by `caption_id`.
  No confident tag → `null` (a wrong tag is worse than none).
- **No audio is ever stored** by the server (no disk, no logs). Only text, tags, probs, timings.
- **No secrets, datasets, weights, or recordings in git.** Secrets in `.env` / `.xcconfig`
  (gitignored); data in the team's shared Drive; model artifacts in W&B.
- **OpenAI is never called from the iOS app.** Only from `language/` benchmark scripts.
- The only cloud piece is the optional tone/STT server. Training runs locally on team Macs.

## Conventions
- **Interfaces first:** every model sits behind a protocol/class (`SpeakerScorer`, `ToneBackend`)
  with a stub/mock, so swapping models touches nothing else.
- **Features are defined once** in `ml/common/features.py`; Swift mirrors it, tested against
  `ml/common/fixtures/`. Changing it invalidates trained models: flag it loudly.
- **Events:** `schemas/events.schema.json` (v1.1) is the cross-team contract. Pydantic
  (`datamodel-code-generator`) and Swift (`quicktype`) types are generated from it, never
  hand-edited. Schema change → bump `schema_version`, regenerate, update `schemas/tests/`.
- All timestamps: seconds since session start on the **phone's** monotonic clock.
- Every event/log carries model versions. Every training run goes to W&B with its config committed.
- Keep `torch`/`mediapipe` out of `server/` deps.
- **Verify, don't eyeball.** Python: run the commands below. Swift: `swift test` / `xcodebuild`,
  never "looks right". Report what you actually ran.

## Commands (repo root, Python 3.11+, [uv](https://docs.astral.sh/uv/))
```bash
uv sync                                        # install everything + dev tools
uv run ruff check .                            # lint (CI)
uv run pytest                                  # tests (CI)
uv add --package graption-server <pkg>         # add a dep to one member (server | ml | language)
cd server && uv run uvicorn app.main:app --host 0.0.0.0 --port 8000   # once server/app/main.py exists

# iOS (macOS + Xcode): must print ** BUILD SUCCEEDED **
xcodebuild -project apps/ios/Graption.xcodeproj -scheme Graption \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
Never put a `DEVELOPMENT_TEAM` or bundle ID in `project.pbxproj`; signing comes from
`apps/ios/Config/Local.xcconfig` (gitignored).

## Teams and where they work
| Team | Python | iOS (`apps/ios/Packages/`, planned) |
|---|---|---|
| Vision | `ml/common/` (feature spec), `ml/asd/` | `GraptionVision` |
| Audio | `ml/tone/`, `server/app/tone.py` (tone backend) | `GraptionAudio` |
| Platform | `server/`, `language/`, `schemas/`, CI | app target, `GraptionCore`, `GraptionNetwork`, `GraptionFusion`, past-meetings dashboard |
| UI/UX | none | `GraptionUI` |

PRs to `main`; CI must pass. Changes to `schemas/` or `ml/common/` affect other teams: tag the lead.
