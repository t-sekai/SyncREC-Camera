/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A sample app that shows how to a use the AVFoundation capture APIs to perform media capture.
*/

import os
import SwiftUI

private enum AppTab: Hashable {
    case camera
    case videos
}

@main
/// The AVCam app's main entry point.
struct AVCamApp: App {

    // Simulator doesn't support the AVFoundation capture APIs. Use the preview camera when running in Simulator.
    @State private var camera = CameraModel()
    @State private var selectedTab: AppTab = .camera
    
    // An indication of the scene's operational state.
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            Group {
                if camera.isRemoteDirectorModeEnabled {
                    CameraView(camera: camera, openLocalVideos: {})
                } else {
                    TabView(selection: $selectedTab) {
                        CameraView(camera: camera, openLocalVideos: {
                            selectedTab = .videos
                        })
                            .tabItem {
                                Label("Camera", systemImage: "camera")
                            }
                            .tag(AppTab.camera)

                        LocalVideosView(camera: camera)
                            .tabItem {
                                Label("Videos", systemImage: "film.stack")
                            }
                            .tag(AppTab.videos)
                    }
                }
            }
                .statusBarHidden(true)
                .task {
                    // Start the capture pipeline.
                    if camera.isRemoteDirectorModeEnabled || selectedTab == .camera {
                        await camera.start()
                    } else {
                        await camera.refreshLocalVideos()
                    }
                }
                .onChange(of: selectedTab) { _, newTab in
                    Task { @MainActor in
                        switch newTab {
                        case .camera:
                            await camera.start()
                            await camera.syncState()
                        case .videos:
                            await camera.stop()
                            await camera.refreshLocalVideos()
                        }
                    }
                }
                // Monitor the scene phase. Synchronize the persistent state when
                // the camera is running and the app becomes active.
                .onChange(of: scenePhase) { _, newPhase in
                    Task { @MainActor in
                        switch newPhase {
                        case .active:
                            if camera.isRemoteDirectorModeEnabled || selectedTab == .camera {
                                await camera.start()
                                await camera.syncState()
                            } else {
                                await camera.refreshLocalVideos()
                            }
                        case .background, .inactive:
                            await camera.stop()
                        @unknown default:
                            break
                        }
                    }
                }
        }
    }
}

/// A global logger for the app.
let logger = Logger()
