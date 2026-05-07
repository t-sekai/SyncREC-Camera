/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A Control Center extension for SyncREC Camera.
*/

import SwiftUI
import WidgetKit
import AppIntents

struct AVCamControlCenterExtension: ControlWidget {
    
    static var kind = "com.syncrec.camera.AVCamControlCenterExtension.ControlButton"
    static var displayName: LocalizedStringResource = "Open SyncREC"
    static var description: LocalizedStringResource = "Launch SyncREC Camera."
    
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: AVCamControlCenterExtension.kind) {
            ControlWidgetButton(action: AVCamCaptureIntent()) {
                Label("Open SyncREC", systemImage: "curlybraces")
            }
        }
        .displayName(AVCamControlCenterExtension.displayName)
        .description(AVCamControlCenterExtension.description)
    }
}
