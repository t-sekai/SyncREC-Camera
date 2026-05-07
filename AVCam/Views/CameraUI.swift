/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that presents the main camera user interface.
*/

import SwiftUI
import AVFoundation

/// A view that presents the main camera user interface.
struct CameraUI<CameraModel: Camera>: PlatformView {

    let camera: CameraModel
    let openLocalVideos: () -> Void
    @State private var selectedManualControl: ManualControlType?
    
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    var body: some View {
        Group {
            if isRegularSize {
                regularUI
            } else {
                compactUI
            }
        }
        .overlay(alignment: .top) {
            RecordingTimeView(time: camera.captureActivity.currentTime,
                              tentacleTimecode: camera.displayedTentacleTimecode,
                              recordingTimecode: camera.displayedRecordingTimecode)
                .offset(y: isRegularSize ? 20 : 0)
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                ManualControlChipRow(camera: camera,
                                     controls: [.iso, .whiteBalance, .fps],
                                     selectedControl: $selectedManualControl)
                if let selectedManualControl, selectedManualControl.isTopControl {
                    ManualControlPanel(camera: camera, control: selectedManualControl)
                }
            }
                .padding(.top, manualControlTopInset)
                .padding(.leading, 12)
                .padding(.trailing, 100)
                .opacity(camera.prefersMinimizedUI ? 0 : 1)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 8) {
                if let selectedManualControl, !selectedManualControl.isTopControl {
                    ManualControlPanel(camera: camera, control: selectedManualControl)
                }
                ManualControlChipRow(camera: camera,
                                     controls: [.shutter, .tint, .focus],
                                     selectedControl: $selectedManualControl)
            }
            .padding(.leading, 12)
            .padding(.bottom, manualControlBottomInset)
            .padding(.trailing, 100)
            .opacity(camera.prefersMinimizedUI ? 0 : 1)
        }
        .overlay {
            StatusOverlayView(status: camera.status)
        }
    }
    
    /// This view arranges UI elements vertically.
    @ViewBuilder
    var compactUI: some View {
        VStack(spacing: 0) {
            FeaturesToolbar(camera: camera)
            Spacer()
            MainToolbar(camera: camera, openLocalVideos: openLocalVideos)
                .padding(.bottom, bottomPadding)
        }
    }
    
    /// This view arranges UI elements in a layered stack.
    @ViewBuilder
    var regularUI: some View {
        VStack {
            Spacer()
            ZStack {
                MainToolbar(camera: camera, openLocalVideos: openLocalVideos)
                FeaturesToolbar(camera: camera)
                    .frame(width: 250)
                    .offset(x: 250) // The vertical offset from center.
            }
            .frame(width: 740)
            .background(.ultraThinMaterial.opacity(0.8))
            .cornerRadius(12)
            .padding(.bottom, 32)
        }
    }
    
    var bottomPadding: CGFloat {
        // Dynamically calculate the offset for the bottom toolbar in iOS.
        let bounds = UIScreen.main.bounds
        let rect = AVMakeRect(aspectRatio: movieAspectRatio, insideRect: bounds)
        return (rect.minY.rounded() / 2) + 12
    }

    var manualControlTopInset: CGFloat {
        isRegularSize ? 20 : 62
    }

    var manualControlBottomInset: CGFloat {
        isRegularSize ? 116 : bottomPadding + 84
    }
}

private enum ManualControlType: Hashable {
    case iso
    case whiteBalance
    case fps
    case shutter
    case tint
    case focus

    var isTopControl: Bool {
        switch self {
        case .iso, .whiteBalance, .fps:
            true
        case .shutter, .tint, .focus:
            false
        }
    }
}

private struct ManualControlChipRow<CameraModel: Camera>: View {
    let camera: CameraModel
    let controls: [ManualControlType]
    @Binding var selectedControl: ManualControlType?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(controls, id: \.self) { control in
                controlChip(control)
            }
        }
    }

    private func controlChip(_ control: ManualControlType) -> some View {
        Button {
            selectedControl = selectedControl == control ? nil : control
        } label: {
            HStack(spacing: 6) {
                Text(chipTitle(for: control))
                    .font(.caption.weight(.semibold))
                Image(systemName: isLocked(control) ? "lock.fill" : "lock.open")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(selectedControl == control ? Color.black : Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedControl == control ? Color.white : Color.black.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }

    private func chipTitle(for control: ManualControlType) -> String {
        switch control {
        case .iso:
            return "ISO \(Int(camera.manualControlState.iso))"
        case .whiteBalance:
            return "WB \(Int(camera.manualControlState.whiteBalanceTemperature))K"
        case .fps:
            return "FPS \(Int(camera.manualControlState.fps.rounded()))"
        case .shutter:
            return "S \(shutterText(seconds: camera.manualControlState.shutterSeconds))"
        case .tint:
            return "Tint \(Int(camera.manualControlState.tint))"
        case .focus:
            return camera.manualControlState.isFocusLocked ? "AF Locked" : "AF Auto"
        }
    }

    private func isLocked(_ control: ManualControlType) -> Bool {
        switch control {
        case .iso:
            return camera.manualControlState.isISOLocked
        case .whiteBalance:
            return camera.manualControlState.isWhiteBalanceLocked
        case .fps:
            return camera.manualControlState.isFPSLocked
        case .shutter:
            return camera.manualControlState.isShutterLocked
        case .tint:
            return camera.manualControlState.isTintLocked
        case .focus:
            return camera.manualControlState.isFocusLocked
        }
    }

    private func shutterText(seconds: Double) -> String {
        guard seconds > 0 else { return String(format: "%.4f s", seconds) }
        let denominator = Int((1.0 / seconds).rounded())
        if denominator > 1 {
            return "1/\(denominator)"
        }
        return String(format: "%.4f s", seconds)
    }
}

private struct ManualControlPanel<CameraModel: Camera>: View {
    let camera: CameraModel
    let control: ManualControlType

    var body: some View {
        sliderPanel(title: title,
                    isSupported: isSupported,
                    slider: AnyView(sliderView),
                    valueText: valueText,
                    isLocked: isLocked,
                    lockAction: lockAction)
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var sliderView: some View {
        switch control {
        case .iso:
            Slider(
                value: Binding(
                    get: { camera.manualControlState.iso },
                    set: { newValue in updateManualState { $0.iso = newValue } }
                ),
                in: camera.manualControlCapabilities.isoRange,
                step: 1
            )
        case .whiteBalance:
            Slider(
                value: Binding(
                    get: { camera.manualControlState.whiteBalanceTemperature },
                    set: { newValue in updateManualState { $0.whiteBalanceTemperature = newValue } }
                ),
                in: camera.manualControlCapabilities.whiteBalanceTemperatureRange,
                step: 50
            )
        case .fps:
            Slider(
                value: Binding(
                    get: { camera.manualControlState.fps },
                    set: { newValue in updateManualState { $0.fps = newValue } }
                ),
                in: camera.manualControlCapabilities.fpsRange,
                step: 1
            )
        case .shutter:
            Slider(
                value: Binding(
                    get: { camera.manualControlState.shutterSeconds },
                    set: { newValue in updateManualState { $0.shutterSeconds = newValue } }
                ),
                in: camera.manualControlCapabilities.shutterRange,
                step: shutterStep
            )
        case .tint:
            Slider(
                value: Binding(
                    get: { camera.manualControlState.tint },
                    set: { newValue in updateManualState { $0.tint = newValue } }
                ),
                in: camera.manualControlCapabilities.tintRange,
                step: 1
            )
        case .focus:
            Slider(
                value: Binding(
                    get: { camera.manualControlState.focusLensPosition },
                    set: { newValue in updateManualState { $0.focusLensPosition = newValue } }
                ),
                in: camera.manualControlCapabilities.focusRange,
                step: 0.01
            )
        }
    }

    private var title: String {
        switch control {
        case .iso: return "ISO"
        case .whiteBalance: return "White Balance"
        case .fps: return "Frame Rate"
        case .shutter: return "Shutter"
        case .tint: return "Tint"
        case .focus: return "Autofocus / Focus"
        }
    }

    private var isSupported: Bool {
        switch control {
        case .iso, .shutter:
            return camera.manualControlCapabilities.supportsManualExposure
        case .whiteBalance, .tint:
            return camera.manualControlCapabilities.supportsWhiteBalanceLock
        case .fps:
            return camera.manualControlCapabilities.supportsFrameRateControl
        case .focus:
            return camera.manualControlCapabilities.supportsFocusLock
        }
    }

    private var isLocked: Bool {
        switch control {
        case .iso:
            return camera.manualControlState.isISOLocked
        case .whiteBalance:
            return camera.manualControlState.isWhiteBalanceLocked
        case .fps:
            return camera.manualControlState.isFPSLocked
        case .shutter:
            return camera.manualControlState.isShutterLocked
        case .tint:
            return camera.manualControlState.isTintLocked
        case .focus:
            return camera.manualControlState.isFocusLocked
        }
    }

    private var valueText: String {
        switch control {
        case .iso:
            return "ISO \(Int(camera.manualControlState.iso))"
        case .whiteBalance:
            return "\(Int(camera.manualControlState.whiteBalanceTemperature))K"
        case .fps:
            return "\(Int(camera.manualControlState.fps.rounded())) fps"
        case .shutter:
            return shutterText(seconds: camera.manualControlState.shutterSeconds)
        case .tint:
            return "\(Int(camera.manualControlState.tint))"
        case .focus:
            return String(format: "Lens %.2f", camera.manualControlState.focusLensPosition)
        }
    }

    private var shutterStep: Double {
        let range = camera.manualControlCapabilities.shutterRange
        return max((range.upperBound - range.lowerBound) / 200.0, 0.0001)
    }

    private var lockAction: () -> Void {
        {
            updateManualState { state in
                switch control {
                case .iso:
                    let shouldLock = !state.isISOLocked
                    state.isISOLocked = shouldLock
                    state.isShutterLocked = shouldLock
                case .whiteBalance:
                    let shouldLock = !state.isWhiteBalanceLocked
                    state.isWhiteBalanceLocked = shouldLock
                    state.isTintLocked = shouldLock
                case .fps:
                    state.isFPSLocked.toggle()
                case .shutter:
                    let shouldLock = !state.isShutterLocked
                    state.isISOLocked = shouldLock
                    state.isShutterLocked = shouldLock
                case .tint:
                    let shouldLock = !state.isTintLocked
                    state.isWhiteBalanceLocked = shouldLock
                    state.isTintLocked = shouldLock
                case .focus:
                    state.isFocusLocked.toggle()
                }
            }
        }
    }

    private func sliderPanel(title: String,
                             isSupported: Bool,
                             slider: AnyView,
                             valueText: String,
                             isLocked: Bool,
                             lockAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(isLocked ? "Unlock" : "Lock") {
                    lockAction()
                }
                .buttonStyle(.borderedProminent)
                .font(.caption.weight(.semibold))
                .disabled(!isSupported)
            }

            if isSupported {
                slider
                    .disabled(!isLocked)
                Text(valueText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not supported on this camera.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 260)
    }

    private func shutterText(seconds: Double) -> String {
        guard seconds > 0 else { return String(format: "%.4f s", seconds) }
        let denominator = Int((1.0 / seconds).rounded())
        if denominator > 1 {
            return "1/\(denominator)"
        }
        return String(format: "%.4f s", seconds)
    }

    private func updateManualState(_ mutation: (inout ManualCameraControlState) -> Void) {
        var newState = camera.manualControlState
        mutation(&newState)
        camera.manualControlState = newState
    }
}

#if DEBUG
#Preview {
    CameraUI(camera: PreviewCameraModel(), openLocalVideos: {})
}
#endif
