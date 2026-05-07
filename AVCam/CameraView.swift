/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The main user interface for the sample app.
*/

import SwiftUI
import AVFoundation
import AVKit

@MainActor
struct CameraView<CameraModel: Camera>: PlatformView {

    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    let camera: CameraModel
    let openLocalVideos: () -> Void

    var body: some View {
        ZStack {
            if camera.isRigLowPowerUIActive {
                RigLowPowerView(statusLines: camera.rigStatusLines)
            } else {
                // A container view that manages the placement of the preview.
                PreviewContainer(camera: camera) {
                    // A view that provides a preview of the captured content.
                    CameraPreview(source: camera.previewSource)
                        // Handle capture events from device hardware buttons.
                        .onCameraCaptureEvent(defaultSoundDisabled: true) { event in
                            if event.phase == .ended {
                                let sound: AVCaptureEventSound = camera.captureActivity.isRecording ?
                                    .endVideoRecording : .beginVideoRecording
                                // Toggle video recording when pressing a hardware button.
                                await camera.toggleRecording()
                                // Play a sound when capturing by clicking an AirPods stem.
                                if event.shouldPlaySound {
                                    event.play(sound)
                                }
                            }
                        }
                        // Focus and expose at the tapped point.
                        .onTapGesture { location in
                            Task { await camera.focusAndExpose(at: location) }
                        }
                        /// The value of `shouldFlashScreen` changes briefly to `true` when capture
                        /// starts, and then immediately changes to `false`. Use this change to
                        /// flash the screen to provide visual feedback when capturing photos.
                        .opacity(camera.shouldFlashScreen ? 0 : 1)
                }
            }
            // The main camera user interface.
            if !camera.isRigLowPowerUIActive {
                CameraUI(camera: camera, openLocalVideos: openLocalVideos)
            }
        }
    }
}

private struct RigLowPowerView: View {
    let statusLines: [String]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(statusLines, id: \.self) { line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(16)
        }
    }
}

#if DEBUG
#Preview {
    CameraView(camera: PreviewCameraModel(), openLocalVideos: {})
}
#endif

enum SwipeDirection {
    case left
    case right
    case up
    case down
}
