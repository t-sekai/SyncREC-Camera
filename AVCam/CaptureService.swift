/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that manages a capture session and its inputs and outputs.
*/

import Foundation
@preconcurrency import AVFoundation
import Combine
import CoreImage
import simd
import UIKit

private enum PreviewPhotoCaptureError: LocalizedError {
    case captureServiceNotReady
    case sessionNotRunning
    case interrupted
    case recordingActive
    case noRecentVideoFrame
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .captureServiceNotReady:
            return "Capture service is not ready."
        case .sessionNotRunning:
            return "Capture session is not running."
        case .interrupted:
            return "Capture session is interrupted."
        case .recordingActive:
            return "Refused to capture preview photo while recording."
        case .noRecentVideoFrame:
            return "No recent video frame is available for preview capture."
        case .imageEncodingFailed:
            return "Unable to encode preview photo JPEG."
        }
    }
}

/// An actor that manages the capture pipeline, which includes the capture session, device inputs, and capture outputs.
/// The app defines it as an `actor` type to ensure that all camera operations happen off of the `@MainActor`.
actor CaptureService {
    
    /// A value that indicates whether the capture service is idle or capturing a photo or movie.
    @Published private(set) var captureActivity: CaptureActivity = .idle
    /// A value that indicates the current capture capabilities of the service.
    @Published private(set) var captureCapabilities = CaptureCapabilities.unknown
    /// A Boolean value that indicates whether a higher priority event, like receiving a phone call, interrupts the app.
    @Published private(set) var isInterrupted = false
    /// A Boolean value that indicates whether the user enables HDR video capture.
    @Published var isHDRVideoEnabled = false
    /// A Boolean value that indicates whether capture controls are in a fullscreen appearance.
    @Published var isShowingFullscreenControls = false
    
    /// A type that connects a preview destination with the capture session.
    nonisolated let previewSource: PreviewSource
    
    // The app's capture session.
    private let captureSession = AVCaptureSession()
    
    // An object that manages the app's photo capture behavior.
    private let photoCapture = PhotoCapture()
    
    // An object that manages the app's video capture behavior.
    private let movieCapture = MovieCapture()
    // A lightweight video-data output used to read camera intrinsics from sample-buffer metadata.
    private let calibrationVideoDataOutput = AVCaptureVideoDataOutput()
    private let calibrationVideoDataDelegate = CalibrationVideoDataDelegate()
    private let calibrationVideoDataOutputQueue = DispatchQueue(label: "com.syncrec.camera.calibrationVideoDataOutputQueue")
    
    // An internal collection of active output services for this video-only build.
    private var outputServices: [any OutputService] { [movieCapture] }
    
    // The video input for the currently selected device camera.
    private var activeVideoInput: AVCaptureDeviceInput?
    
    // The mode of capture, fixed to video for this app build.
    private(set) var captureMode = CaptureMode.video
    
    // An object the service uses to retrieve capture devices.
    private let deviceLookup = DeviceLookup()
    
    // An object that monitors the state of the system-preferred camera.
    private let systemPreferredCamera = SystemPreferredCameraObserver()
    
    // An object that monitors video device rotations.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator!
    private var rotationObservers = [AnyObject]()
    
    // A Boolean value that indicates whether the actor finished its required configuration.
    private var isSetUp = false

    private static let calibrationTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // A Boolean that indicates whether the app expects the capture session to be running.
    private var shouldRunSession = false
    
    // A delegate object that responds to capture control activation and presentation events.
    private var controlsDelegate = CaptureControlsDelegate()
    
    // A map that stores capture controls by device identifier.
    private var controlsMap: [String: [AVCaptureControl]] = [:]

    // The most recently applied manual control state.
    private var manualControlState = ManualCameraControlState.default
    private var selectedVideoCaptureMode = VideoCaptureModePreset.hd1080p30
    // The active deterministic profile, if installed. When present, legacy manual controls must not unlock hardware.
    private var activeManualLockProfile: ManualLockProfile?
    private var lastManualLockApplyReport: ManualApplyReport?
    private var lastManualLockValidationReport: ManualValidationReport?
    private var lastManualLockActualSnapshot: ManualCameraActualSnapshot?
    // The most recent camera intrinsic matrix observed from video sample-buffer attachments.
    private var latestCameraIntrinsics: [Double]?
    private var latestCameraIntrinsicsTimestamp: Date?
    // The most recent video frame from the lightweight video-data output for remote preview checks.
    private var latestPreviewPixelBuffer: CVPixelBuffer?
    private var latestPreviewPixelBufferTimestamp: Date?
    private let previewCIContext = CIContext()
    
    // A serial dispatch queue to use for capture control actions.
    private let sessionQueue = DispatchSerialQueue(label: "com.syncrec.camera.sessionQueue")
    
    // Sets the session queue as the actor's executor.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        sessionQueue.asUnownedSerialExecutor()
    }
    
    init() {
        // Create a source object to connect the preview view with the capture session.
        previewSource = DefaultPreviewSource(session: captureSession)

        calibrationVideoDataDelegate.onSampleBuffer = { [weak self] sampleBuffer in
            guard let self else { return }
            Task {
                await self.handleCalibrationVideoSampleBuffer(sampleBuffer)
            }
        }
    }
    
    // MARK: - Authorization
    /// A Boolean value that indicates whether a person authorizes this app to use
    /// device cameras and microphones. If they haven't previously authorized the
    /// app, querying this property prompts them for authorization.
    var isAuthorized: Bool {
        get async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            // Determine whether a person previously authorized camera access.
            var isAuthorized = status == .authorized
            // If the system hasn't determined their authorization status,
            // explicitly prompt them for approval.
            if status == .notDetermined {
                isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            return isAuthorized
        }
    }
    
    // MARK: - Capture session life cycle
    func start(with state: CameraState) async throws {
        // Set initial operating state.
        captureMode = .video
        isHDRVideoEnabled = state.isVideoHDREnabled
        
        // Exit early if not authorized or the session is already running.
        guard await isAuthorized, !captureSession.isRunning else { return }
        // Configure the session and start it.
        try await setUpSession()
        shouldRunSession = true
        captureSession.startRunning()
        await afterPotentialReconfiguration(reason: "start_running")
    }

    func stop() {
        shouldRunSession = false

        guard captureSession.isRunning else {
            captureActivity = .idle
            return
        }

        captureSession.stopRunning()
        captureActivity = .idle
    }
    
    // MARK: - Capture setup
    // Performs the initial capture session configuration.
    private func setUpSession() async throws {
        // Return early if already set up.
        guard !isSetUp else { return }

        // Observe internal state and notifications.
        observeOutputServices()
        observeNotifications()
        observeCaptureControlsState()
        
        do {
            // Retrieve the default camera and microphone.
            let defaultCamera = try deviceLookup.defaultCamera
            let defaultMic = try deviceLookup.defaultMic

            // Enable using AirPods as a high-quality lapel microphone.
            captureSession.configuresApplicationAudioSessionForBluetoothHighQualityRecording = true

            // Add inputs for the default camera and microphone devices.
            activeVideoInput = try addInput(for: defaultCamera)
            try addInput(for: defaultMic)

            captureSession.sessionPreset = .high
            // Add the movie output as the default output type.
            try addOutput(movieCapture.output)
            if captureSession.canAddOutput(calibrationVideoDataOutput) {
                captureSession.addOutput(calibrationVideoDataOutput)
            } else {
                logger.error("Unable to add calibration video-data output; sample-buffer intrinsics won't be available.")
            }
            configureCalibrationVideoDataOutput()
            configureCameraIntrinsicsDelivery()
            await setHDRVideoEnabled(isHDRVideoEnabled)
            
            // Configure controls to use with the Camera Control.
            configureControls(for: defaultCamera)
            // Monitor the system-preferred camera state.
            monitorSystemPreferredCamera()
            // Configure a rotation coordinator for the default video device.
            createRotationCoordinator(for: defaultCamera)
            // Observe changes to the default camera's subject area.
            observeSubjectAreaChanges(of: defaultCamera)
            // Update the service's advertised capabilities.
            updateCaptureCapabilities()
            
            isSetUp = true
            await afterPotentialReconfiguration(reason: "set_up_session")
        } catch {
            throw CameraError.setupFailed
        }
    }

    // Adds an input to the capture session to connect the specified capture device.
    @discardableResult
    private func addInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let input = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            throw CameraError.addInputFailed
        }
        return input
    }
    
    // Adds an output to the capture session to connect the specified capture device, if allowed.
    private func addOutput(_ output: AVCaptureOutput) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            throw CameraError.addOutputFailed
        }
    }
    
    // The device for the active video input.
    private var currentDevice: AVCaptureDevice {
        guard let device = activeVideoInput?.device else {
            fatalError("No device found for current video input.")
        }
        return device
    }

    // MARK: - Manual camera controls

    func applyManualControlState(_ requestedState: ManualCameraControlState) -> ManualCameraControlSnapshot {
        guard isSetUp else {
            return ManualCameraControlSnapshot(state: requestedState, capabilities: .unavailable)
        }
        guard activeManualLockProfile == nil else {
            return ManualCameraControlSnapshot(state: manualControlState,
                                              capabilities: manualControlCapabilities(for: currentDevice))
        }

        let device = currentDevice
        let capabilities = manualControlCapabilities(for: device)
        var resolvedState = clampedState(requestedState, capabilities: capabilities)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            applyFrameRateControl(&resolvedState, device: device, capabilities: capabilities)
            applyExposureControl(&resolvedState, device: device, capabilities: capabilities)
            applyWhiteBalanceControl(&resolvedState, device: device, capabilities: capabilities)
            applyFocusControl(&resolvedState, device: device, capabilities: capabilities)
        } catch {
            logger.error("Unable to apply manual camera controls: \(error.localizedDescription, privacy: .public)")
        }

        refreshUnlockedManualControlValues(&resolvedState, device: device)
        manualControlState = resolvedState
        return ManualCameraControlSnapshot(state: resolvedState, capabilities: capabilities)
    }

    func currentManualControlSnapshot() -> ManualCameraControlSnapshot {
        guard isSetUp else {
            return ManualCameraControlSnapshot(state: manualControlState, capabilities: .unavailable)
        }

        let device = currentDevice
        let capabilities = manualControlCapabilities(for: device)
        var resolvedState = clampedState(manualControlState, capabilities: capabilities)
        refreshUnlockedManualControlValues(&resolvedState, device: device)
        manualControlState = resolvedState
        return ManualCameraControlSnapshot(state: resolvedState, capabilities: capabilities)
    }

    func setContinuousAutoFocus(reason: String) throws -> ManualCameraActualSnapshot {
        guard isSetUp else {
            throw NSError(domain: "ManualFocusControl",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Capture service is not ready."])
        }

        let device = currentDevice
        let focusMode: AVCaptureDevice.FocusMode
        if device.isFocusModeSupported(.continuousAutoFocus) {
            focusMode = .continuousAutoFocus
        } else if device.isFocusModeSupported(.autoFocus) {
            focusMode = .autoFocus
        } else {
            throw NSError(domain: "ManualFocusControl",
                          code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Autofocus is not supported on this camera."])
        }

        try device.lockForConfiguration()
        do {
            defer { device.unlockForConfiguration() }
            device.focusMode = focusMode
            device.isSubjectAreaChangeMonitoringEnabled = true
        }

        manualControlState.isFocusLocked = false
        manualControlState.focusLensPosition = device.lensPosition
        if var profile = activeManualLockProfile {
            profile.desired.focusLensPosition = nil
            activeManualLockProfile = profile
        }

        let snapshot = exportActualCameraSnapshot(reason: reason)
        lastManualLockActualSnapshot = snapshot
        return snapshot
    }

    func setFocusLockedAtCurrentPosition(reason: String) async throws -> ManualCameraActualSnapshot {
        guard isSetUp else {
            throw NSError(domain: "ManualFocusControl",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Capture service is not ready."])
        }

        let device = currentDevice
        let lensPosition = device.lensPosition
        try await setFocusLocked(device: device, lensPosition: lensPosition)

        manualControlState.isFocusLocked = true
        manualControlState.focusLensPosition = lensPosition
        if var profile = activeManualLockProfile {
            profile.desired.focusLensPosition = lensPosition
            activeManualLockProfile = profile
        }

        let snapshot = exportActualCameraSnapshot(reason: reason)
        lastManualLockActualSnapshot = snapshot
        return snapshot
    }

    func toggleContinuousAutoFocus(reason: String) async throws -> (snapshot: ManualCameraActualSnapshot, isAutoFocusEnabled: Bool) {
        if manualControlState.isFocusLocked ||
            activeManualLockProfile?.desired.focusLensPosition != nil ||
            currentDevice.focusMode == .locked {
            let snapshot = try setContinuousAutoFocus(reason: reason)
            return (snapshot, true)
        }

        let snapshot = try await setFocusLockedAtCurrentPosition(reason: reason)
        return (snapshot, false)
    }

    func releaseManualLocks(preserveFocus: Bool, reason: String) throws -> ManualCameraActualSnapshot {
        guard isSetUp else {
            throw NSError(domain: "ManualLockProfile",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Capture service is not ready."])
        }

        let device = currentDevice
        let capabilities = manualControlCapabilities(for: device)
        let preservedFocusLock = preserveFocus && (
            manualControlState.isFocusLocked || activeManualLockProfile?.desired.focusLensPosition != nil
        )
        let preservedFocusLensPosition = activeManualLockProfile?.desired.focusLensPosition
            ?? manualControlState.focusLensPosition

        activeManualLockProfile = nil
        lastManualLockApplyReport = nil
        lastManualLockValidationReport = nil

        var state = manualControlState
        state.isFPSLocked = false
        state.isISOLocked = false
        state.isShutterLocked = false
        state.isWhiteBalanceLocked = false
        state.isTintLocked = false
        state.isFocusLocked = preservedFocusLock
        state.focusLensPosition = preservedFocusLensPosition
        state = clampedState(state, capabilities: capabilities)

        try device.lockForConfiguration()
        do {
            defer { device.unlockForConfiguration() }
            applyFrameRateControl(&state, device: device, capabilities: capabilities)
            applyExposureControl(&state, device: device, capabilities: capabilities)
            applyWhiteBalanceControl(&state, device: device, capabilities: capabilities)
            applyFocusControl(&state, device: device, capabilities: capabilities)
        }

        refreshUnlockedManualControlValues(&state, device: device)
        manualControlState = state
        configureControls(for: device)

        let snapshot = exportActualCameraSnapshot(reason: reason)
        lastManualLockActualSnapshot = snapshot
        return snapshot
    }

    func currentVideoCaptureModeStatus() -> VideoCaptureModeStatus {
        guard isSetUp else {
            return VideoCaptureModeStatus.unavailable
        }
        return videoCaptureModeStatus(for: currentDevice)
    }

    func videoCaptureModeSupport() -> [VideoCaptureModeSupport] {
        guard isSetUp else {
            return VideoCaptureModePreset.allCases.map {
                VideoCaptureModeSupport(preset: $0,
                                        isSupported: false,
                                        reason: "Capture service unavailable.")
            }
        }
        return videoCaptureModeSupport(for: currentDevice)
    }

    func applyVideoCaptureModePreset(_ preset: VideoCaptureModePreset,
                                     reason: String) async -> VideoCaptureModeApplyReport {
        guard isSetUp else {
            let status = VideoCaptureModeStatus.unavailable
            return VideoCaptureModeApplyReport(requestedPreset: preset,
                                               classification: .failedApply,
                                               detail: "Capture service unavailable.",
                                               status: status)
        }
        guard !captureActivity.isRecording else {
            let status = videoCaptureModeStatus(for: currentDevice)
            return VideoCaptureModeApplyReport(requestedPreset: preset,
                                               classification: .failedApply,
                                               detail: "Refused to change capture mode while recording.",
                                               status: status)
        }
        if activeManualLockProfile?.policy.ownsHDRAndFormat == true {
            let status = videoCaptureModeStatus(for: currentDevice)
            return VideoCaptureModeApplyReport(requestedPreset: preset,
                                               classification: .failedApply,
                                               detail: "Manual lock profile owns camera format/FPS.",
                                               status: status)
        }

        let device = currentDevice
        guard let format = matchingVideoCaptureModeFormat(for: preset,
                                                          device: device,
                                                          preferredDescriptor: nil,
                                                          preferredFieldOfView: device.activeFormat.videoFieldOfView) else {
            selectedVideoCaptureMode = preset
            let status = videoCaptureModeStatus(for: device,
                                                detail: "\(preset.displayName) is unsupported on this camera.")
            return VideoCaptureModeApplyReport(requestedPreset: preset,
                                               classification: .unsupportedMode,
                                               detail: "\(preset.displayName) is unsupported on this camera.",
                                               status: status)
        }

        do {
            try applyVideoCaptureModePreset(preset, format: format, device: device)
        } catch {
            selectedVideoCaptureMode = preset
            let status = videoCaptureModeStatus(for: device,
                                                detail: error.localizedDescription)
            return VideoCaptureModeApplyReport(requestedPreset: preset,
                                               classification: .failedApply,
                                               detail: error.localizedDescription,
                                               status: status)
        }

        selectedVideoCaptureMode = preset
        updateCaptureCapabilities()
        await afterPotentialReconfiguration(reason: reason)

        let status = videoCaptureModeStatus(for: device)
        let exact = status.actualPreset == preset && actualFPSMatchesPreset(status.actualFPS, preset: preset)
        return VideoCaptureModeApplyReport(requestedPreset: preset,
                                           classification: exact ? .exactModeApplied : .failedApply,
                                           detail: exact ? "Applied \(preset.displayName)." : "Applied format readback did not match \(preset.displayName).",
                                           status: status)
    }

    func clearManualLockProfile(reason: String) {
        guard isSetUp else { return }
        activeManualLockProfile = nil
        lastManualLockApplyReport = nil
        lastManualLockValidationReport = nil
        lastManualLockActualSnapshot = exportActualCameraSnapshot(reason: reason)
        configureControls(for: currentDevice)
    }

    func installManualLockProfile(_ profile: ManualLockProfile,
                                  reason: String,
                                  requestID: String? = nil,
                                  dryRun: Bool = false) async -> ManualApplyReport {
        let startedAt = Self.unixMilliseconds()

        guard isSetUp else {
            let report = ManualApplyReport(reportID: UUID().uuidString,
                                           requestID: requestID,
                                           profileID: profile.profileID,
                                           reason: reason,
                                           dryRun: dryRun,
                                           startedAtUnixMilliseconds: startedAt,
                                           completedAtUnixMilliseconds: Self.unixMilliseconds(),
                                           classification: .failed,
                                           detail: "Capture service is not ready.",
                                           parameterReports: [
                                               ManualParameterReport(parameter: "capture_service",
                                                                     status: .unavailable,
                                                                     detail: "Capture session is not set up.")
                                           ],
                                           actualSnapshot: nil)
            lastManualLockApplyReport = report
            return report
        }

        if dryRun {
            let compatibility = dryRunManualLockProfile(profile, reason: reason, requestID: requestID)
            let report = ManualApplyReport(reportID: UUID().uuidString,
                                           requestID: requestID,
                                           profileID: profile.profileID,
                                           reason: reason,
                                           dryRun: true,
                                           startedAtUnixMilliseconds: startedAt,
                                           completedAtUnixMilliseconds: Self.unixMilliseconds(),
                                           classification: compatibility.classification,
                                           detail: compatibility.detail,
                                           parameterReports: compatibility.parameterReports,
                                           actualSnapshot: compatibility.actualSnapshot)
            lastManualLockApplyReport = report
            lastManualLockValidationReport = compatibility
            lastManualLockActualSnapshot = compatibility.actualSnapshot
            return report
        }

        if captureActivity.isRecording && !profile.policy.allowApplyWhileRecording {
            let snapshot = exportActualCameraSnapshot(reason: reason)
            let report = ManualApplyReport(reportID: UUID().uuidString,
                                           requestID: requestID,
                                           profileID: profile.profileID,
                                           reason: reason,
                                           dryRun: false,
                                           startedAtUnixMilliseconds: startedAt,
                                           completedAtUnixMilliseconds: Self.unixMilliseconds(),
                                           classification: .refused,
                                           detail: "Refused to apply deterministic profile while recording.",
                                           parameterReports: [
                                               ManualParameterReport(parameter: "recording_state",
                                                                     status: .refused,
                                                                     detail: "Profile policy does not allow hardware mutation while recording.")
                                           ],
                                           actualSnapshot: snapshot)
            lastManualLockApplyReport = report
            lastManualLockActualSnapshot = snapshot
            return report
        }

        activeManualLockProfile = profile
        if profile.policy.disableCaptureControls {
            removeCaptureControls()
        }

        var applyReports = [ManualParameterReport]()
        do {
            applyReports.append(contentsOf: try await applyManualLockProfileToHardware(profile))
        } catch {
            let snapshot = exportActualCameraSnapshot(reason: reason)
            applyReports.append(ManualParameterReport(parameter: "profile_apply",
                                                      status: .incompatible,
                                                      detail: error.localizedDescription))
            let report = ManualApplyReport(reportID: UUID().uuidString,
                                           requestID: requestID,
                                           profileID: profile.profileID,
                                           reason: reason,
                                           dryRun: false,
                                           startedAtUnixMilliseconds: startedAt,
                                           completedAtUnixMilliseconds: Self.unixMilliseconds(),
                                           classification: .failed,
                                           detail: "Manual profile apply failed: \(error.localizedDescription)",
                                           parameterReports: applyReports,
                                           actualSnapshot: snapshot)
            lastManualLockApplyReport = report
            lastManualLockActualSnapshot = snapshot
            var storedProfile = profile
            storedProfile.lastApplyReport = report
            storedProfile.actualValidatedSnapshot = snapshot
            activeManualLockProfile = storedProfile
            return report
        }

        let validation = validateManualLockProfile(reason: "\(reason)_post_apply",
                                                  requestID: requestID,
                                                  profileOverride: profile)
        let report = ManualApplyReport(reportID: UUID().uuidString,
                                       requestID: requestID,
                                       profileID: profile.profileID,
                                       reason: reason,
                                       dryRun: false,
                                       startedAtUnixMilliseconds: startedAt,
                                       completedAtUnixMilliseconds: Self.unixMilliseconds(),
                                       classification: validation.classification,
                                       detail: validation.detail,
                                       parameterReports: applyReports + validation.parameterReports,
                                       actualSnapshot: validation.actualSnapshot)
        lastManualLockApplyReport = report
        lastManualLockValidationReport = validation
        lastManualLockActualSnapshot = validation.actualSnapshot
        var storedProfile = profile
        storedProfile.lastApplyReport = report
        storedProfile.actualValidatedSnapshot = validation.actualSnapshot
        activeManualLockProfile = storedProfile
        return report
    }

    func reapplyManualLockProfile(reason: String,
                                  requestID: String? = nil) async -> ManualApplyReport {
        guard let profile = activeManualLockProfile else {
            let now = Self.unixMilliseconds()
            return ManualApplyReport(reportID: UUID().uuidString,
                                     requestID: requestID,
                                     profileID: nil,
                                     reason: reason,
                                     dryRun: false,
                                     startedAtUnixMilliseconds: now,
                                     completedAtUnixMilliseconds: now,
                                     classification: .failed,
                                     detail: "No active manual lock profile.",
                                     parameterReports: [
                                         ManualParameterReport(parameter: "profile",
                                                               status: .unavailable,
                                                               detail: "No active profile is installed.")
                                     ],
                                     actualSnapshot: exportActualCameraSnapshot(reason: reason))
        }
        return await installManualLockProfile(profile, reason: reason, requestID: requestID, dryRun: false)
    }

    func validateManualLockProfile(reason: String,
                                   requestID: String? = nil) -> ManualValidationReport {
        validateManualLockProfile(reason: reason, requestID: requestID, profileOverride: nil)
    }

    private func validateManualLockProfile(reason: String,
                                           requestID: String?,
                                           profileOverride: ManualLockProfile?) -> ManualValidationReport {
        let snapshot = exportActualCameraSnapshot(reason: reason)
        guard let profile = profileOverride ?? activeManualLockProfile else {
            let report = ManualValidationReport(reportID: UUID().uuidString,
                                                requestID: requestID,
                                                profileID: nil,
                                                reason: reason,
                                                validatedAtUnixMilliseconds: Self.unixMilliseconds(),
                                                classification: .unknown,
                                                detail: "No active manual lock profile.",
                                                parameterReports: [
                                                    ManualParameterReport(parameter: "profile",
                                                                          status: .notRequested,
                                                                          critical: false,
                                                                          detail: "No active profile is installed.")
                                                ],
                                                actualSnapshot: snapshot)
            lastManualLockValidationReport = report
            lastManualLockActualSnapshot = snapshot
            return report
        }

        let reports = validationReports(for: profile, actual: snapshot)
        let classification = classification(for: reports, policy: profile.policy)
        let detail: String
        switch classification {
        case .exactMatch:
            detail = "Actual camera state matches deterministic profile."
        case .adjustedMatch:
            detail = "Actual camera state differs only by policy-allowed adjustments."
        case .incompatible:
            detail = "Actual camera state is incompatible with deterministic profile."
        case .drifted:
            detail = "Actual camera state drifted from deterministic profile."
        case .refused:
            detail = "Validation refused."
        case .failed:
            detail = "Validation failed."
        case .unknown:
            detail = "Validation status is unknown."
        }

        let report = ManualValidationReport(reportID: UUID().uuidString,
                                            requestID: requestID,
                                            profileID: profile.profileID,
                                            reason: reason,
                                            validatedAtUnixMilliseconds: Self.unixMilliseconds(),
                                            classification: classification,
                                            detail: detail,
                                            parameterReports: reports,
                                            actualSnapshot: snapshot)
        lastManualLockValidationReport = report
        lastManualLockActualSnapshot = snapshot
        return report
    }

    private func dryRunManualLockProfile(_ profile: ManualLockProfile,
                                         reason: String,
                                         requestID: String?) -> ManualValidationReport {
        let snapshot = exportActualCameraSnapshot(reason: reason)
        var reports = [ManualParameterReport]()
        let desired = profile.desired
        let device = currentDevice
        let requestedFormat = requestedFormatForDesiredSettings(desired, device: device)

        if let preset = desired.captureModePreset {
            let supported = requestedFormat != nil
            reports.append(ManualParameterReport(parameter: "capture_mode",
                                                 status: supported ? .exact : .incompatible,
                                                 requested: preset.rawValue,
                                                 actual: snapshot.actualCaptureModePreset?.rawValue,
                                                 detail: supported ? "\(preset.displayName) is supported." : "\(preset.displayName) is unsupported on this device."))
            if let fps = desired.selectedFPS,
               !nearlyEqual(fps, preset.fps, relativeTolerance: 0.0005, absoluteTolerance: 0.001) {
                reports.append(ManualParameterReport(parameter: "fps",
                                                     status: .incompatible,
                                                     requested: String(format: "%.6f", fps),
                                                     actual: String(format: "%.6f", preset.fps),
                                                     detail: "Profile FPS conflicts with capture mode preset."))
            }
        }

        if desired.captureModePreset == nil, let descriptor = desired.format {
            if matchingFormat(for: descriptor, fps: desired.selectedFPS, device: device) != nil {
                reports.append(ManualParameterReport(parameter: "active_format",
                                                     status: .exact,
                                                     requested: formatSummary(descriptor),
                                                     actual: snapshot.activeFormat.map(formatSummary(_:)),
                                                     detail: "A compatible activeFormat exists."))
            } else {
                reports.append(ManualParameterReport(parameter: "active_format",
                                                     status: .incompatible,
                                                     requested: formatSummary(descriptor),
                                                     actual: snapshot.activeFormat.map(formatSummary(_:)),
                                                     detail: "No compatible activeFormat exists on this device."))
            }
        }

        if let fps = desired.selectedFPS {
            let ranges = (requestedFormat ?? device.activeFormat)
                .videoSupportedFrameRateRanges
            let supported = ranges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
            reports.append(ManualParameterReport(parameter: "fps",
                                                 status: supported ? .exact : .incompatible,
                                                 requested: String(format: "%.6f", fps),
                                                 actual: snapshot.actualFPSMinFrameDurationSeconds.map { String(format: "%.9f", 1.0 / $0) },
                                                 detail: supported ? "Requested FPS is supported." : "Requested FPS is outside supported ranges."))
        }

        if let iso = desired.iso {
            let format = requestedFormat ?? device.activeFormat
            let supported = iso >= format.minISO && iso <= format.maxISO
            reports.append(ManualParameterReport(parameter: "iso",
                                                 status: supported ? .exact : .incompatible,
                                                 requested: String(format: "%.3f", iso),
                                                 actual: snapshot.exposure.map { String(format: "%.3f", $0.iso) },
                                                 detail: supported ? "Requested ISO is in range." : "Requested ISO is outside active format range."))
        }

        if let exposureDuration = desired.exposureDurationSeconds {
            let format = requestedFormat ?? device.activeFormat
            let minExposure = finiteSeconds(from: format.minExposureDuration) ?? 0
            let maxExposure = finiteSeconds(from: format.maxExposureDuration) ?? .greatestFiniteMagnitude
            let supported = exposureDuration >= minExposure && exposureDuration <= maxExposure
            reports.append(ManualParameterReport(parameter: "exposure_duration",
                                                 status: supported ? .exact : .incompatible,
                                                 requested: String(format: "%.9f", exposureDuration),
                                                 actual: snapshot.exposure?.exposureDurationSeconds.map { String(format: "%.9f", $0) },
                                                 detail: supported ? "Requested shutter duration is in range." : "Requested shutter duration is outside active format range."))
        }

        if desired.whiteBalanceGains != nil || desired.whiteBalanceTemperature != nil || desired.whiteBalanceTint != nil {
            let supported = device.isWhiteBalanceModeSupported(.locked)
            reports.append(ManualParameterReport(parameter: "white_balance",
                                                 status: supported ? .exact : .incompatible,
                                                 requested: desired.whiteBalanceGains.map(gainsSummary(_:)),
                                                 actual: snapshot.whiteBalance.map { gainsSummary($0.gains) },
                                                 detail: supported ? "White balance lock is supported." : "White balance lock is unsupported."))
        }

        if desired.focusLensPosition != nil {
            let supported = device.isLockingFocusWithCustomLensPositionSupported
            reports.append(ManualParameterReport(parameter: "focus_lens_position",
                                                 status: supported ? .exact : .incompatible,
                                                 critical: profile.policy.focusIsCritical,
                                                 requested: desired.focusLensPosition.map { String(format: "%.6f", $0) },
                                                 actual: snapshot.focus.map { String(format: "%.6f", $0.lensPosition) },
                                                 detail: supported ? "Focus lock is supported." : "Focus lens-position lock is unsupported."))
        }

        if let zoom = desired.zoomFactor {
            let format = requestedFormat ?? device.activeFormat
            let supported = zoom >= 1.0 && zoom <= format.videoMaxZoomFactor
            reports.append(ManualParameterReport(parameter: "zoom_factor",
                                                 status: supported ? .exact : .incompatible,
                                                 critical: profile.policy.zoomIsCritical,
                                                 requested: String(format: "%.6f", zoom),
                                                 actual: snapshot.zoom.map { String(format: "%.6f", $0.factor) },
                                                 detail: supported ? "Zoom factor is supported." : "Zoom factor is outside active format range."))
        }

        if desired.preferredStabilizationModeRawValue != nil {
            let supported = movieCapture.output.connection(with: .video)?.isVideoStabilizationSupported ?? false
            reports.append(ManualParameterReport(parameter: "stabilization",
                                                 status: supported ? .exact : .incompatible,
                                                 requested: desired.preferredStabilizationMode ?? desired.preferredStabilizationModeRawValue.map(String.init),
                                                 actual: snapshot.stabilization?.preferredMode,
                                                 detail: supported ? "Video stabilization preference can be set." : "Video stabilization is unsupported."))
        }

        if reports.isEmpty {
            reports.append(ManualParameterReport(parameter: "profile",
                                                 status: .notRequested,
                                                 critical: false,
                                                 detail: "Profile contains no deterministic settings."))
        }

        let classification = classification(for: reports, policy: profile.policy)
        return ManualValidationReport(reportID: UUID().uuidString,
                                      requestID: requestID,
                                      profileID: profile.profileID,
                                      reason: reason,
                                      validatedAtUnixMilliseconds: Self.unixMilliseconds(),
                                      classification: classification,
                                      detail: classification == .incompatible ? "Dry run found incompatible parameters." : "Dry run found compatible parameters.",
                                      parameterReports: reports,
                                      actualSnapshot: snapshot)
    }

    private func applyManualLockProfileToHardware(_ profile: ManualLockProfile) async throws -> [ManualParameterReport] {
        var reports = [ManualParameterReport]()
        let desired = profile.desired
        let device = currentDevice

        var selectedFormat: AVCaptureDevice.Format?
        if let preset = desired.captureModePreset {
            guard let match = matchingVideoCaptureModeFormat(for: preset,
                                                             device: device,
                                                             preferredDescriptor: desired.format,
                                                             preferredFieldOfView: desired.format?.videoFieldOfViewDegrees) else {
                throw NSError(domain: "ManualLockProfile",
                              code: 99,
                              userInfo: [NSLocalizedDescriptionKey: "\(preset.displayName) is unsupported on this device."])
            }
            if let fps = desired.selectedFPS,
               !nearlyEqual(fps, preset.fps, relativeTolerance: 0.0005, absoluteTolerance: 0.001) {
                throw NSError(domain: "ManualLockProfile",
                              code: 98,
                              userInfo: [NSLocalizedDescriptionKey: "Profile FPS \(fps) conflicts with capture mode \(preset.rawValue)."])
            }
            selectedFormat = match
        } else if let descriptor = desired.format {
            guard let match = matchingFormat(for: descriptor, fps: desired.selectedFPS, device: device) else {
                throw NSError(domain: "ManualLockProfile",
                              code: 100,
                              userInfo: [NSLocalizedDescriptionKey: "No compatible activeFormat for \(formatSummary(descriptor))."])
            }
            selectedFormat = match
        }

        captureSession.beginConfiguration()
        if selectedFormat != nil, captureSession.canSetSessionPreset(.inputPriority) {
            captureSession.sessionPreset = .inputPriority
        }

        try device.lockForConfiguration()
        if let selectedFormat, device.activeFormat != selectedFormat {
            device.activeFormat = selectedFormat
            reports.append(ManualParameterReport(parameter: "active_format",
                                                 status: .applied,
                                                 requested: selectedFormat.mapFormatSummary,
                                                 detail: "Set activeFormat by deterministic descriptor."))
        }

        if let preset = desired.captureModePreset {
            guard let duration = fixedFrameDuration(forFPS: preset.fps, format: device.activeFormat) else {
                throw NSError(domain: "ManualLockProfile",
                              code: 97,
                              userInfo: [NSLocalizedDescriptionKey: "Requested capture mode \(preset.rawValue) is unsupported by the active format."])
            }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            selectedVideoCaptureMode = preset
            reports.append(ManualParameterReport(parameter: "capture_mode",
                                                 status: .applied,
                                                 requested: preset.rawValue,
                                                 detail: "Set activeFormat and fixed frame duration for \(preset.displayName)."))
        } else if let fps = desired.selectedFPS {
            guard let duration = supportedFrameDuration(forFPS: fps, device: device) else {
                throw NSError(domain: "ManualLockProfile",
                              code: 101,
                              userInfo: [NSLocalizedDescriptionKey: "Requested FPS \(fps) is unsupported by the active format."])
            }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            reports.append(ManualParameterReport(parameter: "fps",
                                                 status: .applied,
                                                 requested: String(format: "%.6f", fps),
                                                 detail: "Set active min/max frame durations to requested FPS."))
        } else {
            if let minDuration = desired.activeVideoMinFrameDurationSeconds {
                guard let duration = supportedFrameDuration(forDurationSeconds: minDuration, device: device) else {
                    throw NSError(domain: "ManualLockProfile",
                                  code: 102,
                                  userInfo: [NSLocalizedDescriptionKey: "Requested minimum frame duration \(minDuration) is unsupported by the active format."])
                }
                device.activeVideoMinFrameDuration = duration
            }
            if let maxDuration = desired.activeVideoMaxFrameDurationSeconds {
                guard let duration = supportedFrameDuration(forDurationSeconds: maxDuration, device: device) else {
                    throw NSError(domain: "ManualLockProfile",
                                  code: 103,
                                  userInfo: [NSLocalizedDescriptionKey: "Requested maximum frame duration \(maxDuration) is unsupported by the active format."])
                }
                device.activeVideoMaxFrameDuration = duration
            }
            if desired.activeVideoMinFrameDurationSeconds != nil || desired.activeVideoMaxFrameDurationSeconds != nil {
                reports.append(ManualParameterReport(parameter: "fps",
                                                     status: .applied,
                                                     detail: "Set active min/max frame durations from profile."))
            }
        }

        if let zoom = desired.zoomFactor {
            device.videoZoomFactor = zoom
            reports.append(ManualParameterReport(parameter: "zoom_factor",
                                                 status: .applied,
                                                 critical: profile.policy.zoomIsCritical,
                                                 requested: String(format: "%.6f", zoom),
                                                 detail: "Set video zoom factor."))
        }

        if desired.focusLensPosition != nil {
            device.isSubjectAreaChangeMonitoringEnabled = false
        }
        device.unlockForConfiguration()
        captureSession.commitConfiguration()

        if let rawMode = desired.preferredStabilizationModeRawValue {
            setPreferredVideoStabilizationMode(rawMode)
            reports.append(ManualParameterReport(parameter: "stabilization",
                                                 status: .applied,
                                                 requested: desired.preferredStabilizationMode ?? String(rawMode),
                                                 detail: "Set preferred stabilization mode on video connections."))
        }

        if desired.exposureDurationSeconds != nil || desired.iso != nil {
            let currentExposure = finiteSeconds(from: device.exposureDuration) ?? desired.exposureDurationSeconds ?? 1.0 / 48.0
            let duration = CMTime(seconds: desired.exposureDurationSeconds ?? currentExposure,
                                  preferredTimescale: 1_000_000_000)
            try await setExposureLocked(device: device, duration: duration, iso: desired.iso ?? device.iso)
            reports.append(ManualParameterReport(parameter: "exposure",
                                                 status: .applied,
                                                 requested: exposureSummary(durationSeconds: desired.exposureDurationSeconds,
                                                                           iso: desired.iso),
                                                 detail: "Set custom exposure duration/ISO."))
        }

        if let gains = desired.whiteBalanceGains {
            try await setWhiteBalanceLocked(device: device, gains: gains)
            reports.append(ManualParameterReport(parameter: "white_balance",
                                                 status: .applied,
                                                 requested: gainsSummary(gains),
                                                 detail: "Set locked white balance gains."))
        } else if desired.whiteBalanceTemperature != nil || desired.whiteBalanceTint != nil {
            let current = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            let target = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: desired.whiteBalanceTemperature ?? current.temperature,
                tint: desired.whiteBalanceTint ?? current.tint
            )
            var gains = device.deviceWhiteBalanceGains(for: target)
            gains = normalizeWhiteBalanceGains(gains, device: device)
            try await setWhiteBalanceLocked(device: device,
                                            gains: ManualWhiteBalanceGains(red: gains.redGain,
                                                                           green: gains.greenGain,
                                                                           blue: gains.blueGain))
            let temperatureText = desired.whiteBalanceTemperature.map { String(format: "%.2f", $0) } ?? "current"
            let tintText = desired.whiteBalanceTint.map { String(format: "%.2f", $0) } ?? "current"
            reports.append(ManualParameterReport(parameter: "white_balance",
                                                 status: .applied,
                                                 requested: "temperature=\(temperatureText), tint=\(tintText)",
                                                 detail: "Set locked white balance from temperature/tint."))
        }

        if let focus = desired.focusLensPosition {
            try await setFocusLocked(device: device, lensPosition: focus)
            reports.append(ManualParameterReport(parameter: "focus_lens_position",
                                                 status: .applied,
                                                 critical: profile.policy.focusIsCritical,
                                                 requested: String(format: "%.6f", focus),
                                                 detail: "Set locked focus lens position."))
        }

        return reports
    }


    private func applyFrameRateControl(_ state: inout ManualCameraControlState,
                                       device: AVCaptureDevice,
                                       capabilities: ManualCameraControlCapabilities) {
        guard capabilities.supportsFrameRateControl else { return }

        state.fps = clamp(state.fps, to: capabilities.fpsRange)
        if state.isFPSLocked {
            let requestedFPS = state.fps
            guard let targetDuration = supportedFrameDuration(forFPS: requestedFPS, device: device) else {
                logger.error("Unsupported FPS \(requestedFPS, privacy: .public) for active camera format.")
                state.isFPSLocked = false
                state.fps = actualOrDefaultFPS(for: device, fallback: requestedFPS)
                return
            }
            device.activeVideoMinFrameDuration = targetDuration
            device.activeVideoMaxFrameDuration = targetDuration
        } else {
            device.activeVideoMinFrameDuration = CMTime.invalid
            device.activeVideoMaxFrameDuration = CMTime.invalid
            state.fps = actualOrDefaultFPS(for: device, fallback: state.fps)
        }
    }

    private func applyExposureControl(_ state: inout ManualCameraControlState,
                                      device: AVCaptureDevice,
                                      capabilities: ManualCameraControlCapabilities) {
        guard capabilities.supportsManualExposure else { return }

        state.iso = clamp(state.iso, to: capabilities.isoRange)
        state.shutterSeconds = clamp(state.shutterSeconds, to: capabilities.shutterRange)

        if state.hasAnyExposureLock {
            let currentShutter = safeSeconds(from: device.exposureDuration, fallback: state.shutterSeconds)
            let targetShutter = state.isShutterLocked ? state.shutterSeconds : currentShutter
            let targetDuration = CMTime(seconds: targetShutter, preferredTimescale: 1_000_000_000)
            let targetISO = state.isISOLocked ? state.iso : device.iso
            device.setExposureModeCustom(duration: targetDuration, iso: targetISO, completionHandler: nil)
        } else if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    private func applyWhiteBalanceControl(_ state: inout ManualCameraControlState,
                                          device: AVCaptureDevice,
                                          capabilities: ManualCameraControlCapabilities) {
        guard capabilities.supportsWhiteBalanceLock else { return }

        state.whiteBalanceTemperature = clamp(state.whiteBalanceTemperature,
                                              to: capabilities.whiteBalanceTemperatureRange)
        state.tint = clamp(state.tint, to: capabilities.tintRange)

        if state.hasAnyWhiteBalanceLock {
            let current = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            let targetTemperature = state.isWhiteBalanceLocked ? state.whiteBalanceTemperature : current.temperature
            let targetTint = state.isTintLocked ? state.tint : current.tint
            let targetValues = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: targetTemperature,
                                                                                    tint: targetTint)
            var gains = device.deviceWhiteBalanceGains(for: targetValues)
            gains = normalizeWhiteBalanceGains(gains, device: device)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)

            // Keep locked values aligned to the nearest representable gains on this sensor.
            let resolved = device.temperatureAndTintValues(for: gains)
            if state.isWhiteBalanceLocked {
                state.whiteBalanceTemperature = clamp(resolved.temperature,
                                                      to: capabilities.whiteBalanceTemperatureRange)
            }
            if state.isTintLocked {
                state.tint = clamp(resolved.tint, to: capabilities.tintRange)
            }
        } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    private func applyFocusControl(_ state: inout ManualCameraControlState,
                                   device: AVCaptureDevice,
                                   capabilities: ManualCameraControlCapabilities) {
        guard capabilities.supportsFocusLock else { return }

        state.focusLensPosition = clamp(state.focusLensPosition, to: capabilities.focusRange)
        if state.isFocusLocked {
            // Prevent subject-area callbacks from re-enabling autofocus while focus is locked.
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.setFocusModeLocked(lensPosition: state.focusLensPosition, completionHandler: nil)
        } else if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    private func manualControlCapabilities(for device: AVCaptureDevice) -> ManualCameraControlCapabilities {
        let isoRange = device.activeFormat.minISO...device.activeFormat.maxISO
        let shutterMin = safeSeconds(from: device.activeFormat.minExposureDuration, fallback: 1.0 / 2000.0)
        let shutterMax = safeSeconds(from: device.activeFormat.maxExposureDuration, fallback: 0.25)
        let shutterRange = min(shutterMin, shutterMax)...max(shutterMin, shutterMax)
        let fpsRange = supportedFPSRange(for: device) ?? ManualCameraControlCapabilities.unavailable.fpsRange

        return ManualCameraControlCapabilities(
            isoRange: isoRange,
            whiteBalanceTemperatureRange: 2000...10000,
            fpsRange: fpsRange,
            shutterRange: shutterRange,
            tintRange: -150...150,
            focusRange: 0...1,
            supportsManualExposure: device.isExposureModeSupported(.custom),
            supportsWhiteBalanceLock: device.isWhiteBalanceModeSupported(.locked),
            supportsFrameRateControl: supportedFPSRange(for: device) != nil,
            supportsFocusLock: device.isLockingFocusWithCustomLensPositionSupported
        )
    }

    private func supportedFPSRange(for device: AVCaptureDevice) -> ClosedRange<Double>? {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard let first = ranges.first else { return nil }

        var minFPS = first.minFrameRate
        var maxFPS = first.maxFrameRate
        for range in ranges.dropFirst() {
            minFPS = min(minFPS, range.minFrameRate)
            maxFPS = max(maxFPS, range.maxFrameRate)
        }

        guard minFPS.isFinite, maxFPS.isFinite, minFPS > 0, maxFPS >= minFPS else {
            return nil
        }
        return minFPS...maxFPS
    }

    private func videoCaptureModeSupport(for device: AVCaptureDevice) -> [VideoCaptureModeSupport] {
        VideoCaptureModePreset.allCases.map { preset in
            if matchingVideoCaptureModeFormat(for: preset,
                                              device: device,
                                              preferredDescriptor: nil,
                                              preferredFieldOfView: device.activeFormat.videoFieldOfView) != nil {
                return VideoCaptureModeSupport(preset: preset, isSupported: true, reason: nil)
            }
            return VideoCaptureModeSupport(preset: preset,
                                           isSupported: false,
                                           reason: "No compatible \(preset.summary) format.")
        }
    }

    private func videoCaptureModeStatus(for device: AVCaptureDevice,
                                        detail: String? = nil) -> VideoCaptureModeStatus {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let actualFPS = actualFPS(for: device)
        let actualPreset = presetMatching(width: Int(dimensions.width),
                                          height: Int(dimensions.height),
                                          fps: actualFPS)
        let supported = videoCaptureModeSupport(for: device)
            .filter(\.isSupported)
            .map(\.preset)
        return VideoCaptureModeStatus(selectedPreset: selectedVideoCaptureMode,
                                      actualPreset: actualPreset,
                                      actualWidth: Int(dimensions.width),
                                      actualHeight: Int(dimensions.height),
                                      actualFPS: actualFPS,
                                      supportedPresets: supported,
                                      detail: detail)
    }

    private func actualFPS(for device: AVCaptureDevice) -> Double? {
        if let minDuration = finiteSeconds(from: device.activeVideoMinFrameDuration),
           let maxDuration = finiteSeconds(from: device.activeVideoMaxFrameDuration),
           nearlyEqual(minDuration, maxDuration, relativeTolerance: 0.0005, absoluteTolerance: 0.000_001) {
            return 1.0 / minDuration
        }
        if let minDuration = finiteSeconds(from: device.activeVideoMinFrameDuration) {
            return 1.0 / minDuration
        }
        return nil
    }

    private func presetMatching(width: Int,
                                height: Int,
                                fps: Double?) -> VideoCaptureModePreset? {
        guard let fps else { return nil }
        return VideoCaptureModePreset.allCases.first {
            $0.width == width && $0.height == height && actualFPSMatchesPreset(fps, preset: $0)
        }
    }

    private func actualFPSMatchesPreset(_ actualFPS: Double?,
                                        preset: VideoCaptureModePreset) -> Bool {
        guard let actualFPS else { return false }
        return abs(actualFPS - preset.fps) <= 0.25
    }

    private func fixedFrameDuration(forFPS fps: Double,
                                    format: AVCaptureDevice.Format) -> CMTime? {
        guard fps.isFinite, fps > 0 else { return nil }
        let tolerance = max(0.0001, fps * 0.00001)
        guard format.videoSupportedFrameRateRanges.contains(where: {
            fps >= $0.minFrameRate - tolerance && fps <= $0.maxFrameRate + tolerance
        }) else {
            return nil
        }
        let rounded = fps.rounded()
        if abs(fps - rounded) <= 0.0001 {
            return CMTime(value: 1, timescale: CMTimeScale(max(1, Int32(rounded))))
        }
        return CMTime(seconds: 1.0 / fps, preferredTimescale: 600_000)
    }

    private func applyVideoCaptureModePreset(_ preset: VideoCaptureModePreset,
                                             format: AVCaptureDevice.Format,
                                             device: AVCaptureDevice) throws {
        guard let duration = fixedFrameDuration(forFPS: preset.fps, format: format) else {
            throw NSError(domain: "VideoCaptureMode",
                          code: 200,
                          userInfo: [NSLocalizedDescriptionKey: "\(preset.displayName) is unsupported by the selected active format."])
        }

        captureSession.beginConfiguration()
        if captureSession.canSetSessionPreset(.inputPriority) {
            captureSession.sessionPreset = .inputPriority
        }

        do {
            try device.lockForConfiguration()
            if device.activeFormat != format {
                device.activeFormat = format
            }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            captureSession.commitConfiguration()
        } catch {
            captureSession.commitConfiguration()
            throw error
        }
    }

    private func clampedState(_ state: ManualCameraControlState,
                              capabilities: ManualCameraControlCapabilities) -> ManualCameraControlState {
        var clamped = state
        clamped.iso = clamp(state.iso, to: capabilities.isoRange)
        clamped.whiteBalanceTemperature = clamp(state.whiteBalanceTemperature,
                                                to: capabilities.whiteBalanceTemperatureRange)
        clamped.fps = clamp(state.fps, to: capabilities.fpsRange)
        clamped.shutterSeconds = clamp(state.shutterSeconds, to: capabilities.shutterRange)
        clamped.tint = clamp(state.tint, to: capabilities.tintRange)
        clamped.focusLensPosition = clamp(state.focusLensPosition, to: capabilities.focusRange)
        return clamped
    }

    private func normalizeWhiteBalanceGains(_ gains: AVCaptureDevice.WhiteBalanceGains,
                                            device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        var normalized = gains
        let maxGain = device.maxWhiteBalanceGain
        normalized.redGain = clamp(normalized.redGain, to: 1...maxGain)
        normalized.greenGain = clamp(normalized.greenGain, to: 1...maxGain)
        normalized.blueGain = clamp(normalized.blueGain, to: 1...maxGain)
        return normalized
    }

    private func safeSeconds(from time: CMTime, fallback: Double) -> Double {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return fallback }
        return seconds
    }

    private func finiteSeconds(from time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    private func supportedFrameDuration(forFPS fps: Double, device: AVCaptureDevice) -> CMTime? {
        guard fps.isFinite, fps > 0 else { return nil }

        let fpsTolerance = max(0.0001, fps * 0.00001)
        for range in device.activeFormat.videoSupportedFrameRateRanges {
            guard fps >= range.minFrameRate - fpsTolerance,
                  fps <= range.maxFrameRate + fpsTolerance else {
                continue
            }

            if abs(fps - range.maxFrameRate) <= fpsTolerance {
                return range.minFrameDuration
            }
            if abs(fps - range.minFrameRate) <= fpsTolerance {
                return range.maxFrameDuration
            }

            return CMTime(seconds: 1.0 / fps, preferredTimescale: 600_000)
        }

        return nil
    }

    private func supportedFrameDuration(forDurationSeconds seconds: Double,
                                        device: AVCaptureDevice) -> CMTime? {
        guard seconds.isFinite, seconds > 0 else { return nil }

        let durationTolerance = max(0.000_001, seconds * 0.00001)
        for range in device.activeFormat.videoSupportedFrameRateRanges {
            guard let minDurationSeconds = finiteSeconds(from: range.minFrameDuration),
                  let maxDurationSeconds = finiteSeconds(from: range.maxFrameDuration) else {
                continue
            }

            if abs(seconds - minDurationSeconds) <= durationTolerance {
                return range.minFrameDuration
            }
            if abs(seconds - maxDurationSeconds) <= durationTolerance {
                return range.maxFrameDuration
            }
            if seconds >= minDurationSeconds - durationTolerance,
               seconds <= maxDurationSeconds + durationTolerance {
                return CMTime(seconds: seconds, preferredTimescale: 600_000)
            }
        }

        return nil
    }

    private func actualOrDefaultFPS(for device: AVCaptureDevice, fallback: Double) -> Double {
        if let minDuration = finiteSeconds(from: device.activeVideoMinFrameDuration),
           let maxDuration = finiteSeconds(from: device.activeVideoMaxFrameDuration),
           nearlyEqual(minDuration, maxDuration, relativeTolerance: 0.0005, absoluteTolerance: 0.000_001) {
            return 1.0 / minDuration
        }
        if let minDuration = finiteSeconds(from: device.activeVideoMinFrameDuration) {
            return 1.0 / minDuration
        }

        let maxFPS = device.activeFormat.videoSupportedFrameRateRanges
            .map(\.maxFrameRate)
            .filter { $0.isFinite && $0 > 0 }
            .max()
        return maxFPS ?? fallback
    }

    private func refreshUnlockedManualControlValues(_ state: inout ManualCameraControlState,
                                                    device: AVCaptureDevice) {
        if !state.isFPSLocked {
            state.fps = actualOrDefaultFPS(for: device, fallback: state.fps)
        }
        if !state.isISOLocked {
            state.iso = device.iso
        }
        if !state.isShutterLocked,
           let exposureDuration = finiteSeconds(from: device.exposureDuration) {
            state.shutterSeconds = exposureDuration
        }

        let whiteBalance = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        if !state.isWhiteBalanceLocked, whiteBalance.temperature.isFinite {
            state.whiteBalanceTemperature = whiteBalance.temperature
        }
        if !state.isTintLocked, whiteBalance.tint.isFinite {
            state.tint = whiteBalance.tint
        }
        if !state.isFocusLocked {
            state.focusLensPosition = device.lensPosition
        }
    }

    private func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func cameraPositionDescription(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .unspecified:
            return "unspecified"
        case .back:
            return "back"
        case .front:
            return "front"
        @unknown default:
            return "unknown"
        }
    }

    private func serializedCalibrationPayload(_ payload: [String: Any]) -> Data {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: options) else {
            let fallback = #"{"available":false,"reason":"json_serialization_failed"}"#
            return Data(fallback.utf8)
        }
        return data
    }

    private func jsonSafeValue(from value: Any) -> Any? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let numberValue = number.doubleValue
            guard numberValue.isFinite else { return nil }
            return number
        }
        if let data = value as? Data {
            return [
                "type": "Data",
                "byteCount": data.count,
                "base64": data.base64EncodedString()
            ]
        }
        if let array = value as? [Any] {
            return array.compactMap { jsonSafeValue(from: $0) }
        }
        if let dictionary = value as? [AnyHashable: Any] {
            var mapped = [String: Any]()
            for (key, nestedValue) in dictionary {
                let keyString = String(describing: key)
                if let jsonValue = jsonSafeValue(from: nestedValue) {
                    mapped[keyString] = jsonValue
                }
            }
            return mapped
        }
        if let date = value as? Date {
            return Self.calibrationTimestampFormatter.string(from: date)
        }
        if let url = value as? URL {
            return url.absoluteString
        }
        return String(describing: value)
    }

    func exportActualCameraSnapshot(reason: String,
                                    identity: ManualSnapshotDeviceIdentity = .unknown) -> ManualCameraActualSnapshot {
        guard isSetUp, let device = activeVideoInput?.device else {
            return ManualCameraActualSnapshot(capturedAtUnixMilliseconds: Self.unixMilliseconds(),
                                              reason: reason,
                                              identity: identity,
                                              device: nil,
                                              activeFormat: nil,
                                              actualFPSMinFrameDurationSeconds: nil,
                                              actualFPSMaxFrameDurationSeconds: nil,
                                              exposure: nil,
                                              whiteBalance: nil,
                                              focus: nil,
                                              zoom: nil,
                                              stabilization: nil,
                                              intrinsics: ManualCameraIntrinsicsSnapshot(available: false,
                                                                                        timestampUnixMilliseconds: nil,
                                                                                        matrix3x3RowMajor: nil,
                                                                                        freshnessSeconds: nil,
                                                                                        missingReason: "capture_service_not_ready"),
                                              isSubjectAreaChangeMonitoringEnabled: nil)
        }

        let format = device.activeFormat
        let modeStatus = videoCaptureModeStatus(for: device)
        let whiteBalance = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        let intrinsics: ManualCameraIntrinsicsSnapshot
        if let latestCameraIntrinsics {
            let timestamp = latestCameraIntrinsicsTimestamp ?? Date()
            intrinsics = ManualCameraIntrinsicsSnapshot(available: true,
                                                        timestampUnixMilliseconds: Self.unixMilliseconds(timestamp),
                                                        matrix3x3RowMajor: latestCameraIntrinsics,
                                                        freshnessSeconds: Date().timeIntervalSince(timestamp),
                                                        missingReason: nil)
        } else {
            intrinsics = ManualCameraIntrinsicsSnapshot(available: false,
                                                        timestampUnixMilliseconds: nil,
                                                        matrix3x3RowMajor: nil,
                                                        freshnessSeconds: nil,
                                                        missingReason: "no_intrinsics_sample_buffer_attachment_seen")
        }

        let snapshot = ManualCameraActualSnapshot(
            capturedAtUnixMilliseconds: Self.unixMilliseconds(),
            reason: reason,
            identity: identity,
            device: ManualCaptureDeviceDescriptor(
                localizedName: device.localizedName,
                uniqueID: device.uniqueID,
                modelID: device.modelID,
                deviceType: device.deviceType.rawValue,
                position: cameraPositionDescription(device.position),
                isGeometricDistortionCorrectionSupported: device.isGeometricDistortionCorrectionSupported,
                isGeometricDistortionCorrectionEnabled: device.isGeometricDistortionCorrectionEnabled
            ),
            selectedCaptureModePreset: modeStatus.selectedPreset,
            actualCaptureModePreset: modeStatus.actualPreset,
            supportedCaptureModePresets: modeStatus.supportedPresets,
            activeFormat: formatDescriptor(for: format, device: device),
            actualFPSMinFrameDurationSeconds: finiteSeconds(from: device.activeVideoMinFrameDuration),
            actualFPSMaxFrameDurationSeconds: finiteSeconds(from: device.activeVideoMaxFrameDuration),
            exposure: ManualExposureSnapshot(
                exposureDurationSeconds: finiteSeconds(from: device.exposureDuration),
                iso: device.iso,
                exposureModeRawValue: device.exposureMode.rawValue,
                exposureMode: exposureModeName(device.exposureMode)
            ),
            whiteBalance: ManualWhiteBalanceSnapshot(
                gains: ManualWhiteBalanceGains(red: device.deviceWhiteBalanceGains.redGain,
                                                green: device.deviceWhiteBalanceGains.greenGain,
                                                blue: device.deviceWhiteBalanceGains.blueGain),
                temperature: whiteBalance.temperature.isFinite ? whiteBalance.temperature : nil,
                tint: whiteBalance.tint.isFinite ? whiteBalance.tint : nil,
                modeRawValue: device.whiteBalanceMode.rawValue,
                mode: whiteBalanceModeName(device.whiteBalanceMode)
            ),
            focus: ManualFocusSnapshot(
                lensPosition: device.lensPosition,
                focusModeRawValue: device.focusMode.rawValue,
                focusMode: focusModeName(device.focusMode)
            ),
            zoom: ManualZoomSnapshot(factor: device.videoZoomFactor),
            stabilization: stabilizationSnapshot(),
            intrinsics: intrinsics,
            isSubjectAreaChangeMonitoringEnabled: device.isSubjectAreaChangeMonitoringEnabled
        )
        lastManualLockActualSnapshot = snapshot
        return snapshot
    }

    private func validationReports(for profile: ManualLockProfile,
                                   actual: ManualCameraActualSnapshot) -> [ManualParameterReport] {
        let desired = profile.desired
        var reports = [ManualParameterReport]()

        if let requestedPreset = desired.captureModePreset {
            let actualPreset = actual.actualCaptureModePreset
            let exactMode = actualPreset == requestedPreset
            reports.append(ManualParameterReport(parameter: "capture_mode",
                                                 status: exactMode ? .exact : .incompatible,
                                                 requested: requestedPreset.rawValue,
                                                 actual: actualPreset?.rawValue,
                                                 detail: exactMode ? nil : "Actual capture mode differs from requested preset."))
        }

        if desired.captureModePreset == nil, let requested = desired.format {
            let status: ManualParameterStatus
            let detail: String?
            if let actualFormat = actual.activeFormat,
               requested.width == actualFormat.width,
               requested.height == actualFormat.height,
               requested.mediaSubTypeRawValue == actualFormat.mediaSubTypeRawValue,
               requested.isVideoBinned == actualFormat.isVideoBinned {
                status = .exact
                detail = nil
            } else {
                status = profile.policy.allowFormatSubstitution ? .adjusted : .incompatible
                detail = "Active format differs from requested deterministic descriptor."
            }
            reports.append(ManualParameterReport(parameter: "active_format",
                                                 status: status,
                                                 requested: formatSummary(requested),
                                                 actual: actual.activeFormat.map(formatSummary(_:)),
                                                 detail: detail))
        }

        if let fps = desired.selectedFPS {
            let requestedDuration = 1.0 / fps
            let minMatches = actual.actualFPSMinFrameDurationSeconds.map { nearlyEqual($0, requestedDuration, relativeTolerance: 0.0005, absoluteTolerance: 0.000_001) } ?? false
            let maxMatches = actual.actualFPSMaxFrameDurationSeconds.map { nearlyEqual($0, requestedDuration, relativeTolerance: 0.0005, absoluteTolerance: 0.000_001) } ?? false
            reports.append(ManualParameterReport(parameter: "fps",
                                                 status: minMatches && maxMatches ? .exact : .incompatible,
                                                 requested: String(format: "%.6f", fps),
                                                 actual: fpsSummary(actual),
                                                 detail: minMatches && maxMatches ? nil : "Actual frame durations do not match requested FPS."))
        }

        if let exposureDuration = desired.exposureDurationSeconds {
            let matches = actual.exposure?.exposureDurationSeconds.map {
                exposureDurationsMatch(actual: $0, requested: exposureDuration)
            } ?? false
            reports.append(ManualParameterReport(parameter: "exposure_duration",
                                                 status: matches ? .exact : .incompatible,
                                                 requested: String(format: "%.9f", exposureDuration),
                                                 actual: actual.exposure?.exposureDurationSeconds.map { String(format: "%.9f", $0) },
                                                 detail: matches ? nil : "Actual exposure duration differs from requested shutter."))
        }

        if let iso = desired.iso {
            let matches = actual.exposure.map { abs(Double($0.iso - iso)) <= 0.5 } ?? false
            reports.append(ManualParameterReport(parameter: "iso",
                                                 status: matches ? .exact : .incompatible,
                                                 requested: String(format: "%.3f", iso),
                                                 actual: actual.exposure.map { String(format: "%.3f", $0.iso) },
                                                 detail: matches ? nil : "Actual ISO differs from requested ISO."))
        }

        if let gains = desired.whiteBalanceGains {
            let matches = actual.whiteBalance.map { whiteBalanceGainsNearlyEqual($0.gains, gains) } ?? false
            reports.append(ManualParameterReport(parameter: "white_balance_gains",
                                                 status: matches ? .exact : .incompatible,
                                                 requested: gainsSummary(gains),
                                                 actual: actual.whiteBalance.map { gainsSummary($0.gains) },
                                                 detail: matches ? nil : "Actual white-balance gains differ from requested gains."))
        }

        if let temperature = desired.whiteBalanceTemperature {
            let matches = actual.whiteBalance?.temperature.map { abs($0 - temperature) <= 50 } ?? false
            reports.append(ManualParameterReport(parameter: "white_balance_temperature",
                                                 status: matches ? .exact : .incompatible,
                                                 requested: String(format: "%.2f", temperature),
                                                 actual: actual.whiteBalance?.temperature.map { String(format: "%.2f", $0) },
                                                 detail: matches ? nil : "Actual white-balance temperature differs from requested temperature."))
        }

        if let tint = desired.whiteBalanceTint {
            let matches = actual.whiteBalance?.tint.map { abs($0 - tint) <= 2 } ?? false
            reports.append(ManualParameterReport(parameter: "white_balance_tint",
                                                 status: matches ? .exact : .incompatible,
                                                 requested: String(format: "%.2f", tint),
                                                 actual: actual.whiteBalance?.tint.map { String(format: "%.2f", $0) },
                                                 detail: matches ? nil : "Actual white-balance tint differs from requested tint."))
        }

        if let focus = desired.focusLensPosition {
            let matches = actual.focus.map { abs(Double($0.lensPosition - focus)) <= 0.005 } ?? false
            reports.append(ManualParameterReport(parameter: "focus_lens_position",
                                                 status: matches ? .exact : .incompatible,
                                                 critical: profile.policy.focusIsCritical,
                                                 requested: String(format: "%.6f", focus),
                                                 actual: actual.focus.map { String(format: "%.6f", $0.lensPosition) },
                                                 detail: matches ? nil : "Actual focus lens position differs from requested position."))
        }

        if let zoom = desired.zoomFactor {
            let matches = actual.zoom.map { abs(Double($0.factor - zoom)) <= 0.001 } ?? false
            reports.append(ManualParameterReport(parameter: "zoom_factor",
                                                 status: matches ? .exact : .incompatible,
                                                 critical: profile.policy.zoomIsCritical,
                                                 requested: String(format: "%.6f", zoom),
                                                 actual: actual.zoom.map { String(format: "%.6f", $0.factor) },
                                                 detail: matches ? nil : "Actual zoom factor differs from requested zoom."))
        }

        if let stabilization = desired.preferredStabilizationModeRawValue {
            let matches = actual.stabilization?.preferredModeRawValue == stabilization
            reports.append(ManualParameterReport(parameter: "stabilization",
                                                 status: matches ? .exact : .incompatible,
                                                 requested: desired.preferredStabilizationMode ?? String(stabilization),
                                                 actual: actual.stabilization?.preferredMode,
                                                 detail: matches ? nil : "Preferred stabilization mode differs from profile."))
        }

        if reports.isEmpty {
            reports.append(ManualParameterReport(parameter: "profile",
                                                 status: .notRequested,
                                                 critical: false,
                                                 detail: "Profile contains no deterministic settings."))
        }
        return reports
    }

    private func exposureDurationsMatch(actual: Double, requested: Double) -> Bool {
        // AVCaptureDevice quantizes custom exposure durations to sensor-supported ticks.
        // Treat sub-frame, sub-percent differences as the same deterministic shutter.
        nearlyEqual(actual,
                    requested,
                    relativeTolerance: 0.005,
                    absoluteTolerance: 0.000_050)
    }

    private func classification(for reports: [ManualParameterReport],
                                policy: ManualLockProfilePolicy) -> ManualReportClassification {
        if reports.contains(where: { $0.critical && [.incompatible, .unavailable, .refused, .drifted].contains($0.status) }) {
            return .incompatible
        }
        if reports.contains(where: { $0.critical && $0.status == .adjusted && !policy.allowCriticalValueAdjustment }) {
            return .incompatible
        }
        if reports.contains(where: { $0.status == .adjusted }) {
            return .adjustedMatch
        }
        return .exactMatch
    }

    private func afterPotentialReconfiguration(reason: String) async {
        guard let profile = activeManualLockProfile else { return }

        if captureActivity.isRecording {
            _ = validateManualLockProfile(reason: "\(reason)_recording_validation",
                                          requestID: nil,
                                          profileOverride: profile)
            return
        }

        let validation = validateManualLockProfile(reason: "\(reason)_validation",
                                                  requestID: nil,
                                                  profileOverride: profile)
        guard validation.classification != .exactMatch,
              profile.policy.autoReapplyWhenIdle else {
            return
        }
        _ = await installManualLockProfile(profile, reason: "\(reason)_auto_reapply", requestID: nil, dryRun: false)
    }

    private func requestedFormatForDesiredSettings(_ desired: ManualCameraDesiredSettings,
                                                   device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        if let preset = desired.captureModePreset {
            return matchingVideoCaptureModeFormat(for: preset,
                                                  device: device,
                                                  preferredDescriptor: desired.format,
                                                  preferredFieldOfView: desired.format?.videoFieldOfViewDegrees)
        }
        if let descriptor = desired.format {
            return matchingFormat(for: descriptor, fps: desired.selectedFPS, device: device)
        }
        return nil
    }

    private func matchingFormat(for descriptor: ManualCameraFormatDescriptor,
                                fps: Double?,
                                device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let matches = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dimensions.width) == descriptor.width,
                  Int(dimensions.height) == descriptor.height else {
                return false
            }
            if let rawValue = descriptor.mediaSubTypeRawValue,
               format.formatDescription.mediaSubType.rawValue != rawValue {
                return false
            }
            if let isVideoBinned = descriptor.isVideoBinned,
               format.isVideoBinned != isVideoBinned {
                return false
            }
            if let isTenBit = descriptor.isTenBit,
               format.isTenBitFormat != isTenBit {
                return false
            }
            if let fps {
                return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
            }
            return true
        }

        return matches.sorted {
            let leftMax = $0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rightMax = $1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return leftMax > rightMax
        }.first
    }

    private func matchingVideoCaptureModeFormat(for preset: VideoCaptureModePreset,
                                                device: AVCaptureDevice,
                                                preferredDescriptor: ManualCameraFormatDescriptor?,
                                                preferredFieldOfView: Float?) -> AVCaptureDevice.Format? {
        let targetFPS = preset.fps
        let preferredSubtype = preferredDescriptor?.mediaSubTypeRawValue
            ?? device.activeFormat.formatDescription.mediaSubType.rawValue
        let preferredBinned = preferredDescriptor?.isVideoBinned
        let preferTenBit = preferredDescriptor?.isTenBit ?? isHDRVideoEnabled
        let fov = preferredFieldOfView ?? preferredDescriptor?.videoFieldOfViewDegrees ?? device.activeFormat.videoFieldOfView

        let matches = device.formats.filter { format in
            guard CMFormatDescriptionGetMediaType(format.formatDescription) == kCMMediaType_Video else {
                return false
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Int(dimensions.width) == preset.width,
                  Int(dimensions.height) == preset.height else {
                return false
            }
            guard isCompatibleVideoSubType(format.formatDescription.mediaSubType.rawValue) else {
                return false
            }
            return format.videoSupportedFrameRateRanges.contains {
                targetFPS >= $0.minFrameRate - 0.001 && targetFPS <= $0.maxFrameRate + 0.001
            }
        }

        return matches.sorted { left, right in
            let leftTenBitPenalty = tenBitPenalty(format: left, preferTenBit: preferTenBit)
            let rightTenBitPenalty = tenBitPenalty(format: right, preferTenBit: preferTenBit)
            if leftTenBitPenalty != rightTenBitPenalty {
                return leftTenBitPenalty < rightTenBitPenalty
            }

            let leftSubtypePenalty = subtypePenalty(format: left, preferredSubtype: preferredSubtype)
            let rightSubtypePenalty = subtypePenalty(format: right, preferredSubtype: preferredSubtype)
            if leftSubtypePenalty != rightSubtypePenalty {
                return leftSubtypePenalty < rightSubtypePenalty
            }

            let leftBinnedPenalty = binnedPenalty(format: left, preferredBinned: preferredBinned)
            let rightBinnedPenalty = binnedPenalty(format: right, preferredBinned: preferredBinned)
            if leftBinnedPenalty != rightBinnedPenalty {
                return leftBinnedPenalty < rightBinnedPenalty
            }

            let leftFOVDelta = abs(left.videoFieldOfView - fov)
            let rightFOVDelta = abs(right.videoFieldOfView - fov)
            if leftFOVDelta != rightFOVDelta {
                return leftFOVDelta < rightFOVDelta
            }

            let leftMaxFPS = left.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rightMaxFPS = right.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return leftMaxFPS < rightMaxFPS
        }.first
    }

    private func isCompatibleVideoSubType(_ rawValue: UInt32) -> Bool {
        rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            rawValue == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    private func tenBitPenalty(format: AVCaptureDevice.Format,
                               preferTenBit: Bool) -> Int {
        format.isTenBitFormat == preferTenBit ? 0 : 1
    }

    private func subtypePenalty(format: AVCaptureDevice.Format,
                                preferredSubtype: UInt32?) -> Int {
        guard let preferredSubtype else { return 0 }
        return format.formatDescription.mediaSubType.rawValue == preferredSubtype ? 0 : 1
    }

    private func binnedPenalty(format: AVCaptureDevice.Format,
                               preferredBinned: Bool?) -> Int {
        if let preferredBinned, format.isVideoBinned == preferredBinned {
            return 0
        }
        return format.isVideoBinned ? 2 : 1
    }

    private func formatDescriptor(for format: AVCaptureDevice.Format,
                                  device: AVCaptureDevice) -> ManualCameraFormatDescriptor {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let rawSubType = format.formatDescription.mediaSubType.rawValue
        let ranges = format.videoSupportedFrameRateRanges.map {
            ManualFrameRateRange(minFrameRate: $0.minFrameRate, maxFrameRate: $0.maxFrameRate)
        }
        return ManualCameraFormatDescriptor(width: Int(dimensions.width),
                                            height: Int(dimensions.height),
                                            mediaSubTypeFourCC: fourCCString(rawSubType),
                                            mediaSubTypeRawValue: rawSubType,
                                            isVideoBinned: format.isVideoBinned,
                                            minISO: format.minISO,
                                            maxISO: format.maxISO,
                                            minExposureDurationSeconds: finiteSeconds(from: format.minExposureDuration),
                                            maxExposureDurationSeconds: finiteSeconds(from: format.maxExposureDuration),
                                            supportedFrameRateRanges: ranges,
                                            videoMaxZoomFactor: format.videoMaxZoomFactor,
                                            videoZoomFactorUpscaleThreshold: format.videoZoomFactorUpscaleThreshold,
                                            videoFieldOfViewDegrees: format.videoFieldOfView,
                                            geometricDistortionCorrectedVideoFieldOfViewDegrees: format.geometricDistortionCorrectedVideoFieldOfView,
                                            activeColorSpaceRawValue: device.activeColorSpace.rawValue,
                                            isTenBit: format.isTenBitFormat,
                                            hdr10BitSupported: device.activeFormat10BitVariant != nil)
    }

    private func setPreferredVideoStabilizationMode(_ rawValue: Int) {
        guard let mode = AVCaptureVideoStabilizationMode(rawValue: rawValue) else { return }
        for connection in movieCapture.output.connections where connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = mode
        }
    }

    private func stabilizationSnapshot() -> ManualStabilizationSnapshot? {
        guard let connection = movieCapture.output.connection(with: .video) else { return nil }
        return ManualStabilizationSnapshot(preferredModeRawValue: connection.preferredVideoStabilizationMode.rawValue,
                                           preferredMode: stabilizationModeName(connection.preferredVideoStabilizationMode),
                                           activeModeRawValue: connection.activeVideoStabilizationMode.rawValue,
                                           activeMode: stabilizationModeName(connection.activeVideoStabilizationMode),
                                           isSupported: connection.isVideoStabilizationSupported)
    }

    private func setExposureLocked(device: AVCaptureDevice,
                                   duration: CMTime,
                                   iso: Float) async throws {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(duration: duration, iso: iso) { _ in
                    continuation.resume()
                }
                device.unlockForConfiguration()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func setWhiteBalanceLocked(device: AVCaptureDevice,
                                       gains: ManualWhiteBalanceGains) async throws {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try device.lockForConfiguration()
                let requestedGains = AVCaptureDevice.WhiteBalanceGains(redGain: gains.red,
                                                                       greenGain: gains.green,
                                                                       blueGain: gains.blue)
                let normalized = normalizeWhiteBalanceGains(requestedGains, device: device)
                device.setWhiteBalanceModeLocked(with: normalized) { _ in
                    continuation.resume()
                }
                device.unlockForConfiguration()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func setFocusLocked(device: AVCaptureDevice,
                                lensPosition: Float) async throws {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try device.lockForConfiguration()
                device.isSubjectAreaChangeMonitoringEnabled = false
                device.setFocusModeLocked(lensPosition: lensPosition) { _ in
                    continuation.resume()
                }
                device.unlockForConfiguration()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func removeCaptureControls() {
        guard captureSession.supportsControls else { return }
        captureSession.beginConfiguration()
        for control in captureSession.controls {
            captureSession.removeControl(control)
        }
        captureSession.commitConfiguration()
    }

    private static func unixMilliseconds(_ date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private func nearlyEqual(_ lhs: Double,
                             _ rhs: Double,
                             relativeTolerance: Double,
                             absoluteTolerance: Double) -> Bool {
        abs(lhs - rhs) <= max(absoluteTolerance, abs(rhs) * relativeTolerance)
    }

    private func whiteBalanceGainsNearlyEqual(_ lhs: ManualWhiteBalanceGains,
                                              _ rhs: ManualWhiteBalanceGains) -> Bool {
        abs(lhs.red - rhs.red) <= 0.01 &&
        abs(lhs.green - rhs.green) <= 0.01 &&
        abs(lhs.blue - rhs.blue) <= 0.01
    }

    private func formatSummary(_ descriptor: ManualCameraFormatDescriptor) -> String {
        let subtype = descriptor.mediaSubTypeFourCC ?? descriptor.mediaSubTypeRawValue.map(String.init) ?? "unknown"
        let binned = descriptor.isVideoBinned.map { $0 ? "binned" : "not_binned" } ?? "binned_unknown"
        return "\(descriptor.width)x\(descriptor.height) \(subtype) \(binned)"
    }

    private func fpsSummary(_ snapshot: ManualCameraActualSnapshot) -> String? {
        guard let minDuration = snapshot.actualFPSMinFrameDurationSeconds,
              let maxDuration = snapshot.actualFPSMaxFrameDurationSeconds else {
            return nil
        }
        return "min=\(String(format: "%.9f", minDuration)), max=\(String(format: "%.9f", maxDuration))"
    }

    private func gainsSummary(_ gains: ManualWhiteBalanceGains) -> String {
        "r=\(String(format: "%.4f", gains.red)), g=\(String(format: "%.4f", gains.green)), b=\(String(format: "%.4f", gains.blue))"
    }

    private func exposureSummary(durationSeconds: Double?, iso: Float?) -> String {
        let duration = durationSeconds.map { String(format: "%.9f", $0) } ?? "current"
        let isoText = iso.map { String(format: "%.3f", $0) } ?? "current"
        return "duration=\(duration), iso=\(isoText)"
    }

    private func fourCCString(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(value)"
    }

    private func exposureModeName(_ mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode {
        case .locked:
            return "locked"
        case .autoExpose:
            return "auto_expose"
        case .continuousAutoExposure:
            return "continuous_auto_exposure"
        case .custom:
            return "custom"
        @unknown default:
            return "unknown"
        }
    }

    private func whiteBalanceModeName(_ mode: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch mode {
        case .locked:
            return "locked"
        case .autoWhiteBalance:
            return "auto_white_balance"
        case .continuousAutoWhiteBalance:
            return "continuous_auto_white_balance"
        @unknown default:
            return "unknown"
        }
    }

    private func focusModeName(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .locked:
            return "locked"
        case .autoFocus:
            return "auto_focus"
        case .continuousAutoFocus:
            return "continuous_auto_focus"
        @unknown default:
            return "unknown"
        }
    }

    private func stabilizationModeName(_ mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .off:
            return "off"
        case .standard:
            return "standard"
        case .cinematic:
            return "cinematic"
        case .cinematicExtended:
            return "cinematic_extended"
        case .previewOptimized:
            return "preview_optimized"
        case .cinematicExtendedEnhanced:
            return "cinematic_extended_enhanced"
        case .lowLatency:
            return "low_latency"
        case .auto:
            return "auto"
        @unknown default:
            return "unknown"
        }
    }
    
    // MARK: - Capture controls
    
    private func configureControls(for device: AVCaptureDevice) {
        
        // Exit early if the host device doesn't support capture controls.
        guard captureSession.supportsControls else { return }
        
        // Begin configuring the capture session.
        captureSession.beginConfiguration()
        
        // Remove previously configured controls, if any.
        for control in captureSession.controls {
            captureSession.removeControl(control)
        }

        if activeManualLockProfile?.policy.disableCaptureControls == true {
            captureSession.commitConfiguration()
            return
        }
        
        // Create controls and add them to the capture session.
        for control in createControls(for: device) {
            if captureSession.canAddControl(control) {
                captureSession.addControl(control)
            } else {
                logger.info("Unable to add control \(control).")
            }
        }
        
        // Set the controls delegate.
        captureSession.setControlsDelegate(controlsDelegate, queue: sessionQueue)
        
        // Commit the capture session configuration.
        captureSession.commitConfiguration()
    }
    
    func createControls(for device: AVCaptureDevice) -> [AVCaptureControl] {
        // Retrieve the capture controls for this device, if they exist.
        guard let controls = controlsMap[device.uniqueID] else {
            // Define the default controls.
            var controls = [
                AVCaptureSystemZoomSlider(device: device),
                AVCaptureSystemExposureBiasSlider(device: device)
            ]
            // Create a lens position control if the device supports setting a custom position.
            if device.isLockingFocusWithCustomLensPositionSupported {
                // Create a slider to adjust the value from 0 to 1.
                let lensSlider = AVCaptureSlider("Lens Position", symbolName: "circle.dotted.circle", in: 0...1)
                // Perform the slider's action on the session queue.
                lensSlider.setActionQueue(sessionQueue) { lensPosition in
                    do {
                        try device.lockForConfiguration()
                        device.setFocusModeLocked(lensPosition: lensPosition)
                        device.unlockForConfiguration()
                    } catch {
                        logger.info("Unable to change the lens position: \(error)")
                    }
                }
                // Add the slider the controls array.
                controls.append(lensSlider)
            }
            // Store the controls for future use.
            controlsMap[device.uniqueID] = controls
            return controls
        }
        
        // Return the previously created controls.
        return controls
    }
    
    // MARK: - Capture mode selection
    
    /// Changes the mode of capture, which can be `photo` or `video`.
    ///
    /// - Parameter `captureMode`: The capture mode to enable.
    func setCaptureMode(_ captureMode: CaptureMode) async throws {
        guard captureMode == .video else { return }
        self.captureMode = .video
        
        // Change the configuration atomically.
        captureSession.beginConfiguration()
        
        captureSession.sessionPreset = .high
        if !captureSession.outputs.contains(where: { $0 === movieCapture.output }) {
            try addOutput(movieCapture.output)
        }
        if !captureSession.outputs.contains(where: { $0 === calibrationVideoDataOutput }) {
            if captureSession.canAddOutput(calibrationVideoDataOutput) {
                captureSession.addOutput(calibrationVideoDataOutput)
            } else {
                logger.error("Unable to add calibration video-data output during mode reconfiguration.")
            }
        }
        configureCalibrationVideoDataOutput()
        configureCameraIntrinsicsDelivery()
        captureSession.commitConfiguration()

        if isHDRVideoEnabled {
            await setHDRVideoEnabled(true)
        }

        _ = await applyVideoCaptureModePreset(selectedVideoCaptureMode,
                                              reason: "set_capture_mode_restore_video_preset")

        // Update the advertised capabilities after reconfiguration.
        updateCaptureCapabilities()
        await afterPotentialReconfiguration(reason: "set_capture_mode")
    }
    
    // MARK: - Device selection
    
    /// Changes the capture device that provides video input.
    ///
    /// The app calls this method in response to the user tapping the button in the UI to change cameras.
    /// The implementation switches between the front and back cameras and, in iPadOS,
    /// connected external cameras.
    func selectNextVideoDevice() async {
        // The array of available video capture devices.
        let videoDevices = deviceLookup.cameras

        // Find the index of the currently selected video device.
        let selectedIndex = videoDevices.firstIndex(of: currentDevice) ?? 0
        // Get the next index.
        var nextIndex = selectedIndex + 1
        // Wrap around if the next index is invalid.
        if nextIndex == videoDevices.endIndex {
            nextIndex = 0
        }
        
        let nextDevice = videoDevices[nextIndex]
        // Change the session's active capture device.
        await changeCaptureDevice(to: nextDevice, reason: "select_next_video_device")
        
        // The app only calls this method in response to the user requesting to switch cameras.
        // Set the new selection as the user's preferred camera.
        AVCaptureDevice.userPreferredCamera = nextDevice
    }
    
    // Changes the device the service uses for video capture.
    private func changeCaptureDevice(to device: AVCaptureDevice, reason: String) async {
        // The service must have a valid video input prior to calling this method.
        guard let currentInput = activeVideoInput else { fatalError() }
        
        // Bracket the following configuration in a begin/commit configuration pair.
        captureSession.beginConfiguration()
        
        // Remove the existing video input before attempting to connect a new one.
        captureSession.removeInput(currentInput)
        do {
            // Attempt to connect a new input and device to the capture session.
            activeVideoInput = try addInput(for: device)
            // Configure capture controls for new device selection.
            configureControls(for: device)
            // Configure a new rotation coordinator for the new device.
            createRotationCoordinator(for: device)
            // Register for device observations.
            observeSubjectAreaChanges(of: device)
            configureCalibrationVideoDataOutput()
            configureCameraIntrinsicsDelivery()
            // Update the service's advertised capabilities.
            updateCaptureCapabilities()
        } catch {
            // Reconnect the existing camera on failure.
            captureSession.addInput(currentInput)
        }
        captureSession.commitConfiguration()
        await afterPotentialReconfiguration(reason: reason)
    }
    
    /// Monitors changes to the system's preferred camera selection.
    ///
    /// iPadOS supports external cameras. When someone connects an external camera to their iPad,
    /// they're signaling the intent to use the device. The system responds by updating the
    /// system-preferred camera (SPC) selection to this new device. When this occurs, if the SPC
    /// isn't the currently selected camera, switch to the new device.
    private func monitorSystemPreferredCamera() {
        Task {
            // An object monitors changes to system-preferred camera (SPC) value.
            for await camera in systemPreferredCamera.changes {
                // If the SPC isn't the currently selected camera, attempt to change to that device.
                if let camera, currentDevice != camera {
                    logger.debug("Switching camera selection to the system-preferred camera.")
                    if activeManualLockProfile?.policy.ignoreSystemPreferredCameraWhileLocked == true {
                        _ = validateManualLockProfile(reason: "system_preferred_camera_change_ignored")
                        continue
                    }
                    await changeCaptureDevice(to: camera, reason: "system_preferred_camera_change")
                }
            }
        }
    }
    
    // MARK: - Rotation handling
    
    /// Create a new rotation coordinator for the specified device and observe its state to monitor rotation changes.
    private func createRotationCoordinator(for device: AVCaptureDevice) {
        // Create a new rotation coordinator for this device.
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: videoPreviewLayer)
        
        // Set initial rotation state on the preview and output connections.
        updatePreviewRotation(rotationCoordinator.videoRotationAngleForHorizonLevelPreview)
        updateCaptureRotation(rotationCoordinator.videoRotationAngleForHorizonLevelCapture)
        
        // Cancel previous observations.
        rotationObservers.removeAll()
        
        // Add observers to monitor future changes.
        rotationObservers.append(
            rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                // Update the capture preview rotation.
                Task { await self.updatePreviewRotation(angle) }
            }
        )
        
        rotationObservers.append(
            rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                // Update the capture preview rotation.
                Task { await self.updateCaptureRotation(angle) }
            }
        )
    }
    
    private func updatePreviewRotation(_ angle: CGFloat) {
        let connection = videoPreviewLayer.connection
        Task { @MainActor in
            // Set initial rotation angle on the video preview.
            connection?.videoRotationAngle = angle
        }
    }
    
    private func updateCaptureRotation(_ angle: CGFloat) {
        // Update the orientation for all output services.
        outputServices.forEach { $0.setVideoRotationAngle(angle) }
        calibrationVideoDataOutput.connection(with: .video)?.videoRotationAngle = angle
    }
    
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // Access the capture session's connected preview layer.
        guard let previewLayer = captureSession.connections.compactMap({ $0.videoPreviewLayer }).first else {
            fatalError("The app is misconfigured. The capture session should have a connection to a preview layer.")
        }
        return previewLayer
    }
    
    // MARK: - Automatic focus and exposure
    
    /// Performs a one-time automatic focus and expose operation.
    ///
    /// The app calls this method as the result of a person tapping on the preview area.
    func focusAndExpose(at point: CGPoint, adjustExposure: Bool = true) {
        guard activeManualLockProfile == nil else { return }
        // The point this call receives is in view-space coordinates. Convert this point to device coordinates.
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        do {
            // Perform a user-initiated focus and expose.
            try focusAndExpose(at: devicePoint, isUserInitiated: true, adjustExposure: adjustExposure)
        } catch {
            logger.debug("Unable to perform focus and exposure operation. \(error)")
        }
    }
    
    // Observe notifications of type `subjectAreaDidChangeNotification` for the specified device.
    private func observeSubjectAreaChanges(of device: AVCaptureDevice) {
        // Cancel the previous observation task.
        subjectAreaChangeTask?.cancel()
        subjectAreaChangeTask = Task {
            // Signal true when this notification occurs.
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification, object: device).compactMap({ _ in true }) {
                if activeManualLockProfile != nil {
                    continue
                }
                // Keep a true manual focus lock fixed at the same distance.
                if manualControlState.isFocusLocked {
                    continue
                }
                // Perform a system-initiated focus and expose.
                try? focusAndExpose(at: CGPoint(x: 0.5, y: 0.5), isUserInitiated: false)
            }
        }
    }
    private var subjectAreaChangeTask: Task<Void, Never>?
    
    private func focusAndExpose(at devicePoint: CGPoint, isUserInitiated: Bool, adjustExposure: Bool = true) throws {
        guard activeManualLockProfile == nil else { return }
        if manualControlState.isFocusLocked {
            return
        }

        // Configure the current device.
        let device = currentDevice
        
        // The following mode and point of interest configuration requires obtaining an exclusive lock on the device.
        try device.lockForConfiguration()
        
        let focusMode = isUserInitiated ? AVCaptureDevice.FocusMode.autoFocus : .continuousAutoFocus
        if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = focusMode
        }
        
        if adjustExposure {
            let exposureMode = isUserInitiated ? AVCaptureDevice.ExposureMode.autoExpose : .continuousAutoExposure
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = exposureMode
            }
        }
        // Enable subject-area change monitoring when performing a user-initiated automatic focus and exposure operation.
        // If this method enables change monitoring, when the device's subject area changes, the app calls this method a
        // second time and resets the device to continuous automatic focus and exposure.
        device.isSubjectAreaChangeMonitoringEnabled = isUserInitiated && adjustExposure
        
        // Release the lock.
        device.unlockForConfiguration()
    }
    
    // MARK: - Photo capture
    func capturePhoto(with features: PhotoFeatures) async throws -> Photo {
        try await photoCapture.capturePhoto(with: features)
    }

    func capturePreviewPhoto(requestID: String,
                             identity: ManualSnapshotDeviceIdentity,
                             longEdge: Int,
                             jpegQuality: Double) async throws -> RemotePreviewPhotoCapture {
        guard isSetUp else {
            throw PreviewPhotoCaptureError.captureServiceNotReady
        }
        guard captureSession.isRunning else {
            throw PreviewPhotoCaptureError.sessionNotRunning
        }
        guard !isInterrupted else {
            throw PreviewPhotoCaptureError.interrupted
        }
        guard !captureActivity.isRecording else {
            throw PreviewPhotoCaptureError.recordingActive
        }
        let frameDeadline = Date().addingTimeInterval(2.0)
        while !hasFreshPreviewFrame(maxAgeSeconds: 1.0), Date() < frameDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let pixelBuffer = latestPreviewPixelBuffer,
              let pixelBufferTimestamp = latestPreviewPixelBufferTimestamp,
              Date().timeIntervalSince(pixelBufferTimestamp) <= 1.0 else {
            throw PreviewPhotoCaptureError.noRecentVideoFrame
        }

        let clampedLongEdge = min(max(longEdge, 960), 1280)
        let clampedQuality = min(max(jpegQuality, 0.5), 0.7)
        let encoded = try encodePreviewJPEG(from: pixelBuffer,
                                            longEdge: clampedLongEdge,
                                            jpegQuality: clampedQuality)
        let capturedAt = Date()
        let actualSnapshot = exportActualCameraSnapshot(reason: "remote_capture_preview_photo",
                                                        identity: identity)
        let rotationAngle = calibrationVideoDataOutput.connection(with: .video)?.videoRotationAngle
        let metadata = RemotePreviewPhotoMetadata(
            requestID: requestID,
            deviceID: identity.remoteDeviceID,
            deviceName: identity.remoteDeviceName,
            captureTimestampUnixMilliseconds: Self.unixMilliseconds(capturedAt),
            captureTimestamp: Self.calibrationTimestampFormatter.string(from: capturedAt),
            captureSource: "AVCaptureVideoDataOutput",
            image: RemotePreviewPhotoImageMetadata(width: encoded.width,
                                                   height: encoded.height,
                                                   byteCount: encoded.data.count,
                                                   longEdgeLimit: clampedLongEdge,
                                                   jpegQuality: clampedQuality),
            videoRotationAngleDegrees: rotationAngle.map(Double.init),
            activeManualLockProfileID: activeManualLockProfile?.profileID,
            actualCameraSnapshot: actualSnapshot
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataData = try encoder.encode(metadata)
        return RemotePreviewPhotoCapture(jpegData: encoded.data,
                                         metadataJSONData: metadataData,
                                         imageWidth: encoded.width,
                                         imageHeight: encoded.height,
                                         captureTimestampUnixMilliseconds: Self.unixMilliseconds(capturedAt))
    }

    private func encodePreviewJPEG(from pixelBuffer: CVPixelBuffer,
                                   longEdge: Int,
                                   jpegQuality: Double) throws -> (data: Data, width: Int, height: Int) {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw PreviewPhotoCaptureError.imageEncodingFailed
        }

        let maxSourceEdge = max(sourceWidth, sourceHeight)
        let scale = min(1.0, Double(longEdge) / Double(maxSourceEdge))
        let outputWidth = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let outputHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))

        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let outputRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgImage = previewCIContext.createCGImage(scaledImage,
                                                           from: outputRect,
                                                           format: .RGBA8,
                                                           colorSpace: colorSpace),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: jpegQuality) else {
            throw PreviewPhotoCaptureError.imageEncodingFailed
        }

        return (data, outputWidth, outputHeight)
    }

    private func hasFreshPreviewFrame(maxAgeSeconds: TimeInterval) -> Bool {
        guard latestPreviewPixelBuffer != nil,
              let latestPreviewPixelBufferTimestamp else {
            return false
        }
        return Date().timeIntervalSince(latestPreviewPixelBufferTimestamp) <= maxAgeSeconds
    }
    
    // MARK: - Movie capture
    /// Starts recording video. The video records until the user stops recording,
    /// which calls the following `stopRecording()` method.
    func startRecording(recordingStartMetadata: RecordingStartTimecodeMetadata?) async -> ManualValidationReport? {
        var validationReport: ManualValidationReport?
        if let profile = activeManualLockProfile {
            var validation = validateManualLockProfile(reason: "before_recording_start",
                                                       requestID: nil,
                                                       profileOverride: profile)
            if validation.classification != .exactMatch && !captureActivity.isRecording && profile.policy.autoReapplyWhenIdle {
                _ = await installManualLockProfile(profile, reason: "before_recording_start_reapply")
                validation = validateManualLockProfile(reason: "before_recording_start_after_reapply",
                                                       requestID: nil,
                                                       profileOverride: profile)
            }
            validationReport = validation
            guard validation.classification == .exactMatch || validation.classification == .adjustedMatch else {
                return validation
            }
        }

        let stabilizationMode: AVCaptureVideoStabilizationMode?
        if let profile = activeManualLockProfile {
            stabilizationMode = profile.desired.preferredStabilizationModeRawValue
                .flatMap(AVCaptureVideoStabilizationMode.init(rawValue:))
        } else {
            stabilizationMode = .auto
        }
        movieCapture.startRecording(recordingStartMetadata: recordingStartMetadata,
                                    preferredStabilizationMode: stabilizationMode)
        if let profile = activeManualLockProfile {
            validationReport = validateManualLockProfile(reason: "after_recording_start",
                                                         requestID: nil,
                                                         profileOverride: profile)
        }
        return validationReport
    }
    
    /// Stops the recording and returns the captured movie.
    func stopRecording() async throws -> Movie {
        try await movieCapture.stopRecording()
    }

    /// Captures a JSON snapshot of camera calibration-related state at recording start.
    func recordingCalibrationJSONData() -> Data {
        let actualSnapshot = exportActualCameraSnapshot(reason: "recording_calibration_sidecar")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(actualSnapshot) {
            return data
        }

        var payload: [String: Any] = [
            "schemaVersion": 1,
            "capturedAt": Self.calibrationTimestampFormatter.string(from: Date()),
            "source": "AVCaptureDevice.activeFormat"
        ]

        guard isSetUp, let device = activeVideoInput?.device else {
            payload["available"] = false
            payload["reason"] = "capture_service_not_ready"
            return serializedCalibrationPayload(payload)
        }

        payload["available"] = true

        let format = device.activeFormat
        let formatDescription = format.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)

        var devicePayload: [String: Any] = [
            "localizedName": device.localizedName,
            "uniqueID": device.uniqueID,
            "modelID": device.modelID,
            "deviceType": device.deviceType.rawValue,
            "position": cameraPositionDescription(device.position),
            "isGeometricDistortionCorrectionSupported": device.isGeometricDistortionCorrectionSupported,
            "isGeometricDistortionCorrectionEnabled": device.isGeometricDistortionCorrectionEnabled,
            "activeColorSpaceRawValue": device.activeColorSpace.rawValue
        ]
        if let exposureDurationSeconds = finiteSeconds(from: device.exposureDuration) {
            devicePayload["exposureDurationSeconds"] = exposureDurationSeconds
        }
        payload["device"] = devicePayload

        let frameRateRanges = format.videoSupportedFrameRateRanges.compactMap { range -> [String: Any]? in
            guard range.minFrameRate.isFinite, range.maxFrameRate.isFinite else { return nil }
            return [
                "minFrameRate": range.minFrameRate,
                "maxFrameRate": range.maxFrameRate
            ]
        }

        var formatPayload: [String: Any] = [
            "mediaType": format.mediaType.rawValue,
            "dimensions": [
                "width": Int(dimensions.width),
                "height": Int(dimensions.height)
            ],
            "isVideoBinned": format.isVideoBinned,
            "videoFieldOfViewDegrees": format.videoFieldOfView,
            "geometricDistortionCorrectedVideoFieldOfViewDegrees": format.geometricDistortionCorrectedVideoFieldOfView,
            "videoMaxZoomFactor": format.videoMaxZoomFactor,
            "videoZoomFactorUpscaleThreshold": format.videoZoomFactorUpscaleThreshold,
            "minISO": format.minISO,
            "maxISO": format.maxISO,
            "supportedFrameRateRanges": frameRateRanges
        ]
        if let minExposureDurationSeconds = finiteSeconds(from: format.minExposureDuration) {
            formatPayload["minExposureDurationSeconds"] = minExposureDurationSeconds
        }
        if let maxExposureDurationSeconds = finiteSeconds(from: format.maxExposureDuration) {
            formatPayload["maxExposureDurationSeconds"] = maxExposureDurationSeconds
        }
        payload["activeFormat"] = formatPayload

        var captureStatePayload: [String: Any] = [
            "videoZoomFactor": device.videoZoomFactor,
            "iso": device.iso,
            "lensPosition": device.lensPosition,
            "exposureTargetBias": device.exposureTargetBias
        ]
        if let activeVideoMinFrameDurationSeconds = finiteSeconds(from: device.activeVideoMinFrameDuration) {
            captureStatePayload["activeVideoMinFrameDurationSeconds"] = activeVideoMinFrameDurationSeconds
        }
        if let activeVideoMaxFrameDurationSeconds = finiteSeconds(from: device.activeVideoMaxFrameDuration) {
            captureStatePayload["activeVideoMaxFrameDurationSeconds"] = activeVideoMaxFrameDurationSeconds
        }
        let whiteBalance = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
        if whiteBalance.temperature.isFinite {
            captureStatePayload["whiteBalanceTemperature"] = whiteBalance.temperature
        }
        if whiteBalance.tint.isFinite {
            captureStatePayload["whiteBalanceTint"] = whiteBalance.tint
        }
        payload["captureState"] = captureStatePayload

        if let connection = movieCapture.output.connection(with: .video) {
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
            var connectionPayload: [String: Any] = [
                "isEnabled": connection.isEnabled,
                "isActive": connection.isActive,
                "isVideoStabilizationSupported": connection.isVideoStabilizationSupported,
                "preferredVideoStabilizationModeRawValue": connection.preferredVideoStabilizationMode.rawValue,
                "activeVideoStabilizationModeRawValue": connection.activeVideoStabilizationMode.rawValue,
                "isCameraIntrinsicMatrixDeliverySupported": connection.isCameraIntrinsicMatrixDeliverySupported,
                "isCameraIntrinsicMatrixDeliveryEnabled": connection.isCameraIntrinsicMatrixDeliveryEnabled
            ]
            if connection.videoRotationAngle.isFinite {
                connectionPayload["videoRotationAngleDegrees"] = connection.videoRotationAngle
            }
            payload["videoConnection"] = connectionPayload
        }

        if let connection = calibrationVideoDataOutput.connection(with: .video) {
            var connectionPayload: [String: Any] = [
                "isEnabled": connection.isEnabled,
                "isActive": connection.isActive,
                "isCameraIntrinsicMatrixDeliverySupported": connection.isCameraIntrinsicMatrixDeliverySupported,
                "isCameraIntrinsicMatrixDeliveryEnabled": connection.isCameraIntrinsicMatrixDeliveryEnabled
            ]
            if connection.videoRotationAngle.isFinite {
                connectionPayload["videoRotationAngleDegrees"] = connection.videoRotationAngle
            }
            payload["videoDataConnection"] = connectionPayload
        }

        if let intrinsics = latestCameraIntrinsics {
            payload["cameraIntrinsicsFromSampleBuffer"] = [
                "source": "sampleBufferAttachment",
                "timestamp": Self.calibrationTimestampFormatter.string(from: latestCameraIntrinsicsTimestamp ?? Date()),
                "matrix3x3RowMajor": [
                    [intrinsics[0], intrinsics[1], intrinsics[2]],
                    [intrinsics[3], intrinsics[4], intrinsics[5]],
                    [intrinsics[6], intrinsics[7], intrinsics[8]]
                ],
                "matrix3x3FlatRowMajor": intrinsics
            ]
        } else {
            payload["cameraIntrinsicsFromSampleBuffer"] = [
                "available": false,
                "reason": "no_intrinsics_sample_buffer_attachment_seen"
            ]
        }

        if let extensions = CMFormatDescriptionGetExtensions(formatDescription),
           let sanitizedExtensions = jsonSafeValue(from: extensions) {
            payload["formatDescriptionExtensions"] = sanitizedExtensions
        }

        return serializedCalibrationPayload(payload)
    }

    private func configureCameraIntrinsicsDelivery() {
        guard let connection = movieCapture.output.connection(with: .video) else {
            return
        }
        guard connection.isCameraIntrinsicMatrixDeliverySupported else {
            return
        }
        connection.isCameraIntrinsicMatrixDeliveryEnabled = true
    }

    private func configureCalibrationVideoDataOutput() {
        calibrationVideoDataOutput.alwaysDiscardsLateVideoFrames = true
        calibrationVideoDataOutput.setSampleBufferDelegate(calibrationVideoDataDelegate,
                                                           queue: calibrationVideoDataOutputQueue)

        guard let connection = calibrationVideoDataOutput.connection(with: .video) else {
            return
        }
        if connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
    }

    private func handleCalibrationVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            latestPreviewPixelBuffer = pixelBuffer
            latestPreviewPixelBufferTimestamp = Date()
        }

        guard let attachment = CMGetAttachment(sampleBuffer,
                                               key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                               attachmentModeOut: nil) else {
            return
        }
        guard let intrinsics = decodeIntrinsicMatrix(attachment) else {
            return
        }
        latestCameraIntrinsics = intrinsics
        latestCameraIntrinsicsTimestamp = Date()
    }

    private func decodeIntrinsicMatrix(_ attachment: CFTypeRef) -> [Double]? {
        if CFGetTypeID(attachment) == CFDataGetTypeID() {
            let data = attachment as! CFData as Data
            return decodeIntrinsicMatrixData(data)
        }
        if let data = attachment as? Data {
            return decodeIntrinsicMatrixData(data)
        }
        if let values = attachment as? [NSNumber], values.count == 9 {
            return values.map(\.doubleValue)
        }
        if let values = attachment as? [Double], values.count == 9 {
            return values
        }
        if let values = attachment as? [Float], values.count == 9 {
            return values.map(Double.init)
        }
        return nil
    }

    private func decodeIntrinsicMatrixData(_ data: Data) -> [Double]? {
        // CoreMedia commonly stores this as matrix_float3x3 (48 bytes due SIMD padding).
        if data.count == MemoryLayout<matrix_float3x3>.size {
            var matrix = matrix_float3x3()
            _ = withUnsafeMutableBytes(of: &matrix) { destination in
                data.copyBytes(to: destination)
            }
            let c0 = matrix.columns.0
            let c1 = matrix.columns.1
            let c2 = matrix.columns.2
            // Export row-major for JSON readability/consistency.
            return [
                Double(c0.x), Double(c1.x), Double(c2.x),
                Double(c0.y), Double(c1.y), Double(c2.y),
                Double(c0.z), Double(c1.z), Double(c2.z)
            ]
        }

        if data.count == 9 * MemoryLayout<Float>.size {
            return data.withUnsafeBytes { rawBuffer in
                let values = rawBuffer.bindMemory(to: Float.self)
                guard values.count >= 9 else { return nil }
                return Array(values.prefix(9)).map(Double.init)
            }
        }
        // Some producers serialize 3x4 padded float columns (12 floats total).
        if data.count == 12 * MemoryLayout<Float>.size {
            return data.withUnsafeBytes { rawBuffer in
                let values = rawBuffer.bindMemory(to: Float.self)
                guard values.count >= 12 else { return nil }
                let c0 = SIMD3<Float>(values[0], values[1], values[2])
                let c1 = SIMD3<Float>(values[4], values[5], values[6])
                let c2 = SIMD3<Float>(values[8], values[9], values[10])
                return [
                    Double(c0.x), Double(c1.x), Double(c2.x),
                    Double(c0.y), Double(c1.y), Double(c2.y),
                    Double(c0.z), Double(c1.z), Double(c2.z)
                ]
            }
        }
        if data.count == 9 * MemoryLayout<Double>.size {
            return data.withUnsafeBytes { rawBuffer in
                let values = rawBuffer.bindMemory(to: Double.self)
                guard values.count >= 9 else { return nil }
                return Array(values.prefix(9))
            }
        }
        return nil
    }

    /// Sets whether the app captures HDR video.
    func setHDRVideoEnabled(_ isEnabled: Bool) async {
        if activeManualLockProfile?.policy.ownsHDRAndFormat == true {
            await afterPotentialReconfiguration(reason: "hdr_toggle_blocked_by_profile")
            return
        }
        // Bracket the following configuration in a begin/commit configuration pair.
        captureSession.beginConfiguration()
        do {
            // If the current device provides a 10-bit HDR format, enable it for use.
            if isEnabled, let format = currentDevice.activeFormat10BitVariant {
                try currentDevice.lockForConfiguration()
                currentDevice.activeFormat = format
                currentDevice.unlockForConfiguration()
                isHDRVideoEnabled = true
            } else {
                isHDRVideoEnabled = false
            }
        } catch {
            logger.error("Unable to obtain lock on device and can't enable HDR video capture.")
        }
        captureSession.commitConfiguration()
        _ = await applyVideoCaptureModePreset(selectedVideoCaptureMode,
                                              reason: "set_hdr_video_enabled_restore_video_preset")
        isHDRVideoEnabled = currentDevice.activeFormat.isTenBitFormat
        await afterPotentialReconfiguration(reason: "set_hdr_video_enabled")
    }
    
    // MARK: - Internal state management
    /// Updates the state of the actor to ensure its advertised capabilities are accurate.
    ///
    /// When the capture session changes, such as changing modes or input devices, the service
    /// calls this method to update its configuration and capabilities. The app uses this state to
    /// determine which features to enable in the user interface.
    private func updateCaptureCapabilities() {
        // Update the output service configuration.
        outputServices.forEach { $0.updateConfiguration(for: currentDevice) }
        // Set the capture service's capabilities for the selected mode.
        captureCapabilities = movieCapture.capabilities
    }
    
    /// Merge the `captureActivity` values of the photo and movie capture services,
    /// and assign the value to the actor's property.`
    private func observeOutputServices() {
        movieCapture.$captureActivity
            .assign(to: &$captureActivity)
    }
    
    /// Observe when capture control enter and exit a fullscreen appearance.
    private func observeCaptureControlsState() {
        controlsDelegate.onControlsDidBecomeInactive = { [weak self] in
            guard let self else { return }
            Task {
                await self.afterPotentialReconfiguration(reason: "capture_controls_inactive")
            }
        }
        controlsDelegate.$isShowingFullscreenControls
            .assign(to: &$isShowingFullscreenControls)
    }
    
    /// Observe capture-related notifications.
    private func observeNotifications() {
        Task {
            for await reason in NotificationCenter.default.notifications(named: AVCaptureSession.wasInterruptedNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject? })
                .compactMap({ AVCaptureSession.InterruptionReason(rawValue: $0.integerValue) }) {
                /// Set the `isInterrupted` state as appropriate.
                isInterrupted = [.audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient].contains(reason)
            }
        }
        
        Task {
            // Await notification of the end of an interruption.
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.interruptionEndedNotification) {
                isInterrupted = false
                await afterPotentialReconfiguration(reason: "interruption_ended")
            }
        }
        
        Task {
            for await error in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionErrorKey] as? AVError }) {
                // If the system resets media services, the capture session stops running.
                if error.code == .mediaServicesWereReset {
                    if shouldRunSession, !captureSession.isRunning {
                        captureSession.startRunning()
                        await afterPotentialReconfiguration(reason: "media_services_were_reset_restart")
                    }
                }
            }
        }
    }
}

class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {
    
    @Published private(set) var isShowingFullscreenControls = false
    var onControlsDidBecomeInactive: (() -> Void)?

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        logger.debug("Capture controls active.")
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = true
        logger.debug("Capture controls will enter fullscreen appearance.")
    }
    
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = false
        logger.debug("Capture controls will exit fullscreen appearance.")
    }
    
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        logger.debug("Capture controls inactive.")
        onControlsDidBecomeInactive?()
    }
}

private final class CalibrationVideoDataDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSampleBuffer?(sampleBuffer)
    }
}

private extension AVCaptureDevice.Format {
    var mapFormatSummary: String {
        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        return "\(dimensions.width)x\(dimensions.height) \(formatDescription.mediaSubType.rawValue)"
    }
}
