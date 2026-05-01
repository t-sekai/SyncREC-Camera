/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Supporting data types for the app.
*/

import Foundation
import AVFoundation

// MARK: - Supporting types

/// An enumeration that describes the current status of the camera.
enum CameraStatus {
    /// The initial status upon creation.
    case unknown
    /// A status that indicates a person disallows access to the camera or microphone.
    case unauthorized
    /// A status that indicates the camera failed to start.
    case failed
    /// A status that indicates the camera is successfully running.
    case running
    /// A status that indicates higher-priority media processing is interrupting the camera.
    case interrupted
}

/// A decoded SMPTE timecode packet from a Tentacle Sync E device.
struct TentacleTimecode: Sendable, Equatable {

    let fps: Int
    let hours: Int
    let minutes: Int
    let seconds: Int
    let frames: Int
    let rawPayload: String
    let extraPayload: String

    init?(fps: Int,
          hours: Int,
          minutes: Int,
          seconds: Int,
          frames: Int,
          rawPayload: String = "",
          extraPayload: String = "") {
        guard fps > 0 else { return nil }
        guard hours >= 0, hours < 24 else { return nil }
        guard minutes >= 0, minutes < 60 else { return nil }
        guard seconds >= 0, seconds < 60 else { return nil }
        guard frames >= 0, frames < fps else { return nil }

        self.fps = fps
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.rawPayload = rawPayload
        self.extraPayload = extraPayload
    }

    init?(payload: Data) {
        let bytes = Array(payload)
        guard bytes.count >= 5 else { return nil }

        let fps = Int(bytes[0])
        let hours = Int(bytes[1])
        let minutes = Int(bytes[2])
        let seconds = Int(bytes[3])
        let frames = Int(bytes[4])

        guard fps > 0 else { return nil }
        guard hours < 24, minutes < 60, seconds < 60 else { return nil }
        guard frames >= 0, frames < fps else { return nil }

        self.fps = fps
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
        self.rawPayload = Self.hexString(bytes)
        self.extraPayload = bytes.count > 5 ? Self.hexString(bytes[5...]) : ""
    }

    var formatted: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    var formattedToSeconds: String {
        String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var formattedWithStaticFrames: String {
        String(format: "%02d:%02d:%02d:00", hours, minutes, seconds)
    }

    var secondsOfDay: Int {
        (hours * 3600) + (minutes * 60) + seconds
    }

    var totalFramesOfDay: Int {
        (secondsOfDay * fps) + frames
    }

    func advanced(by elapsedSeconds: TimeInterval) -> TentacleTimecode? {
        guard elapsedSeconds.isFinite else { return self }

        let fps = max(self.fps, 1)
        let baseFrameCount = (((hours * 60) + minutes) * 60 + seconds) * fps + frames
        let elapsedFrameCount = max(0, Int((elapsedSeconds * Double(fps)).rounded(.down)))

        let framesPerDay = 24 * 60 * 60 * fps
        let absoluteFrameCount = (baseFrameCount + elapsedFrameCount) % framesPerDay

        let absoluteSecondCount = absoluteFrameCount / fps
        let nextFrames = absoluteFrameCount % fps
        let nextHours = absoluteSecondCount / 3600
        let nextMinutes = (absoluteSecondCount % 3600) / 60
        let nextSeconds = absoluteSecondCount % 60

        return TentacleTimecode(fps: fps,
                                hours: nextHours,
                                minutes: nextMinutes,
                                seconds: nextSeconds,
                                frames: nextFrames,
                                rawPayload: rawPayload,
                                extraPayload: extraPayload)
    }

    private static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexString(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

struct RecordingStartTimecodeMetadata: Sendable, Equatable {
    let timecode: String
    let fps: Int
    let source: String
}

enum TentacleConnectionState: Equatable {
    case idle
    case bluetoothUnavailable
    case unauthorized
    case scanning
    case connecting(String)
    case connected(String)
    case reconnecting(String?)
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Timecode idle"
        case .bluetoothUnavailable:
            return "Bluetooth unavailable"
        case .unauthorized:
            return "Bluetooth permission needed"
        case .scanning:
            return "Scanning for Tentacle"
        case .connecting(let deviceName):
            return "Connecting to \(deviceName)"
        case .connected(let deviceName):
            return "Connected: \(deviceName)"
        case .reconnecting(let deviceName):
            if let deviceName {
                return "Reconnecting to \(deviceName)"
            }
            return "Reconnecting"
        case .failed(let message):
            return "Timecode error: \(message)"
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var remoteControlValue: String {
        switch self {
        case .idle:
            return "idle"
        case .bluetoothUnavailable:
            return "bluetooth_unavailable"
        case .unauthorized:
            return "unauthorized"
        case .scanning:
            return "scanning"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .reconnecting:
            return "reconnecting"
        case .failed:
            return "failed"
        }
    }
}

/// The lock state and values for manual camera controls.
struct ManualCameraControlState: Codable, Equatable, Sendable {
    var iso: Float = 100
    var isISOLocked = false
    var whiteBalanceTemperature: Float = 5600
    var isWhiteBalanceLocked = false
    var fps: Double = 30
    var isFPSLocked = false
    var shutterSeconds: Double = 1.0 / 48.0
    var isShutterLocked = false
    var tint: Float = 0
    var isTintLocked = false
    var focusLensPosition: Float = 0.5
    var isFocusLocked = false

    var hasAnyExposureLock: Bool {
        isISOLocked || isShutterLocked
    }

    var hasAnyWhiteBalanceLock: Bool {
        isWhiteBalanceLocked || isTintLocked
    }

    static let `default` = ManualCameraControlState()
}

/// Device-specific ranges and capability flags for manual camera controls.
struct ManualCameraControlCapabilities: Sendable, Equatable {
    var isoRange: ClosedRange<Float>
    var whiteBalanceTemperatureRange: ClosedRange<Float>
    var fpsRange: ClosedRange<Double>
    var shutterRange: ClosedRange<Double>
    var tintRange: ClosedRange<Float>
    var focusRange: ClosedRange<Float>
    var supportsManualExposure: Bool
    var supportsWhiteBalanceLock: Bool
    var supportsFrameRateControl: Bool
    var supportsFocusLock: Bool

    static let unavailable = ManualCameraControlCapabilities(
        isoRange: 25...2000,
        whiteBalanceTemperatureRange: 2000...10000,
        fpsRange: 1...120,
        shutterRange: 1.0 / 2000.0...0.25,
        tintRange: -150...150,
        focusRange: 0...1,
        supportsManualExposure: false,
        supportsWhiteBalanceLock: false,
        supportsFrameRateControl: false,
        supportsFocusLock: false
    )
}

/// A combined model of manual camera control state and capabilities.
struct ManualCameraControlSnapshot: Sendable, Equatable {
    var state: ManualCameraControlState
    var capabilities: ManualCameraControlCapabilities

    static let unavailable = ManualCameraControlSnapshot(state: .default,
                                                          capabilities: .unavailable)
}

// MARK: - Deterministic manual lock profiles

enum ManualProfileDriftStatus: String, Codable, Sendable, Equatable {
    case unknown
    case inSync = "in_sync"
    case drifted
    case reapplying
    case failed
}

enum ManualParameterStatus: String, Codable, Sendable, Equatable {
    case exact
    case applied
    case adjusted
    case incompatible
    case unavailable
    case refused
    case drifted
    case notRequested = "not_requested"
}

enum ManualReportClassification: String, Codable, Sendable, Equatable {
    case exactMatch = "exact_match"
    case adjustedMatch = "adjusted_match"
    case incompatible
    case refused
    case failed
    case drifted
    case unknown
}

struct ManualParameterReport: Codable, Sendable, Equatable {
    var parameter: String
    var status: ManualParameterStatus
    var critical: Bool
    var requested: String?
    var actual: String?
    var detail: String?

    init(parameter: String,
         status: ManualParameterStatus,
         critical: Bool = true,
         requested: String? = nil,
         actual: String? = nil,
         detail: String? = nil) {
        self.parameter = parameter
        self.status = status
        self.critical = critical
        self.requested = requested
        self.actual = actual
        self.detail = detail
    }
}

struct ManualFrameRateRange: Codable, Sendable, Equatable {
    var minFrameRate: Double
    var maxFrameRate: Double
}

struct ManualWhiteBalanceGains: Codable, Sendable, Equatable {
    var red: Float
    var green: Float
    var blue: Float
}

struct ManualSnapshotDeviceIdentity: Codable, Sendable, Equatable {
    var remoteDeviceID: String
    var remoteDeviceName: String
    var appVersion: String

    static let unknown = ManualSnapshotDeviceIdentity(remoteDeviceID: "unknown",
                                                      remoteDeviceName: "unknown",
                                                      appVersion: "unknown")
}

struct ManualProfileSourceMetadata: Codable, Sendable, Equatable {
    var source: String
    var sourceDeviceID: String?
    var sourceDeviceName: String?
    var sourceAppVersion: String?
    var sourceSnapshotHash: String?
    var createdAtUnixMilliseconds: Int64

    static func local(deviceID: String?,
                      deviceName: String?,
                      appVersion: String?,
                      sourceSnapshotHash: String?) -> ManualProfileSourceMetadata {
        ManualProfileSourceMetadata(source: "iphone_actual_snapshot",
                                    sourceDeviceID: deviceID,
                                    sourceDeviceName: deviceName,
                                    sourceAppVersion: appVersion,
                                    sourceSnapshotHash: sourceSnapshotHash,
                                    createdAtUnixMilliseconds: Int64(Date().timeIntervalSince1970 * 1000))
    }
}

struct ManualLockProfilePolicy: Codable, Sendable, Equatable {
    var allowFormatSubstitution = false
    var allowCriticalValueAdjustment = false
    var focusIsCritical = true
    var zoomIsCritical = true
    var allowApplyWhileRecording = false
    var disableCaptureControls = true
    var ownsHDRAndFormat = true
    var ignoreSystemPreferredCameraWhileLocked = true
    var autoReapplyWhenIdle = true

    static let strict = ManualLockProfilePolicy()
}

struct ManualCameraFormatDescriptor: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var mediaSubTypeFourCC: String?
    var mediaSubTypeRawValue: UInt32?
    var isVideoBinned: Bool?
    var minISO: Float?
    var maxISO: Float?
    var minExposureDurationSeconds: Double?
    var maxExposureDurationSeconds: Double?
    var supportedFrameRateRanges: [ManualFrameRateRange]
    var videoMaxZoomFactor: CGFloat?
    var videoZoomFactorUpscaleThreshold: CGFloat?
    var videoFieldOfViewDegrees: Float?
    var geometricDistortionCorrectedVideoFieldOfViewDegrees: Float?
    var activeColorSpaceRawValue: Int?
    var isTenBit: Bool?
    var hdr10BitSupported: Bool?
}

struct ManualCaptureDeviceDescriptor: Codable, Sendable, Equatable {
    var localizedName: String
    var uniqueID: String
    var modelID: String
    var deviceType: String
    var position: String
    var isGeometricDistortionCorrectionSupported: Bool
    var isGeometricDistortionCorrectionEnabled: Bool
}

struct ManualExposureSnapshot: Codable, Sendable, Equatable {
    var exposureDurationSeconds: Double?
    var iso: Float
    var exposureModeRawValue: Int
    var exposureMode: String
}

struct ManualWhiteBalanceSnapshot: Codable, Sendable, Equatable {
    var gains: ManualWhiteBalanceGains
    var temperature: Float?
    var tint: Float?
    var modeRawValue: Int
    var mode: String
}

struct ManualFocusSnapshot: Codable, Sendable, Equatable {
    var lensPosition: Float
    var focusModeRawValue: Int
    var focusMode: String
}

struct ManualZoomSnapshot: Codable, Sendable, Equatable {
    var factor: CGFloat
}

struct ManualStabilizationSnapshot: Codable, Sendable, Equatable {
    var preferredModeRawValue: Int?
    var preferredMode: String?
    var activeModeRawValue: Int?
    var activeMode: String?
    var isSupported: Bool
}

struct ManualCameraIntrinsicsSnapshot: Codable, Sendable, Equatable {
    var available: Bool
    var timestampUnixMilliseconds: Int64?
    var matrix3x3RowMajor: [Double]?
    var freshnessSeconds: Double?
    var missingReason: String?
}

struct ManualCameraDesiredSettings: Codable, Sendable, Equatable {
    var format: ManualCameraFormatDescriptor?
    var selectedFPS: Double?
    var activeVideoMinFrameDurationSeconds: Double?
    var activeVideoMaxFrameDurationSeconds: Double?
    var exposureDurationSeconds: Double?
    var iso: Float?
    var whiteBalanceTemperature: Float?
    var whiteBalanceTint: Float?
    var whiteBalanceGains: ManualWhiteBalanceGains?
    var focusLensPosition: Float?
    var zoomFactor: CGFloat?
    var preferredStabilizationModeRawValue: Int?
    var preferredStabilizationMode: String?
    var hdrIntent: String?
    var activeColorSpaceRawValue: Int?
    var bitDepth: Int?
}

struct ManualCameraActualSnapshot: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var capturedAtUnixMilliseconds: Int64
    var reason: String
    var identity: ManualSnapshotDeviceIdentity
    var device: ManualCaptureDeviceDescriptor?
    var activeFormat: ManualCameraFormatDescriptor?
    var actualFPSMinFrameDurationSeconds: Double?
    var actualFPSMaxFrameDurationSeconds: Double?
    var exposure: ManualExposureSnapshot?
    var whiteBalance: ManualWhiteBalanceSnapshot?
    var focus: ManualFocusSnapshot?
    var zoom: ManualZoomSnapshot?
    var stabilization: ManualStabilizationSnapshot?
    var intrinsics: ManualCameraIntrinsicsSnapshot
    var isSubjectAreaChangeMonitoringEnabled: Bool?
}

struct ManualApplyReport: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var reportID: String
    var requestID: String?
    var profileID: String?
    var reason: String
    var dryRun: Bool
    var startedAtUnixMilliseconds: Int64
    var completedAtUnixMilliseconds: Int64
    var classification: ManualReportClassification
    var detail: String
    var parameterReports: [ManualParameterReport]
    var actualSnapshot: ManualCameraActualSnapshot?
}

struct ManualValidationReport: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var reportID: String
    var requestID: String?
    var profileID: String?
    var reason: String
    var validatedAtUnixMilliseconds: Int64
    var classification: ManualReportClassification
    var detail: String
    var parameterReports: [ManualParameterReport]
    var actualSnapshot: ManualCameraActualSnapshot?
}

struct ManualLockProfile: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var profileID: String
    var name: String?
    var source: ManualProfileSourceMetadata
    var desired: ManualCameraDesiredSettings
    var policy: ManualLockProfilePolicy
    var actualValidatedSnapshot: ManualCameraActualSnapshot?
    var lastApplyReport: ManualApplyReport?

    var isActive: Bool { true }
}

struct ManualLockProfileStore: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var activeDesiredProfile: ManualLockProfile?
    var draftProfile: ManualLockProfile?
    var lastActualSnapshot: ManualCameraActualSnapshot?
    var lastApplyReport: ManualApplyReport?
    var lastValidationReport: ManualValidationReport?
    var driftStatus: ManualProfileDriftStatus = .unknown
}

/// An enumeration that defines the activity states the capture service supports.
///
/// This type provides feedback to the UI regarding the active status of the `CaptureService` actor.
enum CaptureActivity {
    case idle
    /// A status that indicates the capture service is performing photo capture.
    case photoCapture(willCapture: Bool = false, isLivePhoto: Bool = false)
    /// A status that indicates the capture service is performing movie capture.
    case movieCapture(duration: TimeInterval = 0.0)
    
    var isLivePhoto: Bool {
        if case .photoCapture(_, let isLivePhoto) = self {
            return isLivePhoto
        }
        return false
    }
    
    var willCapture: Bool {
        if case .photoCapture(let willCapture, _) = self {
            return willCapture
        }
        return false
    }
    
    var currentTime: TimeInterval {
        if case .movieCapture(let duration) = self {
            return duration
        }
        return .zero
    }
    
    var isRecording: Bool {
        if case .movieCapture(_) = self {
            return true
        }
        return false
    }
}

/// An enumeration of the capture modes that the camera supports.
enum CaptureMode: String, Identifiable, CaseIterable, Codable {
    var id: Self { self }
    /// A mode that enables photo capture.
    case photo
    /// A mode that enables video capture.
    case video
    
    var systemName: String {
        switch self {
        case .photo:
            "camera.fill"
        case .video:
            "video.fill"
        }
    }
}

/// A structure that represents a captured photo.
struct Photo: Sendable {
    let data: Data
    let isProxy: Bool
    let livePhotoMovieURL: URL?
}

/// A structure that contains the uniform type identifier and movie URL.
struct Movie: Sendable {
    /// The temporary location of the file on disk.
    let url: URL
}

struct RemotePreviewPhotoCapture: Sendable {
    let jpegData: Data
    let metadataJSONData: Data
    let imageWidth: Int
    let imageHeight: Int
    let captureTimestampUnixMilliseconds: Int64
}

struct RemotePreviewPhotoImageMetadata: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var byteCount: Int
    var longEdgeLimit: Int
    var jpegQuality: Double
}

struct RemotePreviewPhotoMetadata: Codable, Sendable, Equatable {
    var schemaVersion: Int = 1
    var requestID: String
    var deviceID: String
    var deviceName: String
    var captureTimestampUnixMilliseconds: Int64
    var captureTimestamp: String
    var captureSource: String
    var image: RemotePreviewPhotoImageMetadata
    var videoRotationAngleDegrees: Double?
    var activeManualLockProfileID: String?
    var actualCameraSnapshot: ManualCameraActualSnapshot
}

struct PhotoFeatures {
    let isLivePhotoEnabled: Bool
    let qualityPrioritization: QualityPrioritization
}

/// A structure that represents the capture capabilities of `CaptureService` in
/// its current configuration.
struct CaptureCapabilities {

    let isLivePhotoCaptureSupported: Bool
    let isHDRSupported: Bool
    
    init(isLivePhotoCaptureSupported: Bool = false,
         isHDRSupported: Bool = false) {
        self.isLivePhotoCaptureSupported = isLivePhotoCaptureSupported
        self.isHDRSupported = isHDRSupported
    }
    
    static let unknown = CaptureCapabilities()
}

enum QualityPrioritization: Int, Identifiable, CaseIterable, CustomStringConvertible, Codable {
    var id: Self { self }
    case speed = 1
    case balanced
    case quality
    var description: String {
        switch self {
        case.speed:
            return "Speed"
        case .balanced:
            return "Balanced"
        case .quality:
            return "Quality"
        }
    }
}

enum CameraError: Error {
    case videoDeviceUnavailable
    case audioDeviceUnavailable
    case addInputFailed
    case addOutputFailed
    case setupFailed
    case deviceChangeFailed
}

protocol OutputService {
    associatedtype Output: AVCaptureOutput
    var output: Output { get }
    var captureActivity: CaptureActivity { get }
    var capabilities: CaptureCapabilities { get }
    func updateConfiguration(for device: AVCaptureDevice)
    func setVideoRotationAngle(_ angle: CGFloat)
}

extension OutputService {
    func setVideoRotationAngle(_ angle: CGFloat) {
        // Set the rotation angle on the output object's video connection.
        output.connection(with: .video)?.videoRotationAngle = angle
    }
    func updateConfiguration(for device: AVCaptureDevice) {}
}
