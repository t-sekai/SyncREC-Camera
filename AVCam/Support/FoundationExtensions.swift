/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Extensions on Foundation types.
*/

import Foundation

extension URL {
    /// A unique output location to write a movie.
    static var movieFileURL: URL {
        URL.temporaryDirectory.appending(component: UUID().uuidString).appendingPathExtension(for: .quickTimeMovie)
    }

    /// The preferred folder for local video recordings visible in Finder and Files (On My iPhone).
    static var localVideosDirectoryURL: URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.temporaryDirectory
        return baseURL.appendingPathComponent("Videos", isDirectory: true)
    }

    /// Output location for a named local video recording.
    static func localVideoRecordingFileURL(fileBaseName: String) -> URL {
        let fileManager = FileManager.default
        let videosURL = localVideosDirectoryURL
        try? fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)
        return videosURL.appending(component: fileBaseName).appendingPathExtension(for: .quickTimeMovie)
    }
}
