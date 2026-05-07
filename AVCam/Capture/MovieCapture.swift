/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that manages a movie capture output to record videos.
*/

import AVFoundation
import Combine

/// An object that manages a movie capture output to record videos.
final class MovieCapture: OutputService {
    
    /// A value that indicates the current state of movie capture.
    @Published private(set) var captureActivity: CaptureActivity = .idle
    
    /// The capture output type for this service.
    let output = AVCaptureMovieFileOutput()
    // An internal alias for the output.
    private var movieOutput: AVCaptureMovieFileOutput { output }
    
    // A delegate object to respond to movie capture events.
    private var delegate: MovieCaptureDelegate?
    
    // The interval at which to update the recording time.
    private let refreshInterval = TimeInterval(0.25)
    private var timerCancellable: AnyCancellable?
    
    // A Boolean value that indicates whether the currently selected camera's
    // active format supports HDR.
    private var isHDRSupported = false

    private static let remuxQueue = DispatchQueue(label: "com.syncrec.camera.timecodeRemuxQueue")
    
    // MARK: - Capturing a movie
    
    /// Starts movie recording.
    func startRecording(recordingStartMetadata: RecordingStartTimecodeMetadata?,
                        preferredStabilizationMode: AVCaptureVideoStabilizationMode? = .auto) {
        // Return early if already recording.
        guard !movieOutput.isRecording else { return }
        
        guard let connection = movieOutput.connection(with: .video) else {
            fatalError("Configuration error. No video connection found.")
        }

        // Configure connection for HEVC capture.
        if movieOutput.availableVideoCodecTypes.contains(.hevc) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }

        // Stabilization is controlled by the caller so deterministic manual profiles can prevent hidden resets.
        if connection.isVideoStabilizationSupported, let preferredStabilizationMode {
            connection.preferredVideoStabilizationMode = preferredStabilizationMode
        }

        movieOutput.metadata = metadataItems(for: recordingStartMetadata)
        
        // Start a timer to update the recording time.
        startMonitoringDuration()
        
        delegate = MovieCaptureDelegate(recordingStartMetadata: recordingStartMetadata)
        movieOutput.startRecording(to: URL.localVideoRecordingFileURL, recordingDelegate: delegate!)
    }
    
    /// Stops movie recording.
    /// - Returns: A `Movie` object that represents the captured movie.
    func stopRecording() async throws -> Movie {
        // Use a continuation to adapt the delegate-based capture API to an async interface.
        return try await withCheckedThrowingContinuation { continuation in
            // Set the continuation on the delegate to handle the capture result.
            delegate?.continuation = continuation
            
            /// Stops recording, which causes the output to call the `MovieCaptureDelegate` object.
            movieOutput.stopRecording()
            stopMonitoringDuration()
        }
    }
    
    // MARK: - Movie capture delegate
    /// A delegate object that responds to the capture output finalizing movie recording.
    private class MovieCaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
        
        private let recordingStartMetadata: RecordingStartTimecodeMetadata?
        var continuation: CheckedContinuation<Movie, Error>?

        init(recordingStartMetadata: RecordingStartTimecodeMetadata?) {
            self.recordingStartMetadata = recordingStartMetadata
        }
        
        func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
            let isFinishedSuccessfully: Bool
            if let nsError = error as NSError? {
                let completionKey = AVErrorRecordingSuccessfullyFinishedKey
                isFinishedSuccessfully = (nsError.userInfo[completionKey] as? Bool) ?? false
                if !isFinishedSuccessfully {
                    // Only fail when AVFoundation explicitly indicates the recording didn't finish.
                    let continuation = continuation
                    self.continuation = nil
                    continuation?.resume(throwing: nsError)
                    return
                }
            } else {
                isFinishedSuccessfully = true
            }

            guard isFinishedSuccessfully else {
                let continuation = continuation
                self.continuation = nil
                continuation?.resume(throwing: CocoaError(.fileWriteUnknown))
                return
            }

            guard let continuation else { return }
            self.continuation = nil

            Task.detached(priority: .userInitiated) {
                let remuxedURL = MovieCapture.remuxAddingTimecodeTrackIfPossible(sourceURL: outputFileURL,
                                                                                  recordingStartMetadata: self.recordingStartMetadata)
                continuation.resume(returning: Movie(url: remuxedURL))
            }
        }
    }
    
    // MARK: - Monitoring recorded duration
    
    // Starts a timer to update the recording time.
    private func startMonitoringDuration() {
        captureActivity = .movieCapture()
        timerCancellable = Timer.publish(every: refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // Poll the movie output for its recorded duration.
                let duration = movieOutput.recordedDuration.seconds
                captureActivity = .movieCapture(duration: duration)
            }
    }
    
    /// Stops the timer and resets the time to `CMTime.zero`.
    private func stopMonitoringDuration() {
        timerCancellable?.cancel()
        captureActivity = .idle
    }
    
    func updateConfiguration(for device: AVCaptureDevice) {
        // The app supports HDR video capture if the active format supports it.
        isHDRSupported = device.activeFormat10BitVariant != nil
    }

    private func metadataItems(for startMetadata: RecordingStartTimecodeMetadata?) -> [AVMetadataItem] {
        guard let startMetadata else { return [] }

        let summary = "Start TC \(startMetadata.timecode) @ \(startMetadata.fps) fps"
        let title = makeCommonMetadataItem(key: .commonKeyTitle, value: summary)
        let description = makeCommonMetadataItem(key: .commonKeyDescription, value: summary)
        let creator = makeCommonMetadataItem(key: .commonKeyCreator, value: startMetadata.source)
        let quickTimeDescription = makeQuickTimeMetadataDescriptionItem(value: summary)
        return [title, description, creator, quickTimeDescription]
    }

    private func makeCommonMetadataItem(key: AVMetadataKey, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .common
        item.key = key as NSString
        item.value = value as NSString
        return item
    }

    private func makeQuickTimeMetadataDescriptionItem(value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = AVMetadataKey.quickTimeMetadataKeyDescription as NSString
        item.value = value as NSString
        return item
    }

    private static func remuxAddingTimecodeTrackIfPossible(sourceURL: URL,
                                                           recordingStartMetadata: RecordingStartTimecodeMetadata?) -> URL {
        guard let recordingStartMetadata,
              let startFrameNumber = frameNumber(from: recordingStartMetadata.timecode, fps: recordingStartMetadata.fps) else {
            return sourceURL
        }

        do {
            return try remuxAddingTimecodeTrack(sourceURL: sourceURL,
                                                startFrameNumber: startFrameNumber,
                                                fps: recordingStartMetadata.fps)
        } catch {
            logger.error("Unable to add tmcd timecode track: \(error.localizedDescription, privacy: .public)")
            return sourceURL
        }
    }

    private static func remuxAddingTimecodeTrack(sourceURL: URL,
                                                 startFrameNumber: Int32,
                                                 fps: Int) throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = asset.tracks.filter { $0.mediaType == .video || $0.mediaType == .audio }
        guard !tracks.isEmpty else { return sourceURL }

        let outputURL = sourceURL
            .deletingPathExtension()
            .appendingPathExtension("tmcd.mov")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.metadata = asset.metadata

        var ioPairs = [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)]()
        var videoWriterInput: AVAssetWriterInput?

        for track in tracks {
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else { continue }
            reader.add(readerOutput)

            let sourceFormatHint = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
            let writerInput = AVAssetWriterInput(mediaType: track.mediaType,
                                                 outputSettings: nil,
                                                 sourceFormatHint: sourceFormatHint)
            writerInput.expectsMediaDataInRealTime = false
            if track.mediaType == .video {
                writerInput.transform = track.preferredTransform
                videoWriterInput = writerInput
            }
            guard writer.canAdd(writerInput) else { continue }
            writer.add(writerInput)
            ioPairs.append((output: readerOutput, input: writerInput))
        }

        guard let videoWriterInput else {
            try? fileManager.removeItem(at: outputURL)
            return sourceURL
        }

        let fps = max(1, fps)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        var timecodeFormatDescription: CMFormatDescription?
        let createStatus = CMTimeCodeFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                             timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                                                             frameDuration: frameDuration,
                                                             frameQuanta: UInt32(fps),
                                                             flags: 0,
                                                             extensions: nil,
                                                             formatDescriptionOut: &timecodeFormatDescription)
        guard createStatus == noErr, let timecodeFormatDescription else {
            try? fileManager.removeItem(at: outputURL)
            return sourceURL
        }

        let timecodeInput = AVAssetWriterInput(mediaType: .timecode,
                                               outputSettings: nil,
                                               sourceFormatHint: timecodeFormatDescription)
        timecodeInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(timecodeInput) else {
            try? fileManager.removeItem(at: outputURL)
            return sourceURL
        }
        writer.add(timecodeInput)
        timecodeInput.addTrackAssociation(withTrackOf: videoWriterInput, type: AVAssetTrack.AssociationType.timecode.rawValue)

        guard reader.startReading() else {
            try? fileManager.removeItem(at: outputURL)
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        guard writer.startWriting() else {
            try? fileManager.removeItem(at: outputURL)
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        let completionGroup = DispatchGroup()
        let stateLock = NSLock()
        var firstError: Error?

        for pair in ioPairs {
            completionGroup.enter()
            pair.input.requestMediaDataWhenReady(on: remuxQueue) {
                while pair.input.isReadyForMoreMediaData {
                    if let sampleBuffer = pair.output.copyNextSampleBuffer() {
                        if !pair.input.append(sampleBuffer) {
                            stateLock.lock()
                            firstError = firstError ?? writer.error ?? CocoaError(.fileWriteUnknown)
                            stateLock.unlock()
                            pair.input.markAsFinished()
                            completionGroup.leave()
                            return
                        }
                    } else {
                        pair.input.markAsFinished()
                        completionGroup.leave()
                        return
                    }
                }
            }
        }

        completionGroup.enter()
        timecodeInput.requestMediaDataWhenReady(on: remuxQueue) {
            guard timecodeInput.isReadyForMoreMediaData else { return }

            do {
                let duration = asset.duration.isValid && asset.duration > .zero ? asset.duration : CMTime(value: 1, timescale: CMTimeScale(fps))
                let sampleBuffer = try makeTimecodeSampleBuffer(startFrameNumber: startFrameNumber,
                                                                duration: duration,
                                                                formatDescription: timecodeFormatDescription)
                if !timecodeInput.append(sampleBuffer) {
                    stateLock.lock()
                    firstError = firstError ?? writer.error ?? CocoaError(.fileWriteUnknown)
                    stateLock.unlock()
                }
            } catch {
                stateLock.lock()
                firstError = firstError ?? error
                stateLock.unlock()
            }

            timecodeInput.markAsFinished()
            completionGroup.leave()
        }

        completionGroup.wait()

        if let firstError {
            writer.cancelWriting()
            reader.cancelReading()
            try? fileManager.removeItem(at: outputURL)
            throw firstError
        }

        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finishSemaphore.signal()
        }
        finishSemaphore.wait()

        if let finishError = writer.error {
            try? fileManager.removeItem(at: outputURL)
            throw finishError
        }

        if fileManager.fileExists(atPath: sourceURL.path) {
            try fileManager.removeItem(at: sourceURL)
        }
        try fileManager.moveItem(at: outputURL, to: sourceURL)
        return sourceURL
    }

    private static func makeTimecodeSampleBuffer(startFrameNumber: Int32,
                                                 duration: CMTime,
                                                 formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                             memoryBlock: nil,
                                                             blockLength: MemoryLayout<UInt32>.size,
                                                             blockAllocator: kCFAllocatorDefault,
                                                             customBlockSource: nil,
                                                             offsetToData: 0,
                                                             dataLength: MemoryLayout<UInt32>.size,
                                                             flags: 0,
                                                             blockBufferOut: &blockBuffer)
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else {
            throw CocoaError(.coderInvalidValue)
        }

        var frameNumberBigEndian = CFSwapInt32HostToBig(UInt32(bitPattern: startFrameNumber))
        let replaceStatus = CMBlockBufferReplaceDataBytes(with: &frameNumberBigEndian,
                                                          blockBuffer: blockBuffer,
                                                          offsetIntoDestination: 0,
                                                          dataLength: MemoryLayout<UInt32>.size)
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw CocoaError(.coderInvalidValue)
        }

        var timingInfo = CMSampleTimingInfo(duration: duration,
                                            presentationTimeStamp: .zero,
                                            decodeTimeStamp: .invalid)
        var sampleSize = MemoryLayout<UInt32>.size
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                     dataBuffer: blockBuffer,
                                                     formatDescription: formatDescription,
                                                     sampleCount: 1,
                                                     sampleTimingEntryCount: 1,
                                                     sampleTimingArray: &timingInfo,
                                                     sampleSizeEntryCount: 1,
                                                     sampleSizeArray: &sampleSize,
                                                     sampleBufferOut: &sampleBuffer)
        guard sampleStatus == noErr, let sampleBuffer else {
            throw CocoaError(.coderInvalidValue)
        }
        return sampleBuffer
    }

    private static func frameNumber(from timecode: String, fps: Int) -> Int32? {
        let fps = max(1, fps)
        let components = timecode.split(separator: ":")
        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]),
              hours >= 0, hours < 24,
              minutes >= 0, minutes < 60,
              seconds >= 0, seconds < 60,
              frames >= 0, frames < fps else {
            return nil
        }

        let totalFrames = (((hours * 60) + minutes) * 60 + seconds) * fps + frames
        return Int32(totalFrames)
    }

    // MARK: - Configuration
    /// Returns the capabilities for this capture service.
    var capabilities: CaptureCapabilities {
        CaptureCapabilities(isHDRSupported: isHDRSupported)
    }
}
