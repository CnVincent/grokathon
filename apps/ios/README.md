# apps/ios: Graption iOS app

Spec: `docs/GRAPTION_CONTEXT.md` §6 (app) and §14 (workflow). The app provides live captions,
sound alerts, a camera screen, and a local saved-transcript demo.
Mac + Xcode required; GraptionCore requires Swift 6.0+.

## Run it (first time, each developer)
1. Xcode → **Settings → Accounts** → **+** → sign in with your Apple ID (free is fine).
2. `cp apps/ios/Config/Local.xcconfig.example apps/ios/Config/Local.xcconfig` and fill in
   `DEVELOPMENT_TEAM` (your 10-character team ID) and `DEV_SUFFIX` (your name). Add `TONE_URL`
   (for example, `ws:/$()/<mac-lan-ip>:8000`; the unusual spelling avoids xcconfig treating `//` as a comment)
   and `TONE_TOKEN` only when testing the tone server. Set `XAI_API_KEY` only if siren
   and alarm banners should ask Grok why the sound is happening, or if typed replies
   should be translated and spoken by Grok. Leave it empty and those banners stay
   on-device; typed replies are spoken on-device and are not translated. Optional
   `XAI_SPEECH_ENGINE` is `tts` (default) or `voice` (Grok Voice 3.0). This file is
   gitignored. It exists because two free Apple IDs can't share one bundle ID.
3. Open `apps/ios/Graption.xcodeproj`. Pick a simulator and press ⌘R.
4. On your iPhone: plug in → **Trust** → Settings → Privacy & Security → **Developer Mode** on →
   pick the phone in Xcode → ⌘R. First run only: Settings → General → VPN & Device Management →
   trust your Apple ID. Free-account installs expire after ~7 days; ⌘R again to reinstall.

**Don't** set Team or Bundle Identifier in Xcode's Signing & Capabilities tab. That writes your
personal values into the shared project file. Use `Local.xcconfig`.

Verify from the terminal (no signing needed):
```bash
xcodebuild -project apps/ios/Graption.xcodeproj -scheme Graption \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Structure
```
apps/ios/
├── Graption.xcodeproj     # committed (Xcode 16+ synchronized folders: adding files doesn't edit it)
├── Graption/              # thin app target: entry point + wiring only                  (Platform)
├── Config/
│   ├── Base.xcconfig      # shared settings: bundle ID = edu.gatech.graption.$(DEV_SUFFIX)
│   └── Local.xcconfig     # gitignored: DEVELOPMENT_TEAM, DEV_SUFFIX, TONE_URL, TONE_TOKEN, XAI_API_KEY
└── Packages/              # planned local Swift packages; almost all code will live here
    ├── GraptionCore/      # event types generated from the schema, Mock* classes        (Platform)
    ├── GraptionVision/    # camera, MediaPipe, FaceTracker, FeatureBuilder, SpeakerModel (Vision)
    ├── GraptionAudio/     # mic, loudness, VAD, WhisperKit, SoundAnalysis               (Audio)
    ├── GraptionFusion/    # ScoreBuffer, Fusion (pick speaker for each caption)         (Platform)
    ├── GraptionNetwork/   # ToneClient, GrokSTTClient, siren context, spoken replies (Platform)
    └── GraptionUI/        # live captions, highlights, tone chips, sound banners,
                           # past-meetings dashboard with AI summaries      (UI/UX; dashboard: Platform)
```
Add a package with **File → New → Package…** saved into `apps/ios/Packages/`, then add it to the
Graption target under **General → Frameworks, Libraries, and Embedded Content**.

## MediaPipe Face Landmarker V1

Google's current iOS setup guide supports Swift Package Manager. Use it for this project:

1. In Xcode with Graption.xcodeproj opened, choose **File -> Add Package Dependencies...**.
2. Add `https://github.com/google-ai-edge/mediapipe` and select the `MediaPipeTasksVision`
    product for the `Graption` target. `MediaPipeTasksCommon` is included automatically.
      - There is a chance that MediaPipeTasksVision doesnt get caught, in that case reinstall
      the package setting the dependency Rule to Branch and typing in master in the box to the
      right. It should show after this
3. Download Google's Face Landmarker model bundle from the [Face Landmarker models]
    (https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker/index#models)
    documentation. Add the downloaded `face_landmarker.task` to the `Graption` target's app
    resources. The file is ignored by git, so every developer downloads it locally.
      - Just drag and drop into the blue folder on xcode - the file name must be the exact same
      and show up under copy bundle resources in build phases when Graption app is targeted.
4. Add `NSCameraUsageDescription` to the app target's Info.plist. The generated Info.plist
    setting can be supplied as `INFOPLIST_KEY_NSCameraUsageDescription` in the target build
    settings.
   - Target: Graption -> Info -> Click plus on the last item in Custom iOS Target Properties
     -> Select: Privacy - Camera Usage Description -> on the right field enter the message
     (ex. Graption needs camera access to analyze your face.)
5. Build from Xcode once so SPM resolves the package. A physical iPhone is required for the
    live camera result; the simulator cannot provide a useful camera test.
   - All the set up for connecting a device with ICloud needs to be done for this
The older Face Landmarker page also documents CocoaPods, but SPM is the current project setup
path and avoids introducing a `Podfile` and generated workspace into this repository.

V1 implementation contract:

- Capture the back camera with `AVCaptureSession` at up to 1080p and 15 fps, using continuous
   autofocus, exposure, and white balance. Portrait and landscape both work:
   `AVCaptureDevice.RotationCoordinator` gives one horizon-level angle that is applied to both the
   preview and the analyzed buffers, so boxes line up with the screen and faces stay upright for
   Vision and MediaPipe. Tracks reset when the angle changes.
- Detect faces with Apple Vision (`VNDetectFaceRectanglesRequest`), which finds faces across a
   room. MediaPipe's bundled short-range detector only finds faces within about arm's length.
- There are two landmark modes for now, chosen by `LandmarkMode`. **`.faceCrops` is currently
   selected**:
   - `.faceCrops` (selected): runs `FaceLandmarker` in `.image` mode on a 256×256 crop around
     each Vision face, so far faces get landmarks too. Costs one small MediaPipe run per face.
   - `.fullFrame`: runs `FaceLandmarker` once per frame on the whole frame in `.video` mode with
     `numFaces = 4` and attaches each mesh to the Vision box containing its nose tip. Far faces
     are tracked but get no landmarks.
   - To switch, change `FaceCaptureEngine(landmarkMode: .faceCrops)` in `CameraController`
     (`Graption/CameraView.swift`) to `.fullFrame` and rebuild. ASD training extraction must use
     the same mode; see `docs/GRAPTION_CONTEXT.md` §6.
   - Blendshapes and transformation matrices stay disabled until a consumer needs them.
- All inference runs synchronously on one video queue with `alwaysDiscardsLateVideoFrames`, so
   frames that arrive while busy are dropped and latency never queues up.
- Tracks are matched greedily by center distance, smoothed with a One Euro filter, keep stable
   IDs, and coast for at most two missed frames. The overlay draws a solid box for faces with
   landmarks and a dashed box for faces that were detected but have no mesh. It accounts for the
   preview's aspect-fill crop.
- Keep camera capture and MediaPipe behind the planned `GraptionVision` boundary so the later
   tracker and speaker model can consume the same per-frame results.

Official references: [MediaPipe iOS setup]
(https://developers.google.com/edge/mediapipe/solutions/setup_ios) and [Face Landmarker iOS]
(https://developers.google.com/edge/mediapipe/solutions/vision/face_landmarker/ios).

WhisperKit is SwiftPM (`argmaxinc/WhisperKit`).
- WhisperKit is SwiftPM (`argmaxinc/WhisperKit`).
- Minimum iOS is 17.0 for now; lower it if a team phone can't run 17. On-device summaries need iOS 26+.

## Rules
- Verify with `xcodebuild` / `swift test`, not "looks right".
- Event types are generated from `schemas/events.schema.json`, not hand-written.
- No secrets in the repo: they go in the gitignored `Local.xcconfig`.

## Caption persistence (issue #29)

`GraptionCore` exposes `SavedCaption`, `SavedSession`, `SessionStore`, `FileSessionStore`,
and `SessionRecorder`. Create a recorder at session start, call `append` with each final
caption as it renders, route tone responses to `applyTone(captionID:tag:modelVersion:)`,
and call `try await end()` when capture ends. Captions save immediately with optional tone;
a late tone updates the same file. If a save fails, keep the recorder and retry `end()`.
Caption offsets use the phone's monotonic session clock; `startedAt` is only a display date.
These are local storage types, not a replacement for the generated event contract.

The default store writes atomic, versioned JSON to `Library/Application Support/Sessions/`
in the app sandbox, excludes it from backups, and uses complete file protection on iOS.
It accepts only transcript records; it has no audio/video field or raw-event save API.
History is newest-first. Corrupt/unsupported files surface a load error.

### Manual acceptance test (simulator or iPhone)

1. Run the **Debug** scheme from Xcode. No tone server, microphone, or models are needed.
2. Open **Saved sessions**, then tap **Start Fake Session**. Expect three captions from `f1`, `f2`, and **Someone**;
   the first has tone `happy`, the others have no tone. The fake times run from 0 to 7 seconds.
3. Tap **End Session & Save**. A session with **3 captions** appears under Saved sessions.
4. Open it and verify all text, speakers, tone, and start/end times.
5. Stop the app in Xcode or force-quit it in the app switcher. Launch it again without
   uninstalling it or resetting simulator data. The saved session should appear automatically.
6. Open the same transcript and verify the same three captions. Tap **Reload Saved Sessions**
   to exercise a fresh disk read. Repeat with another fake session; both should remain.
7. Repeat in airplane mode to confirm storage is fully offline.

The fake-session demo is Debug-only. Live caption capture remains independent and does not
save a caption session yet. Force-quitting an active, unended session does not save it.
Uninstalling the app removes its locally saved sessions.

### Automated verification

```bash
swift test --package-path apps/ios/Packages/GraptionCore
xcodebuild -project apps/ios/Graption.xcodeproj -scheme Graption \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Tests cover persistence through a new store instance, every caption field, the complete
JSON field allowlist, absent tone, late tone, duplicate/repeated saves, empty sessions,
sort order, invalid timings, failed-save retry, and corrupted JSON. They use temporary
folders and synthetic text; they never capture audio.
