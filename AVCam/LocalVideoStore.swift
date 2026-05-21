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

    func store(movie: Movie, calibrationJSON: Data?, fileBaseName: String) async throws -> URL {
        try await waitForMovieFileToExist(at: movie.url)
        let folderURL = try ensureVideosFolder()
        let preferredURL = folderURL.appending(path: "\(sanitizedBaseName(fileBaseName)).mov",
                                               directoryHint: .notDirectory)

        let destinationURL: URL
        if isSameFileLocation(movie.url, preferredURL) {
            destinationURL = movie.url
        } else {
            let relocatedURL = uniqueDestination(preferredURL)
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

    private func sanitizedBaseName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var output = ""
        var lastWasSeparator = false

        for scalar in trimmed.unicodeScalars {
            let scalarValue = scalar.value
            let isASCIIAlphanumeric = (48...57).contains(scalarValue)
                || (65...90).contains(scalarValue)
                || (97...122).contains(scalarValue)
            if isASCIIAlphanumeric || scalarValue == 95 || scalarValue == 45 {
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                output.append("-")
                lastWasSeparator = true
            }
        }

        let cleaned = output.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if cleaned.isEmpty {
            return "recording"
        }
        return String(cleaned.prefix(160))
    }

    private func uniqueDestination(_ candidate: URL) -> URL {
        guard fileManager.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let stem = candidate.deletingPathExtension().lastPathComponent
        let pathExtension = candidate.pathExtension
        let folderURL = candidate.deletingLastPathComponent()
        var index = 2
        while true {
            let next = folderURL.appending(path: "\(stem)_\(index).\(pathExtension)", directoryHint: .notDirectory)
            if !fileManager.fileExists(atPath: next.path) {
                return next
            }
            index += 1
        }
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
