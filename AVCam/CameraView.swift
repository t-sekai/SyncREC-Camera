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
            if camera.isRemoteDirectorModeEnabled {
                RemoteDirectorModeView(camera: camera)
            } else if camera.isRigLowPowerUIActive {
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
            if !camera.isRigLowPowerUIActive && !camera.isRemoteDirectorModeEnabled {
                CameraUI(camera: camera, openLocalVideos: openLocalVideos)
            }
        }
    }
}

private struct RemoteDirectorModeView<CameraModel: Camera>: View {
    let camera: CameraModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: camera.remoteDirectorApprovalState.isApproved ? "checkmark.seal.fill" : "hand.raised.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(camera.remoteDirectorApprovalState.isApproved ? Color.green : Color.orange)
                    Text("Remote Director")
                        .font(.title.bold())
                    Text(statusText)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Experiment")
                            .font(.headline)
                        Spacer()
                        Text("Take")
                            .font(.headline)
                            .frame(width: 72, alignment: .leading)
                    }
                    HStack(alignment: .center, spacing: 12) {
                        TextField("experiment", text: Binding(
                            get: { camera.remoteDirectorExperimentName },
                            set: { camera.remoteDirectorExperimentName = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                        Text(camera.remoteDirectorTakeNumberText)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .frame(width: 72, alignment: .leading)
                            .frame(minHeight: 36)
                    }
                    Button("Set Experiment Name") {
                        Task { await camera.remoteDirectorSetExperimentName() }
                    }
                    .disabled(!camera.remoteDirectorApprovalState.isApproved)
                }

                VStack(spacing: 12) {
                    Button("Prepare + Commit Start") {
                        Task { await camera.remoteDirectorPrepareCommitStart() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!camera.remoteDirectorApprovalState.isApproved)

                    Button("Prepare Stop") {
                        Task { await camera.remoteDirectorPrepareStop() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!camera.remoteDirectorApprovalState.isApproved)

                    Button("Arm Idle All") {
                        Task { await camera.remoteDirectorArmIdleAll() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!camera.remoteDirectorApprovalState.isApproved)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(camera.remoteDirectorSummaryLines, id: \.self) { line in
                        Text(line)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if !camera.remoteDirectorLastResult.isEmpty {
                        Text(camera.remoteDirectorLastResult)
                            .font(.callout)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 10) {
                    Button("Request Approval Again") {
                        Task { await camera.requestRemoteDirectorApproval() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(camera.remoteDirectorApprovalState.isApproved)

                    Button("Exit Remote Director") {
                        Task { await camera.exitRemoteDirectorMode() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var statusText: String {
        switch camera.remoteDirectorApprovalState {
        case .approved:
            return "Approved. Commands will be sent through the laptop director."
        case .pending, .requesting:
            return camera.remoteDirectorStatusText
        case .busy:
            return "Another phone is currently the remote director."
        case .denied:
            return "Request denied by the laptop director."
        case .released:
            return "Remote director slot was released."
        case .disconnected:
            return "Disconnected from the laptop director."
        case .inactive:
            return camera.remoteDirectorStatusText
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
