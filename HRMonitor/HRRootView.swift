import SwiftUI
import Combine
import CoreBluetooth
import os
import UniformTypeIdentifiers
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

final class HRBluetooth: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let objectWillChange = ObservableObjectPublisher()

    @Published var devices: [DeviceItem] = []
    @Published var status: String = "Waiting for Bluetooth…"
    @Published var heartRate: Int? = nil
    @Published var connectedName: String? = nil
    @Published var isScanning: Bool = false
    @Published var scanAll: Bool = true
    @Published var logs: [LogEntry] = []

    private let log = Logger(subsystem: "com.yourname.hrmonitor", category: "BLE")
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

    // global rolling log
    private var globalLogURL: URL?             // Documents/hr_app_log.txt
    private var globalLogHandle: FileHandle?

    // ---------- BLE UUIDs ----------
    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    private let restoreID = "com.yourname.hrmonitor.central" // stable

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreID]
        )

        startGlobalLog() // open rolling log immediately
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

    // MARK: - Global rolling log
    private func startGlobalLog() {
        do {
            let dir = try documentsDir()
            let url = dir.appendingPathComponent("hr_app_log.txt")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            globalLogURL = url
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

    // MARK: - Session data file
    private func startSessionFileIfNeeded() {
        guard sessionHandle == nil else { return }
        sessionStart = Date()
        do {
            let dir = try documentsDir()
            let url = dir.appendingPathComponent("hr_session_current.txt")
            if FileManager.default.fileExists(atPath: url.path) {
                // overwrite any stale current session
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

    private func sessionSuggestedFilename() -> String {
        let d = sessionStart ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "hrmonitor_\(f.string(from: d)).txt"
    }

    // Rename current session file to timestamped final name in Documents
    private func finalizeSessionFile() {
        guard let url = sessionFileURL else { return }
        do {
            let dir = try documentsDir()
            let dest = dir.appendingPathComponent(sessionSuggestedFilename())
            // close before rename
            closeSessionFile()
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: url, to: dest)
            writeGlobal("Session finalized: \(dest.lastPathComponent)")
            logLine("Session saved: \(dest.lastPathComponent)")
        } catch {
            logLine("Finalize error: \(error.localizedDescription)")
            writeGlobal("Finalize error: \(error.localizedDescription)")
        }
        sessionFileURL = nil
        sessionStart = nil
        sampleCounter = 0
    }

    private func keepSessionFile() {
        // Leave hr_session_current.txt as-is (user can fetch it via Files)
        closeSessionFile()
        writeGlobal("Session kept as hr_session_current.txt")
        logLine("Session kept as hr_session_current.txt")
        sessionFileURL = nil
        sessionStart = nil
        sampleCounter = 0
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

    // MARK: - Connect/Disconnect (manual end uses endSession(save:))
    func connect(to item: DeviceItem) {
        stopScanning()
        connected = item.peripheral
        connected?.delegate = self
        connectedName = item.name
        heartRate = nil
        status = "Connecting to \(item.name)…"
        logLine("Connecting to \(item.name) [\(item.id)]")
        central.connect(item.peripheral, options: nil)
        objectWillChange.send()
    }

    func endSession(save: Bool) {
        // Manual end: stop scanning & timer, flush files, disconnect if needed
        isManuallyEndingSession = true
        stopScanning()
        stopSamplingTimer()
        flushFiles()
        if let p = connected { central.cancelPeripheralConnection(p) }
        connected = nil
        connectedName = nil
        heartRate = nil
        status = "Disconnected (manual)."
        if save { finalizeSessionFile() } else { keepSessionFile() }
        // Resume scanning for next device
        startScanning()
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
        objectWillChange.send()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logLine("didDisconnect: \(peripheral.name ?? "Unknown"), error=\(String(describing: error))")
        connected = nil
        connectedName = nil
        status = "Disconnected."
        // IMPORTANT: do NOT stop the timer or close the session here, so we keep writing 1 Hz
        // with Fresh=0 (reusing lastKnownBPM) during transient disconnects.
        if !isManuallyEndingSession {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startScanning()
            }
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
        logLine("HR = \(bpm) bpm")
        objectWillChange.send()
        // NOTE: the 1 Hz timer handles the actual file write so it always emits rows
    }
}

// MARK: - Root UI
struct HRRootView: View {
    @StateObject var ble = HRBluetooth()
    @State private var showLog = true
    @State private var showSaveDialog = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                // Status line
                HStack {
                    Text(ble.status).font(.callout).lineLimit(2)
                    Spacer()
                }

                // Controls
                Toggle("Scan all devices (not only Heart Rate)", isOn: $ble.scanAll)
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

                    if let name = ble.connectedName {
                        Button("Disconnect \(name)") {
                            showSaveDialog = true // ask to finalize/keep
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Big last-log line
                HStack {
                    let last = ble.logs.last
                    Text(last == nil ? "—" :
                         (last!.count > 1 ? "\(last!.text) ×\(last!.count)" : last!.text))
                        .font(.title3.monospaced())
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)

                // Device list
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

                // Live HR
                if let hr = ble.heartRate, let name = ble.connectedName {
                    VStack(spacing: 6) {
                        Text("Connected to \(name)").font(.subheadline)
                        Text("\(hr) ❤️ BPM").font(.system(size: 44, weight: .bold))
                    }
                    .padding(.top, 4)
                }

                // Collapsible full log
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
            }
            .padding()
            .navigationTitle("HR Monitor")
            .onAppear { if !ble.isScanning { ble.startScanning() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                ble.flushFiles()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                ble.flushFiles()
            }
            .confirmationDialog("Write session to file?", isPresented: $showSaveDialog, titleVisibility: .visible) {
                Button("Save (rename to timestamp)") {
                    ble.endSession(save: true)   // renames hr_session_current.txt → hrmonitor_YYYYMMDD_HHmmss.txt
                }
                Button("Don’t Save (keep current)", role: .destructive) {
                    ble.endSession(save: false)  // keeps hr_session_current.txt
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
}

