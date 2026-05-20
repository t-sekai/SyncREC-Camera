/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Remote director control plane types and client.
*/

import Foundation
import SwiftUI

struct RemoteDirectorStatusPayload {
    let recording: Bool
    let armed: Bool
    let battery: Double?
    let storageGB: Double?
    let localVideoCount: Int
    let uploadedVideoCount: Int
    let pendingUploadVideoCount: Int
    let localVideoBytes: Int64
    let uploadedVideoBytes: Int64
    let pendingUploadVideoBytes: Int64
    let selectedCaptureMode: String?
    let actualVideoWidth: Int?
    let actualVideoHeight: Int?
    let actualVideoFPS: Double?
    let actualCaptureMode: String?
    let supportedCaptureModes: [String]
    let tentacleState: String
    let timecode: String
    let fps: Int?
    let cameraParamsStatus: String?
    let cameraParamsSummary: String?
    let rigState: RigState
    let preferredStatusIntervalMS: UInt64

    static let empty = RemoteDirectorStatusPayload(recording: false,
                                                   armed: false,
                                                   battery: nil,
                                                   storageGB: nil,
                                                   localVideoCount: 0,
                                                   uploadedVideoCount: 0,
                                                   pendingUploadVideoCount: 0,
                                                   localVideoBytes: 0,
                                                   uploadedVideoBytes: 0,
                                                   pendingUploadVideoBytes: 0,
                                                   selectedCaptureMode: nil,
                                                   actualVideoWidth: nil,
                                                   actualVideoHeight: nil,
                                                   actualVideoFPS: nil,
                                                   actualCaptureMode: nil,
                                                   supportedCaptureModes: [],
                                                   tentacleState: "unknown",
                                                   timecode: "",
                                                   fps: nil,
                                                   cameraParamsStatus: nil,
                                                   cameraParamsSummary: nil,
                                                   rigState: .normalExit,
                                                   preferredStatusIntervalMS: 1_000)
}

enum RemoteDirectorCommand {
    case arm
    case armIdle
    case prepareStart(sessionID: String, startAtUnixMS: Int64)
    case commitStart(sessionID: String, startAtUnixMS: Int64)
    case prepareStop(sessionID: String, stopAtUnixMS: Int64)
    case prepareRecording(sessionID: String?)
    case startRecording(sessionID: String?, startAtUnixMS: Int64?)
    case stopRecording(sessionID: String?, stopAtUnixMS: Int64?)
    case getStatus
    case setBrightness(Double)
    case pullVideos(jobID: String, policy: String, maxFiles: Int, uploadURL: String?)
    case deleteLocalVideos(policy: RemoteLocalVideoDeletePolicy)
    case setCaptureMode(VideoCaptureModePreset)
    case capturePreviewPhoto(batchID: String,
                             uploadURL: String?,
                             longEdge: Int,
                             jpegQuality: Double,
                             uploadJitterSeconds: Double,
                             attempt: Int)
    case exportCameraParams
    case applyCameraParams(profile: ManualLockProfile, dryRun: Bool)
    case validateCameraParams
    case setFocusMode(String)
    case releaseCameraParamLocks(preserveFocus: Bool)
    case lockCameraParamLocks
    case toggleCameraParamLocks(preserveFocus: Bool)
}

enum RemoteLocalVideoDeletePolicy {
    case uploadedOnly
    case forceAll
}

struct RemoteDirectorCommandEnvelope {
    let requestID: String
    let command: RemoteDirectorCommand
}

struct RemoteDirectorCommandReply {
    let ok: Bool
    let detail: String
    let payload: [String: Any]?

    static func success(_ detail: String, payload: [String: Any]? = nil) -> RemoteDirectorCommandReply {
        .init(ok: true, detail: detail, payload: payload)
    }

    static func failure(_ detail: String, payload: [String: Any]? = nil) -> RemoteDirectorCommandReply {
        .init(ok: false, detail: detail, payload: payload)
    }
}

@MainActor
final class RemoteDirectorClient {

    typealias StatusProvider = () -> RemoteDirectorStatusPayload
    typealias CommandHandler = (RemoteDirectorCommandEnvelope) async -> RemoteDirectorCommandReply
    typealias TimeSyncHandler = (DirectorTimeSyncPacket) -> Void

    private static let deviceIDDefaultsKey = "RemoteDirectorDeviceID"
    private static let reconnectDelayMS: UInt64 = 2_000
    private static let statusIntervalMS: UInt64 = 1_000
    private static let burstStatusDebounceMS: UInt64 = 150
    private static let maxClockOffsetSamples = 32

    var statusProvider: StatusProvider?
    var commandHandler: CommandHandler?
    var timeSyncHandler: TimeSyncHandler?
    var deviceNameProvider: (() -> String)?
    private(set) var connectionStatus = "disconnected"

    private let session = URLSession(configuration: .default)
    private let deviceID: String
    private let appVersion: String
    private let appBuild: String
    private let appDisplayVersion: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingBurstStatusTask: Task<Void, Never>?
    private var shouldRun = false
    private var isConnecting = false
    private var clockOffsetSamplesMS = [Double]()
    private var estimatedClockOffsetMS = 0.0

    init() {
        deviceID = Self.loadOrCreateDeviceID()
        appVersion = Self.bundleInfoString(forKey: "CFBundleShortVersionString")
        appBuild = Self.bundleInfoString(forKey: "CFBundleVersion")
        appDisplayVersion = Self.formatAppDisplayVersion(version: appVersion, build: appBuild)
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func start() {
        guard !shouldRun else { return }
        guard directorURL() != nil else {
            logger.info("Remote director URL unavailable. Set UserDefaults key \(RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey, privacy: .public) to ws://<host>:8765.")
            connectionStatus = "not_configured"
            return
        }
        shouldRun = true
        connectionStatus = "connecting"
        connectIfNeeded()
    }

    func stop() {
        shouldRun = false
        reconnectTask?.cancel()
        receiveTask?.cancel()
        statusTask?.cancel()
        pendingBurstStatusTask?.cancel()
        reconnectTask = nil
        receiveTask = nil
        statusTask = nil
        pendingBurstStatusTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnecting = false
        clockOffsetSamplesMS.removeAll(keepingCapacity: true)
        estimatedClockOffsetMS = 0
        connectionStatus = "disconnected"
    }

    var hasConfiguredDirectorURL: Bool {
        directorURL() != nil
    }

    func currentDirectorSynchronizedUnixMilliseconds() -> Int64 {
        let now = Self.unixNowMS()
        guard !clockOffsetSamplesMS.isEmpty else { return now }
        return now + Int64(estimatedClockOffsetMS.rounded())
    }

    func sendStatusNow() {
        Task { @MainActor in
            await sendStatus()
        }
    }

    func sendStatusSoon() {
        guard shouldRun else { return }
        guard pendingBurstStatusTask == nil else { return }

        pendingBurstStatusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.burstStatusDebounceMS * 1_000_000)
            guard !Task.isCancelled else { return }
            self.pendingBurstStatusTask = nil
            await self.sendStatus()
        }
    }

    func sendTransferUpdate(jobID: String,
                            state: String,
                            detail: String? = nil,
                            sentFiles: Int? = nil,
                            totalFiles: Int? = nil,
                            sentBytes: Int64? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendTransferUpdatePayload(jobID: jobID,
                                                 state: state,
                                                 detail: detail,
                                                 sentFiles: sentFiles,
                                                 totalFiles: totalFiles,
                                                 sentBytes: sentBytes)
        }
    }

    func sendPreviewPhotoUpdate(requestID: String,
                                state: String,
                                detail: String? = nil,
                                imageBytes: Int? = nil,
                                metadataBytes: Int? = nil,
                                failureReason: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendPreviewPhotoUpdatePayload(requestID: requestID,
                                                     state: state,
                                                     detail: detail,
                                                     imageBytes: imageBytes,
                                                     metadataBytes: metadataBytes,
                                                     failureReason: failureReason)
        }
    }

    func transferDeviceID() -> String {
        deviceID
    }

    func manualSnapshotIdentity() -> ManualSnapshotDeviceIdentity {
        ManualSnapshotDeviceIdentity(remoteDeviceID: deviceID,
                                     remoteDeviceName: resolvedDeviceName(),
                                     appVersion: appDisplayVersion)
    }

    func resolveUploadBaseURL(override uploadURLString: String?) -> URL? {
        if let uploadURLString {
            let trimmed = uploadURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               let uploadURL = URL(string: trimmed),
               let scheme = uploadURL.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return uploadURL
            }
        }

        guard let wsURL = directorURL(),
              var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        case "http", "https":
            break
        default:
            return nil
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/upload"
        return components.url
    }

    private func sendTransferUpdatePayload(jobID: String,
                                           state: String,
                                           detail: String? = nil,
                                           sentFiles: Int? = nil,
                                           totalFiles: Int? = nil,
                                           sentBytes: Int64? = nil) async {
        var message: [String: Any] = [
            "type": "transfer",
            "device_id": deviceID,
            "job_id": jobID,
            "state": state
        ]

        if let detail, !detail.isEmpty {
            message["detail"] = detail
        }
        if let sentFiles {
            message["sent_files"] = sentFiles
        }
        if let totalFiles {
            message["total_files"] = totalFiles
        }
        if let sentBytes {
            message["sent_bytes"] = sentBytes
        }

        await sendJSONObject(message)
    }

    private func sendPreviewPhotoUpdatePayload(requestID: String,
                                               state: String,
                                               detail: String? = nil,
                                               imageBytes: Int? = nil,
                                               metadataBytes: Int? = nil,
                                               failureReason: String? = nil) async {
        var message: [String: Any] = [
            "type": "preview_photo",
            "device_id": deviceID,
            "request_id": requestID,
            "state": state
        ]

        if let detail, !detail.isEmpty {
            message["detail"] = detail
        }
        if let imageBytes {
            message["image_bytes"] = imageBytes
        }
        if let metadataBytes {
            message["metadata_bytes"] = metadataBytes
        }
        if let failureReason, !failureReason.isEmpty {
            message["failure_reason"] = failureReason
        }

        await sendJSONObject(message)
    }

    private func connectIfNeeded() {
        guard shouldRun else { return }
        guard !isConnecting, webSocketTask == nil else { return }
        guard let url = directorURL() else { return }

        isConnecting = true
        connectionStatus = "connecting"
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        isConnecting = false
        connectionStatus = "connected"

        logger.info("Connected to remote director \(url.absoluteString, privacy: .public)")

        receiveTask?.cancel()
        statusTask?.cancel()
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        statusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.statusLoop()
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sendHello()
            await self.sendStatus()
        }
    }

    private func receiveLoop() async {
        guard let task = webSocketTask else { return }

        do {
            while shouldRun {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    await handleInboundText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleInboundText(text)
                    }
                @unknown default:
                    break
                }
            }
        } catch {
            logger.error("Remote director receive loop failed: \(error.localizedDescription, privacy: .public)")
        }

        handleDisconnectAndReconnect()
    }

    private func statusLoop() async {
        while shouldRun {
            let interval = statusProvider?().preferredStatusIntervalMS ?? Self.statusIntervalMS
            let clampedInterval = min(max(interval, 1_000), 15_000)
            try? await Task.sleep(nanoseconds: clampedInterval * 1_000_000)
            if Task.isCancelled { return }
            await sendStatus()
        }
    }

    private func handleDisconnectAndReconnect() {
        receiveTask?.cancel()
        statusTask?.cancel()
        pendingBurstStatusTask?.cancel()
        receiveTask = nil
        statusTask = nil
        pendingBurstStatusTask = nil
        webSocketTask = nil
        isConnecting = false
        connectionStatus = "disconnected"

        guard shouldRun else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: Self.reconnectDelayMS * 1_000_000)
            guard !Task.isCancelled else { return }
            self.connectIfNeeded()
        }
    }

    private func sendHello() async {
        let message: [String: Any] = [
            "type": "hello",
            "device_id": deviceID,
            "name": resolvedDeviceName(),
            "app_version": appVersion,
            "app_build": appBuild
        ]
        await sendJSONObject(message)
    }

    private func sendStatus() async {
        guard let statusProvider else { return }
        let status = statusProvider()

        var message: [String: Any] = [
            "type": "status",
            "device_id": deviceID,
            "name": resolvedDeviceName(),
            "app_version": appVersion,
            "app_build": appBuild,
            "recording": status.recording,
            "armed": status.armed,
            "tentacle_state": status.tentacleState,
            "timecode": status.timecode
        ]

        if let battery = status.battery {
            message["battery"] = battery
        }
        if let storageGB = status.storageGB {
            message["storage_gb"] = storageGB
        }
        message["local_video_count"] = status.localVideoCount
        message["uploaded_video_count"] = status.uploadedVideoCount
        message["pending_upload_video_count"] = status.pendingUploadVideoCount
        message["local_video_bytes"] = status.localVideoBytes
        message["uploaded_video_bytes"] = status.uploadedVideoBytes
        message["pending_upload_video_bytes"] = status.pendingUploadVideoBytes
        if let selectedCaptureMode = status.selectedCaptureMode {
            message["capture_mode"] = selectedCaptureMode
        }
        if let actualVideoWidth = status.actualVideoWidth {
            message["actual_video_width"] = actualVideoWidth
        }
        if let actualVideoHeight = status.actualVideoHeight {
            message["actual_video_height"] = actualVideoHeight
        }
        if let actualVideoFPS = status.actualVideoFPS {
            message["actual_video_fps"] = actualVideoFPS
        }
        if let actualCaptureMode = status.actualCaptureMode {
            message["actual_capture_mode"] = actualCaptureMode
        }
        message["supported_capture_modes"] = status.supportedCaptureModes
        if let fps = status.fps {
            message["fps"] = fps
        }
        if let cameraParamsStatus = status.cameraParamsStatus {
            message["camera_params_status"] = cameraParamsStatus
        }
        if let cameraParamsSummary = status.cameraParamsSummary {
            message["camera_params_summary"] = cameraParamsSummary
        }
        message["rig_state"] = status.rigState.rawValue

        await sendJSONObject(message)
    }

    private func handleInboundText(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            logger.error("Invalid remote director payload.")
            return
        }

        guard let type = payload["type"] as? String else {
            return
        }

        if type == "time_sync" {
            handleTimeSyncPayload(payload)
            return
        }
        guard type == "command" else { return }
        guard let commandName = payload["command"] as? String else {
            return
        }
        let requestID = payload["request_id"] as? String ?? UUID().uuidString

        if commandName == "ping" {
            await sendJSONObject([
                "type": "pong",
                "device_id": deviceID,
                "request_id": requestID
            ])
            return
        }

        guard let envelope = parseCommandEnvelope(commandName: commandName,
                                                  payload: payload,
                                                  requestID: requestID) else {
            await sendAck(requestID: requestID, reply: .failure("Invalid command payload."))
            return
        }

        guard let commandHandler else {
            await sendAck(requestID: requestID, reply: .failure("Command handler unavailable."))
            return
        }

        let reply = await commandHandler(envelope)
        await sendAck(requestID: requestID, reply: reply)
        await sendStatus()
    }

    private func handleTimeSyncPayload(_ payload: [String: Any]) {
        guard let packet = parseTimeSyncPacket(payload) else { return }
        updateClockOffsetEstimate(usingDirectorUnixMilliseconds: packet.directorUnixMilliseconds)
        timeSyncHandler?(packet)
    }

    private func parseTimeSyncPacket(_ payload: [String: Any]) -> DirectorTimeSyncPacket? {
        guard let unixMS = int64Value(payload["unix_ms"]) else { return nil }
        let sequence = int64Value(payload["seq"])
        let source = (payload["source"] as? String) ?? "director"

        var parsedTimecode: TentacleTimecode?
        if let fps = intValue(payload["fps"]),
           let hours = intValue(payload["hours"]),
           let minutes = intValue(payload["minutes"]),
           let seconds = intValue(payload["seconds"]),
           let frames = intValue(payload["frames"]) {
            parsedTimecode = TentacleTimecode(fps: fps,
                                              hours: hours,
                                              minutes: minutes,
                                              seconds: seconds,
                                              frames: frames)
        } else {
            parsedTimecode = synthesizedTimecodeFromUnixMilliseconds(unixMS)
        }

        return DirectorTimeSyncPacket(directorUnixMilliseconds: unixMS,
                                      sequence: sequence,
                                      source: source,
                                      timecode: parsedTimecode)
    }

    private func synthesizedTimecodeFromUnixMilliseconds(_ unixMS: Int64) -> TentacleTimecode? {
        let defaultFPS = 30
        let date = Date(timeIntervalSince1970: Double(unixMS) / 1000.0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        guard let hours = components.hour,
              let minutes = components.minute,
              let seconds = components.second else {
            return nil
        }

        let nanoseconds = components.nanosecond ?? 0
        let frame = min(max(Int((Double(nanoseconds) / 1_000_000_000.0) * Double(defaultFPS)), 0), defaultFPS - 1)
        return TentacleTimecode(fps: defaultFPS,
                                hours: hours,
                                minutes: minutes,
                                seconds: seconds,
                                frames: frame)
    }

    private func updateClockOffsetEstimate(usingDirectorUnixMilliseconds directorUnixMS: Int64) {
        let localUnixMS = Self.unixNowMS()
        let sampleOffsetMS = Double(directorUnixMS - localUnixMS)
        clockOffsetSamplesMS.append(sampleOffsetMS)

        if clockOffsetSamplesMS.count > Self.maxClockOffsetSamples {
            let overflow = clockOffsetSamplesMS.count - Self.maxClockOffsetSamples
            clockOffsetSamplesMS.removeFirst(overflow)
        }
        estimatedClockOffsetMS = median(clockOffsetSamplesMS)
    }

    private func parseCommandEnvelope(commandName: String,
                                      payload: [String: Any],
                                      requestID: String) -> RemoteDirectorCommandEnvelope? {
        let command: RemoteDirectorCommand
        switch commandName {
        case "arm":
            command = .arm
        case "arm_idle", "set_idle":
            command = .armIdle
        case "prepare_start":
            guard let sessionID = payload["session_id"] as? String,
                  let startAtUnixMS = int64Value(payload["start_at_unix_ms"]) else { return nil }
            command = .prepareStart(sessionID: sessionID, startAtUnixMS: startAtUnixMS)
        case "commit_start":
            guard let sessionID = payload["session_id"] as? String,
                  let startAtUnixMS = int64Value(payload["start_at_unix_ms"]) else { return nil }
            command = .commitStart(sessionID: sessionID, startAtUnixMS: startAtUnixMS)
        case "prepare_stop":
            let sessionID = payload["session_id"] as? String ?? "unknown-session"
            guard let stopAtUnixMS = int64Value(payload["stop_at_unix_ms"]) else { return nil }
            command = .prepareStop(sessionID: sessionID, stopAtUnixMS: stopAtUnixMS)
        case "prepare_recording":
            command = .prepareRecording(sessionID: payload["session_id"] as? String)
        case "start_recording":
            command = .startRecording(sessionID: payload["session_id"] as? String,
                                      startAtUnixMS: int64Value(payload["start_at_unix_ms"]))
        case "stop_recording":
            command = .stopRecording(sessionID: payload["session_id"] as? String,
                                     stopAtUnixMS: int64Value(payload["stop_at_unix_ms"]))
        case "get_status":
            command = .getStatus
        case "set_brightness":
            guard let brightness = doubleValue(payload["brightness"]) ?? doubleValue(payload["value"]) else {
                return nil
            }
            command = .setBrightness(brightness)
        case "pull_videos":
            let jobID = (payload["job_id"] as? String).flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? UUID().uuidString
            let policy = (payload["policy"] as? String) ?? "new_only"
            let maxFiles = max(0, intValue(payload["max_files"]) ?? 0)
            let uploadURL = payload["upload_url"] as? String
            command = .pullVideos(jobID: jobID,
                                  policy: policy,
                                  maxFiles: maxFiles,
                                  uploadURL: uploadURL)
        case "delete_uploaded_videos", "delete_uploaded_local_videos", "cleanup_uploaded_videos":
            command = .deleteLocalVideos(policy: .uploadedOnly)
        case "force_delete_videos", "force_delete_local_videos", "delete_all_videos":
            command = .deleteLocalVideos(policy: .forceAll)
        case "set_capture_mode", "apply_capture_mode":
            let rawMode = (payload["mode"] as? String) ?? (payload["capture_mode"] as? String) ?? ""
            guard let preset = VideoCaptureModePreset(rawValue: rawMode) else { return nil }
            command = .setCaptureMode(preset)
        case "capture_preview_photo":
            let batchID = (payload["batch_id"] as? String).flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? "preview-\(UUID().uuidString)"
            let uploadURL = payload["upload_url"] as? String
            let longEdge = intValue(payload["long_edge"]) ?? 1280
            let jpegQuality = doubleValue(payload["jpeg_quality"]) ?? 0.65
            let uploadJitterSeconds = max(0, doubleValue(payload["upload_jitter_seconds"]) ?? 0)
            let attempt = max(1, intValue(payload["attempt"]) ?? 1)
            command = .capturePreviewPhoto(batchID: batchID,
                                           uploadURL: uploadURL,
                                           longEdge: longEdge,
                                           jpegQuality: jpegQuality,
                                           uploadJitterSeconds: uploadJitterSeconds,
                                           attempt: attempt)
        case "export_camera_params":
            command = .exportCameraParams
        case "apply_camera_params":
            guard let presetObject = payload["preset"],
                  let profile = decodeManualLockProfile(from: presetObject) else { return nil }
            let dryRun = boolValue(payload["dry_run"]) ?? false
            command = .applyCameraParams(profile: profile, dryRun: dryRun)
        case "validate_camera_params":
            command = .validateCameraParams
        case "set_focus_mode", "set_autofocus", "enable_auto_focus":
            let rawMode = ((payload["mode"] as? String)
                           ?? (payload["focus_mode"] as? String)
                           ?? ((boolValue(payload["enabled"]) ?? true) ? "continuous_auto_focus" : "locked"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let normalizedMode: String
            switch rawMode {
            case "continuous_auto_focus", "continuousautofocus", "continuous", "auto_focus", "autofocus", "auto":
                normalizedMode = "continuous_auto_focus"
            case "locked", "lock", "focus_locked", "manual", "manual_focus":
                normalizedMode = "locked"
            default:
                return nil
            }
            command = .setFocusMode(normalizedMode)
        case "lock_focus", "disable_auto_focus":
            command = .setFocusMode("locked")
        case "toggle_focus_mode", "toggle_auto_focus":
            command = .setFocusMode("toggle_auto_focus")
        case "release_camera_param_locks", "release_camera_params", "unlock_camera_params":
            let preserveFocus = boolValue(payload["preserve_focus"]) ?? true
            command = .releaseCameraParamLocks(preserveFocus: preserveFocus)
        case "lock_camera_param_locks", "lock_camera_params":
            command = .lockCameraParamLocks
        case "toggle_camera_param_locks", "toggle_camera_params", "toggle_camera_locks":
            let preserveFocus = boolValue(payload["preserve_focus"]) ?? true
            command = .toggleCameraParamLocks(preserveFocus: preserveFocus)
        default:
            return nil
        }

        return RemoteDirectorCommandEnvelope(requestID: requestID, command: command)
    }

    private func sendAck(requestID: String, reply: RemoteDirectorCommandReply) async {
        var object: [String: Any] = [
            "type": "ack",
            "device_id": deviceID,
            "request_id": requestID,
            "ok": reply.ok,
            "detail": reply.detail
        ]
        if let payload = reply.payload {
            object["payload"] = payload
        }
        await sendJSONObject(object)
    }

    private func sendJSONObject(_ object: [String: Any]) async {
        guard let webSocketTask else { return }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("Unable to encode remote director payload.")
            return
        }

        do {
            try await webSocketTask.send(.string(text))
        } catch {
            logger.error("Unable to send remote director payload: \(error.localizedDescription, privacy: .public)")
            handleDisconnectAndReconnect()
        }
    }

    private func directorURL() -> URL? {
        // Disable remote control in extensions; run only in the app.
        guard Bundle.main.bundleURL.pathExtension != "appex" else { return nil }

        if let defaultsURL = UserDefaults.standard.string(forKey: RemoteDirectorConfiguration.directorWebSocketURLDefaultsKey),
           !defaultsURL.isEmpty,
           let url = URL(string: defaultsURL) {
            return url
        }

        if let environmentURL = ProcessInfo.processInfo.environment["DIRECTOR_WS_URL"],
           !environmentURL.isEmpty,
           let url = URL(string: environmentURL) {
            return url
        }

        if let infoURL = Bundle.main.object(forInfoDictionaryKey: RemoteDirectorConfiguration.directorWebSocketURLInfoKey) as? String,
           !infoURL.isEmpty,
           let url = URL(string: infoURL) {
            return url
        }

        return URL(string: RemoteDirectorConfiguration.defaultDirectorWebSocketURL)
    }

    private static func loadOrCreateDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDDefaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIDDefaultsKey)
        return generated
    }

    private static func bundleInfoString(forKey key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return "unknown"
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    private static func formatAppDisplayVersion(version: String, build: String) -> String {
        switch (version == "unknown", build == "unknown") {
        case (false, false):
            return build == version ? version : "\(version) (\(build))"
        case (false, true):
            return version
        case (true, false):
            return "build \(build)"
        case (true, true):
            return "unknown"
        }
    }

    private static func unixNowMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        if let value = value as? String {
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Int64 {
            return Int(exactly: value)
        }
        if let value = value as? Double {
            return Int(value)
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Float {
            return Double(value)
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? Int64 {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func decodeManualLockProfile(from object: Any) -> ManualLockProfile? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return try? JSONDecoder().decode(ManualLockProfile.self, from: data)
    }

    private func resolvedDeviceName() -> String {
        let candidate = deviceNameProvider?().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? UIDevice.current.name : candidate
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

extension UIDevice {
    var batteryLevelNormalized: Double? {
        let level = batteryLevel
        guard level >= 0 else { return nil }
        return Double(level)
    }
}

extension FileManager {
    var availableStorageGB: Double? {
        do {
            let values = try URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let bytes = values.volumeAvailableCapacityForImportantUsage {
                return Double(bytes) / 1_000_000_000.0
            }
        } catch {
            return nil
        }
        return nil
    }
}
