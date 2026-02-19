import SwiftUI
import Combine
import CoreBluetooth
import UIKit

// MARK: - Device row model
struct DeviceItem: Identifiable, Hashable {
    let id: String              // peripheral.identifier.uuidString (stable)
    let name: String
    let rssi: Int
    let advertisesHR: Bool
    let peripheral: CBPeripheral
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Log model with unique identity + coalescing
struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var count: Int = 1
    var timestamp: Date = .now
}

enum AppMode {
    case discovery
    case monitoring
}

struct UserNotice: Identifiable, Hashable {
    let id = UUID()
    let message: String
}

private struct HeartRatePoint {
    let timestamp: Date
    let bpm: Int
}

final class HRBluetooth: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let objectWillChange = ObservableObjectPublisher()

    @Published var devices: [DeviceItem] = []
    @Published var status: String = "Waiting for Bluetooth…"
    @Published var heartRate: Int? = nil
    @Published var connectedName: String? = nil
    @Published var isScanning: Bool = false
    @Published var scanAll: Bool = false
    @Published var logs: [LogEntry] = []
    @Published var mode: AppMode = .discovery
    @Published var average1Minute: Double? = nil
    @Published var average5Minutes: Double? = nil
    @Published var notice: UserNotice? = nil

    private var central: CBCentralManager!
    private var connected: CBPeripheral?
    private var devicesByID: [String: DeviceItem] = [:]
    private var seenIDsThisScan: Set<String> = []

    // ---------- Persistent storage (Documents) ----------
    private var sessionStart: Date?
    private var sessionFileURL: URL?           // Documents/hr_session_current.txt
    private var sessionHandle: FileHandle?
    private var sampleTimer: DispatchSourceTimer?
    private var sampleCounter: Int = 0
    private var lastKnownBPM: Int = -1
    private var hadUpdateSinceLastSample: Bool = false
    private var isManuallyEndingSession = false
    private var hrHistory: [HeartRatePoint] = []

    // global rolling log
    private var globalLogHandle: FileHandle?

    // ---------- BLE UUIDs ----------
    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    private let restoreID = "com.yourname.hrmonitor.central" // stable
    private let currentSessionFileName = "hr_session_current.txt"

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreID]
        )

        startGlobalLog() // open rolling log immediately
        recoverCurrentSessionFileIfNeeded(reason: "startup", shouldNotify: true)
        logLine("Central created, waiting for state…")

        // Self-check prints
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] {
            logLine("UIBackgroundModes: \(modes)")
        } else { logLine("UIBackgroundModes missing") }

        if Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") == nil {
            logLine("NSBluetoothAlwaysUsageDescription is MISSING")
        }
    }

    // MARK: - Paths (Documents)
    private func documentsDir() throws -> URL {
        let url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    private func notifyUser(_ message: String) {
        notice = UserNotice(message: message)
    }

    // MARK: - Global rolling log
    private func startGlobalLog() {
        do {
            let dir = try documentsDir()
            let url = dir.appendingPathComponent("hr_app_log.txt")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            globalLogHandle = try FileHandle(forWritingTo: url)
            try globalLogHandle?.seekToEnd()
            writeGlobal("==== App start \(ISO8601DateFormatter().string(from: Date())) ====")
        } catch {
            print("Global log open error:", error.localizedDescription)
        }
    }

    private func writeGlobal(_ s: String) {
        guard let h = globalLogHandle else { return }
        let iso = ISO8601DateFormatter()
        let line = "[\(iso.string(from: Date()))] \(s)\n"
        do { try h.write(contentsOf: Data(line.utf8)) } catch { print("Global log write error:", error.localizedDescription) }
    }

    func flushFiles() {
        do { try sessionHandle?.synchronize() } catch { print("session sync error:", error.localizedDescription) }
        do { try globalLogHandle?.synchronize() } catch { print("global log sync error:", error.localizedDescription) }
    }

    // MARK: - Filenames / migration
    private func timestampStem(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: date)
    }

    private func modificationDate(for fileURL: URL) -> Date {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let modified = attrs[.modificationDate] as? Date {
            return modified
        }
        return Date()
    }

    private func uniqueSessionDestination(in dir: URL, baseDate: Date) -> URL {
        let base = "hrmonitor_\(timestampStem(for: baseDate))"
        var candidate = dir.appendingPathComponent("\(base).txt")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(suffix).txt")
            suffix += 1
        }
        return candidate
    }

    @discardableResult
    private func recoverCurrentSessionFileIfNeeded(reason: String, shouldNotify: Bool) -> String? {
        do {
            let dir = try documentsDir()
            let current = dir.appendingPathComponent(currentSessionFileName)
            guard FileManager.default.fileExists(atPath: current.path) else { return nil }

            let recoveredDate = modificationDate(for: current)
            let destination = uniqueSessionDestination(in: dir, baseDate: recoveredDate)
            try FileManager.default.moveItem(at: current, to: destination)

            let message = "Recovered temp session on \(reason): \(destination.lastPathComponent)"
            logLine(message)
            if shouldNotify {
                notifyUser("Recovered unsaved data as \(destination.lastPathComponent).")
            }
            return destination.lastPathComponent
        } catch {
            logLine("Recover temp session error: \(error.localizedDescription)")
            return nil
        }
    }

    private func resetSessionState() {
        sessionFileURL = nil
        sessionStart = nil
        sessionHandle = nil
        sampleCounter = 0
    }

    private func resetMonitoringMetrics() {
        heartRate = nil
        lastKnownBPM = -1
        hadUpdateSinceLastSample = false
        average1Minute = nil
        average5Minutes = nil
        hrHistory.removeAll()
    }

    // MARK: - Session data file
    private func startSessionFileIfNeeded() {
        guard sessionHandle == nil else { return }
        sessionStart = Date()
        do {
            let dir = try documentsDir()
            recoverCurrentSessionFileIfNeeded(reason: "before_new_session", shouldNotify: false)

            let url = dir.appendingPathComponent(currentSessionFileName)
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            FileManager.default.createFile(atPath: url.path, contents: nil)
            sessionFileURL = url
            sessionHandle = try FileHandle(forWritingTo: url)
            // header with third column 'Fresh' (1=new value this second; 0=reused)
            let header = "ISO8601,BPM,Fresh\n"
            try sessionHandle?.write(contentsOf: Data(header.utf8))
            writeGlobal("Session file started: \(url.lastPathComponent)")
            logLine("Session file started: \(url.lastPathComponent)")
        } catch {
            logLine("Session file error: \(error.localizedDescription)")
            writeGlobal("Session file error: \(error.localizedDescription)")
            sessionFileURL = nil
            sessionHandle = nil
        }
    }

    private func appendSampleToFile(bpm: Int, fresh: Bool) {
        startSessionFileIfNeeded()
        guard let handle = sessionHandle else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(iso.string(from: Date())),\(bpm),\(fresh ? 1 : 0)\n"
        do {
            try handle.write(contentsOf: Data(line.utf8))
            sampleCounter += 1
            if sampleCounter % 30 == 0 { try handle.synchronize() } // flush every ~30s
        } catch {
            logLine("Data write error: \(error.localizedDescription)")
            writeGlobal("Data write error: \(error.localizedDescription)")
        }
    }

    private func closeSessionFile() {
        do { try sessionHandle?.synchronize() } catch { }
        try? sessionHandle?.close()
        sessionHandle = nil
    }

    // Rename current session file to timestamped final name in Documents
    @discardableResult
    private func finalizeSessionFile(shouldNotify: Bool) -> String? {
        closeSessionFile()
        do {
            let dir = try documentsDir()
            let source: URL
            if let url = sessionFileURL {
                source = url
            } else {
                let currentURL = dir.appendingPathComponent(currentSessionFileName)
                guard FileManager.default.fileExists(atPath: currentURL.path) else {
                    resetSessionState()
                    return nil
                }
                source = currentURL
            }

            let baseDate = sessionStart ?? modificationDate(for: source)
            let dest = uniqueSessionDestination(in: dir, baseDate: baseDate)
            try FileManager.default.moveItem(at: source, to: dest)
            logLine("Session saved: \(dest.lastPathComponent)")
            if shouldNotify {
                notifyUser("Session saved: \(dest.lastPathComponent)")
            }
            resetSessionState()
            return dest.lastPathComponent
        } catch {
            logLine("Finalize error: \(error.localizedDescription)")
            if shouldNotify {
                notifyUser("Save failed: \(error.localizedDescription)")
            }
            resetSessionState()
            return nil
        }
    }

    // MARK: - 1 Hz sampler (even across disconnects)
    private func startSamplingTimerIfNeeded() {
        guard sampleTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let bpm = self.lastKnownBPM
            let fresh = self.hadUpdateSinceLastSample
            self.appendSampleToFile(bpm: bpm, fresh: fresh)
            self.hadUpdateSinceLastSample = false
        }
        t.resume()
        sampleTimer = t
        writeGlobal("Sampling timer started (1 Hz)")
    }

    private func stopSamplingTimer() {
        sampleTimer?.cancel()
        sampleTimer = nil
        writeGlobal("Sampling timer stopped")
    }

    // MARK: - HR averages
    private func recalculateAverages(now: Date) {
        let oneMinuteAgo = now.addingTimeInterval(-60)
        let fiveMinutesAgo = now.addingTimeInterval(-300)

        let oneMinuteValues = hrHistory.filter { $0.timestamp >= oneMinuteAgo }.map(\.bpm)
        let fiveMinuteValues = hrHistory.filter { $0.timestamp >= fiveMinutesAgo }.map(\.bpm)

        average1Minute = oneMinuteValues.isEmpty
            ? nil
            : Double(oneMinuteValues.reduce(0, +)) / Double(oneMinuteValues.count)
        average5Minutes = fiveMinuteValues.isEmpty
            ? nil
            : Double(fiveMinuteValues.reduce(0, +)) / Double(fiveMinuteValues.count)
    }

    private func addHeartRateToHistory(_ bpm: Int) {
        let now = Date()
        hrHistory.append(HeartRatePoint(timestamp: now, bpm: bpm))
        let trimDate = now.addingTimeInterval(-305)
        hrHistory.removeAll { $0.timestamp < trimDate }
        recalculateAverages(now: now)
    }

    // MARK: - Logging helpers (UI + file)
    private func logLine(_ s: String) {
        print(s)
        writeGlobal(s)
        if var last = logs.last, last.text == s {
            last.count += 1
            last.timestamp = .now
            logs[logs.count - 1] = last
        } else {
            logs.append(LogEntry(text: s))
            if logs.count > 300 { logs.removeFirst(100) }
        }
        objectWillChange.send()
    }

    // MARK: - Scanning
    func startScanning() {
        guard mode == .discovery else { return }
        guard central.state == .poweredOn else {
            status = "Bluetooth not ready (\(central.state.rawValue))."
            isScanning = false
            logLine("Cannot scan; state=\(central.state.rawValue)")
            objectWillChange.send(); return
        }
        if isScanning { return }
        devicesByID.removeAll(); devices = []; seenIDsThisScan.removeAll()
        status = scanAll ? "Scanning (ALL devices)..." : "Scanning (Heart Rate service)…"
        logLine("Start scan; filter: \(scanAll ? "nil" : "180D")")
        central.scanForPeripherals(withServices: scanAll ? nil : [hrService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        objectWillChange.send()
    }

    func stopScanning() {
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        if connected == nil { status = "Idle" }
        logLine("Stopped scanning")
        objectWillChange.send()
    }

    // MARK: - Connect/Disconnect
    func connect(to item: DeviceItem) {
        mode = .monitoring
        stopScanning()
        connected = item.peripheral
        connected?.delegate = self
        connectedName = item.name
        resetMonitoringMetrics()
        status = "Connecting to \(item.name)…"
        logLine("Connecting to \(item.name) [\(item.id)]")
        central.connect(item.peripheral, options: nil)
        objectWillChange.send()
    }

    func stopMonitoring() {
        guard mode == .monitoring else { return }
        isManuallyEndingSession = true
        stopScanning()
        stopSamplingTimer()
        flushFiles()
        if let p = connected { central.cancelPeripheralConnection(p) }
        connected = nil
        connectedName = nil
        status = "Monitoring stopped."
        mode = .discovery
        resetMonitoringMetrics()

        if finalizeSessionFile(shouldNotify: true) == nil {
            notifyUser("Monitoring stopped. No session file was found.")
        }

        isManuallyEndingSession = false
        objectWillChange.send()
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:  status = "Bluetooth ON";             logLine("central.state = poweredOn")
        case .unauthorized: status = "Bluetooth permission denied. Enable in Settings."; logLine("central.state = unauthorized")
        case .poweredOff: status = "Turn Bluetooth ON.";       logLine("central.state = poweredOff")
        case .resetting:  status = "Resetting Bluetooth…";     logLine("central.state = resetting")
        case .unsupported:status = "BLE unsupported on this device."; logLine("central.state = unsupported")
        case .unknown:    status = "Bluetooth state unknown."; logLine("central.state = unknown")
        @unknown default: status = "Bluetooth state: \(central.state.rawValue)"; logLine("central.state = \(central.state.rawValue)")
        }
        objectWillChange.send()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        logLine("willRestoreState keys: \(Array(dict.keys))")
        // Keep session going across restores; timer keeps writing lastKnownBPM
        mode = .monitoring
        startSamplingTimerIfNeeded()
        startSessionFileIfNeeded()
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = restored.first {
            connected = p
            connected?.delegate = self
            connectedName = p.name ?? "Heart Rate Sensor"
            status = "Restored connection; discovering services…"
            p.discoverServices([hrService])
            objectWillChange.send()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown"
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasHR = serviceUUIDs.contains(hrService)
        let id = peripheral.identifier.uuidString

        if !seenIDsThisScan.contains(id) {
            logLine("Discovered: \(name)  RSSI=\(RSSI)  HRAdv=\(hasHR)  id=\(id)  services=\(serviceUUIDs.map{$0.uuidString})")
            seenIDsThisScan.insert(id)
        }

        let item = DeviceItem(id: id, name: name, rssi: RSSI.intValue, advertisesHR: hasHR, peripheral: peripheral)
        devicesByID[id] = item
        devices = devicesByID.values.sorted { $0.rssi > $1.rssi }
        objectWillChange.send()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Connected. Discovering services…"
        logLine("didConnect: \(peripheral.name ?? "Unknown")")
        startSamplingTimerIfNeeded()     // 1 Hz sampling
        startSessionFileIfNeeded()       // ensure file exists
        peripheral.discoverServices([hrService])
        objectWillChange.send()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Failed to connect."
        logLine("didFailToConnect: \(String(describing: error))")
        connected = nil
        connectedName = nil
        stopSamplingTimer()
        finalizeSessionFile(shouldNotify: false)
        mode = .discovery
        notifyUser("Connection failed. Please select a device again.")
        objectWillChange.send()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logLine("didDisconnect: \(peripheral.name ?? "Unknown"), error=\(String(describing: error))")
        connected = nil
        connectedName = nil
        if mode == .monitoring {
            status = "Disconnected. Stop monitoring to save the file."
        } else {
            status = "Disconnected."
        }
        objectWillChange.send()
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error {
            status = "Service discovery error: \(e.localizedDescription)"
            logLine("Service discovery error: \(e)")
            objectWillChange.send(); return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == hrService }) else {
            status = "Heart Rate service not found."
            logLine("Heart Rate service not found on \(peripheral.name ?? "Unknown")")
            objectWillChange.send(); return
        }
        peripheral.discoverCharacteristics([hrMeasurement], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let e = error {
            status = "Characteristic discovery error: \(e.localizedDescription)"
            logLine("Characteristic discovery error: \(e)")
            objectWillChange.send(); return
        }
        guard let ch = service.characteristics?.first(where: { $0.uuid == hrMeasurement }) else {
            status = "Heart Rate measurement not found."
            logLine("HR measurement (2A37) not found")
            objectWillChange.send(); return
        }
        peripheral.setNotifyValue(true, for: ch)
        status = "Receiving heart rate…"
        logLine("Subscribed to 2A37 notifications")
        objectWillChange.send()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { logLine("didUpdateValue error: \(e)"); return }
        guard characteristic.uuid == hrMeasurement,
              let data = characteristic.value, data.count >= 2 else { return }

        let flags = data[0]
        let bpm: Int
        if (flags & 0x01) == 0 && data.count >= 2 {
            bpm = Int(data[1])
        } else if data.count >= 3 {
            let v = UInt16(data[1]) | (UInt16(data[2]) << 8)
            bpm = Int(v)
        } else { return }

        heartRate = bpm
        lastKnownBPM = bpm
        hadUpdateSinceLastSample = true
        addHeartRateToHistory(bpm)
        logLine("HR = \(bpm) bpm")
        objectWillChange.send()
        // NOTE: the 1 Hz timer handles the actual file write so it always emits rows
    }
}

// MARK: - Root UI
struct HRRootView: View {
    @StateObject var ble = HRBluetooth()
    @State private var showLog = true

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack {
                    Text(ble.status).font(.callout).lineLimit(2)
                    Spacer()
                }

                if ble.mode == .discovery {
                    Toggle("Scan all devices (include non-HR devices)", isOn: $ble.scanAll)
                        .font(.subheadline)

                    HStack(spacing: 12) {
                        Button(action: {
                            ble.isScanning ? ble.stopScanning() : ble.startScanning()
                        }) {
                            if ble.isScanning {
                                Label("Stop Scan", systemImage: "stop.circle")
                            } else {
                                Label("Start Scan", systemImage: "dot.radiowaves.left.and.right")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    List(ble.devices) { item in
                        Button { ble.connect(to: item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.name).font(.headline)
                                    if item.advertisesHR {
                                        Text("HR")
                                            .font(.caption)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke())
                                    }
                                    Spacer()
                                    Text("\(item.rssi) dBm").font(.caption)
                                }
                                Text(item.id).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)

                    DisclosureGroup(isExpanded: $showLog) {
                        ScrollView {
                            LazyVStack(alignment: .leading) {
                                ForEach(ble.logs.suffix(60)) { entry in
                                    Text(entry.count > 1 ? "\(entry.text) ×\(entry.count)" : entry.text)
                                        .font(.caption.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                    } label: {
                        Text("Debug Log (last 60)").font(.footnote)
                    }
                    .padding(.top, 4)
                } else {
                    VStack(spacing: 14) {
                        Text(ble.connectedName ?? "Heart Rate Sensor")
                            .font(.headline)

                        Text(ble.heartRate.map { "\($0)" } ?? "--")
                            .font(.system(size: 60, weight: .bold, design: .rounded))
                        Text("BPM")
                            .font(.title3)
                            .foregroundColor(.secondary)

                        HStack(spacing: 12) {
                            VStack(spacing: 4) {
                                Text("Last 1 min avg")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(formatAverage(ble.average1Minute))
                                    .font(.title3.monospacedDigit())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(10)

                            VStack(spacing: 4) {
                                Text("Last 5 min avg")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(formatAverage(ble.average5Minutes))
                                    .font(.title3.monospacedDigit())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(10)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(10)
                        }

                        Button(role: .destructive) {
                            ble.stopMonitoring()
                        } label: {
                            Label("Stop Monitoring", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .navigationTitle("HR Monitor")
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                ble.flushFiles()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                ble.flushFiles()
            }
            .alert(item: $ble.notice) { notice in
                Alert(
                    title: Text("HR Monitor"),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func formatAverage(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f bpm", value)
    }
}
