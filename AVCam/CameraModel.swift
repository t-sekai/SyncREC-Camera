/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that provides the interface to the features of the camera.
*/

import SwiftUI
import Combine
import UIKit

enum RemoteDirectorConfiguration {
    static let directorWebSocketURLDefaultsKey = "DirectorWebSocketURL"
    static let directorWebSocketURLInfoKey = "DirectorWebSocketURL"
    static let directorDeviceNameDefaultsKey = "DirectorDeviceName"
    static let defaultDirectorWebSocketURL = "ws://192.168.0.20:8765"
}

private enum RemoteTransferConfiguration {
    static let uploadedVideoFingerprintsDefaultsKey = "RemoteUploadedVideoFingerprints"
    static let maxRememberedFingerprints = 5_000
}

private enum ManualControlConfiguration {
    static let manualControlStateDefaultsKey = "ManualCameraControlState"
    static let selectedVideoCaptureModeDefaultsKey = "SelectedVideoCaptureModePreset"
    static let manualLockProfileDefaultsKey = "ManualLockProfileStorePath"
    static let manualLockProfileDirectoryName = "ManualCameraParameters"
    static let manualLockProfileFilename = "ManualLockProfileStore.json"
}

private enum TentacleSyncConfiguration {
    static let maxSamples = 160
    static let minSamplesForFit = 8
    static let fitIntervalSeconds: TimeInterval = 0.4
    static let hardReplaceThresholdMS = 100.0
    static let blendAlpha = 0.2
    static let staleSignalThresholdSeconds: TimeInterval = 3.0
}

/// An object that provides the interface to the features of the camera.
///
/// This object provides the default implementation of the `Camera` protocol, which defines the interface
/// to configure the camera hardware and capture media. `CameraModel` doesn't perform capture itself, but is an
/// `@Observable` type that mediates interactions between the app's SwiftUI views and `CaptureService`.
///
/// For SwiftUI previews and Simulator, the app uses `PreviewCameraModel` instead.
///
@MainActor
@Observable
final class CameraModel: Camera {
    
    /// The current status of the camera, such as unauthorized, running, or failed.
    private(set) var status = CameraStatus.unknown
    
    /// The current state of photo or movie capture.
    private(set) var captureActivity = CaptureActivity.idle
    
    /// A Boolean value that indicates whether the app is currently switching video devices.
    private(set) var isSwitchingVideoDevices = false
    
    /// A Boolean value that indicates whether the camera prefers showing a minimized set of UI controls.
    private(set) var prefersMinimizedUI = false
    
    /// A Boolean value that indicates whether the app is currently switching capture modes.
    private(set) var isSwitchingModes = false
    
    /// A Boolean value that indicates whether to show visual feedback when capture begins.
    private(set) var shouldFlashScreen = false
    
    /// A thumbnail for the last captured photo or video.
    private(set) var thumbnail: CGImage?
    
    /// An error that indicates the details of an error during photo or movie capture.
    private(set) var error: Error?
    
    /// An object that provides the connection between the capture session and the video preview layer.
    var previewSource: PreviewSource { captureService.previewSource }
    
    /// A Boolean that indicates whether the camera supports HDR video recording.
    private(set) var isHDRVideoSupported = false
    
    /// An object that saves captured media to a person's Photos library.
    private let mediaLibrary = MediaLibrary()

    /// An object that stores captured videos in the app sandbox.
    private let localVideoStore = LocalVideoStore()
    
    /// An object that manages the app's capture functionality.
    private let captureService = CaptureService()

    /// An object that manages Tentacle Sync E timecode over BLE.
    private let tentacleTimecodeService: TentacleTimecodeService
    /// An object that manages Tentacle timecode mirrored from the director over LAN.
    private let directorLANTimecodeService: DirectorLANTimecodeService

    /// An object that manages remote recording control from a laptop director.
    private let remoteDirectorClient: RemoteDirectorClient
    private var activeTimecodeInputMode: ResolvedTimecodeInputMode = .tentacleBLE

    /// The current Bluetooth connection state for Tentacle timecode.
    private(set) var tentacleConnectionState = TentacleConnectionState.idle

    /// The most recently received Tentacle timecode packet.
    private(set) var tentacleTimecode: TentacleTimecode?

    /// The continuously advancing Tentacle timecode display value.
    private(set) var displayedTentacleTimecode = ""

    /// The recording timer display value (`HH:MM:SS.mmm`) while actively recording.
    private(set) var displayedRecordingTimecode = ""

    /// The frame rate for the continuously advancing Tentacle timecode display value.
    private(set) var displayedTentacleFPS: Int?

    /// The WebSocket endpoint for the laptop director.
    var directorWebSocketURL = "" {
        didSet { handleDirectorWebSocketURLChange(from: oldValue) }
    }

    /// User-configurable device name shown to the laptop director.
    var directorDeviceName = UIDevice.current.name {
        didSet { handleDirectorDeviceNameChange(from: oldValue) }
    }

    /// Persisted list of local video files in the app sandbox.
    private(set) var localVideoURLs = [URL]()

    /// The current values and lock states for manual camera controls.
    var manualControlState = ManualCameraControlState.default {
        didSet { handleManualControlStateChange(from: oldValue) }
    }

    /// The capabilities and supported numeric ranges for manual camera controls.
    private(set) var manualControlCapabilities = ManualCameraControlCapabilities.unavailable

    /// The selected named video capture mode preset.
    var selectedVideoCaptureMode = VideoCaptureModePreset.hd1080p30 {
        didSet { handleSelectedVideoCaptureModeChange(from: oldValue) }
    }

    /// The supported named video capture modes for the active camera.
    private(set) var videoCaptureModeSupport = VideoCaptureModePreset.allCases.map {
        VideoCaptureModeSupport(preset: $0,
                                isSupported: false,
                                reason: "Camera not running.")
    }

    /// The actual applied video capture mode read back from AVFoundation.
    private(set) var videoCaptureModeStatus = VideoCaptureModeStatus.unavailable

    var isManualLockActive: Bool { activeManualLockProfile != nil }

    /// Draft and active deterministic camera profiles for copy/sync operation.
    private(set) var draftManualLockProfile: ManualLockProfile?
    private(set) var activeManualLockProfile: ManualLockProfile?
    private(set) var lastManualActualSnapshot: ManualCameraActualSnapshot?
    private(set) var lastManualApplyReport: ManualApplyReport?
    private(set) var lastManualValidationReport: ManualValidationReport?
    private(set) var manualProfileDriftStatus = ManualProfileDriftStatus.unknown

    /// A Boolean value that indicates whether this camera is armed for remote trigger.
    private(set) var isRemoteArmed = false

    /// The current app-level rig state for remote low-power operation.
    private(set) var rigState: RigState = .normalExit

    /// Whether the UI should present the black low-power rig screen.
    private(set) var isRigLowPowerUIActive = false

    /// Compact status lines shown in the low-power rig UI.
    private(set) var rigStatusLines = [String]()

    /// Prevents manual-control didSet recursion when updates originate from capture-device sync.
    private var isUpdatingManualControlState = false

    /// Tracks whether internal code is setting the capture mode directly.
    private var isApplyingCaptureModeInternally = false

    /// Tracks whether internal code is publishing selected video capture mode readback.
    private var isApplyingVideoCaptureModeInternally = false

    /// Tracks whether internal code is restoring the HDR UI value while a profile owns HDR/format.
    private var isApplyingHDRInternally = false

    /// The most recent prepared remote start command.
    private var pendingRemoteStart: PreparedRemoteStart?

    /// Task for a scheduled remote start.
    private var remoteStartTask: Task<Void, Never>?

    /// Task for a scheduled remote stop.
    private var remoteStopTask: Task<Void, Never>?

    /// Task for an active remote pull-videos upload job.
    private var remotePullVideosTask: Task<Void, Never>?

    /// Task for an active remote preview-photo capture/upload job.
    private var remotePreviewPhotoTask: Task<Void, Never>?

    /// Task that advances Tentacle timecode display between BLE updates.
    private var tentacleClockTask: Task<Void, Never>?

    /// Anchor for continuous Tentacle timecode display.
    private var tentacleClockAnchor: TentacleClockAnchor?

    /// Fitted local-to-remote Tentacle clock model.
    private var tentacleClockModel: TentacleClockModel?

    /// Rolling buffer of recent Tentacle sync samples.
    private var tentacleSyncSamples = [TentacleSyncSample]()

    /// Day-rollover offset in frames applied while unwrapping samples.
    private var tentacleRolloverOffsetFrames = 0

    /// Last unwrapped frame value observed from Tentacle.
    private var lastTentacleUnwrappedFrame: Int?

    /// Last uptime at which model fitting ran.
    private var lastTentacleModelFitUptime: TimeInterval = 0

    /// Last uptime when a valid Tentacle packet was ingested.
    private var lastTentacleSignalUptime: TimeInterval?

    /// Last displayed frame-of-day to avoid redundant UI publishes.
    private var lastPublishedTentacleFrameOfDay: Int?

    /// Task that advances the local recording timer display.
    private var recordingClockTask: Task<Void, Never>?

    /// Task that refreshes displayed unlocked manual-control values from the camera.
    private var manualControlRefreshTask: Task<Void, Never>?

    /// Anchor for a recording timer display seeded from Tentacle at record start.
    private var recordingClockAnchor: RecordingClockAnchor?

    /// Tentacle timecode frozen at recording start for metadata.
    private var recordingStartTimecodeMetadata: RecordingStartTimecodeMetadata?

    /// Calibration snapshot captured at recording start and persisted as sidecar JSON on stop.
    private var pendingRecordingCalibrationJSON: Data?

    /// Ensures camera state observers are only attached once.
    private var hasAttachedStateObservers = false

    /// Observes Guided Access mode changes so rig power policy can be restored immediately.
    private var guidedAccessObserver: NSObjectProtocol?

    /// Stores the pre-rig brightness when this app changes brightness for Guided Access rig mode.
    private var brightnessBeforeRigDim: CGFloat?
    
    /// Persistent state shared between the app and capture extension.
    private var cameraState = CameraState()

    private struct TentacleClockAnchor {
        let referenceTimecode: TentacleTimecode
        let referenceUptime: TimeInterval
    }

    private struct TentacleSyncSample {
        let localUptime: TimeInterval
        let remoteFramesOfDay: Int
        let unwrappedRemoteFrames: Int
        let fps: Int
    }

    private struct TentacleClockModel {
        let fps: Int
        let slopeFramesPerSecond: Double
        let interceptFrames: Double

        func predictUnwrappedFrames(at uptime: TimeInterval) -> Double {
            (slopeFramesPerSecond * uptime) + interceptFrames
        }

        func predictFramesOfDay(at uptime: TimeInterval) -> Int {
            let framesPerDay = max(1, 24 * 60 * 60 * fps)
            let roundedFrames = Int(predictUnwrappedFrames(at: uptime).rounded())
            return ((roundedFrames % framesPerDay) + framesPerDay) % framesPerDay
        }
    }

    private struct RecordingClockAnchor {
        let baseMillisecondsOfDay: Int
        let startUptime: TimeInterval
    }
    
    init() {
        tentacleTimecodeService = TentacleTimecodeService()
        directorLANTimecodeService = DirectorLANTimecodeService()
        remoteDirectorClient = RemoteDirectorClient()

        tentacleTimecodeService.onUpdate = { [weak self] connectionState, timecode in
            self?.handleTimecodeServiceUpdate(connectionState: connectionState,
                                              timecode: timecode,
                                              source: .tentacleBLE)
        }
        directorLANTimecodeService.onUpdate = { [weak self] connectionState, timecode in
            self?.handleTimecodeServiceUpdate(connectionState: connectionState,
                                              timecode: timecode,
                                              source: .directorLAN)
        }

        remoteDirectorClient.statusProvider = { [weak self] in
            guard let self else { return .empty }
            return self.remoteStatusPayload()
        }

        remoteDirectorClient.deviceNameProvider = { [weak self] in
            self?.directorDeviceName ?? UIDevice.current.name
        }

        remoteDirectorClient.commandHandler = { [weak self] command in
            guard let self else {
                return .failure("Camera model unavailable.")
            }
            return await self.handleRemoteDirectorCommand(command)
        }
        remoteDirectorClient.timeSyncHandler = { [weak self] packet in
            self?.directorLANTimecodeService.ingest(packet)
        }

        directorWebSocketURL = currentDirectorWebSocketURL()
        directorDeviceName = currentDirectorDeviceName()
        observeGuidedAccessChanges()
        updateRigStatusLines()
        isUpdatingManualControlState = true
        manualControlState = loadManualControlState()
        isUpdatingManualControlState = false
        isApplyingVideoCaptureModeInternally = true
        selectedVideoCaptureMode = loadSelectedVideoCaptureMode()
        videoCaptureModeStatus = VideoCaptureModeStatus(selectedPreset: selectedVideoCaptureMode,
                                                        actualPreset: nil,
                                                        actualWidth: nil,
                                                        actualHeight: nil,
                                                        actualFPS: nil,
                                                        supportedPresets: [],
                                                        detail: "Camera not running.")
        isApplyingVideoCaptureModeInternally = false

        let manualProfileStore = loadManualLockProfileStore()
        draftManualLockProfile = manualProfileStore.draftProfile
        activeManualLockProfile = manualProfileStore.activeDesiredProfile
        lastManualActualSnapshot = manualProfileStore.lastActualSnapshot
        lastManualApplyReport = manualProfileStore.lastApplyReport
        lastManualValidationReport = manualProfileStore.lastValidationReport
        manualProfileDriftStatus = manualProfileStore.driftStatus
    }

    deinit {
        let tentacleTimecodeService = tentacleTimecodeService
        let directorLANTimecodeService = directorLANTimecodeService
        let remoteDirectorClient = remoteDirectorClient
        Task { @MainActor in
            tentacleTimecodeService.stop()
            directorLANTimecodeService.stop()
            remoteDirectorClient.stop()
        }
    }

    private func handleDirectorWebSocketURLChange(from oldValue: String) {
        let normalized = directorWebSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized != directorWebSocketURL {
            directorWebSocketURL = normalized
            return
        }

        guard normalized != oldValue else { return }

        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey)
        } else {
            UserDefaults.standard.set(normalized, forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey)
        }

        guard status == .running else { return }
        remoteDirectorClient.stop()
        remoteDirectorClient.start()
        restartTimecodeServiceIfNeeded()
    }

    private func currentDirectorWebSocketURL() -> String {
        if let defaultsURL = UserDefaults.standard.string(forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey),
           !defaultsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return defaultsURL
        }
        if let infoURL = Bundle.main.object(forInfoDictionaryKey: RemoteDirectorConfiguration.directorWebSocketURLInfoKey) as? String,
           !infoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return infoURL
        }
        return RemoteDirectorConfiguration.defaultDirectorWebSocketURL
    }

    private func handleDirectorDeviceNameChange(from oldValue: String) {
        let normalized = directorDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = normalized.isEmpty ? UIDevice.current.name : normalized
        if resolved != directorDeviceName {
            directorDeviceName = resolved
            return
        }

        guard resolved != oldValue else { return }
        UserDefaults.standard.set(resolved, forKey: RemoteDirectorConfiguration.directorDeviceNameDefaultsKey)

        guard status == .running else { return }
        remoteDirectorClient.stop()
        remoteDirectorClient.start()
    }

    private func currentDirectorDeviceName() -> String {
        if let defaultsValue = UserDefaults.standard.string(forKey: RemoteDirectorConfiguration.directorDeviceNameDefaultsKey),
           !defaultsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return defaultsValue
        }
        return UIDevice.current.name
    }

    var isRigKioskMode: Bool {
        UIAccessibility.isGuidedAccessEnabled
    }

    private func observeGuidedAccessChanges() {
        guidedAccessObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.guidedAccessStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleGuidedAccessStatusChange()
            }
        }
    }

    private func handleGuidedAccessStatusChange() async {
        logger.info("Guided Access status changed. rigKioskMode=\(self.isRigKioskMode, privacy: .public)")
        if !isRigKioskMode && rigState == .armedIdle {
            rigState = .normalExit
            _ = await ensureCaptureSessionRunningForRig(reason: "guided_access_disabled")
        }
        applyRigPowerPolicy()
        updateRigStatusLines()
        remoteDirectorClient.sendStatusNow()
    }

    private func applyRigPowerPolicy() {
        // Camera/network control in this app is foreground-only. Guided Access can keep the app
        // onscreen as a rig/kiosk controller, but this code does not rely on background camera
        // access, screen-lock camera access, background modes, silent audio, or private APIs.
        let shouldKeepAwake = captureActivity.isRecording || rigState == .recording || rigState == .recordingPrepared || (isRigKioskMode && rigState == .armedIdle)
        setApplicationIdleTimerDisabled(shouldKeepAwake)

        let shouldDimForRig = isRigKioskMode && (rigState == .armedIdle || rigState == .preview || rigState == .recordingPrepared || rigState == .recording)
        if shouldDimForRig {
            if brightnessBeforeRigDim == nil {
                brightnessBeforeRigDim = UIScreen.main.brightness
            }
            UIScreen.main.brightness = 0.01
        } else if let brightnessBeforeRigDim {
            UIScreen.main.brightness = brightnessBeforeRigDim
            self.brightnessBeforeRigDim = nil
        }

        isRigLowPowerUIActive = isRigKioskMode && rigState == .armedIdle
    }

    private func setApplicationIdleTimerDisabled(_ disabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return }
        let selector = NSSelectorFromString("sharedApplication")
        guard let applicationClass = NSClassFromString("UIApplication") as? NSObject.Type,
              applicationClass.responds(to: selector),
              let unmanagedApplication = applicationClass.perform(selector),
              let application = unmanagedApplication.takeUnretainedValue() as? UIApplication else {
            return
        }
        application.isIdleTimerDisabled = disabled
    }

    private func updateRigStatusLines() {
        let batteryText = UIDevice.current.batteryLevelNormalized
            .map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown"
        let storageText = FileManager.default.availableStorageGB
            .map { String(format: "%.1f GB free", $0) } ?? "storage unknown"
        rigStatusLines = [
            "Device: \(directorDeviceName)",
            "ID: \(remoteDirectorClient.transferDeviceID())",
            "Director: \(remoteDirectorClient.connectionStatus)",
            "Battery: \(batteryText)",
            "Storage: \(storageText)",
            "Rig: \(rigState.rawValue)"
        ]
    }

    private func configuredTimecodeInputModeSetting() -> TimecodeInputModeSetting {
        if let rawValue = UserDefaults.standard.string(forKey: TimecodeInputConfiguration.modeDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let parsed = TimecodeInputModeSetting(rawValue: rawValue) {
            return parsed
        }
        return .auto
    }

    private func resolvedTimecodeInputMode() -> ResolvedTimecodeInputMode {
        switch configuredTimecodeInputModeSetting() {
        case .tentacleBLE:
            return .tentacleBLE
        case .directorLAN:
            return .directorLAN
        case .auto:
            return remoteDirectorClient.hasConfiguredDirectorURL ? .directorLAN : .tentacleBLE
        }
    }

    private func restartTimecodeServiceIfNeeded() {
        guard status == .running else { return }
        startActiveTimecodeService()
    }

    private func startActiveTimecodeService() {
        let resolvedMode = resolvedTimecodeInputMode()
        if resolvedMode != activeTimecodeInputMode {
            resetTentacleClockModel()
            tentacleConnectionState = .idle
            tentacleTimecode = nil
            displayedTentacleTimecode = ""
            displayedTentacleFPS = nil
        }

        activeTimecodeInputMode = resolvedMode
        switch resolvedMode {
        case .tentacleBLE:
            directorLANTimecodeService.stop()
            tentacleTimecodeService.start()
        case .directorLAN:
            tentacleTimecodeService.stop()
            directorLANTimecodeService.start()
        }
    }

    private func stopAllTimecodeServices() {
        tentacleTimecodeService.stop()
        directorLANTimecodeService.stop()
    }

    private func handleTimecodeServiceUpdate(connectionState: TentacleConnectionState,
                                             timecode: TentacleTimecode?,
                                             source: ResolvedTimecodeInputMode) {
        guard source == activeTimecodeInputMode else { return }

        let wasConnected = tentacleConnectionState.isConnected
        tentacleConnectionState = connectionState
        tentacleTimecode = timecode
        if connectionState.isConnected, let timecode {
            ingestTentacleTimecode(timecode, wasPreviouslyConnected: wasConnected)
        } else {
            lastTentacleSignalUptime = nil
            refreshTentacleClock()
        }
        remoteDirectorClient.sendStatusSoon()
    }

    private func handleManualControlStateChange(from oldValue: ManualCameraControlState) {
        guard !isUpdatingManualControlState else { return }
        guard manualControlState != oldValue else { return }

        persistManualControlState(manualControlState)
        guard status == .running else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.activeManualLockProfile != nil {
                await self.disableActiveManualLockProfile(reason: "manual_control_override")
            }
            await self.applyManualControlStateToDevice()
        }
    }

    private func handleSelectedVideoCaptureModeChange(from oldValue: VideoCaptureModePreset) {
        guard !isApplyingVideoCaptureModeInternally else { return }
        guard selectedVideoCaptureMode != oldValue else { return }

        if activeManualLockProfile != nil {
            isApplyingVideoCaptureModeInternally = true
            selectedVideoCaptureMode = oldValue
            isApplyingVideoCaptureModeInternally = false
            return
        }

        persistSelectedVideoCaptureMode(selectedVideoCaptureMode)
        guard status == .running else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applySelectedVideoCaptureModeToDevice(reason: "user_selected_capture_mode")
        }
    }

    private func applyManualControlStateToDevice() async {
        if activeManualLockProfile != nil {
            await reapplyActiveManualLockProfile(reason: "legacy_manual_apply_redirect")
            return
        }

        let snapshot = await captureService.applyManualControlState(manualControlState)

        isUpdatingManualControlState = true
        manualControlCapabilities = snapshot.capabilities
        manualControlState = snapshot.state
        isUpdatingManualControlState = false

        persistManualControlState(snapshot.state)
        startManualControlRefreshIfNeeded()
        remoteDirectorClient.sendStatusNow()
    }

    private func refreshManualControlStateFromDevice() async {
        guard status == .running, activeManualLockProfile == nil else { return }

        let snapshot = await captureService.currentManualControlSnapshot()
        guard snapshot.state != manualControlState || snapshot.capabilities != manualControlCapabilities else {
            return
        }

        isUpdatingManualControlState = true
        manualControlCapabilities = snapshot.capabilities
        manualControlState = snapshot.state
        isUpdatingManualControlState = false
    }

    private func refreshManualControlCapabilitiesFromDevice() async {
        let snapshot = await captureService.currentManualControlSnapshot()
        let capabilities = snapshot.capabilities
        guard capabilities.hasAnySupportedControl || manualControlCapabilities == .unavailable else {
            return
        }
        guard capabilities != manualControlCapabilities else { return }

        manualControlCapabilities = capabilities
    }

    private func refreshVideoCaptureModeStateFromDevice() async {
        videoCaptureModeSupport = await captureService.videoCaptureModeSupport()
        let status = await captureService.currentVideoCaptureModeStatus()
        publishVideoCaptureModeStatus(status)
    }

    private func publishVideoCaptureModeStatus(_ modeStatus: VideoCaptureModeStatus) {
        isApplyingVideoCaptureModeInternally = true
        if selectedVideoCaptureMode != modeStatus.selectedPreset {
            selectedVideoCaptureMode = modeStatus.selectedPreset
        }
        videoCaptureModeStatus = modeStatus
        videoCaptureModeSupport = VideoCaptureModePreset.allCases.map { preset in
            VideoCaptureModeSupport(preset: preset,
                                    isSupported: modeStatus.supportedPresets.contains(preset),
                                    reason: modeStatus.supportedPresets.contains(preset) ? nil : "No compatible format.")
        }
        isApplyingVideoCaptureModeInternally = false
    }

    private func applySelectedVideoCaptureModeToDevice(reason: String) async {
        guard activeManualLockProfile == nil else { return }
        let report = await captureService.applyVideoCaptureModePreset(selectedVideoCaptureMode,
                                                                      reason: reason)
        publishVideoCaptureModeStatus(report.status)
        if report.classification == .exactModeApplied || report.classification == .adjustedCompatibleMode {
            isUpdatingManualControlState = true
            manualControlState.fps = report.status.actualFPS ?? selectedVideoCaptureMode.fps
            manualControlState.isFPSLocked = true
            isUpdatingManualControlState = false
            persistManualControlState(manualControlState)
        }
        await refreshManualControlCapabilitiesFromDevice()
        await applyManualControlStateToDevice()
        remoteDirectorClient.sendStatusNow()
    }

    private func startManualControlRefreshIfNeeded() {
        guard status == .running, activeManualLockProfile == nil else {
            stopManualControlRefresh()
            return
        }
        guard manualControlRefreshTask == nil else { return }

        manualControlRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                guard self.status == .running, self.activeManualLockProfile == nil else { return }
                await self.refreshManualControlStateFromDevice()
            }
        }
    }

    private func stopManualControlRefresh() {
        manualControlRefreshTask?.cancel()
        manualControlRefreshTask = nil
    }

    private func disableActiveManualLockProfile(reason: String) async {
        guard activeManualLockProfile != nil else { return }

        activeManualLockProfile = nil
        manualProfileDriftStatus = .unknown
        await captureService.clearManualLockProfile(reason: reason)
        persistManualLockProfileStore()
        remoteDirectorClient.sendStatusNow()
        startManualControlRefreshIfNeeded()
    }

    private func loadManualControlState() -> ManualCameraControlState {
        guard let data = UserDefaults.standard.data(forKey: ManualControlConfiguration.manualControlStateDefaultsKey) else {
            return .default
        }
        guard let decoded = try? JSONDecoder().decode(ManualCameraControlState.self, from: data) else {
            return .default
        }
        return decoded
    }

    private func persistManualControlState(_ state: ManualCameraControlState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: ManualControlConfiguration.manualControlStateDefaultsKey)
    }

    private func loadSelectedVideoCaptureMode() -> VideoCaptureModePreset {
        guard let rawValue = UserDefaults.standard.string(forKey: ManualControlConfiguration.selectedVideoCaptureModeDefaultsKey),
              let preset = VideoCaptureModePreset(rawValue: rawValue) else {
            return .hd1080p30
        }
        return preset
    }

    private func persistSelectedVideoCaptureMode(_ preset: VideoCaptureModePreset) {
        UserDefaults.standard.set(preset.rawValue,
                                  forKey: ManualControlConfiguration.selectedVideoCaptureModeDefaultsKey)
    }

    private func installActiveManualLockProfile(reason: String, requestID: String? = nil) async {
        guard let profile = activeManualLockProfile else {
            await applyManualControlStateToDevice()
            return
        }

        stopManualControlRefresh()
        manualProfileDriftStatus = .reapplying
        let report = await captureService.installManualLockProfile(profile,
                                                                   reason: reason,
                                                                   requestID: requestID,
                                                                   dryRun: false)
        await refreshManualControlCapabilitiesFromDevice()
        updateManualLockProfileState(from: report)
        persistManualLockProfileStore()
        remoteDirectorClient.sendStatusNow()
    }

    private func reapplyActiveManualLockProfile(reason: String, requestID: String? = nil) async {
        guard activeManualLockProfile != nil else { return }

        stopManualControlRefresh()
        manualProfileDriftStatus = .reapplying
        let report = await captureService.reapplyManualLockProfile(reason: reason, requestID: requestID)
        await refreshManualControlCapabilitiesFromDevice()
        updateManualLockProfileState(from: report)
        persistManualLockProfileStore()
        remoteDirectorClient.sendStatusNow()
    }

    private func validateActiveManualLockProfile(reason: String, requestID: String? = nil) async -> ManualValidationReport? {
        guard activeManualLockProfile != nil else { return nil }
        let report = await captureService.validateManualLockProfile(reason: reason, requestID: requestID)
        updateManualLockProfileState(from: report)
        persistManualLockProfileStore()
        remoteDirectorClient.sendStatusNow()
        return report
    }

    private func updateManualLockProfileState(from report: ManualApplyReport) {
        lastManualApplyReport = report
        lastManualActualSnapshot = report.actualSnapshot

        if var profile = activeManualLockProfile {
            profile.lastApplyReport = report
            profile.actualValidatedSnapshot = report.actualSnapshot
            activeManualLockProfile = profile
        }

        switch report.classification {
        case .exactMatch, .adjustedMatch:
            manualProfileDriftStatus = .inSync
        case .drifted:
            manualProfileDriftStatus = .drifted
        case .incompatible, .failed, .refused:
            manualProfileDriftStatus = .failed
        case .unknown:
            manualProfileDriftStatus = .unknown
        }

        if report.classification == .exactMatch || report.classification == .adjustedMatch {
            updateManualControlStateFromActiveProfile(actualSnapshot: report.actualSnapshot)
        }
    }

    private func updateManualLockProfileState(from report: ManualValidationReport) {
        lastManualValidationReport = report
        lastManualActualSnapshot = report.actualSnapshot

        switch report.classification {
        case .exactMatch, .adjustedMatch:
            manualProfileDriftStatus = .inSync
        case .drifted:
            manualProfileDriftStatus = .drifted
        case .incompatible, .failed, .refused:
            manualProfileDriftStatus = .failed
        case .unknown:
            manualProfileDriftStatus = .unknown
        }
    }

    private func updateManualControlStateFromActiveProfile(actualSnapshot: ManualCameraActualSnapshot?) {
        guard let profile = activeManualLockProfile else { return }

        let desired = profile.desired
        var state = manualControlState

        if let preset = desired.captureModePreset ?? actualSnapshot?.actualCaptureModePreset {
            isApplyingVideoCaptureModeInternally = true
            selectedVideoCaptureMode = preset
            videoCaptureModeStatus = VideoCaptureModeStatus(selectedPreset: preset,
                                                            actualPreset: actualSnapshot?.actualCaptureModePreset,
                                                            actualWidth: actualSnapshot?.activeFormat?.width,
                                                            actualHeight: actualSnapshot?.activeFormat?.height,
                                                            actualFPS: actualSnapshot.flatMap { selectedFPS(from: $0) },
                                                            supportedPresets: actualSnapshot?.supportedCaptureModePresets ?? videoCaptureModeStatus.supportedPresets,
                                                            detail: nil)
            videoCaptureModeSupport = VideoCaptureModePreset.allCases.map { candidate in
                VideoCaptureModeSupport(preset: candidate,
                                        isSupported: videoCaptureModeStatus.supportedPresets.contains(candidate),
                                        reason: videoCaptureModeStatus.supportedPresets.contains(candidate) ? nil : "No compatible format.")
            }
            isApplyingVideoCaptureModeInternally = false
            persistSelectedVideoCaptureMode(preset)
        }

        if let selectedFPS = desired.selectedFPS {
            state.fps = selectedFPS
            state.isFPSLocked = true
        } else if let minDuration = desired.activeVideoMinFrameDurationSeconds,
                  let maxDuration = desired.activeVideoMaxFrameDurationSeconds,
                  minDuration > 0,
                  abs(minDuration - maxDuration) <= max(0.000_001, minDuration * 0.0005) {
            state.fps = 1.0 / minDuration
            state.isFPSLocked = true
        } else if let actualSnapshot,
                  let actualFPS = selectedFPS(from: actualSnapshot) {
            state.fps = actualFPS
            state.isFPSLocked = true
        }

        if let iso = desired.iso ?? actualSnapshot?.exposure?.iso {
            state.iso = iso
            state.isISOLocked = desired.iso != nil
        }

        if let shutter = desired.exposureDurationSeconds ?? actualSnapshot?.exposure?.exposureDurationSeconds {
            state.shutterSeconds = shutter
            state.isShutterLocked = desired.exposureDurationSeconds != nil
        }

        if desired.whiteBalanceGains != nil ||
            desired.whiteBalanceTemperature != nil ||
            desired.whiteBalanceTint != nil {
            if let temperature = desired.whiteBalanceTemperature ?? actualSnapshot?.whiteBalance?.temperature {
                state.whiteBalanceTemperature = temperature
            }
            if let tint = desired.whiteBalanceTint ?? actualSnapshot?.whiteBalance?.tint {
                state.tint = tint
            }
            state.isWhiteBalanceLocked = true
            state.isTintLocked = true
        }

        if let focus = desired.focusLensPosition ?? actualSnapshot?.focus?.lensPosition {
            state.focusLensPosition = focus
            state.isFocusLocked = desired.focusLensPosition != nil
        }

        isUpdatingManualControlState = true
        manualControlState = state
        isUpdatingManualControlState = false
        persistManualControlState(state)
    }

    private func loadManualLockProfileStore() -> ManualLockProfileStore {
        if let url = manualLockProfileStoreURL(),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(ManualLockProfileStore.self, from: data) {
            return decoded
        }

        if let legacyURL = legacyManualLockProfileStoreURL(),
           let data = try? Data(contentsOf: legacyURL),
           let decoded = try? JSONDecoder().decode(ManualLockProfileStore.self, from: data) {
            return decoded
        }

        return ManualLockProfileStore()
    }

    private func persistManualLockProfileStore() {
        guard let url = manualLockProfileStoreURL() else { return }
        let store = ManualLockProfileStore(activeDesiredProfile: activeManualLockProfile,
                                           draftProfile: draftManualLockProfile,
                                           lastActualSnapshot: lastManualActualSnapshot,
                                           lastApplyReport: lastManualApplyReport,
                                           lastValidationReport: lastManualValidationReport,
                                           driftStatus: manualProfileDriftStatus)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store) else { return }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
            try data.write(to: url, options: [.atomic])
            UserDefaults.standard.set(url.path, forKey: ManualControlConfiguration.manualLockProfileDefaultsKey)
        } catch {
            logger.error("Unable to persist manual lock profile store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func manualLockProfileStoreURL() -> URL? {
        manualLockProfileStoreDirectoryURL()?
            .appendingPathComponent(ManualControlConfiguration.manualLockProfileFilename,
                                    isDirectory: false)
    }

    private func manualLockProfileStoreDirectoryURL() -> URL? {
        if let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask).first {
            return directory.appendingPathComponent(ManualControlConfiguration.manualLockProfileDirectoryName,
                                                    isDirectory: true)
        }

        if let directory = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first {
            return directory.appendingPathComponent(ManualControlConfiguration.manualLockProfileDirectoryName,
                                                    isDirectory: true)
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(ManualControlConfiguration.manualLockProfileDirectoryName,
                                    isDirectory: true)
    }

    private func legacyManualLockProfileStoreURL() -> URL? {
        if let storedPath = UserDefaults.standard.string(forKey: ManualControlConfiguration.manualLockProfileDefaultsKey),
           !storedPath.isEmpty {
            let url = URL(fileURLWithPath: storedPath)
            if url.path != manualLockProfileStoreURL()?.path {
                return url
            }
        }
        return nil
    }

    private func seedTentacleClock(with timecode: TentacleTimecode, at uptime: TimeInterval) {
        tentacleClockAnchor = TentacleClockAnchor(referenceTimecode: timecode, referenceUptime: uptime)
        displayedTentacleTimecode = timecode.formatted
        displayedTentacleFPS = timecode.fps
        lastPublishedTentacleFrameOfDay = timecode.totalFramesOfDay
        startTentacleClockIfNeeded()
    }

    private func startTentacleClockIfNeeded() {
        guard tentacleClockTask == nil else { return }
        tentacleClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self else { break }
                self.refreshTentacleClock()
            }
        }
    }

    private func refreshTentacleClock() {
        let current = currentTentacleTimecode() ?? fallbackDirectorClockTimecode()
        guard let current else {
            if !displayedTentacleTimecode.isEmpty || displayedTentacleFPS != nil {
                displayedTentacleTimecode = ""
                displayedTentacleFPS = nil
                lastPublishedTentacleFrameOfDay = nil
            }
            return
        }
        let frameOfDay = current.totalFramesOfDay
        guard frameOfDay != lastPublishedTentacleFrameOfDay else { return }

        displayedTentacleTimecode = current.formatted
        displayedTentacleFPS = current.fps
        lastPublishedTentacleFrameOfDay = frameOfDay
    }

    private func currentTentacleTimecode() -> TentacleTimecode? {
        let now = ProcessInfo.processInfo.systemUptime
        guard isTentacleSignalFresh(at: now) else { return nil }

        if let model = tentacleClockModel {
            return timecodeFrom(totalFramesOfDay: model.predictFramesOfDay(at: now), fps: model.fps)
        }

        guard let anchor = tentacleClockAnchor else {
            return tentacleTimecode
        }
        let elapsed = max(0, now - anchor.referenceUptime)
        return anchor.referenceTimecode.advanced(by: elapsed)
    }

    private func recordingSeedTentacleTimecode() -> TentacleTimecode? {
        if let timecode = currentTentacleTimecode() {
            return timecode
        }
        if let fallback = fallbackDirectorClockTimecode() {
            return fallback
        }

        guard tentacleConnectionState.isConnected else { return nil }
        let now = ProcessInfo.processInfo.systemUptime

        if let model = tentacleClockModel {
            return timecodeFrom(totalFramesOfDay: model.predictFramesOfDay(at: now), fps: model.fps)
        }
        if let anchor = tentacleClockAnchor {
            let elapsed = max(0, now - anchor.referenceUptime)
            return anchor.referenceTimecode.advanced(by: elapsed)
        }
        return tentacleTimecode
    }

    private func fallbackDirectorClockTimecode() -> TentacleTimecode? {
        guard activeTimecodeInputMode == .directorLAN else { return nil }
        let directorUnixMS = remoteDirectorClient.currentDirectorSynchronizedUnixMilliseconds()
        let date = Date(timeIntervalSince1970: Double(directorUnixMS) / 1000.0)
        let fps = max(displayedTentacleFPS ?? tentacleTimecode?.fps ?? 30, 1)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        guard let hours = components.hour,
              let minutes = components.minute,
              let seconds = components.second else {
            return nil
        }
        let nanoseconds = components.nanosecond ?? 0
        let frame = min(max(Int((Double(nanoseconds) / 1_000_000_000.0) * Double(fps)), 0), fps - 1)
        return TentacleTimecode(fps: fps,
                                hours: hours,
                                minutes: minutes,
                                seconds: seconds,
                                frames: frame)
    }

    private func currentRecordingStartMetadata() -> RecordingStartTimecodeMetadata? {
        guard let timecode = recordingSeedTentacleTimecode() else { return nil }
        return RecordingStartTimecodeMetadata(timecode: timecode.formatted,
                                              fps: timecode.fps,
                                              source: activeTimecodeInputMode.sourceIdentifier)
    }

    private func startRecordingClock(seedTimecode: TentacleTimecode?) {
        let baseMilliseconds = seedTimecode.map { millisecondsOfDay(from: $0) } ?? 0
        recordingClockAnchor = RecordingClockAnchor(baseMillisecondsOfDay: baseMilliseconds,
                                                    startUptime: ProcessInfo.processInfo.systemUptime)
        displayedRecordingTimecode = formatClockWithMilliseconds(millisecondsOfDay: baseMilliseconds)

        recordingClockTask?.cancel()
        recordingClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard let self else { break }
                self.refreshRecordingClock()
            }
        }
    }

    private func stopRecordingClock() {
        recordingClockTask?.cancel()
        recordingClockTask = nil
        recordingClockAnchor = nil
        displayedRecordingTimecode = ""
    }

    private func refreshRecordingClock() {
        guard let anchor = recordingClockAnchor else { return }
        let elapsedUptime = max(0, ProcessInfo.processInfo.systemUptime - anchor.startUptime)
        let elapsedMilliseconds = Int((elapsedUptime * 1000).rounded(.down))

        let dayMilliseconds = 24 * 60 * 60 * 1000
        let totalMilliseconds = (anchor.baseMillisecondsOfDay + elapsedMilliseconds) % dayMilliseconds
        displayedRecordingTimecode = formatClockWithMilliseconds(millisecondsOfDay: totalMilliseconds)
    }

    private func millisecondsOfDay(from timecode: TentacleTimecode) -> Int {
        let secondsMilliseconds = timecode.secondsOfDay * 1000
        let frameMilliseconds = Int((Double(timecode.frames) / Double(max(timecode.fps, 1)) * 1000.0).rounded(.down))
        return secondsMilliseconds + frameMilliseconds
    }

    private func formatClockWithMilliseconds(millisecondsOfDay: Int) -> String {
        let dayMilliseconds = 24 * 60 * 60 * 1000
        let normalized = ((millisecondsOfDay % dayMilliseconds) + dayMilliseconds) % dayMilliseconds
        let totalSeconds = normalized / 1000
        let milliseconds = normalized % 1000

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }

    private func ingestTentacleTimecode(_ timecode: TentacleTimecode, wasPreviouslyConnected: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        lastTentacleSignalUptime = now
        let needsHardReset = !wasPreviouslyConnected || displayedTentacleFPS != timecode.fps
        if needsHardReset {
            resetTentacleClockModel()
            seedTentacleClock(with: timecode, at: now)
        } else if tentacleClockAnchor == nil {
            seedTentacleClock(with: timecode, at: now)
        }

        appendTentacleSample(timecode: timecode, localUptime: now)
        updateTentacleClockModelIfNeeded(localUptime: now, force: needsHardReset)
        refreshTentacleClock()
    }

    private func resetTentacleClockModel() {
        tentacleClockModel = nil
        tentacleSyncSamples.removeAll(keepingCapacity: true)
        tentacleRolloverOffsetFrames = 0
        lastTentacleUnwrappedFrame = nil
        lastTentacleModelFitUptime = 0
        lastTentacleSignalUptime = nil
        tentacleClockAnchor = nil
        lastPublishedTentacleFrameOfDay = nil
    }

    private func isTentacleSignalFresh(at uptime: TimeInterval) -> Bool {
        guard let lastSignalUptime = lastTentacleSignalUptime else { return false }
        return (uptime - lastSignalUptime) <= TentacleSyncConfiguration.staleSignalThresholdSeconds
    }

    private func appendTentacleSample(timecode: TentacleTimecode, localUptime: TimeInterval) {
        let fps = timecode.fps
        let framesPerDay = max(1, 24 * 60 * 60 * fps)
        let remoteFrames = timecode.totalFramesOfDay
        let unwrappedFrames: Int

        if let previous = lastTentacleUnwrappedFrame {
            var offset = tentacleRolloverOffsetFrames
            var candidate = remoteFrames + offset

            if candidate < previous - framesPerDay / 2 {
                offset += framesPerDay
                candidate = remoteFrames + offset
            } else if candidate > previous + framesPerDay / 2 {
                offset -= framesPerDay
                candidate = remoteFrames + offset
            }

            tentacleRolloverOffsetFrames = offset
            unwrappedFrames = candidate
        } else {
            tentacleRolloverOffsetFrames = 0
            unwrappedFrames = remoteFrames
        }

        lastTentacleUnwrappedFrame = unwrappedFrames
        tentacleSyncSamples.append(TentacleSyncSample(localUptime: localUptime,
                                                      remoteFramesOfDay: remoteFrames,
                                                      unwrappedRemoteFrames: unwrappedFrames,
                                                      fps: fps))

        if tentacleSyncSamples.count > TentacleSyncConfiguration.maxSamples {
            let overflow = tentacleSyncSamples.count - TentacleSyncConfiguration.maxSamples
            tentacleSyncSamples.removeFirst(overflow)
        }
    }

    private func updateTentacleClockModelIfNeeded(localUptime: TimeInterval, force: Bool) {
        guard tentacleSyncSamples.count >= TentacleSyncConfiguration.minSamplesForFit else { return }
        if !force && (localUptime - lastTentacleModelFitUptime) < TentacleSyncConfiguration.fitIntervalSeconds {
            return
        }
        lastTentacleModelFitUptime = localUptime

        let recentSamples = Array(tentacleSyncSamples.suffix(TentacleSyncConfiguration.maxSamples / 2))
        guard let newModel = robustTentacleFit(samples: recentSamples) else { return }

        guard let oldModel = tentacleClockModel, oldModel.fps == newModel.fps else {
            tentacleClockModel = newModel
            return
        }

        let oldFramesNow = oldModel.predictUnwrappedFrames(at: localUptime)
        let newFramesNow = newModel.predictUnwrappedFrames(at: localUptime)
        let diffMS = ((newFramesNow - oldFramesNow) / Double(oldModel.fps)) * 1000.0

        if abs(diffMS) > TentacleSyncConfiguration.hardReplaceThresholdMS {
            tentacleClockModel = newModel
        } else {
            tentacleClockModel = blendTentacleClockModel(old: oldModel,
                                                         new: newModel,
                                                         alpha: TentacleSyncConfiguration.blendAlpha)
        }
    }

    private func robustTentacleFit(samples: [TentacleSyncSample]) -> TentacleClockModel? {
        guard samples.count >= 2 else { return nil }
        let orderedSamples = samples.sorted(by: { $0.localUptime < $1.localUptime })
        guard var model = fitTentacleLinearModel(samples: orderedSamples) else { return nil }

        let errorsMS = residualsMS(model: model, samples: orderedSamples)
        let thresholdMS = max(1.5, 3.0 * median(errorsMS.map { abs($0) }))
        let filteredSamples = zip(orderedSamples, errorsMS)
            .compactMap { sample, errorMS in
                abs(errorMS) <= thresholdMS ? sample : nil
            }

        if filteredSamples.count >= 4, let refined = fitTentacleLinearModel(samples: filteredSamples) {
            model = refined
        }

        return model
    }

    private func fitTentacleLinearModel(samples: [TentacleSyncSample]) -> TentacleClockModel? {
        guard samples.count >= 2 else { return nil }
        let fps = samples[0].fps
        guard samples.allSatisfy({ $0.fps == fps }) else { return nil }

        guard let firstUptime = samples.first?.localUptime,
              let lastUptime = samples.last?.localUptime,
              (lastUptime - firstUptime) > 0.05 else {
            return nil
        }

        let xs = samples.map(\.localUptime)
        let ys = samples.map { Double($0.unwrappedRemoteFrames) }

        let xMean = xs.reduce(0, +) / Double(xs.count)
        let yMean = ys.reduce(0, +) / Double(ys.count)

        let denom = zip(xs, ys).reduce(0.0) { partial, pair in
            let dx = pair.0 - xMean
            return partial + (dx * dx)
        }
        guard denom > 0 else { return nil }

        let numer = zip(xs, ys).reduce(0.0) { partial, pair in
            let dx = pair.0 - xMean
            let dy = pair.1 - yMean
            return partial + (dx * dy)
        }

        var slope = numer / denom
        if !slope.isFinite {
            return nil
        }

        let idealSlope = Double(fps)
        if slope < idealSlope * 0.5 || slope > idealSlope * 1.5 {
            slope = idealSlope
        }

        let intercept = yMean - (slope * xMean)
        return TentacleClockModel(fps: fps, slopeFramesPerSecond: slope, interceptFrames: intercept)
    }

    private func residualsMS(model: TentacleClockModel, samples: [TentacleSyncSample]) -> [Double] {
        samples.map { sample in
            let predicted = model.predictUnwrappedFrames(at: sample.localUptime)
            let errorFrames = predicted - Double(sample.unwrappedRemoteFrames)
            return (errorFrames / Double(sample.fps)) * 1000.0
        }
    }

    private func blendTentacleClockModel(old: TentacleClockModel,
                                         new: TentacleClockModel,
                                         alpha: Double) -> TentacleClockModel {
        guard old.fps == new.fps else { return new }
        let clampedAlpha = min(max(alpha, 0), 1)
        let slope = ((1.0 - clampedAlpha) * old.slopeFramesPerSecond) + (clampedAlpha * new.slopeFramesPerSecond)
        let intercept = ((1.0 - clampedAlpha) * old.interceptFrames) + (clampedAlpha * new.interceptFrames)
        return TentacleClockModel(fps: old.fps, slopeFramesPerSecond: slope, interceptFrames: intercept)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func timecodeFrom(totalFramesOfDay: Int, fps: Int) -> TentacleTimecode? {
        guard fps > 0 else { return nil }
        let framesPerDay = 24 * 60 * 60 * fps
        let normalizedFrames = ((totalFramesOfDay % framesPerDay) + framesPerDay) % framesPerDay
        let hours = normalizedFrames / (3600 * fps)
        let minuteRemainder = normalizedFrames % (3600 * fps)
        let minutes = minuteRemainder / (60 * fps)
        let secondRemainder = minuteRemainder % (60 * fps)
        let seconds = secondRemainder / fps
        let frames = secondRemainder % fps
        return TentacleTimecode(fps: fps, hours: hours, minutes: minutes, seconds: seconds, frames: frames)
    }
    
    // MARK: - Starting the camera
    /// Start the camera and begin the stream of data.
    func start() async {
        if let failure = await ensureCaptureSessionRunningForRig(reason: "camera_start") {
            logger.error("Failed to start capture service. \(failure.detail, privacy: .public)")
            return
        }
        if rigState == .shutdown {
            rigState = .normalExit
        }
        remoteDirectorClient.start()
        if rigState == .armedIdle {
            _ = await transitionRigState(to: .armedIdle, reason: "camera_start_restore_armed_idle")
        } else {
            applyRigPowerPolicy()
            updateRigStatusLines()
        }
    }

    func stop() async {
        if captureActivity.isRecording {
            await toggleRecording()
        }

        remotePullVideosTask?.cancel()
        remotePullVideosTask = nil
        remotePreviewPhotoTask?.cancel()
        remotePreviewPhotoTask = nil
        await captureService.stop()
        rigState = .normalExit
        isRemoteArmed = false
        applyRigPowerPolicy()
        updateRigStatusLines()
        stopAllTimecodeServices()
        remoteDirectorClient.stop()
        stopRecordingClock()
        stopManualControlRefresh()
        displayedTentacleTimecode = ""
        displayedTentacleFPS = nil

        if status == .running || status == .interrupted {
            status = .unknown
        }
    }
    
    /// Synchronizes the persistent camera state.
    ///
    /// `CameraState` represents the persistent state, such as the capture mode, that the app and extension share.
    func syncState() async {
        cameraState = await CameraState.current
        cameraState.captureMode = .video
        isApplyingCaptureModeInternally = true
        captureMode = .video
        isApplyingCaptureModeInternally = false
        qualityPrioritization = cameraState.qualityPrioritization
        isLivePhotoEnabled = cameraState.isLivePhotoEnabled
        if activeManualLockProfile?.policy.ownsHDRAndFormat != true {
            isHDRVideoEnabled = cameraState.isVideoHDREnabled
        }
    }

    func refreshLocalVideos() async {
        localVideoURLs = await localVideoStore.loadStoredVideos()
    }

    func deleteLocalVideo(_ url: URL) async {
        localVideoURLs = await localVideoStore.delete(urls: [url])
    }

    func deleteLocalVideos(at offsets: IndexSet) async {
        let urlsToDelete: [URL] = offsets.compactMap { index -> URL? in
            guard localVideoURLs.indices.contains(index) else { return nil }
            return localVideoURLs[index]
        }
        localVideoURLs = await localVideoStore.delete(urls: urlsToDelete)
    }
    
    // MARK: - Changing modes and devices
    
    /// A value that indicates the mode of capture for the camera.
    var captureMode = CaptureMode.video {
        didSet {
            if captureMode != .video {
                isApplyingCaptureModeInternally = true
                captureMode = .video
                isApplyingCaptureModeInternally = false
                cameraState.captureMode = .video
                return
            }
            guard status == .running, !isApplyingCaptureModeInternally else { return }
            Task {
                isSwitchingModes = true
                defer { isSwitchingModes = false }
                // Update the configuration of the capture service for the new mode.
                try? await captureService.setCaptureMode(captureMode)
                // Update the persistent state value.
                cameraState.captureMode = .video
                await refreshVideoCaptureModeStateFromDevice()
                await applySelectedVideoCaptureModeToDevice(reason: "set_capture_mode")
                await applyManualControlStateToDevice()
                remoteDirectorClient.sendStatusNow()
            }
        }
    }
    
    /// Selects the next available video device for capture.
    func switchVideoDevices() async {
        isSwitchingVideoDevices = true
        defer { isSwitchingVideoDevices = false }
        await captureService.selectNextVideoDevice()
        if activeManualLockProfile != nil {
            await reapplyActiveManualLockProfile(reason: "switch_video_devices")
        } else {
            await refreshVideoCaptureModeStateFromDevice()
            await applySelectedVideoCaptureModeToDevice(reason: "switch_video_devices_capture_mode")
            await applyManualControlStateToDevice()
        }
    }
    
    // MARK: - Photo capture
    
    /// Captures a photo and writes it to the user's Photos library.
    func capturePhoto() async {
        do {
            let photoFeatures = PhotoFeatures(isLivePhotoEnabled: isLivePhotoEnabled, qualityPrioritization: qualityPrioritization)
            let photo = try await captureService.capturePhoto(with: photoFeatures)
            try await mediaLibrary.save(photo: photo)
        } catch {
            self.error = error
        }
    }
    
    /// A Boolean value that indicates whether to capture Live Photos when capturing stills.
    var isLivePhotoEnabled = true {
        didSet {
            // Update the persistent state value.
            cameraState.isLivePhotoEnabled = isLivePhotoEnabled
        }
    }
    
    /// A value that indicates how to balance the photo capture quality versus speed.
    var qualityPrioritization = QualityPrioritization.quality {
        didSet {
            // Update the persistent state value.
            cameraState.qualityPrioritization = qualityPrioritization
        }
    }
    
    /// Performs a focus and expose operation at the specified screen point.
    func focusAndExpose(at point: CGPoint) async {
        if activeManualLockProfile != nil {
            return
        }
        if manualControlState.isFocusLocked {
            return
        }
        let adjustExposure = !manualControlState.hasAnyExposureLock
        await captureService.focusAndExpose(at: point, adjustExposure: adjustExposure)
    }
    
    /// Sets the `showCaptureFeedback` state to indicate that capture is underway.
    private func flashScreen() {
        shouldFlashScreen = true
        withAnimation(.linear(duration: 0.01)) {
            shouldFlashScreen = false
        }
    }
    
    // MARK: - Video capture
    /// A Boolean value that indicates whether the camera captures video in HDR format.
    var isHDRVideoEnabled = false {
        didSet {
            guard !isApplyingHDRInternally else { return }
            if activeManualLockProfile?.policy.ownsHDRAndFormat == true {
                isApplyingHDRInternally = true
                isHDRVideoEnabled = oldValue
                isApplyingHDRInternally = false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.reapplyActiveManualLockProfile(reason: "hdr_toggle_blocked_by_profile")
                }
                return
            }
            guard status == .running, captureMode == .video else { return }
            Task {
                await captureService.setHDRVideoEnabled(isHDRVideoEnabled)
                // Update the persistent state value.
                cameraState.isVideoHDREnabled = isHDRVideoEnabled
            }
        }
    }
    
    /// Toggles the state of recording.
    func toggleRecording() async {
        switch await captureService.captureActivity {
        case .movieCapture:
            let calibrationJSON = pendingRecordingCalibrationJSON
            pendingRecordingCalibrationJSON = nil
            do {
                // If currently recording, stop and persist the movie to local app storage.
                let movie = try await captureService.stopRecording()
                _ = try await localVideoStore.store(movie: movie, calibrationJSON: calibrationJSON)
                localVideoURLs = await localVideoStore.loadStoredVideos()
                recordingStartTimecodeMetadata = nil
                stopRecordingClock()
                rigState = isRemoteArmed ? .recordingPrepared : .normalExit
                applyRigPowerPolicy()
                updateRigStatusLines()
            } catch {
                logger.error("Failed to persist local video: \(error.localizedDescription, privacy: .public)")
                self.error = error
            }
        default:
            // In any other case, start recording.
            let recordingSeedTimecode = recordingSeedTentacleTimecode()
            recordingStartTimecodeMetadata = currentRecordingStartMetadata()
            let calibrationJSON = await captureService.recordingCalibrationJSONData()
            let validation = await captureService.startRecording(recordingStartMetadata: recordingStartTimecodeMetadata)
            if let validation {
                updateManualLockProfileState(from: validation)
                persistManualLockProfileStore()
                guard validation.classification == .exactMatch || validation.classification == .adjustedMatch else {
                    recordingStartTimecodeMetadata = nil
                    applyRigPowerPolicy()
                    remoteDirectorClient.sendStatusNow()
                    return
                }
            }
            pendingRecordingCalibrationJSON = calibrationJSON
            startRecordingClock(seedTimecode: recordingSeedTimecode)
            rigState = .recording
            applyRigPowerPolicy()
            updateRigStatusLines()
        }
    }
    
    // MARK: - Internal state observations
    
    // Set up camera's state observations.
    private func observeState() {
        Task {
            // Await new thumbnails that the media library generates when saving a file.
            for await thumbnail in mediaLibrary.thumbnails.compactMap({ $0 }) {
                self.thumbnail = thumbnail
            }
        }
        
        Task {
            // Await new capture activity values from the capture service.
            for await activity in await captureService.$captureActivity.values {
                if activity.willCapture {
                    // Flash the screen to indicate capture is starting.
                    flashScreen()
                } else {
                    // Forward the activity to the UI.
                    captureActivity = activity
                    if !activity.isRecording, recordingClockAnchor != nil {
                        stopRecordingClock()
                    }
                    if activity.isRecording {
                        rigState = .recording
                    }
                    applyRigPowerPolicy()
                    updateRigStatusLines()
                    remoteDirectorClient.sendStatusNow()
                }
            }
        }
        
        Task {
            // Await updates to the capabilities that the capture service advertises.
            for await capabilities in await captureService.$captureCapabilities.values {
                isHDRVideoSupported = capabilities.isHDRSupported
                cameraState.isVideoHDRSupported = capabilities.isHDRSupported
                await applyManualControlStateToDevice()
            }
        }
        
        Task {
            // Await updates to a person's interaction with the Camera Control HUD.
            for await isShowingFullscreenControls in await captureService.$isShowingFullscreenControls.values {
                withAnimation {
                    // Prefer showing a minimized UI when capture controls enter a fullscreen appearance.
                    prefersMinimizedUI = isShowingFullscreenControls
                }
            }
        }
    }

    private struct PreparedRemoteStart {
        let sessionID: String
        let startAtUnixMS: Int64
    }

    private struct RemotePullVideosRequest {
        let jobID: String
        let policy: RemotePullVideosPolicy
        let maxFiles: Int
        let uploadURLString: String?
    }

    private struct RemotePreviewPhotoRequest {
        let requestID: String
        let batchID: String
        let uploadURLString: String?
        let longEdge: Int
        let jpegQuality: Double
        let uploadJitterSeconds: Double
        let attempt: Int
    }

    private struct RemoteTransferItem {
        let videoURL: URL
        let sidecarURL: URL?
        let fingerprint: String
        let videoBytes: Int64
        let sidecarBytes: Int64
    }

    private struct LocalVideoStorageSummary {
        let totalCount: Int
        let uploadedCount: Int
        let pendingUploadCount: Int
        let totalBytes: Int64
        let uploadedBytes: Int64
        let pendingUploadBytes: Int64

        static let empty = LocalVideoStorageSummary(totalCount: 0,
                                                    uploadedCount: 0,
                                                    pendingUploadCount: 0,
                                                    totalBytes: 0,
                                                    uploadedBytes: 0,
                                                    pendingUploadBytes: 0)
    }

    private enum RemotePullVideosPolicy {
        case newOnly
        case all

        init(rawValue: String) {
            switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "all", "all_files", "everything":
                self = .all
            default:
                self = .newOnly
            }
        }
    }

    private func remoteStatusPayload() -> RemoteDirectorStatusPayload {
        updateRigStatusLines()
        let storageGB = FileManager.default.availableStorageGB
        let currentTimecode = currentTentacleTimecode()
        let localVideoSummary = currentLocalVideoStorageSummary()
        return RemoteDirectorStatusPayload(
            recording: captureActivity.isRecording,
            armed: isRemoteArmed,
            battery: UIDevice.current.batteryLevelNormalized,
            storageGB: storageGB,
            localVideoCount: localVideoSummary.totalCount,
            uploadedVideoCount: localVideoSummary.uploadedCount,
            pendingUploadVideoCount: localVideoSummary.pendingUploadCount,
            localVideoBytes: localVideoSummary.totalBytes,
            uploadedVideoBytes: localVideoSummary.uploadedBytes,
            pendingUploadVideoBytes: localVideoSummary.pendingUploadBytes,
            selectedCaptureMode: videoCaptureModeStatus.selectedPreset.rawValue,
            actualVideoWidth: videoCaptureModeStatus.actualWidth,
            actualVideoHeight: videoCaptureModeStatus.actualHeight,
            actualVideoFPS: videoCaptureModeStatus.actualFPS,
            actualCaptureMode: videoCaptureModeStatus.actualPreset?.rawValue,
            supportedCaptureModes: videoCaptureModeStatus.supportedPresets.map(\.rawValue),
            tentacleState: tentacleConnectionState.remoteControlValue,
            timecode: currentTimecode?.formatted ?? displayedTentacleTimecode,
            fps: currentTimecode?.fps ?? displayedTentacleFPS,
            cameraParamsStatus: activeManualLockProfile == nil ? "none" : manualProfileDriftStatus.rawValue,
            cameraParamsSummary: manualCameraParamsSummary(),
            rigState: rigState,
            preferredStatusIntervalMS: rigState == .armedIdle ? 5_000 : 1_000
        )
    }

    private func transitionRigState(to targetState: RigState,
                                    reason: String,
                                    stopRecordingIfNeeded: Bool = false) async -> RemoteDirectorCommandReply {
        logger.info("Rig transition \(self.rigState.rawValue, privacy: .public) -> \(targetState.rawValue, privacy: .public), reason=\(reason, privacy: .public)")
        let isRecording = await isCapturePipelineRecording()

        switch targetState {
        case .armedIdle:
            if isRecording {
                guard stopRecordingIfNeeded else {
                    return rigReply(ok: false,
                                    message: "Refused to enter armed idle while recording.",
                                    error: "recording_active")
                }
                let stopReply = await stopRigRecording(reason: reason)
                guard stopReply.ok else { return stopReply }
            }

            remoteStartTask?.cancel()
            remoteStopTask?.cancel()
            pendingRemoteStart = nil
            isRemoteArmed = true
            stopManualControlRefresh()
            await refreshManualControlCapabilitiesFromDevice()
            await captureService.stop()
            rigState = .armedIdle
            applyRigPowerPolicy()
            updateRigStatusLines()
            remoteDirectorClient.sendStatusNow()
            return rigReply(ok: true, message: "Entered armed idle.")

        case .preview:
            if isRecording {
                return rigReply(ok: false,
                                message: "Refused preview while recording.",
                                error: "recording_active")
            }
            if let failure = await ensureCaptureSessionRunningForRig(reason: reason) {
                return failure
            }
            rigState = .preview
            applyRigPowerPolicy()
            updateRigStatusLines()
            remoteDirectorClient.sendStatusNow()
            return rigReply(ok: true, message: "Preview session ready.")

        case .recordingPrepared:
            if isRecording {
                rigState = .recording
                applyRigPowerPolicy()
                return rigReply(ok: true, message: "Already recording.")
            }
            if rigState == .recordingPrepared {
                applyRigPowerPolicy()
                return rigReply(ok: true, message: "Recording already prepared.")
            }
            if let failure = await ensureCaptureSessionRunningForRig(reason: reason) {
                return failure
            }
            isRemoteArmed = true
            rigState = .recordingPrepared
            applyRigPowerPolicy()
            updateRigStatusLines()
            remoteDirectorClient.sendStatusNow()
            return rigReply(ok: true, message: "Recording prepared.")

        case .recording:
            if isRecording {
                rigState = .recording
                applyRigPowerPolicy()
                return rigReply(ok: true, message: "Already recording.")
            }
            if rigState != .recordingPrepared {
                let prepareReply = await transitionRigState(to: .recordingPrepared, reason: "\(reason)_prepare")
                guard prepareReply.ok else { return prepareReply }
            }
            return await startRigRecording(reason: reason)

        case .shutdown, .normalExit:
            if isRecording {
                guard stopRecordingIfNeeded else {
                    return rigReply(ok: false,
                                    message: "Refused normal exit while recording.",
                                    error: "recording_active")
                }
                let stopReply = await stopRigRecording(reason: reason)
                guard stopReply.ok else { return stopReply }
            }
            remoteStartTask?.cancel()
            remoteStopTask?.cancel()
            stopManualControlRefresh()
            await captureService.stop()
            rigState = targetState
            isRemoteArmed = false
            applyRigPowerPolicy()
            updateRigStatusLines()
            remoteDirectorClient.sendStatusNow()
            return rigReply(ok: true, message: "Exited rig mode.")
        }
    }

    private func isCapturePipelineRecording() async -> Bool {
        let serviceCaptureActivity = await captureService.captureActivity
        return captureActivity.isRecording || serviceCaptureActivity.isRecording
    }

    private func ensureCaptureSessionRunningForRig(reason: String) async -> RemoteDirectorCommandReply? {
        guard await captureService.isAuthorized else {
            status = .unauthorized
            return rigReply(ok: false,
                            message: "Camera authorization is unavailable.",
                            error: "unauthorized")
        }

        do {
            await syncState()
            try await captureService.start(with: cameraState)
            if !hasAttachedStateObservers {
                observeState()
                hasAttachedStateObservers = true
            }
            status = .running
            localVideoURLs = await localVideoStore.loadStoredVideos()
            await refreshVideoCaptureModeStateFromDevice()
            await refreshManualControlCapabilitiesFromDevice()
            if activeManualLockProfile != nil {
                await installActiveManualLockProfile(reason: reason)
            } else {
                await applySelectedVideoCaptureModeToDevice(reason: "\(reason)_capture_mode")
                await applyManualControlStateToDevice()
            }
            startActiveTimecodeService()
            return nil
        } catch {
            status = .failed
            logger.error("Failed to start capture session for rig transition: \(error.localizedDescription, privacy: .public)")
            return rigReply(ok: false,
                            message: "Failed to start capture session: \(error.localizedDescription)",
                            error: "capture_session_failed")
        }
    }

    private func startRigRecording(reason: String) async -> RemoteDirectorCommandReply {
        let recordingSeedTimecode = recordingSeedTentacleTimecode()
        recordingStartTimecodeMetadata = currentRecordingStartMetadata()
        let calibrationJSON = await captureService.recordingCalibrationJSONData()
        let validation = await captureService.startRecording(recordingStartMetadata: recordingStartTimecodeMetadata)
        if let validation {
            updateManualLockProfileState(from: validation)
            persistManualLockProfileStore()
            guard validation.classification == .exactMatch || validation.classification == .adjustedMatch else {
                recordingStartTimecodeMetadata = nil
                rigState = .recordingPrepared
                applyRigPowerPolicy()
                remoteDirectorClient.sendStatusNow()
                return rigReply(ok: false,
                                message: validation.detail,
                                error: "manual_lock_validation_failed",
                                extra: ["validation_report": jsonObject(validation) ?? [:]])
            }
        }
        pendingRecordingCalibrationJSON = calibrationJSON
        startRecordingClock(seedTimecode: recordingSeedTimecode)
        rigState = .recording
        applyRigPowerPolicy()
        updateRigStatusLines()
        remoteDirectorClient.sendStatusNow()
        return rigReply(ok: true, message: "Recording started.")
    }

    private func stopRigRecording(reason: String) async -> RemoteDirectorCommandReply {
        guard await isCapturePipelineRecording() else {
            return rigReply(ok: false,
                            message: "Not recording.",
                            error: "not_recording")
        }

        let calibrationJSON = pendingRecordingCalibrationJSON
        pendingRecordingCalibrationJSON = nil
        do {
            let movie = try await captureService.stopRecording()
            _ = try await localVideoStore.store(movie: movie, calibrationJSON: calibrationJSON)
            localVideoURLs = await localVideoStore.loadStoredVideos()
            recordingStartTimecodeMetadata = nil
            stopRecordingClock()
            rigState = .recordingPrepared
            applyRigPowerPolicy()
            updateRigStatusLines()
            remoteDirectorClient.sendStatusNow()
            return rigReply(ok: true, message: "Recording stopped.")
        } catch {
            logger.error("Failed to stop rig recording: \(error.localizedDescription, privacy: .public)")
            self.error = error
            applyRigPowerPolicy()
            return rigReply(ok: false,
                            message: "Failed to stop recording: \(error.localizedDescription)",
                            error: "stop_recording_failed")
        }
    }

    private func setRigBrightness(_ brightness: Double) -> RemoteDirectorCommandReply {
        let clamped = min(max(brightness, 0.01), 1.0)
        if brightnessBeforeRigDim == nil {
            brightnessBeforeRigDim = UIScreen.main.brightness
        }
        UIScreen.main.brightness = clamped
        updateRigStatusLines()
        return rigReply(ok: true,
                        message: String(format: "Brightness set to %.2f.", clamped),
                        extra: ["brightness": clamped])
    }

    private func rigReply(ok: Bool,
                          message: String,
                          error: String? = nil,
                          extra: [String: Any] = [:]) -> RemoteDirectorCommandReply {
        var payload = rigStatusPayload(message: message)
        if let error {
            payload["error"] = error
        }
        for (key, value) in extra {
            payload[key] = value
        }
        return ok ? .success(message, payload: payload) : .failure(message, payload: payload)
    }

    private func rigStatusPayload(message: String) -> [String: Any] {
        updateRigStatusLines()
        let localVideoSummary = currentLocalVideoStorageSummary()
        var payload: [String: Any] = [
            "current_state": rigState.rawValue,
            "device_id": remoteDirectorClient.transferDeviceID(),
            "device_name": directorDeviceName,
            "message": message,
            "guided_access_enabled": isRigKioskMode,
            "director_connection": remoteDirectorClient.connectionStatus,
            "local_video_count": localVideoSummary.totalCount,
            "uploaded_video_count": localVideoSummary.uploadedCount,
            "pending_upload_video_count": localVideoSummary.pendingUploadCount,
            "local_video_bytes": localVideoSummary.totalBytes,
            "uploaded_video_bytes": localVideoSummary.uploadedBytes,
            "pending_upload_video_bytes": localVideoSummary.pendingUploadBytes,
            "capture_mode": videoCaptureModeStatus.selectedPreset.rawValue,
            "supported_capture_modes": videoCaptureModeStatus.supportedPresets.map(\.rawValue)
        ]
        if let actualWidth = videoCaptureModeStatus.actualWidth {
            payload["actual_video_width"] = actualWidth
        }
        if let actualHeight = videoCaptureModeStatus.actualHeight {
            payload["actual_video_height"] = actualHeight
        }
        if let actualFPS = videoCaptureModeStatus.actualFPS {
            payload["actual_video_fps"] = actualFPS
        }
        if let actualMode = videoCaptureModeStatus.actualPreset {
            payload["actual_capture_mode"] = actualMode.rawValue
        }
        if let battery = UIDevice.current.batteryLevelNormalized {
            payload["battery"] = battery
        }
        if let storageGB = FileManager.default.availableStorageGB {
            payload["storage_gb"] = storageGB
        }
        return payload
    }

    private func handleRemoteDirectorCommand(_ command: RemoteDirectorCommandEnvelope) async -> RemoteDirectorCommandReply {
        switch command.command {
        case .arm:
            isRemoteArmed = true
            applyRigPowerPolicy()
            return rigReply(ok: true, message: "Armed.")

        case .armIdle:
            return await transitionRigState(to: .armedIdle, reason: "remote_arm_idle")

        case .prepareStart(let sessionID, let startAtUnixMS):
            let prepareReply = await transitionRigState(to: .recordingPrepared,
                                                        reason: "remote_prepare_start")
            guard prepareReply.ok else { return prepareReply }
            pendingRemoteStart = PreparedRemoteStart(sessionID: sessionID, startAtUnixMS: startAtUnixMS)
            isRemoteArmed = true
            return rigReply(ok: true, message: "Prepared start for session \(sessionID).")

        case .commitStart(let sessionID, let startAtUnixMS):
            guard let prepared = pendingRemoteStart, prepared.sessionID == sessionID else {
                return rigReply(ok: false,
                                message: "Missing matching prepare_start for session \(sessionID).",
                                error: "missing_prepare")
            }

            let targetUnixMS = max(prepared.startAtUnixMS, startAtUnixMS)
            remoteStartTask?.cancel()
            remoteStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitUntil(unixMilliseconds: targetUnixMS)
                guard !Task.isCancelled else { return }
                _ = await self.transitionRigState(to: .recording,
                                                  reason: "remote_commit_start")
                self.pendingRemoteStart = nil
                self.remoteDirectorClient.sendStatusNow()
            }
            return rigReply(ok: true, message: "Commit accepted for session \(sessionID).")

        case .prepareStop(_, let stopAtUnixMS):
            remoteStopTask?.cancel()
            remoteStopTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitUntil(unixMilliseconds: stopAtUnixMS)
                guard !Task.isCancelled else { return }
                _ = await self.transitionRigState(to: .armedIdle,
                                                  reason: "remote_prepare_stop",
                                                  stopRecordingIfNeeded: true)
                self.remoteDirectorClient.sendStatusNow()
            }
            return rigReply(ok: true, message: "Prepared stop.")

        case .prepareRecording:
            return await transitionRigState(to: .recordingPrepared,
                                            reason: "remote_prepare_recording")

        case .startRecording(_, let startAtUnixMS):
            if let startAtUnixMS {
                remoteStartTask?.cancel()
                remoteStartTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.waitUntil(unixMilliseconds: startAtUnixMS)
                    guard !Task.isCancelled else { return }
                    _ = await self.transitionRigState(to: .recording,
                                                      reason: "remote_start_recording_scheduled")
                }
                return rigReply(ok: true, message: "Scheduled recording start.")
            }
            return await transitionRigState(to: .recording,
                                            reason: "remote_start_recording")

        case .stopRecording(_, let stopAtUnixMS):
            if let stopAtUnixMS {
                remoteStopTask?.cancel()
                remoteStopTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.waitUntil(unixMilliseconds: stopAtUnixMS)
                    guard !Task.isCancelled else { return }
                    _ = await self.transitionRigState(to: .armedIdle,
                                                      reason: "remote_stop_recording_scheduled",
                                                      stopRecordingIfNeeded: true)
                }
                return rigReply(ok: true, message: "Scheduled recording stop.")
            }
            guard await isCapturePipelineRecording() else {
                _ = await transitionRigState(to: .armedIdle,
                                             reason: "remote_stop_recording_not_recording")
                return rigReply(ok: false,
                                message: "Not recording. Entered armed idle.",
                                error: "not_recording")
            }
            return await transitionRigState(to: .armedIdle,
                                            reason: "remote_stop_recording",
                                            stopRecordingIfNeeded: true)

        case .getStatus:
            return rigReply(ok: true, message: "Status.")

        case .setBrightness(let brightness):
            return setRigBrightness(brightness)

        case .pullVideos(let jobID, let policyRawValue, let maxFiles, let uploadURL):
            if let remotePullVideosTask, !remotePullVideosTask.isCancelled {
                return rigReply(ok: false,
                                message: "A pull_videos transfer is already running.",
                                error: "busy")
            }

            let request = RemotePullVideosRequest(jobID: jobID,
                                                  policy: RemotePullVideosPolicy(rawValue: policyRawValue),
                                                  maxFiles: max(0, maxFiles),
                                                  uploadURLString: uploadURL)

            remotePullVideosTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.remotePullVideosTask = nil }
                await self.runRemotePullVideosJob(request)
            }
            return rigReply(ok: true, message: "Accepted pull_videos job \(jobID).")

        case .deleteLocalVideos(let policy):
            return await deleteLocalVideosForRemote(policy: policy)

        case .setCaptureMode(let preset):
            return await applyRemoteCaptureMode(preset)

        case .capturePreviewPhoto(let batchID, let uploadURL, let longEdge, let jpegQuality, let uploadJitterSeconds, let attempt):
            guard !captureActivity.isRecording else {
                return rigReply(ok: false,
                                message: "Refused to capture preview photo while recording.",
                                error: "recording_active",
                                extra: ["status": "recording_active"])
            }
            guard remoteDirectorClient.resolveUploadBaseURL(override: uploadURL) != nil else {
                return rigReply(ok: false,
                                message: "Unable to resolve upload URL.",
                                error: "upload_failed",
                                extra: ["status": "upload_failed"])
            }
            if let remotePreviewPhotoTask, !remotePreviewPhotoTask.isCancelled {
                return rigReply(ok: false,
                                message: "A preview photo capture is already running.",
                                error: "busy",
                                extra: ["status": "busy"])
            }

            let request = RemotePreviewPhotoRequest(requestID: command.requestID,
                                                    batchID: batchID,
                                                    uploadURLString: uploadURL,
                                                    longEdge: longEdge,
                                                    jpegQuality: jpegQuality,
                                                    uploadJitterSeconds: uploadJitterSeconds,
                                                    attempt: attempt)
            remotePreviewPhotoTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.remotePreviewPhotoTask = nil }
                await self.runRemotePreviewPhotoJob(request)
            }
            return rigReply(ok: true,
                            message: "Accepted preview photo request.",
                            extra: [
                                "status": "accepted",
                                "capture_source": "video_data_output",
                                "batch_id": batchID,
                                "attempt": attempt
                            ])

        case .exportCameraParams:
            let payload = await exportCameraParamsPayload(requestID: command.requestID)
            var replyPayload = rigStatusPayload(message: "Exported camera parameters.")
            replyPayload["camera_params"] = payload
            return .success("Exported camera parameters.", payload: replyPayload)

        case .applyCameraParams(let profile, let dryRun):
            let report = await applyRemoteCameraParams(profile,
                                                       requestID: command.requestID,
                                                       dryRun: dryRun)
            let payload = cameraParamsReportPayload(applyReport: report)
            let ok = report.classification == .exactMatch || report.classification == .adjustedMatch
            var replyPayload = rigStatusPayload(message: report.detail)
            replyPayload["camera_params"] = payload
            return ok ? .success(report.detail, payload: replyPayload) : .failure(report.detail, payload: replyPayload)

        case .validateCameraParams:
            guard let report = await validateActiveManualLockProfile(reason: "remote_validate_camera_params",
                                                                     requestID: command.requestID) else {
                return .failure("No active manual lock profile.")
            }
            let payload = cameraParamsReportPayload(validationReport: report)
            let ok = report.classification == .exactMatch || report.classification == .adjustedMatch
            var replyPayload = rigStatusPayload(message: report.detail)
            replyPayload["camera_params"] = payload
            return ok ? .success(report.detail, payload: replyPayload) : .failure(report.detail, payload: replyPayload)
        }
    }

    private func applyRemoteCameraParams(_ profile: ManualLockProfile,
                                         requestID: String,
                                         dryRun: Bool) async -> ManualApplyReport {
        if dryRun {
            let report = await captureService.installManualLockProfile(profile,
                                                                       reason: "remote_apply_camera_params_dry_run",
                                                                       requestID: requestID,
                                                                       dryRun: true)
            updateManualLockProfileState(from: report)
            return report
        }

        activeManualLockProfile = profile
        stopManualControlRefresh()
        manualProfileDriftStatus = .reapplying
        let report = await captureService.installManualLockProfile(profile,
                                                                   reason: "remote_apply_camera_params",
                                                                   requestID: requestID,
                                                                   dryRun: false)
        await refreshManualControlCapabilitiesFromDevice()
        updateManualLockProfileState(from: report)
        persistManualLockProfileStore()
        remoteDirectorClient.sendStatusNow()
        return report
    }

    private func applyRemoteCaptureMode(_ preset: VideoCaptureModePreset) async -> RemoteDirectorCommandReply {
        guard !captureActivity.isRecording, !(await isCapturePipelineRecording()) else {
            return rigReply(ok: false,
                            message: "Refused to change capture mode while recording.",
                            error: "recording_active")
        }
        guard activeManualLockProfile == nil else {
            return rigReply(ok: false,
                            message: "Capture mode is owned by the active camera params profile. Sync camera params to change it.",
                            error: "manual_lock_active")
        }

        isApplyingVideoCaptureModeInternally = true
        selectedVideoCaptureMode = preset
        isApplyingVideoCaptureModeInternally = false
        persistSelectedVideoCaptureMode(preset)

        let report = await captureService.applyVideoCaptureModePreset(preset,
                                                                      reason: "remote_set_capture_mode")
        publishVideoCaptureModeStatus(report.status)
        if report.classification == .exactModeApplied || report.classification == .adjustedCompatibleMode {
            isUpdatingManualControlState = true
            manualControlState.fps = report.status.actualFPS ?? preset.fps
            manualControlState.isFPSLocked = true
            isUpdatingManualControlState = false
            persistManualControlState(manualControlState)
            await applyManualControlStateToDevice()
        }
        await refreshManualControlCapabilitiesFromDevice()
        remoteDirectorClient.sendStatusNow()

        let ok = report.classification == .exactModeApplied || report.classification == .adjustedCompatibleMode
        return rigReply(ok: ok,
                        message: report.detail,
                        error: ok ? nil : report.classification.rawValue,
                        extra: [
                            "capture_mode_report": jsonObject(report) ?? [:]
                        ])
    }

    private func exportCameraParamsPayload(requestID: String) async -> [String: Any] {
        let identity = remoteDirectorClient.manualSnapshotIdentity()
        let actualSnapshot = await captureService.exportActualCameraSnapshot(reason: "remote_export_camera_params",
                                                                             identity: identity)
        lastManualActualSnapshot = actualSnapshot
        let profile = activeManualLockProfile ?? manualLockProfile(from: actualSnapshot)
        persistManualLockProfileStore()

        var payload: [String: Any] = [
            "schema_version": 1,
            "request_id": requestID,
            "source_snapshot_hash": stableHash(of: actualSnapshot)
        ]
        if let requestedProfile = jsonObject(profile) {
            payload["requested_profile"] = requestedProfile
        }
        if let lastManualApplyReport,
           let lastApplyPayload = jsonObject(lastManualApplyReport) {
            payload["last_apply_report"] = lastApplyPayload
        }
        if let actualPayload = jsonObject(actualSnapshot) {
            payload["actual_snapshot"] = actualPayload
        }
        return payload
    }

    private func cameraParamsReportPayload(applyReport: ManualApplyReport) -> [String: Any] {
        [
            "schema_version": 1,
            "apply_report": jsonObject(applyReport) ?? [:],
            "actual_snapshot": applyReport.actualSnapshot.flatMap(jsonObject(_:)) ?? [:],
            "requested_profile": activeManualLockProfile.flatMap(jsonObject(_:)) ?? [:]
        ]
    }

    private func cameraParamsReportPayload(validationReport: ManualValidationReport) -> [String: Any] {
        [
            "schema_version": 1,
            "validation_report": jsonObject(validationReport) ?? [:],
            "actual_snapshot": validationReport.actualSnapshot.flatMap(jsonObject(_:)) ?? [:],
            "requested_profile": activeManualLockProfile.flatMap(jsonObject(_:)) ?? [:]
        ]
    }

    private func manualLockProfile(from snapshot: ManualCameraActualSnapshot) -> ManualLockProfile {
        let desired = ManualCameraDesiredSettings(
            captureModePreset: snapshot.actualCaptureModePreset,
            format: snapshot.activeFormat,
            selectedFPS: selectedFPS(from: snapshot),
            activeVideoMinFrameDurationSeconds: snapshot.actualFPSMinFrameDurationSeconds,
            activeVideoMaxFrameDurationSeconds: snapshot.actualFPSMaxFrameDurationSeconds,
            exposureDurationSeconds: snapshot.exposure?.exposureDurationSeconds,
            iso: snapshot.exposure?.iso,
            whiteBalanceTemperature: snapshot.whiteBalance?.temperature,
            whiteBalanceTint: snapshot.whiteBalance?.tint,
            whiteBalanceGains: snapshot.whiteBalance?.gains,
            focusLensPosition: snapshot.focus?.lensPosition,
            zoomFactor: snapshot.zoom?.factor,
            preferredStabilizationModeRawValue: snapshot.stabilization?.preferredModeRawValue,
            preferredStabilizationMode: snapshot.stabilization?.preferredMode,
            hdrIntent: snapshot.activeFormat?.isTenBit == true ? "hdr10bit" : "sdr",
            activeColorSpaceRawValue: snapshot.activeFormat?.activeColorSpaceRawValue,
            bitDepth: snapshot.activeFormat?.isTenBit == true ? 10 : 8
        )
        return ManualLockProfile(
            profileID: UUID().uuidString,
            name: "Actual \(snapshot.identity.remoteDeviceName)",
            source: .local(deviceID: snapshot.identity.remoteDeviceID,
                           deviceName: snapshot.identity.remoteDeviceName,
                           appVersion: snapshot.identity.appVersion,
                           sourceSnapshotHash: stableHash(of: snapshot)),
            desired: desired,
            policy: .strict,
            actualValidatedSnapshot: snapshot,
            lastApplyReport: nil
        )
    }

    private func selectedFPS(from snapshot: ManualCameraActualSnapshot) -> Double? {
        guard let minDuration = snapshot.actualFPSMinFrameDurationSeconds,
              let maxDuration = snapshot.actualFPSMaxFrameDurationSeconds,
              minDuration > 0,
              abs(minDuration - maxDuration) <= max(0.000_001, minDuration * 0.0005) else {
            return nil
        }
        return 1.0 / minDuration
    }

    private func manualCameraParamsSummary() -> String? {
        guard let snapshot = lastManualActualSnapshot else {
            return activeManualLockProfile?.name
        }
        let format = snapshot.activeFormat.map { "\($0.width)x\($0.height)" } ?? "unknown_format"
        let fps = selectedFPS(from: snapshot).map { String(format: "%.3f fps", $0) } ?? "variable fps"
        let iso = snapshot.exposure.map { String(format: "ISO %.0f", $0.iso) } ?? "ISO unknown"
        let mode = snapshot.actualCaptureModePreset?.rawValue ?? selectedVideoCaptureMode.rawValue
        return "\(mode), \(format), \(fps), \(iso)"
    }

    private func jsonObject<T: Encodable>(_ value: T) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func stableHash<T: Encodable>(of value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            return "hash_unavailable"
        }

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private func runRemotePreviewPhotoJob(_ request: RemotePreviewPhotoRequest) async {
        guard let uploadBaseURL = remoteDirectorClient.resolveUploadBaseURL(override: request.uploadURLString) else {
            remoteDirectorClient.sendPreviewPhotoUpdate(requestID: request.requestID,
                                                        state: "failed",
                                                        detail: "Unable to resolve upload URL.",
                                                        failureReason: "upload_failed")
            return
        }

        let jitterSeconds = min(max(request.uploadJitterSeconds, 0), 3)
        if jitterSeconds > 0 {
            let delay = Double.random(in: 0...jitterSeconds)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }

        let previewReply = await transitionRigState(to: .preview,
                                                    reason: "remote_capture_preview_photo")
        guard previewReply.ok else {
            remoteDirectorClient.sendPreviewPhotoUpdate(requestID: request.requestID,
                                                        state: "failed",
                                                        detail: previewReply.detail,
                                                        failureReason: "capture_failed")
            return
        }

        remoteDirectorClient.sendPreviewPhotoUpdate(requestID: request.requestID,
                                                    state: "capturing",
                                                    detail: "Capturing preview frame.")

        let capture: RemotePreviewPhotoCapture
        do {
            capture = try await captureService.capturePreviewPhoto(requestID: request.requestID,
                                                                   identity: remoteDirectorClient.manualSnapshotIdentity(),
                                                                   longEdge: request.longEdge,
                                                                   jpegQuality: request.jpegQuality)
        } catch {
            _ = await transitionRigState(to: .armedIdle,
                                         reason: "remote_capture_preview_photo_failed")
            remoteDirectorClient.sendPreviewPhotoUpdate(requestID: request.requestID,
                                                        state: "failed",
                                                        detail: error.localizedDescription,
                                                        failureReason: "capture_failed")
            return
        }

        remoteDirectorClient.sendPreviewPhotoUpdate(requestID: request.requestID,
                                                    state: "uploading",
                                                    detail: "Uploading preview photo.",
                                                    imageBytes: capture.jpegData.count,
                                                    metadataBytes: capture.metadataJSONData.count)

        do {
            try await uploadPreviewCaptureWithRetry(capture,
                                                    uploadBaseURL: uploadBaseURL,
                                                    request: request)
            _ = await transitionRigState(to: .armedIdle,
                                         reason: "remote_capture_preview_photo_done")
            remoteDirectorClient.sendPreviewPhotoUpdate(requestID: request.requestID,
                                                        state: "done",
                                                        detail: "Preview photo uploaded.",
                                                        imageBytes: capture.jpegData.count,
                                                        metadataBytes: capture.metadataJSONData.count)
        } catch {
            _ = await transitionRigState(to: .armedIdle,
                                         reason: "remote_capture_preview_photo_upload_failed")
            remoteDirectorClient.sendPreviewPhotoUpdate(requestID: request.requestID,
                                                        state: "failed",
                                                        detail: "Preview upload failed: \(error.localizedDescription)",
                                                        imageBytes: capture.jpegData.count,
                                                        metadataBytes: capture.metadataJSONData.count,
                                                        failureReason: "upload_failed")
        }
    }

    private func uploadPreviewCaptureWithRetry(_ capture: RemotePreviewPhotoCapture,
                                               uploadBaseURL: URL,
                                               request: RemotePreviewPhotoRequest) async throws {
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await uploadSinglePreviewFile(data: capture.jpegData,
                                                  uploadBaseURL: uploadBaseURL,
                                                  request: request,
                                                  filename: previewFilename(extension: "jpg"),
                                                  contentKind: "preview_photo",
                                                  mimeType: "image/jpeg")
                try await uploadSinglePreviewFile(data: capture.metadataJSONData,
                                                  uploadBaseURL: uploadBaseURL,
                                                  request: request,
                                                  filename: previewFilename(extension: "json"),
                                                  contentKind: "preview_photo_metadata",
                                                  mimeType: "application/json")
                return
            } catch {
                lastError = error
                guard attempt == 1 else { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw lastError ?? NSError(domain: "RemotePreviewPhoto",
                                   code: 2001,
                                   userInfo: [NSLocalizedDescriptionKey: "Preview upload failed."])
    }

    private func uploadSinglePreviewFile(data: Data,
                                         uploadBaseURL: URL,
                                         request: RemotePreviewPhotoRequest,
                                         filename: String,
                                         contentKind: String,
                                         mimeType: String) async throws {
        guard let requestURL = previewUploadRequestURL(baseURL: uploadBaseURL,
                                                       request: request,
                                                       filename: filename,
                                                       contentKind: contentKind) else {
            throw NSError(domain: "RemotePreviewPhoto",
                          code: 2002,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid preview upload URL components."])
        }

        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(contentKind, forHTTPHeaderField: "X-Content-Kind")
        urlRequest.setValue(filename, forHTTPHeaderField: "X-Original-Filename")
        urlRequest.setValue(remoteDirectorClient.transferDeviceID(), forHTTPHeaderField: "X-Device-ID")
        urlRequest.setValue(directorDeviceName, forHTTPHeaderField: "X-Device-Name")
        urlRequest.setValue(request.requestID, forHTTPHeaderField: "X-Request-ID")
        urlRequest.setValue(request.batchID, forHTTPHeaderField: "X-Preview-Batch-ID")
        urlRequest.setValue(request.requestID, forHTTPHeaderField: "X-Transfer-Job-ID")

        let (_, response) = try await URLSession.shared.upload(for: urlRequest, from: data)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "RemotePreviewPhoto",
                          code: 2003,
                          userInfo: [NSLocalizedDescriptionKey: "Preview upload returned a non-HTTP response."])
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "RemotePreviewPhoto",
                          code: 2004,
                          userInfo: [NSLocalizedDescriptionKey: "Preview upload rejected with HTTP \(httpResponse.statusCode)."])
        }
    }

    private func previewUploadRequestURL(baseURL: URL,
                                         request: RemotePreviewPhotoRequest,
                                         filename: String,
                                         contentKind: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "device_id", value: remoteDirectorClient.transferDeviceID()))
        queryItems.append(URLQueryItem(name: "device_name", value: directorDeviceName))
        queryItems.append(URLQueryItem(name: "job_id", value: request.requestID))
        queryItems.append(URLQueryItem(name: "request_id", value: request.requestID))
        queryItems.append(URLQueryItem(name: "batch_id", value: request.batchID))
        queryItems.append(URLQueryItem(name: "kind", value: contentKind))
        queryItems.append(URLQueryItem(name: "filename", value: filename))
        components.queryItems = queryItems
        return components.url
    }

    private func previewFilename(extension pathExtension: String) -> String {
        let safeBase = sanitizedTransferComponent(directorDeviceName)
            ?? String(remoteDirectorClient.transferDeviceID().prefix(8))
        return "\(safeBase).\(pathExtension)"
    }

    private func sanitizedTransferComponent(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let cleaned = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(80))
    }

    private func currentLocalVideoStorageSummary() -> LocalVideoStorageSummary {
        guard !localVideoURLs.isEmpty else { return .empty }
        let uploadedFingerprints = loadUploadedVideoFingerprints()
        var totalCount = 0
        var uploadedCount = 0
        var totalBytes: Int64 = 0
        var uploadedBytes: Int64 = 0

        for item in localVideoURLs.compactMap(buildRemoteTransferItem(forVideoURL:)) {
            let itemBytes = item.videoBytes + item.sidecarBytes
            totalCount += 1
            totalBytes += itemBytes
            if uploadedFingerprints.contains(item.fingerprint) {
                uploadedCount += 1
                uploadedBytes += itemBytes
            }
        }

        return LocalVideoStorageSummary(totalCount: totalCount,
                                        uploadedCount: uploadedCount,
                                        pendingUploadCount: max(0, totalCount - uploadedCount),
                                        totalBytes: totalBytes,
                                        uploadedBytes: uploadedBytes,
                                        pendingUploadBytes: max(0, totalBytes - uploadedBytes))
    }

    private func deleteLocalVideosForRemote(policy: RemoteLocalVideoDeletePolicy) async -> RemoteDirectorCommandReply {
        guard !captureActivity.isRecording, !(await isCapturePipelineRecording()) else {
            return rigReply(ok: false,
                            message: "Refused to delete local videos while recording.",
                            error: "recording_active")
        }

        if let remotePullVideosTask, !remotePullVideosTask.isCancelled {
            return rigReply(ok: false,
                            message: "Refused to delete local videos while a pull_videos transfer is running.",
                            error: "busy")
        }

        localVideoURLs = await localVideoStore.loadStoredVideos()
        let uploadedFingerprints = loadUploadedVideoFingerprints()
        let allItems = localVideoURLs.compactMap(buildRemoteTransferItem(forVideoURL:))

        let itemsToDelete: [RemoteTransferItem]
        switch policy {
        case .uploadedOnly:
            itemsToDelete = allItems.filter { uploadedFingerprints.contains($0.fingerprint) }
        case .forceAll:
            itemsToDelete = allItems
        }

        let urlsToDelete = itemsToDelete.map(\.videoURL)
        localVideoURLs = await localVideoStore.delete(urls: urlsToDelete)

        let remainingPaths = Set(localVideoURLs.map(canonicalLocalVideoPath(for:)))
        let deletedItems = itemsToDelete.filter { !remainingPaths.contains(canonicalLocalVideoPath(for: $0.videoURL)) }
        let deletedFingerprints = Set(deletedItems.map(\.fingerprint))

        var remainingFingerprints = uploadedFingerprints
        remainingFingerprints.subtract(deletedFingerprints)
        persistUploadedVideoFingerprints(remainingFingerprints)

        let remainingSummary = currentLocalVideoStorageSummary()
        remoteDirectorClient.sendStatusSoon()

        let skippedUnuploadedCount = max(0, allItems.count - itemsToDelete.count)
        let failedDeleteCount = max(0, itemsToDelete.count - deletedItems.count)
        var message: String
        switch policy {
        case .uploadedOnly:
            message = "Deleted \(deletedItems.count) uploaded local video(s); skipped \(skippedUnuploadedCount) not yet uploaded."
        case .forceAll:
            message = "Force-deleted \(deletedItems.count) local video(s)."
        }
        if failedDeleteCount > 0 {
            message += " \(failedDeleteCount) could not be removed."
        }

        let deletePolicyValue: String
        switch policy {
        case .uploadedOnly:
            deletePolicyValue = "uploaded_only"
        case .forceAll:
            deletePolicyValue = "force_all"
        }

        let ok = failedDeleteCount == 0
        return rigReply(ok: ok,
                        message: message,
                        error: ok ? nil : "delete_failed",
                        extra: [
                            "deleted_video_count": deletedItems.count,
                            "skipped_unuploaded_video_count": skippedUnuploadedCount,
                            "failed_delete_video_count": failedDeleteCount,
                            "remaining_video_count": remainingSummary.totalCount,
                            "remaining_uploaded_video_count": remainingSummary.uploadedCount,
                            "remaining_pending_upload_video_count": remainingSummary.pendingUploadCount,
                            "delete_policy": deletePolicyValue
                        ])
    }

    private func canonicalLocalVideoPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func runRemotePullVideosJob(_ request: RemotePullVideosRequest) async {
        remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                state: "starting",
                                                detail: "Preparing local video list.")

        guard let uploadBaseURL = remoteDirectorClient.resolveUploadBaseURL(override: request.uploadURLString) else {
            remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                    state: "failed",
                                                    detail: "Unable to resolve upload URL.")
            return
        }

        let allVideos = await localVideoStore.loadStoredVideos()
        localVideoURLs = allVideos
        var uploadedFingerprints = loadUploadedVideoFingerprints()

        var transferItems = allVideos.compactMap(buildRemoteTransferItem(forVideoURL:))
        if request.policy == .newOnly {
            transferItems.removeAll { uploadedFingerprints.contains($0.fingerprint) }
        }
        if request.maxFiles > 0 {
            transferItems = Array(transferItems.prefix(request.maxFiles))
        }

        if transferItems.isEmpty {
            remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                    state: "done",
                                                    detail: "No videos to upload.",
                                                    sentFiles: 0,
                                                    totalFiles: 0,
                                                    sentBytes: 0)
            return
        }

        remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                state: "starting",
                                                detail: "Uploading \(transferItems.count) videos.",
                                                sentFiles: 0,
                                                totalFiles: transferItems.count,
                                                sentBytes: 0)

        var sentFiles = 0
        var sentBytes: Int64 = 0

        for (index, item) in transferItems.enumerated() {
            if Task.isCancelled {
                remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                        state: "cancelled",
                                                        detail: "Transfer task cancelled.",
                                                        sentFiles: sentFiles,
                                                        totalFiles: transferItems.count,
                                                        sentBytes: sentBytes)
                return
            }

            remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                    state: "progress",
                                                    detail: "Uploading \(index + 1)/\(transferItems.count): \(item.videoURL.lastPathComponent)",
                                                    sentFiles: sentFiles,
                                                    totalFiles: transferItems.count,
                                                    sentBytes: sentBytes)

            do {
                let uploadedBytes = try await uploadTransferItem(item,
                                                                 uploadBaseURL: uploadBaseURL,
                                                                 jobID: request.jobID)
                sentFiles += 1
                sentBytes += uploadedBytes
                uploadedFingerprints.insert(item.fingerprint)
                persistUploadedVideoFingerprints(uploadedFingerprints)
                remoteDirectorClient.sendStatusSoon()

                remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                        state: "progress",
                                                        detail: "Uploaded \(item.videoURL.lastPathComponent)",
                                                        sentFiles: sentFiles,
                                                        totalFiles: transferItems.count,
                                                        sentBytes: sentBytes)
            } catch {
                let detail = "Upload failed for \(item.videoURL.lastPathComponent): \(error.localizedDescription)"
                remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                        state: "failed",
                                                        detail: detail,
                                                        sentFiles: sentFiles,
                                                        totalFiles: transferItems.count,
                                                        sentBytes: sentBytes)
                return
            }
        }

        persistUploadedVideoFingerprints(uploadedFingerprints)
        remoteDirectorClient.sendStatusSoon()
        remoteDirectorClient.sendTransferUpdate(jobID: request.jobID,
                                                state: "done",
                                                detail: "Uploaded \(sentFiles) video(s).",
                                                sentFiles: sentFiles,
                                                totalFiles: transferItems.count,
                                                sentBytes: sentBytes)
    }

    private func buildRemoteTransferItem(forVideoURL videoURL: URL) -> RemoteTransferItem? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: videoURL.path) else { return nil }

        let videoValues = try? videoURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let videoBytes = Int64(videoValues?.fileSize ?? 0)
        let modifiedAt = Int64((videoValues?.contentModificationDate?.timeIntervalSince1970 ?? 0).rounded())

        let sidecarURL = videoURL.deletingPathExtension().appendingPathExtension("json")
        let resolvedSidecarURL: URL?
        let sidecarBytes: Int64
        if fileManager.fileExists(atPath: sidecarURL.path) {
            resolvedSidecarURL = sidecarURL
            let sidecarValues = try? sidecarURL.resourceValues(forKeys: [.fileSizeKey])
            sidecarBytes = Int64(sidecarValues?.fileSize ?? 0)
        } else {
            resolvedSidecarURL = nil
            sidecarBytes = 0
        }

        let fingerprint = "\(videoURL.lastPathComponent)|\(videoBytes)|\(modifiedAt)"
        return RemoteTransferItem(videoURL: videoURL,
                                  sidecarURL: resolvedSidecarURL,
                                  fingerprint: fingerprint,
                                  videoBytes: videoBytes,
                                  sidecarBytes: sidecarBytes)
    }

    private func uploadTransferItem(_ item: RemoteTransferItem,
                                    uploadBaseURL: URL,
                                    jobID: String) async throws -> Int64 {
        var uploadedBytes: Int64 = 0
        try await uploadSingleTransferFile(fileURL: item.videoURL,
                                           uploadBaseURL: uploadBaseURL,
                                           jobID: jobID,
                                           contentKind: "video",
                                           mimeType: mimeType(for: item.videoURL),
                                           fingerprint: item.fingerprint)
        uploadedBytes += item.videoBytes

        if let sidecarURL = item.sidecarURL {
            try await uploadSingleTransferFile(fileURL: sidecarURL,
                                               uploadBaseURL: uploadBaseURL,
                                               jobID: jobID,
                                               contentKind: "calibration_json",
                                               mimeType: "application/json",
                                               fingerprint: item.fingerprint)
            uploadedBytes += item.sidecarBytes
        }

        return uploadedBytes
    }

    private func uploadSingleTransferFile(fileURL: URL,
                                          uploadBaseURL: URL,
                                          jobID: String,
                                          contentKind: String,
                                          mimeType: String,
                                          fingerprint: String) async throws {
        guard let requestURL = transferRequestURL(baseURL: uploadBaseURL,
                                                  jobID: jobID,
                                                  fileURL: fileURL,
                                                  contentKind: contentKind) else {
            throw NSError(domain: "RemoteTransfer",
                          code: 1001,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL components."])
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 30
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue(contentKind, forHTTPHeaderField: "X-Content-Kind")
        request.setValue(fileURL.lastPathComponent, forHTTPHeaderField: "X-Original-Filename")
        request.setValue(fingerprint, forHTTPHeaderField: "X-Upload-Fingerprint")
        request.setValue(remoteDirectorClient.transferDeviceID(), forHTTPHeaderField: "X-Device-ID")
        request.setValue(directorDeviceName, forHTTPHeaderField: "X-Device-Name")
        request.setValue(jobID, forHTTPHeaderField: "X-Transfer-Job-ID")

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "RemoteTransfer",
                          code: 1002,
                          userInfo: [NSLocalizedDescriptionKey: "Upload returned a non-HTTP response."])
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(domain: "RemoteTransfer",
                          code: 1003,
                          userInfo: [NSLocalizedDescriptionKey: "Upload rejected with HTTP \(httpResponse.statusCode)."])
        }
    }

    private func transferRequestURL(baseURL: URL,
                                    jobID: String,
                                    fileURL: URL,
                                    contentKind: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "device_id", value: remoteDirectorClient.transferDeviceID()))
        queryItems.append(URLQueryItem(name: "device_name", value: directorDeviceName))
        queryItems.append(URLQueryItem(name: "job_id", value: jobID))
        queryItems.append(URLQueryItem(name: "kind", value: contentKind))
        queryItems.append(URLQueryItem(name: "filename", value: fileURL.lastPathComponent))
        components.queryItems = queryItems
        return components.url
    }

    private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "mov":
            return "video/quicktime"
        case "mp4":
            return "video/mp4"
        case "json":
            return "application/json"
        default:
            return "application/octet-stream"
        }
    }

    private func loadUploadedVideoFingerprints() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: RemoteTransferConfiguration.uploadedVideoFingerprintsDefaultsKey) ?? []
        return Set(values)
    }

    private func persistUploadedVideoFingerprints(_ fingerprints: Set<String>) {
        var values = Array(fingerprints)
        if values.count > RemoteTransferConfiguration.maxRememberedFingerprints {
            values = Array(values.suffix(RemoteTransferConfiguration.maxRememberedFingerprints))
        }
        UserDefaults.standard.set(values, forKey: RemoteTransferConfiguration.uploadedVideoFingerprintsDefaultsKey)
    }

    private func waitUntil(unixMilliseconds: Int64) async {
        let nowMS = remoteDirectorClient.currentDirectorSynchronizedUnixMilliseconds()
        let delayMS = max(0, unixMilliseconds - nowMS)
        if delayMS > 0 {
            let delayNS = UInt64(delayMS) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNS)
        }
    }

    private func performRemoteStart() async {
        guard status == .running else { return }
        do {
            try await setCaptureModeDirectly(.video)
            if !captureActivity.isRecording {
                await toggleRecording()
            }
            isRemoteArmed = false
        } catch {
            self.error = error
        }
    }

    private func performRemoteStop() async {
        guard status == .running else { return }
        if captureActivity.isRecording {
            await toggleRecording()
        }
        isRemoteArmed = false
    }

    private func setCaptureModeDirectly(_ mode: CaptureMode) async throws {
        guard mode == .video else { return }
        guard captureMode != mode else { return }

        isSwitchingModes = true
        defer { isSwitchingModes = false }

        try await captureService.setCaptureMode(mode)
        isApplyingCaptureModeInternally = true
        captureMode = mode
        isApplyingCaptureModeInternally = false
        cameraState.captureMode = mode
        await applyManualControlStateToDevice()
    }
}
