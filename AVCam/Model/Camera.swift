/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A protocol that represents the model for the camera view.
*/

import SwiftUI

/// A protocol that represents the model for the camera view.
///
/// The AVFoundation camera APIs require running on a physical device. The app defines the model as a protocol to make it
/// simple to swap out the real camera for a test camera when previewing SwiftUI views.
@MainActor
protocol Camera: AnyObject, SendableMetatype {

    /// Provides the current status of the camera.
    var status: CameraStatus { get }

    /// The camera's current activity state, which can be photo capture, movie capture, or idle.
    var captureActivity: CaptureActivity { get }

    /// The current BLE connection state for Tentacle timecode input.
    var tentacleConnectionState: TentacleConnectionState { get }

    /// The current remote rig power/capture state.
    var rigState: RigState { get }

    /// Whether the UI should switch to its black low-power rig presentation.
    var isRigLowPowerUIActive: Bool { get }

    /// Compact status lines for the low-power rig presentation.
    var rigStatusLines: [String] { get }

    /// The most recently received Tentacle timecode payload.
    var tentacleTimecode: TentacleTimecode? { get }

    /// The continuously advancing Tentacle timecode string for UI display.
    var displayedTentacleTimecode: String { get }

    /// The recording timer string (seeded from Tentacle at record start, then locally incremented).
    var displayedRecordingTimecode: String { get }

    /// The frame rate for the displayed Tentacle timecode.
    var displayedTentacleFPS: Int? { get }

    /// The WebSocket URL for the laptop director control plane.
    var directorWebSocketURL: String { get set }

    /// The user-defined device name exposed to remote director clients.
    var directorDeviceName: String { get set }

    /// Whether this iPhone should act as a handheld remote director instead of a recording camera.
    var isRemoteDirectorModeEnabled: Bool { get set }

    /// Approval state for handheld remote director mode.
    var remoteDirectorApprovalState: RemoteDirectorApprovalState { get }

    /// Human-readable remote director connection/control status.
    var remoteDirectorStatusText: String { get }

    /// Editable experiment name sent from the handheld remote director.
    var remoteDirectorExperimentName: String { get set }

    /// Take number mirrored from the laptop director.
    var remoteDirectorTakeNumberText: String { get }

    /// Compact summary lines mirrored from the laptop director.
    var remoteDirectorSummaryLines: [String] { get }

    /// Most recent remote director command result.
    var remoteDirectorLastResult: String { get }

    func requestRemoteDirectorApproval() async
    func exitRemoteDirectorMode() async
    func remoteDirectorSetExperimentName() async
    func remoteDirectorPrepareCommitStart() async
    func remoteDirectorPrepareStop() async
    func remoteDirectorArmIdleAll() async

    /// The current values and lock states for manual camera controls.
    var manualControlState: ManualCameraControlState { get set }

    /// The current capabilities and numeric ranges for manual camera controls.
    var manualControlCapabilities: ManualCameraControlCapabilities { get }

    /// The selected named video capture mode preset.
    var selectedVideoCaptureMode: VideoCaptureModePreset { get set }

    /// The supported named video capture modes for the active camera device.
    var videoCaptureModeSupport: [VideoCaptureModeSupport] { get }

    /// The actual applied video capture mode read back from AVFoundation.
    var videoCaptureModeStatus: VideoCaptureModeStatus { get }

    /// Whether a deterministic manual lock profile currently owns camera format/FPS.
    var isManualLockActive: Bool { get }

    /// The source of video content for a camera preview.
    var previewSource: PreviewSource { get }
    
    /// Starts the camera capture pipeline.
    func start() async

    /// Stops the camera capture pipeline.
    func stop() async

    /// The capture mode, which can be photo or video.
    var captureMode: CaptureMode { get set }
    
    /// A Boolean value that indicates whether the camera is currently switching capture modes.
    var isSwitchingModes: Bool { get }
    
    /// A Boolean value that indicates whether the camera prefers showing a minimized set of UI controls.
    var prefersMinimizedUI: Bool { get }

    /// Switches between video devices available on the host system.
    func switchVideoDevices() async
    
    /// A Boolean value that indicates whether the camera is currently switching video devices.
    var isSwitchingVideoDevices: Bool { get }
    
    /// Performs a one-time automatic focus and exposure operation.
    func focusAndExpose(at point: CGPoint) async
    
    /// A Boolean value that indicates whether to capture Live Photos when capturing stills.
    var isLivePhotoEnabled: Bool { get set }
    
    /// A value that indicates how to balance the photo capture quality versus speed.
    var qualityPrioritization: QualityPrioritization { get set }
    
    /// Captures a photo and writes it to the user's photo library.
    func capturePhoto() async
    
    /// A Boolean value that indicates whether to show visual feedback when capture begins.
    var shouldFlashScreen: Bool { get }
    
    /// A Boolean that indicates whether the camera supports HDR video recording.
    var isHDRVideoSupported: Bool { get }
    
    /// A Boolean value that indicates whether camera enables HDR video recording.
    var isHDRVideoEnabled: Bool { get set }
    
    /// Starts or stops recording a movie, and writes it to the user's photo library when complete.
    func toggleRecording() async
    
    /// A thumbnail image for the most recent photo or video capture.
    var thumbnail: CGImage? { get }

    /// Locally stored video files in the app sandbox.
    var localVideoURLs: [URL] { get }

    /// Reloads locally stored videos from disk.
    func refreshLocalVideos() async

    /// Deletes a single locally stored video file.
    func deleteLocalVideo(_ url: URL) async

    /// Deletes locally stored videos at the given offsets.
    func deleteLocalVideos(at offsets: IndexSet) async
    
    /// An error if the camera encountered a problem.
    var error: Error? { get }
    
    /// Synchronize the state of the camera with the persisted values.
    func syncState() async
}
