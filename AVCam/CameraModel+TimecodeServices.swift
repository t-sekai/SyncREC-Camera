/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Timecode input services for CameraModel.
*/

import Foundation
import CoreBluetooth

enum TimecodeInputConfiguration {
    static let modeDefaultsKey = "TimecodeInputMode"
}

enum TimecodeInputModeSetting: String {
    case auto = "auto"
    case tentacleBLE = "tentacle_ble"
    case directorLAN = "director_lan"
}

enum ResolvedTimecodeInputMode {
    case tentacleBLE
    case directorLAN

    var sourceIdentifier: String {
        switch self {
        case .tentacleBLE:
            return "tentacle_sync_e"
        case .directorLAN:
            return "director_lan_tentacle_sync_e"
        }
    }
}

struct DirectorTimeSyncPacket: Sendable {
    let directorUnixMilliseconds: Int64
    let sequence: Int64?
    let source: String
    let timecode: TentacleTimecode?
}

@MainActor
final class DirectorLANTimecodeService {

    var onUpdate: ((TentacleConnectionState, TentacleTimecode?) -> Void)?

    private static let staleThresholdSeconds: TimeInterval = 3.0
    private static let pollIntervalNanoseconds: UInt64 = 250_000_000

    private var isStarted = false
    private var staleMonitorTask: Task<Void, Never>?
    private var lastPacketUptime: TimeInterval?

    private var connectionState = TentacleConnectionState.idle {
        didSet {
            guard connectionState != oldValue else { return }
            publish()
        }
    }

    private var latestTimecode: TentacleTimecode? {
        didSet {
            guard latestTimecode != oldValue else { return }
            publish()
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lastPacketUptime = nil
        latestTimecode = nil
        connectionState = .scanning
        startStaleMonitorIfNeeded()
    }

    func stop() {
        isStarted = false
        staleMonitorTask?.cancel()
        staleMonitorTask = nil
        lastPacketUptime = nil
        latestTimecode = nil
        connectionState = .idle
    }

    func ingest(_ packet: DirectorTimeSyncPacket) {
        guard isStarted else { return }

        if let timecode = packet.timecode {
            lastPacketUptime = ProcessInfo.processInfo.systemUptime
            latestTimecode = timecode
            connectionState = .connected("Director LAN")
        } else if connectionState == .idle {
            connectionState = .scanning
        }
    }

    private func startStaleMonitorIfNeeded() {
        guard staleMonitorTask == nil else { return }
        staleMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                guard let self else { return }
                self.evaluateFreshness()
            }
        }
    }

    private func evaluateFreshness() {
        guard isStarted else { return }
        guard let lastPacketUptime else {
            if connectionState != .scanning {
                connectionState = .scanning
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if (now - lastPacketUptime) > Self.staleThresholdSeconds {
            latestTimecode = nil
            connectionState = .reconnecting("Director LAN")
        }
    }

    private func publish() {
        onUpdate?(connectionState, latestTimecode)
    }
}

final class TentacleTimecodeService: NSObject {

    var onUpdate: ((TentacleConnectionState, TentacleTimecode?) -> Void)?

    private let timecodeCharacteristicUUID = CBUUID(string: "0dab144c-2cb9-11e6-b67b-9e71128cae77")
    private let preferredNames = ["neurok", "tentacle", "sync e"]
    private static let preferredPeripheralIdentifierDefaultsKey = "TentaclePreferredPeripheralIdentifier"
    private static let preferredPeripheralGracePeriodSeconds: TimeInterval = 4.0
    private static let minReconnectBackoffSeconds: TimeInterval = 0.5
    private static let maxReconnectBackoffSeconds: TimeInterval = 8.0
    private static let reconnectJitterRatio = 0.2

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var isScanning = false
    private var isStarted = false
    private var scanStartUptime: TimeInterval = 0
    private var pendingServiceUUIDs = Set<CBUUID>()
    private var didFindTimecodeCharacteristic = false
    private var pendingRescanWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var preferredPeripheralIdentifier: UUID?

    private var connectionState = TentacleConnectionState.idle {
        didSet {
            guard connectionState != oldValue else { return }
            publish()
        }
    }

    private var latestTimecode: TentacleTimecode? {
        didSet {
            guard latestTimecode != oldValue else { return }
            publish()
        }
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
        if let rawIdentifier = UserDefaults.standard.string(forKey: Self.preferredPeripheralIdentifierDefaultsKey),
           let identifier = UUID(uuidString: rawIdentifier) {
            preferredPeripheralIdentifier = identifier
        }
    }

    func start() {
        isStarted = true
        cancelPendingRescan()
        handleBluetoothState(centralManager.state)
    }

    func stop() {
        isStarted = false
        cancelPendingRescan()
        stopScan()
        if let connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        reconnectAttempt = 0
        pendingServiceUUIDs.removeAll()
        didFindTimecodeCharacteristic = false
        latestTimecode = nil
        connectionState = .idle
    }

    private func handleBluetoothState(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            guard isStarted else { return }
            cancelPendingRescan()
            startScanIfNeeded()
        case .unauthorized:
            stopScan()
            cancelPendingRescan()
            connectedPeripheral = nil
            pendingServiceUUIDs.removeAll()
            didFindTimecodeCharacteristic = false
            connectionState = .unauthorized
        case .unsupported:
            stopScan()
            cancelPendingRescan()
            connectedPeripheral = nil
            pendingServiceUUIDs.removeAll()
            didFindTimecodeCharacteristic = false
            connectionState = .bluetoothUnavailable
        case .poweredOff:
            stopScan()
            cancelPendingRescan()
            connectedPeripheral = nil
            pendingServiceUUIDs.removeAll()
            didFindTimecodeCharacteristic = false
            connectionState = .bluetoothUnavailable
        case .resetting, .unknown:
            stopScan()
            cancelPendingRescan()
            connectedPeripheral = nil
            pendingServiceUUIDs.removeAll()
            didFindTimecodeCharacteristic = false
            connectionState = .idle
        @unknown default:
            stopScan()
            cancelPendingRescan()
            connectedPeripheral = nil
            pendingServiceUUIDs.removeAll()
            didFindTimecodeCharacteristic = false
            connectionState = .idle
        }
    }

    private func startScanIfNeeded(reconnectingDeviceName: String? = nil) {
        guard isStarted, centralManager.state == .poweredOn else { return }
        guard connectedPeripheral == nil else { return }
        guard !isScanning else { return }

        isScanning = true
        scanStartUptime = ProcessInfo.processInfo.systemUptime
        centralManager.scanForPeripherals(withServices: nil, options: nil)

        if let reconnectingDeviceName {
            connectionState = .reconnecting(reconnectingDeviceName)
        } else {
            connectionState = .scanning
        }
    }

    private func stopScan() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
    }

    private func scheduleRescan(reconnectingDeviceName: String?) {
        guard isStarted, centralManager.state == .poweredOn else { return }

        cancelPendingRescan()

        let clampedAttempt = min(reconnectAttempt, 5)
        let exponentialBackoff = Self.minReconnectBackoffSeconds * pow(2.0, Double(clampedAttempt))
        let cappedDelay = min(exponentialBackoff, Self.maxReconnectBackoffSeconds)
        let jitter = cappedDelay * Self.reconnectJitterRatio
        let randomizedDelay = max(0.15, cappedDelay + Double.random(in: -jitter...jitter))
        reconnectAttempt += 1

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRescanWorkItem = nil
            self.startScanIfNeeded(reconnectingDeviceName: reconnectingDeviceName)
        }
        pendingRescanWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + randomizedDelay, execute: workItem)
    }

    private func cancelPendingRescan() {
        pendingRescanWorkItem?.cancel()
        pendingRescanWorkItem = nil
    }

    private func updateConnectedDeviceState(for peripheral: CBPeripheral) {
        connectionState = .connected(deviceName(for: peripheral))
        reconnectAttempt = 0
        preferredPeripheralIdentifier = peripheral.identifier
        UserDefaults.standard.set(peripheral.identifier.uuidString,
                                  forKey: Self.preferredPeripheralIdentifierDefaultsKey)
    }

    private func connect(_ peripheral: CBPeripheral) {
        stopScan()
        cancelPendingRescan()
        connectedPeripheral = peripheral
        latestTimecode = nil
        peripheral.delegate = self
        connectionState = .connecting(deviceName(for: peripheral))
        centralManager.connect(peripheral, options: nil)
    }

    private func disconnectAndRescan(with state: TentacleConnectionState,
                                     clearTimecode: Bool,
                                     reconnectingDeviceName: String? = nil) {
        if clearTimecode {
            latestTimecode = nil
        }
        connectionState = state
        let reconnectingName = reconnectingDeviceName ?? connectedPeripheral.map(deviceName(for:))
        if let connectedPeripheral, connectedPeripheral.state != .disconnected {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        stopScan()
        scheduleRescan(reconnectingDeviceName: reconnectingName)
    }

    private func decodeTentacleTimecode(_ data: Data) -> TentacleTimecode? {
        TentacleTimecode(payload: data)
    }

    private func shouldUsePeripheral(_ peripheral: CBPeripheral, advertisementName: String?) -> Bool {
        if let preferredPeripheralIdentifier {
            if peripheral.identifier == preferredPeripheralIdentifier {
                return true
            }

            let elapsedScanTime = max(0, ProcessInfo.processInfo.systemUptime - scanStartUptime)
            if elapsedScanTime < Self.preferredPeripheralGracePeriodSeconds {
                return false
            }
        }

        let candidates = [peripheral.name, advertisementName]
            .compactMap { $0?.lowercased() }
        return candidates.contains(where: isPreferredDeviceName(_:))
    }

    private func isPreferredDeviceName(_ name: String) -> Bool {
        preferredNames.contains(where: { name.contains($0) })
    }

    private func deviceName(for peripheral: CBPeripheral) -> String {
        peripheral.name ?? "Tentacle"
    }

    private func publish() {
        onUpdate?(connectionState, latestTimecode)
    }

    private func completeCharacteristicDiscovery(for service: CBService) {
        pendingServiceUUIDs.remove(service.uuid)
        if pendingServiceUUIDs.isEmpty && !didFindTimecodeCharacteristic {
            disconnectAndRescan(with: .failed("Tentacle timecode characteristic not found"),
                                clearTimecode: false)
        }
    }
}

extension TentacleTimecodeService: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothState(central.state)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard connectedPeripheral == nil else { return }
        let advertisementName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard shouldUsePeripheral(peripheral, advertisementName: advertisementName) else { return }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pendingServiceUUIDs.removeAll()
        didFindTimecodeCharacteristic = false
        updateConnectedDeviceState(for: peripheral)
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: (any Error)?) {
        disconnectAndRescan(with: .failed(error?.localizedDescription ?? "Failed to connect"),
                            clearTimecode: false)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: (any Error)?) {
        let connectionName = deviceName(for: peripheral)
        let nextState: TentacleConnectionState
        if let error {
            nextState = .failed(error.localizedDescription)
        } else {
            nextState = .reconnecting(connectionName)
        }
        disconnectAndRescan(with: nextState,
                            clearTimecode: false,
                            reconnectingDeviceName: connectionName)
    }
}

extension TentacleTimecodeService: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        if let error {
            disconnectAndRescan(with: .failed(error.localizedDescription), clearTimecode: false)
            return
        }

        guard let services = peripheral.services, !services.isEmpty else {
            disconnectAndRescan(with: .failed("No GATT services available"), clearTimecode: false)
            return
        }

        pendingServiceUUIDs = Set(services.map(\.uuid))
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: (any Error)?) {
        if let error {
            disconnectAndRescan(with: .failed(error.localizedDescription), clearTimecode: false)
            return
        }

        guard let characteristics = service.characteristics else {
            completeCharacteristicDiscovery(for: service)
            return
        }
        for characteristic in characteristics where characteristic.uuid == timecodeCharacteristicUUID {
            didFindTimecodeCharacteristic = true
            peripheral.setNotifyValue(true, for: characteristic)
            peripheral.readValue(for: characteristic)
        }
        completeCharacteristicDiscovery(for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard characteristic.uuid == timecodeCharacteristicUUID else { return }
        if let error {
            disconnectAndRescan(with: .failed(error.localizedDescription), clearTimecode: false)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard characteristic.uuid == timecodeCharacteristicUUID else { return }
        guard error == nil else {
            if let error {
                disconnectAndRescan(with: .failed(error.localizedDescription), clearTimecode: false)
            }
            return
        }
        guard let data = characteristic.value, let timecode = decodeTentacleTimecode(data) else { return }
        reconnectAttempt = 0
        latestTimecode = timecode
    }
}
