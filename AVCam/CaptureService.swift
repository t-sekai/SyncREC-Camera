/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that manages a capture session and its inputs and outputs.
*/

import Foundation
@preconcurrency import AVFoundation
import Combine
import simd

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
    private let calibrationVideoDataOutputQueue = DispatchQueue(label: "com.example.apple-samplecode.AVCam.calibrationVideoDataOutputQueue")
    
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
    // The most recent camera intrinsic matrix observed from video sample-buffer attachments.
    private var latestCameraIntrinsics: [Double]?
    private var latestCameraIntrinsicsTimestamp: Date?
    
    // A serial dispatch queue to use for capture control actions.
    private let sessionQueue = DispatchSerialQueue(label: "com.example.apple-samplecode.AVCam.sessionQueue")
    
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
        try setUpSession()
        shouldRunSession = true
        captureSession.startRunning()
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
    private func setUpSession() throws {
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
            setHDRVideoEnabled(isHDRVideoEnabled)
            
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

        manualControlState = resolvedState
        return ManualCameraControlSnapshot(state: resolvedState, capabilities: capabilities)
    }

    private func applyFrameRateControl(_ state: inout ManualCameraControlState,
                                       device: AVCaptureDevice,
                                       capabilities: ManualCameraControlCapabilities) {
        guard capabilities.supportsFrameRateControl else { return }

        state.fps = clamp(state.fps, to: capabilities.fpsRange)
        if state.isFPSLocked {
            let targetDuration = CMTime(seconds: 1.0 / state.fps, preferredTimescale: 1_000_000_000)
            device.activeVideoMinFrameDuration = targetDuration
            device.activeVideoMaxFrameDuration = targetDuration
        } else {
            device.activeVideoMinFrameDuration = CMTime.invalid
            device.activeVideoMaxFrameDuration = CMTime.invalid
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
    func setCaptureMode(_ captureMode: CaptureMode) throws {
        guard captureMode == .video else { return }
        self.captureMode = .video
        
        // Change the configuration atomically.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
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
        if isHDRVideoEnabled {
            setHDRVideoEnabled(true)
        }

        // Update the advertised capabilities after reconfiguration.
        updateCaptureCapabilities()
    }
    
    // MARK: - Device selection
    
    /// Changes the capture device that provides video input.
    ///
    /// The app calls this method in response to the user tapping the button in the UI to change cameras.
    /// The implementation switches between the front and back cameras and, in iPadOS,
    /// connected external cameras.
    func selectNextVideoDevice() {
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
        changeCaptureDevice(to: nextDevice)
        
        // The app only calls this method in response to the user requesting to switch cameras.
        // Set the new selection as the user's preferred camera.
        AVCaptureDevice.userPreferredCamera = nextDevice
    }
    
    // Changes the device the service uses for video capture.
    private func changeCaptureDevice(to device: AVCaptureDevice) {
        // The service must have a valid video input prior to calling this method.
        guard let currentInput = activeVideoInput else { fatalError() }
        
        // Bracket the following configuration in a begin/commit configuration pair.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
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
                    changeCaptureDevice(to: camera)
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
    
    // MARK: - Movie capture
    /// Starts recording video. The video records until the user stops recording,
    /// which calls the following `stopRecording()` method.
    func startRecording(recordingStartMetadata: RecordingStartTimecodeMetadata?) {
        movieCapture.startRecording(recordingStartMetadata: recordingStartMetadata)
    }
    
    /// Stops the recording and returns the captured movie.
    func stopRecording() async throws -> Movie {
        try await movieCapture.stopRecording()
    }

    /// Captures a JSON snapshot of camera calibration-related state at recording start.
    func recordingCalibrationJSONData() -> Data {
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
            withUnsafeMutableBytes(of: &matrix) { destination in
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
    func setHDRVideoEnabled(_ isEnabled: Bool) {
        // Bracket the following configuration in a begin/commit configuration pair.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        do {
            // If the current device provides a 10-bit HDR format, enable it for use.
            if isEnabled, let format = currentDevice.activeFormat10BitVariant {
                try currentDevice.lockForConfiguration()
                currentDevice.activeFormat = format
                currentDevice.unlockForConfiguration()
                isHDRVideoEnabled = true
            } else {
                captureSession.sessionPreset = .high
                isHDRVideoEnabled = false
            }
        } catch {
            logger.error("Unable to obtain lock on device and can't enable HDR video capture.")
        }
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
            }
        }
        
        Task {
            for await error in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionErrorKey] as? AVError }) {
                // If the system resets media services, the capture session stops running.
                if error.code == .mediaServicesWereReset {
                    if shouldRunSession, !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                }
            }
        }
    }
}

class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {
    
    @Published private(set) var isShowingFullscreenControls = false

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
