# Mobile App Dev Notes

These notes cover the iOS camera app side of SyncREC. The app is adapted from Apple's AVCam sample, but the project-specific behavior centers on foreground multi-phone recording, remote control, local take storage, calibration sidecars, and rig power policy.

## Entry Points

- `AVCam/AVCamApp.swift`: SwiftUI app entry point.
- `AVCam/CameraView.swift`: top-level camera UI.
- `AVCam/CameraModel.swift`: main UI-facing model for capture state and director integration.
- `AVCam/CaptureService.swift`: AVFoundation capture-session owner and camera-parameter logic.
- `AVCam/CameraModel+RemoteDirector.swift`: WebSocket command handling and status reporting.
- `AVCam/CameraModel+TimecodeServices.swift`: director-clock/timecode handling.
- `AVCam/LocalVideoStore.swift`: local movie storage and calibration sidecar persistence.

## Capture Architecture

`CaptureService` owns the AVFoundation session and keeps blocking capture-session work off the main UI path. The app uses the same broad structure as AVCam: SwiftUI views observe `CameraModel`, while `CaptureService` coordinates camera inputs, outputs, preview frames, photos, movies, focus/exposure/white-balance controls, and format selection.

The app is intentionally foreground-only. It does not rely on background camera access, private APIs, silent audio, or screen-lock camera behavior. For rig use, phones should stay foregrounded in the camera app.

## Remote Director Client

`RemoteDirectorClient` connects to the Python director over WebSocket. It sends an initial hello, emits periodic status payloads, handles time-sync packets, and dispatches command envelopes back into `CameraModel`.

Important command families include:

- Recording flow: `arm`, `arm_idle`, `prepare_recording`, `prepare_start`, `commit_start`, `start_recording`, `prepare_stop`, and `stop_recording`.
- Media flow: `capture_preview_photo`, `pull_videos`, and `delete_local_videos`.
- Capture configuration: `set_capture_mode`, `export_camera_params`, `apply_camera_params`, and `validate_camera_params`.
- Parameter locks: focus mode changes, camera-parameter lock/unlock/toggle, and focus-preserving release.
- Power policy: `set_awake_policy` with modes such as `allow_auto_lock_once` and `default`.

Status payloads include recording/armed state, battery, storage, local video counts, pending upload counts, capture mode, actual format, timecode, camera-parameter status, Guided Access state, idle-timer state, and transfer-awake state.

## Recording And Sidecars

After a movie is finalized, `LocalVideoStore` moves or copies it into the app's local `Videos` folder and writes a same-stem JSON sidecar when calibration metadata is available.

The sidecar is used by the ingest workflow and should remain close to the video. It records take/session naming, capture mode, timestamps, timecode context, camera settings, and calibration fields. AVFoundation camera-calibration fields such as lens distortion lookup tables are included when `AVCameraCalibrationData` is exposed by the capture pipeline; otherwise the JSON records a structured missing reason.

## Capture Modes And Params

The mobile app exposes a fixed set of capture-mode presets that the director can apply to all or selected devices. `CaptureService` resolves the closest supported AVFoundation format on each phone and reports both requested and actual capture mode back to the director.

Camera-parameter sync works by exporting a profile from one selected device, applying it to others, and reporting whether each device is in sync, adjusted to a close match, copied, or mismatched. Dry-run sync is available to inspect expected results without changing devices.

## Preview Photos

The director can request downscaled JPEG preview photos for framing checks. The camera app captures the most recent video frame, encodes a JPEG at the requested size/quality, uploads it to the director, and sends metadata beside the image.

Preview capture is refused while recording so it does not interfere with an active take.

## Awake Policy

The app's awake policy is centralized in `applyRigPowerPolicy`.

- Recording always disables the idle timer.
- Active video upload always disables the idle timer until the transfer exits.
- `allow_auto_lock_once` temporarily re-enables Auto-Lock, even in Guided Access, until the user wakes or reopens the app.
- Guided Access defaults to keeping a foregrounded rig phone awake.
- Prepared-but-not-recording state does not keep the phone awake by itself.

This keeps normal camera behavior reasonable while still supporting unattended rig operation.

## Build Notes

The app must run on physical iOS devices for real camera access. Simulator can build the project, but it cannot exercise the AVFoundation capture pipeline with iPhone cameras.

Useful source-only build check:

```sh
xcodebuild -quiet -project "SyncREC Camera.xcodeproj" -scheme AVCam -destination 'generic/platform=iOS' -derivedDataPath /tmp/SyncRECBuild CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
```

The project may emit existing iOS deprecation warnings from Apple's sample-derived code; treat new warnings separately from those baseline warnings.
