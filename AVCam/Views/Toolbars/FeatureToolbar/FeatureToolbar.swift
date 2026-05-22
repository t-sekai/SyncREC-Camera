/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that presents controls to enable capture features.
*/

import SwiftUI

/// A view that presents controls to enable capture features.
struct FeaturesToolbar<CameraModel: Camera>: PlatformView {
    
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    let camera: CameraModel
    @State private var isShowingDirectorSettings = false
    @State private var draftDirectorWebSocketURL = ""
    @State private var draftDirectorDeviceName = ""
    @State private var draftRemoteDirectorMode = false
    
    var body: some View {
        HStack(spacing: 30) {
            directorSettingsButton
            Spacer()
            if camera.isHDRVideoSupported {
                hdrButton
            }
        }
        .buttonStyle(DefaultButtonStyle(size: isRegularSize ? .large : .small))
        .padding([.leading, .trailing])
        // Hide the toolbar items when a person interacts with capture controls.
        .opacity(camera.prefersMinimizedUI ? 0 : 1)
        .sheet(isPresented: $isShowingDirectorSettings) {
            directorSettingsSheet
        }
    }
    
    //  A button to toggle the enabled state of Live Photo capture.
    var livePhotoButton: some View {
        Button {
            camera.isLivePhotoEnabled.toggle()
        } label: {
            Image(systemName: camera.isLivePhotoEnabled ? "livephoto" : "livephoto.slash")
        }
    }
    
    @ViewBuilder
    var prioritizePicker: some View {
        Menu {
            Picker("Quality Prioritization", selection: Binding(
                get: { camera.qualityPrioritization },
                set: { camera.qualityPrioritization = $0 }
            )) {
                ForEach(QualityPrioritization.allCases) {
                    Text($0.description)
                        .font(.body.weight(.bold))
                }
            }

        } label: {
            switch camera.qualityPrioritization {
            case .speed:
                Image(systemName: "dial.low")
            case .balanced:
                Image(systemName: "dial.medium")
            case .quality:
                Image(systemName: "dial.high")
            }
        }
    }

    @ViewBuilder
    var hdrButton: some View {
        if isCompactSize {
            hdrToggleButton
        } else {
            hdrToggleButton
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
    
    var hdrToggleButton: some View {
        Button {
            camera.isHDRVideoEnabled.toggle()
        } label: {
            Text("HDR \(camera.isHDRVideoEnabled ? "On" : "Off")")
                .font(.body.weight(.semibold))
        }
        .disabled(camera.captureActivity.isRecording)
    }
    
    @ViewBuilder
    var compactSpacer: some View {
        if !isRegularSize {
            Spacer()
        }
    }

    var directorSettingsButton: some View {
        Button {
            draftDirectorWebSocketURL = camera.directorWebSocketURL
            draftDirectorDeviceName = camera.directorDeviceName
            draftRemoteDirectorMode = camera.isRemoteDirectorModeEnabled
            isShowingDirectorSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel("Remote Control Settings")
    }

    var directorSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Camera A", text: $draftDirectorDeviceName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Name shown in the laptop director.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Laptop Director") {
                    TextField(RemoteDirectorConfiguration.defaultDirectorWebSocketURL, text: $draftDirectorWebSocketURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Leave blank to use the default director address.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Remote Director Phone") {
                    Toggle("Use this iPhone as handheld director", isOn: $draftRemoteDirectorMode)
                    Text("When enabled, this phone requests laptop approval and shows controller buttons instead of recording.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remote Control")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isShowingDirectorSettings = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        camera.directorWebSocketURL = draftDirectorWebSocketURL
                        camera.directorDeviceName = draftDirectorDeviceName
                        camera.isRemoteDirectorModeEnabled = draftRemoteDirectorMode
                        isShowingDirectorSettings = false
                    }
                }
            }
        }
    }
}
