/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that provides the interface to the features of the camera.
*/

import SwiftUI
import Combine

enum RemoteDirectorConfiguration {
    static let directorWebSocketURLDefaultsKey = "DirectorWebSocketURL"
    static let directorWebSocketURLInfoKey = "DirectorWebSocketURL"
    static let directorDeviceNameDefaultsKey = "DirectorDeviceName"
}

private enum RemoteTransferConfiguration {
    static let uploadedVideoFingerprintsDefaultsKey = "RemoteUploadedVideoFingerprints"
    static let maxRememberedFingerprints = 5_000
}

private enum ManualControlConfiguration {
    static let manualControlStateDefaultsKey = "ManualCameraControlState"
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

    /// Draft and active deterministic camera profiles for copy/sync operation.
    private(set) var draftManualLockProfile: ManualLockProfile?
    private(set) var activeManualLockProfile: ManualLockProfile?
    private(set) var lastManualActualSnapshot: ManualCameraActualSnapshot?
    private(set) var lastManualApplyReport: ManualApplyReport?
    private(set) var lastManualValidationReport: ManualValidationReport?
    private(set) var manualProfileDriftStatus = ManualProfileDriftStatus.unknown

    /// A Boolean value that indicates whether this camera is armed for remote trigger.
    private(set) var isRemoteArmed = false

    /// Prevents manual-control didSet recursion when updates originate from capture-device sync.
    private var isUpdatingManualControlState = false

    /// Tracks whether internal code is setting the capture mode directly.
    private var isApplyingCaptureModeInternally = false

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
        isUpdatingManualControlState = true
        manualControlState = loadManualControlState()
        isUpdatingManualControlState = false

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
        if let defaultsURL = UserDefaults.standard.string(forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey) {
            return defaultsURL
        }
        if let infoURL = Bundle.main.object(forInfoDictionaryKey: RemoteDirectorConfiguration.directorWebSocketURLInfoKey) as? String {
            return infoURL
        }
        return ""
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
        updateManualLockProfileState(from: report)
        persistManualLockProfileStore()
        remoteDirectorClient.sendStatusNow()
    }

    private func reapplyActiveManualLockProfile(reason: String, requestID: String? = nil) async {
        guard activeManualLockProfile != nil else { return }

        stopManualControlRefresh()
        manualProfileDriftStatus = .reapplying
        let report = await captureService.reapplyManualLockProfile(reason: reason, requestID: requestID)
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
        // Verify that the person authorizes the app to use device cameras and microphones.
        guard await captureService.isAuthorized else {
            status = .unauthorized
            return
        }
        do {
            // Synchronize the state of the model with the persistent state.
            await syncState()
            // Start the capture service to start the flow of data.
            try await captureService.start(with: cameraState)
            if !hasAttachedStateObservers {
                observeState()
                hasAttachedStateObservers = true
            }
            status = .running
            localVideoURLs = await localVideoStore.loadStoredVideos()
            if activeManualLockProfile != nil {
                await installActiveManualLockProfile(reason: "camera_start")
            } else {
                await applyManualControlStateToDevice()
            }
            remoteDirectorClient.start()
            startActiveTimecodeService()
        } catch {
            logger.error("Failed to start capture service. \(error)")
            status = .failed
        }
    }

    func stop() async {
        if captureActivity.isRecording {
            await toggleRecording()
        }

        remotePullVideosTask?.cancel()
        remotePullVideosTask = nil
        await captureService.stop()
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
                    remoteDirectorClient.sendStatusNow()
                    return
                }
            }
            pendingRecordingCalibrationJSON = calibrationJSON
            startRecordingClock(seedTimecode: recordingSeedTimecode)
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

    private struct RemoteTransferItem {
        let videoURL: URL
        let sidecarURL: URL?
        let fingerprint: String
        let videoBytes: Int64
        let sidecarBytes: Int64
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
        let storageGB = FileManager.default.availableStorageGB
        let currentTimecode = currentTentacleTimecode()
        return RemoteDirectorStatusPayload(
            recording: captureActivity.isRecording,
            armed: isRemoteArmed,
            battery: UIDevice.current.batteryLevelNormalized,
            storageGB: storageGB,
            tentacleState: tentacleConnectionState.remoteControlValue,
            timecode: currentTimecode?.formatted ?? displayedTentacleTimecode,
            fps: currentTimecode?.fps ?? displayedTentacleFPS,
            cameraParamsStatus: activeManualLockProfile == nil ? "none" : manualProfileDriftStatus.rawValue,
            cameraParamsSummary: manualCameraParamsSummary()
        )
    }

    private func handleRemoteDirectorCommand(_ command: RemoteDirectorCommandEnvelope) async -> RemoteDirectorCommandReply {
        switch command.command {
        case .arm:
            isRemoteArmed = true
            return .success("Armed.")

        case .prepareStart(let sessionID, let startAtUnixMS):
            pendingRemoteStart = PreparedRemoteStart(sessionID: sessionID, startAtUnixMS: startAtUnixMS)
            isRemoteArmed = true
            return .success("Prepared start for session \(sessionID).")

        case .commitStart(let sessionID, let startAtUnixMS):
            guard let prepared = pendingRemoteStart, prepared.sessionID == sessionID else {
                return .failure("Missing matching prepare_start for session \(sessionID).")
            }

            let targetUnixMS = max(prepared.startAtUnixMS, startAtUnixMS)
            remoteStartTask?.cancel()
            remoteStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitUntil(unixMilliseconds: targetUnixMS)
                guard !Task.isCancelled else { return }
                await self.performRemoteStart()
                self.pendingRemoteStart = nil
                self.remoteDirectorClient.sendStatusNow()
            }
            return .success("Commit accepted for session \(sessionID).")

        case .prepareStop(_, let stopAtUnixMS):
            remoteStopTask?.cancel()
            remoteStopTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.waitUntil(unixMilliseconds: stopAtUnixMS)
                guard !Task.isCancelled else { return }
                await self.performRemoteStop()
                self.remoteDirectorClient.sendStatusNow()
            }
            return .success("Prepared stop.")

        case .pullVideos(let jobID, let policyRawValue, let maxFiles, let uploadURL):
            if let remotePullVideosTask, !remotePullVideosTask.isCancelled {
                return .failure("A pull_videos transfer is already running.")
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
            return .success("Accepted pull_videos job \(jobID).")

        case .exportCameraParams:
            let payload = await exportCameraParamsPayload(requestID: command.requestID)
            return .success("Exported camera parameters.", payload: payload)

        case .applyCameraParams(let profile, let dryRun):
            let report = await applyRemoteCameraParams(profile,
                                                       requestID: command.requestID,
                                                       dryRun: dryRun)
            let payload = cameraParamsReportPayload(applyReport: report)
            let ok = report.classification == .exactMatch || report.classification == .adjustedMatch
            return ok ? .success(report.detail, payload: payload) : .failure(report.detail, payload: payload)

        case .validateCameraParams:
            guard let report = await validateActiveManualLockProfile(reason: "remote_validate_camera_params",
                                                                     requestID: command.requestID) else {
                return .failure("No active manual lock profile.")
            }
            let payload = cameraParamsReportPayload(validationReport: report)
            let ok = report.classification == .exactMatch || report.classification == .adjustedMatch
            return ok ? .success(report.detail, payload: payload) : .failure(report.detail, payload: payload)
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
        updateManualLockProfileState(from: report)
        persistManualLockProfileStore()
        remoteDirectorClient.sendStatusNow()
        return report
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
        return "\(format), \(fps), \(iso)"
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
