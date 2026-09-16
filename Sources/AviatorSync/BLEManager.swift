import Foundation
import CoreBluetooth

struct BLEDevice: Identifiable, Equatable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
    static func == (lhs: BLEDevice, rhs: BLEDevice) -> Bool { lhs.id == rhs.id && lhs.rssi == rhs.rssi }
}

struct ActivityDay: Identifiable, Codable, Hashable {
    let date: Date
    let steps: Int
    let calories: Int
    var id: Date { date }
}

@MainActor
final class BLEManager: NSObject, ObservableObject {
    @Published var devices: [BLEDevice] = []
    @Published var status = "Bluetooth inicializálása…"
    @Published var isScanning = false
    @Published var connectedID: UUID?
    @Published var bluetoothReady = false
    @Published var canSync = false
    @Published var batteryLevel: Int?
    @Published var batteryRaw: Int?
    @Published var activityDays: [ActivityDay] = []
    @Published var diagnosticLog: [String] = []

    private let distancePerStepKm: Double = 0.000726
    @Published var caloriesPerStep: Double = 0.04 {
        didSet { UserDefaults.standard.set(caloriesPerStep, forKey: "aviator.caloriesPerStep") }
    }

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private let serviceUUID = CBUUID(string: "00006006-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "00008001-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "00008002-0000-1000-8000-00805F9B34FB")

    private var awaitingCurrentStatus = false
    private var awaitingBattery = false
    private var currentStatusRequested = false
    private var manualDisconnect = false
    private var reconnectPeripheral: CBPeripheral?
    private let dayStoreKey = "aviator.activityDays.v4.iphone"

    override init() {
        super.init()
        let c = UserDefaults.standard.double(forKey: "aviator.caloriesPerStep")
        if c > 0 { caloriesPerStep = c }
        loadStoredDays()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func clearDevices() { devices.removeAll() }

    func startScan() {
        guard central.state == .poweredOn else {
            status = "A Bluetooth nincs bekapcsolva vagy még nem áll készen."
            return
        }
        devices.removeAll()
        isScanning = true
        status = "AVIATOR óra keresése…"
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
        if connectedPeripheral == nil { status = "Keresés leállítva." }
    }

    func connect(to peripheral: CBPeripheral) {
        manualDisconnect = false
        reconnectPeripheral = peripheral
        stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        status = "Csatlakozás: \(peripheral.name ?? "AVIATOR")…"
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        manualDisconnect = true
        reconnectPeripheral = nil
        guard let peripheral = connectedPeripheral else {
            status = "Nincs csatlakoztatott óra."
            return
        }
        central.cancelPeripheralConnection(peripheral)
        status = "Bluetooth kapcsolat bontása…"
    }

    func syncTime() {
        guard canWrite else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }
        let now = Date()
        let cal = Calendar.current
        let year = cal.component(.year, from: now)
        let bytes: [UInt8] = [
            0x6E, 0x01, 0x15,
            UInt8(year & 0xff), UInt8((year >> 8) & 0xff),
            UInt8(cal.component(.month, from: now)),
            UInt8(cal.component(.day, from: now)),
            UInt8(cal.component(.hour, from: now)),
            UInt8(cal.component(.minute, from: now)),
            UInt8(cal.component(.second, from: now)),
            0x8F
        ]
        sendCommand(bytes, label: "idő")
        status = "✓ Idő szinkronizálva."
    }

    func syncData() {
        guard canWrite else {
            status = "Előbb csatlakozz az AVIATOR órához."
            return
        }
        awaitingBattery = true
        awaitingCurrentStatus = false
        currentStatusRequested = false
        sendCommand([0x6E, 0x01, 0x0F, 0x01, 0x8F], label: "akkumulátor")
        status = "Akkumulátor lekérése…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if self.awaitingBattery {
                self.awaitingBattery = false
                self.log("Akkumulátor válasz időtúllépés")
            }
            self.requestCurrentStatusIfNeeded()
        }
    }

    private func requestCurrentStatusIfNeeded() {
        guard canWrite, !currentStatusRequested else { return }
        currentStatusRequested = true
        awaitingCurrentStatus = true
        sendCommand([0x6E, 0x01, 0x1B, 0x01, 0x8F], label: "napi aktuális állapot")
        status = "Mai lépésszám lekérése…"

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.awaitingCurrentStatus else { return }
            self.awaitingCurrentStatus = false
            self.currentStatusRequested = false
            self.status = "Nem érkezett értelmezhető napi állapotválasz."
            self.log("Napi állapot időtúllépés")
        }
    }

    var todaySteps: Int? {
        activityDays.first { Calendar.current.isDateInToday($0.date) }?.steps
    }

    func distanceKm(for steps: Int) -> Double { Double(steps) * distancePerStepKm }
    func calories(for steps: Int) -> Int { max(0, Int((Double(steps) * caloriesPerStep).rounded())) }

    func calibrateCalories(_ calories: Double) -> Bool {
        guard let steps = todaySteps, steps > 0, calories > 0 else {
            status = "Előbb szinkronizáld a mai lépésszámot, majd add meg az órán látható kcal értéket."
            return false
        }
        caloriesPerStep = calories / Double(steps)
        upsertToday(steps: steps)
        status = String(format: "✓ Kalória kalibrálva: %.0f kcal / %d lépés", calories, steps)
        log(String(format: "Kalória kalibráció: %d lépés -> %.0f kcal", steps, calories))
        return true
    }

    func days(in month: Date) -> [ActivityDay] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let start = cal.date(from: comps), let next = cal.date(byAdding: .month, value: 1, to: start) else { return [] }
        return activityDays.filter { $0.date >= start && $0.date < next }.sorted { $0.date < $1.date }
    }

    private var canWrite: Bool { connectedPeripheral != nil && writeCharacteristic != nil }

    private func sendCommand(_ bytes: [UInt8], label: String) {
        guard let peripheral = connectedPeripheral, let characteristic = writeCharacteristic else { return }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: characteristic, type: type)
        log("TX \(label): \(hex(bytes))")
    }

    private func handleNotification(_ data: Data) {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return }
        log("RX: \(hex(bytes))")
        guard bytes.first == 0x6E, bytes.last == 0x8F else { return }

        if awaitingBattery, bytes.count == 5 {
            let raw = Int(bytes[3])
            batteryRaw = raw
            let battery = max(0, min(100, raw * 5))
            batteryLevel = battery
            awaitingBattery = false
            log("Akkumulátor: \(battery)% (raw \(raw), gyári képlet: raw×5)")
            requestCurrentStatusIfNeeded()
            return
        }

        guard awaitingCurrentStatus, bytes.count == 20 else { return }
        awaitingCurrentStatus = false
        currentStatusRequested = false

        let steps = Int(leUInt32(bytes, 11))
        guard steps >= 0 && steps < 500_000 else {
            status = "A lépésszám válasza nem értelmezhető."
            log("Hibás napi lépésszám: \(steps)")
            return
        }

        upsertToday(steps: steps)
        if let battery = batteryLevel {
            status = "✓ Mai adatok frissítve: \(steps) lépés, akku \(battery)%"
            log("Mai állapot: \(steps) lépés | akku \(battery)%")
        } else {
            status = "✓ Mai adatok frissítve: \(steps) lépés"
            log("Mai állapot: \(steps) lépés | akku nem érkezett")
        }
    }

    private func leUInt32(_ bytes: [UInt8], _ start: Int) -> UInt32 {
        guard start >= 0, start + 3 < bytes.count else { return 0 }
        return UInt32(bytes[start]) |
            (UInt32(bytes[start + 1]) << 8) |
            (UInt32(bytes[start + 2]) << 16) |
            (UInt32(bytes[start + 3]) << 24)
    }

    private func upsertToday(steps: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        activityDays.removeAll { cal.isDate($0.date, inSameDayAs: today) }
        activityDays.append(ActivityDay(date: today, steps: steps, calories: calories(for: steps)))
        activityDays.sort { $0.date > $1.date }
        saveStoredDays()
    }

    private func loadStoredDays() {
        guard let data = UserDefaults.standard.data(forKey: dayStoreKey),
              let decoded = try? JSONDecoder().decode([ActivityDay].self, from: data) else { return }
        activityDays = decoded
    }

    private func saveStoredDays() {
        guard let data = try? JSONEncoder().encode(activityDays) else { return }
        UserDefaults.standard.set(data, forKey: dayStoreKey)
    }

    private func log(_ message: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        diagnosticLog.append("[\(f.string(from: Date()))] \(message)")
        if diagnosticLog.count > 300 { diagnosticLog.removeFirst(diagnosticLog.count - 300) }
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            bluetoothReady = central.state == .poweredOn
            status = central.state == .poweredOn ? "Bluetooth kész." : "Bluetooth nem elérhető."
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let name = advertised ?? peripheral.name ?? ""
            guard name.localizedCaseInsensitiveContains("aviator") else { return }
            let d = BLEDevice(peripheral: peripheral, name: name, rssi: RSSI.intValue)
            if let idx = devices.firstIndex(where: { $0.id == d.id }) { devices[idx] = d } else { devices.append(d) }
            devices.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedPeripheral = peripheral
            connectedID = peripheral.identifier
            peripheral.delegate = self
            status = "AVIATOR csatlakoztatva."
            peripheral.discoverServices([serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectedID = nil
            canSync = false
            writeCharacteristic = nil
            notifyCharacteristic = nil
            connectedPeripheral = nil
            if manualDisconnect {
                status = "Lecsatlakoztatva."
            } else {
                status = "Kapcsolat megszakadt. Újracsatlakozás…"
                if let p = reconnectPeripheral { central.connect(p, options: nil) }
            }
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil, let services = peripheral.services else { status = "Szolgáltatáskeresési hiba."; return }
            for s in services where s.uuid == serviceUUID { peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: s) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard error == nil, let chars = service.characteristics else { status = "Karakterisztika-hiba."; return }
            for c in chars {
                if c.uuid == writeUUID { writeCharacteristic = c }
                if c.uuid == notifyUUID { notifyCharacteristic = c; peripheral.setNotifyValue(true, for: c) }
            }
            canSync = writeCharacteristic != nil && notifyCharacteristic != nil
            status = canSync ? "AVIATOR csatlakoztatva és kész." : "A szükséges Mark 1 karakterisztikák nem találhatók."
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        Task { @MainActor in handleNotification(data) }
    }
}
