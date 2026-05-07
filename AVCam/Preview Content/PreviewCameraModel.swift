/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A Camera implementation to use when working with SwiftUI previews.
*/

import Foundation
import SwiftUI

#if DEBUG
@Observable
class PreviewCameraModel: Camera {
    
    var isLivePhotoEnabled = true
    var prefersMinimizedUI = false
    var qualityPrioritization = QualityPrioritization.quality
    var shouldFlashScreen = false
    var isHDRVideoSupported = false
    var isHDRVideoEnabled = false
    var tentacleConnectionState = TentacleConnectionState.connected("Tentacle Preview")
    var rigState = RigState.normalExit
    var isRigLowPowerUIActive = false
    var rigStatusLines = ["Rig: normal_exit", "Director: preview"]
    var tentacleTimecode = TentacleTimecode(payload: Data([30, 16, 21, 21, 3, 0x81, 0x21]))
    var displayedTentacleTimecode = "16:21:21:00"
    var displayedRecordingTimecode = "16:21:21.120"
    var displayedTentacleFPS: Int? = 30
    var directorWebSocketURL = RemoteDirectorConfiguration.defaultDirectorWebSocketURL
    var directorDeviceName = "Camera A"
    var manualControlState = ManualCameraControlState.default
    let manualControlCapabilities = ManualCameraControlCapabilities(
        isoRange: 25...2000,
        whiteBalanceTemperatureRange: 2000...10000,
        fpsRange: 1...120,
        shutterRange: 1.0 / 2000.0...0.25,
        tintRange: -150...150,
        focusRange: 0...1,
        supportsManualExposure: true,
        supportsWhiteBalanceLock: true,
        supportsFrameRateControl: true,
        supportsFocusLock: true
    )
    
    struct PreviewSourceStub: PreviewSource {
        // Stubbed out for test purposes.
        func connect(to target: PreviewTarget) {}
    }
    
    let previewSource: PreviewSource = PreviewSourceStub()
    
    private(set) var status = CameraStatus.unknown
    private(set) var captureActivity = CaptureActivity.idle
    var captureMode = CaptureMode.video {
        didSet {
            isSwitchingModes = true
            Task {
                // Create a short delay to mimic the time it takes to reconfigure the session.
                try? await Task.sleep(until: .now + .seconds(0.3), clock: .continuous)
                self.isSwitchingModes = false
            }
        }
    }
    private(set) var isSwitchingModes = false
    private(set) var isVideoDeviceSwitchable = true
    private(set) var isSwitchingVideoDevices = false
    private(set) var thumbnail: CGImage?
    var localVideoURLs: [URL] = []
    
    var error: Error?
    
    init(status: CameraStatus = .unknown) {
        self.captureMode = .video
        self.status = status
    }
    
    func start() async {
        if status == .unknown {
            status = .running
        }
    }

    func stop() async {
        status = .unknown
        captureActivity = .idle
    }
    
    func switchVideoDevices() {
        logger.debug("Device switching isn't implemented in PreviewCamera.")
    }
    
    func capturePhoto() {
        logger.debug("Photo capture isn't implemented in PreviewCamera.")
    }
    
    func toggleRecording() {
        logger.debug("Moving capture isn't implemented in PreviewCamera.")
    }
    
    func focusAndExpose(at point: CGPoint) {
        logger.debug("Focus and expose isn't implemented in PreviewCamera.")
    }
    
    var recordingTime: TimeInterval { .zero }
    
    private func capabilities(for mode: CaptureMode) -> CaptureCapabilities {
        switch mode {
        case .photo:
            return CaptureCapabilities(isLivePhotoCaptureSupported: true)
        case .video:
            return CaptureCapabilities(isLivePhotoCaptureSupported: false,
                                       isHDRSupported: true)
        }
    }
    
    func syncState() async {
        logger.debug("Syncing state isn't implemented in PreviewCamera.")
    }

    func refreshLocalVideos() async {
        logger.debug("Refreshing local videos isn't implemented in PreviewCamera.")
    }

    func deleteLocalVideo(_ url: URL) async {
        localVideoURLs.removeAll { $0.path() == url.path() }
    }

    func deleteLocalVideos(at offsets: IndexSet) async {
        localVideoURLs.remove(atOffsets: offsets)
    }
}
#endif
