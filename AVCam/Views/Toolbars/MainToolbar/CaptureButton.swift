/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that displays an appropriate capture button for the selected capture mode.
*/

import SwiftUI

/// A view that displays a movie capture button.
@MainActor
struct CaptureButton<CameraModel: Camera>: View {
    
    let camera: CameraModel
    @State var isRecording = false
    
    private let mainButtonDimension: CGFloat = 68
    
    var body: some View {
        captureButton
            .aspectRatio(1.0, contentMode: .fit)
            .frame(width: mainButtonDimension)
            // Respond to recording state changes that occur from hardware button presses.
            .onChange(of: camera.captureActivity.isRecording) { _, newValue in
                // Ensure the button animation occurs when toggling recording state from a hardware button.
                withAnimation(.easeInOut(duration: 0.25)) {
                    isRecording = newValue
                }
            }
    }
    
    @ViewBuilder
    var captureButton: some View {
        MovieCaptureButton(isRecording: $isRecording) { _ in
            Task {
                await camera.toggleRecording()
            }
        }
    }
}

#if DEBUG
#Preview("Video") {
    CaptureButton(camera: PreviewCameraModel())
}
#endif

private struct MovieCaptureButton: View {
    
    private let action: (Bool) -> Void
    private let lineWidth = CGFloat(4.0)
    
    @Binding private var isRecording: Bool
    
    init(isRecording: Binding<Bool>, action: @escaping (Bool) -> Void) {
        _isRecording = isRecording
        self.action = action
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: lineWidth)
                .foregroundColor(Color.white)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isRecording.toggle()
                }
                action(isRecording)
            } label: {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: geometry.size.width / (isRecording ? 4.0 : 2.0))
                        .inset(by: lineWidth * 1.2)
                        .fill(.red)
                        .scaleEffect(isRecording ? 0.6 : 1.0)
                }
            }
            .buttonStyle(NoFadeButtonStyle())
        }
    }
    
    struct NoFadeButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
        }
    }
}
