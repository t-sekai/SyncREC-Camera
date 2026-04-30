/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Local video file persistence for CameraModel.
*/

import Foundation

actor LocalVideoStore {

    private static let folderName = "Videos"
    private static let storedRelativePathsDefaultsKey = "LocalVideoRelativePaths"
    private static let finalizeRetryCount = 40
    private static let finalizeRetryDelayNS: UInt64 = 75_000_000
    private static let relocationRetryCount = 20
    private static let relocationRetryDelayNS: UInt64 = 100_000_000

    private let fileManager = FileManager.default

    func loadStoredVideos() -> [URL] {
        guard let folderURL = try? ensureVideosFolder() else { return [] }

        let storedRelativePaths = UserDefaults.standard.stringArray(forKey: Self.storedRelativePathsDefaultsKey) ?? []
        let restoredFromDefaults = storedRelativePaths
            .map { folderURL.appending(path: $0, directoryHint: .notDirectory) }
            .filter { fileManager.fileExists(atPath: $0.path()) }
        let discoveredInFolder = listVideosInFolder(folderURL)
        let restoredURLs = deduplicatedURLs(restoredFromDefaults + discoveredInFolder)

        persistVideoList(restoredURLs)
        return restoredURLs
    }

    func store(movie: Movie, calibrationJSON: Data?) async throws -> URL {
        try await waitForMovieFileToExist(at: movie.url)
        let folderURL = try ensureVideosFolder()
        let sourceFolderURL = movie.url.deletingLastPathComponent()

        let destinationURL: URL
        if isSameFileLocation(sourceFolderURL, folderURL) {
            destinationURL = movie.url
        } else {
            let relocatedURL = folderURL.appending(path: uniqueFileName(), directoryHint: .notDirectory)
            try await moveOrCopyMovie(from: movie.url, to: relocatedURL)
            destinationURL = relocatedURL
        }

        if let calibrationJSON {
            try writeCalibrationSidecar(calibrationJSON, forMovieURL: destinationURL)
        }
        markExcludedFromBackupIfPossible(destinationURL)
        markExcludedFromBackupIfPossible(calibrationSidecarURL(forMovieURL: destinationURL))

        var urls = loadStoredVideos()
        let destinationPath = canonicalPath(for: destinationURL)
        urls.removeAll { canonicalPath(for: $0) == destinationPath }
        urls.insert(destinationURL, at: 0)
        persistVideoList(urls)
        return destinationURL
    }

    func delete(urls: [URL]) -> [URL] {
        guard !urls.isEmpty else {
            return loadStoredVideos()
        }

        let pathsToDelete = Set(urls.map { canonicalPath(for: $0) })
        for url in urls where fileManager.fileExists(atPath: canonicalPath(for: url)) {
            try? fileManager.removeItem(at: url)
            let sidecarURL = calibrationSidecarURL(forMovieURL: url)
            if fileManager.fileExists(atPath: sidecarURL.path) {
                try? fileManager.removeItem(at: sidecarURL)
            }
        }

        var remaining = loadStoredVideos()
        remaining.removeAll { pathsToDelete.contains(canonicalPath(for: $0)) }
        persistVideoList(remaining)
        return remaining
    }

    private func ensureVideosFolder() throws -> URL {
        let videosURL = preferredVideosFolderURL()
        if !fileManager.fileExists(atPath: videosURL.path) {
            do {
                try fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)
            } catch {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        markExcludedFromBackupIfPossible(videosURL)
        migrateLegacyVideosIfNeeded(to: videosURL)
        return videosURL
    }

    private func preferredVideosFolderURL() -> URL {
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documentsURL.appendingPathComponent(Self.folderName, isDirectory: true)
        }
        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupportURL.appendingPathComponent(Self.folderName, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(Self.folderName, isDirectory: true)
    }

    private func legacyVideosFolderURL(relativeTo preferredURL: URL) -> URL? {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let legacyURL = appSupportURL.appendingPathComponent(Self.folderName, isDirectory: true)
        guard !isSameFileLocation(legacyURL, preferredURL) else {
            return nil
        }
        return legacyURL
    }

    private func migrateLegacyVideosIfNeeded(to preferredURL: URL) {
        guard let legacyURL = legacyVideosFolderURL(relativeTo: preferredURL),
              fileManager.fileExists(atPath: legacyURL.path),
              let contents = try? fileManager.contentsOfDirectory(at: legacyURL,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]) else {
            return
        }

        for sourceURL in contents where shouldMigrateFile(at: sourceURL) {
            let destinationURL = preferredURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
            if fileManager.fileExists(atPath: destinationURL.path) {
                continue
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    try? fileManager.removeItem(at: sourceURL)
                } catch {
                    logger.error("Failed to migrate local video file \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            markExcludedFromBackupIfPossible(destinationURL)
        }

        if let remaining = try? fileManager.contentsOfDirectory(at: legacyURL,
                                                                includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles]),
           remaining.isEmpty {
            try? fileManager.removeItem(at: legacyURL)
        }
    }

    private func shouldMigrateFile(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mov" || ext == "mp4" || ext == "json"
    }

    private func uniqueFileName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let timestamp = formatter.string(from: Date())
        return "video_\(timestamp)_\(UUID().uuidString.prefix(8)).mov"
    }

    private func calibrationSidecarURL(forMovieURL movieURL: URL) -> URL {
        movieURL.deletingPathExtension().appendingPathExtension("json")
    }

    private func writeCalibrationSidecar(_ calibrationJSON: Data, forMovieURL movieURL: URL) throws {
        let sidecarURL = calibrationSidecarURL(forMovieURL: movieURL)
        if fileManager.fileExists(atPath: sidecarURL.path) {
            try fileManager.removeItem(at: sidecarURL)
        }
        try calibrationJSON.write(to: sidecarURL, options: [.atomic])
    }

    private func markExcludedFromBackupIfPossible(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    private func listVideosInFolder(_ folderURL: URL) -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(at: folderURL,
                                                              includingPropertiesForKeys: [.contentModificationDateKey],
                                                              options: [.skipsHiddenFiles]) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "mov" || $0.pathExtension.lowercased() == "mp4" }
            .sorted(by: isOrderedMostRecentFirst(_:_:))
    }

    private func isOrderedMostRecentFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return lhsDate > rhsDate
    }

    private func persistVideoList(_ urls: [URL]) {
        let relativePaths = urls.map(\.lastPathComponent)
        UserDefaults.standard.set(relativePaths, forKey: Self.storedRelativePathsDefaultsKey)
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var unique = [URL]()

        for url in urls.sorted(by: isOrderedMostRecentFirst(_:_:)) {
            let key = canonicalPath(for: url)
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func isSameFileLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(for: lhs) == canonicalPath(for: rhs)
    }

    private func waitForMovieFileToExist(at url: URL) async throws {
        if fileManager.fileExists(atPath: url.path) {
            return
        }

        for _ in 0..<Self.finalizeRetryCount {
            try await Task.sleep(nanoseconds: Self.finalizeRetryDelayNS)
            if fileManager.fileExists(atPath: url.path) {
                return
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func moveOrCopyMovie(from sourceURL: URL, to destinationURL: URL) async throws {
        for attempt in 0..<Self.relocationRetryCount {
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                return
            } catch {
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                    try? fileManager.removeItem(at: sourceURL)
                    return
                } catch {
                    try? fileManager.removeItem(at: destinationURL)
                    if attempt + 1 == Self.relocationRetryCount {
                        throw error
                    }
                    try await Task.sleep(nanoseconds: Self.relocationRetryDelayNS)
                }
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }
}
