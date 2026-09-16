import SwiftUI
import Charts

private enum Metric: String, CaseIterable, Identifiable {
    case steps = "Lépés"
    case distance = "Távolság"
    case calories = "Kalória"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var ble = BLEManager()
    @State private var selectedTab = 0
    @State private var shownMonth = Date()
    @State private var metric: Metric = .steps
    @State private var calibrationCalories: Double = 96

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                overview
                    .tabItem { Label("Áttekintés", systemImage: "watch.analog") }
                    .tag(0)
                monthly
                    .tabItem { Label("Havi grafikon", systemImage: "chart.bar") }
                    .tag(1)
                diagnostics
                    .tabItem { Label("Diagnosztika", systemImage: "waveform.path.ecg") }
                    .tag(2)
            }
            .navigationTitle("AVIATOR Sync")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("F-Series Mark 1 / AVW79215G360")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Circle().fill(ble.connectedID == nil ? .gray : .green).frame(width: 9, height: 9)
                        Text(ble.connectedID == nil ? "Nincs csatlakoztatva" : "AVIATOR csatlakoztatva")
                            .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GroupBox("Bluetooth kapcsolat") {
                    VStack(spacing: 10) {
                        HStack {
                            Button(ble.isScanning ? "Keresés leállítása" : "AVIATOR keresése") {
                                ble.isScanning ? ble.stopScan() : ble.startScan()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Lista törlése") { ble.clearDevices() }
                                .buttonStyle(.bordered)
                            Spacer()
                        }
                        if ble.devices.isEmpty {
                            ContentUnavailableView("Nincs AVIATOR találat", systemImage: "antenna.radiowaves.left.and.right", description: Text("Indítsd el a keresést, majd válaszd ki az órát."))
                                .frame(minHeight: 130)
                        } else {
                            ForEach(ble.devices) { d in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(d.name).font(.headline)
                                        Text("RSSI \(d.rssi)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if ble.connectedID == d.id {
                                        Text("Csatlakozva").foregroundStyle(.secondary)
                                    } else {
                                        Button("Csatlakozás") { ble.connect(to: d.peripheral) }
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button { ble.syncTime() } label: { Label("Idő", systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(!ble.canSync)
                    Button { ble.syncData() } label: { Label("Adatok", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(!ble.canSync)
                    Button { ble.disconnect() } label: { Image(systemName: "bolt.horizontal.circle") }
                        .buttonStyle(.bordered)
                        .disabled(ble.connectedID == nil)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    card("Akkumulátor", ble.batteryLevel.map { "\($0)%" } ?? "–", batteryIcon)
                    card("Mai lépések", today.map { "\($0.steps)" } ?? "–", "figure.walk")
                    card("Mai távolság", today.map { String(format: "%.2f km", ble.distanceKm(for: $0.steps)) } ?? "–", "location")
                    card("Mai kalória", today.map { "\(ble.calories(for: $0.steps)) kcal" } ?? "–", "flame")
                }

                GroupBox("Kalória kalibrálása") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Az órán most:")
                            Spacer()
                            TextField("96", value: $calibrationCalories, format: .number.precision(.fractionLength(0)))
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("kcal")
                        }
                        Button("Kalória kalibrálása") { _ = ble.calibrateCalories(calibrationCalories) }
                            .buttonStyle(.borderedProminent)
                            .disabled(today == nil)
                    }
                }

                Text("A távolság automatikusan számolódik 0,726 m/lépés alapján. A kcal a jelenlegi Mac v4.4-hez hasonlóan kézzel kalibrálható.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(ble.status)
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }

    private var monthly: some View {
        let days = monthDaysFilled
        return ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Button { shownMonth = Calendar.current.date(byAdding: .month, value: -1, to: shownMonth) ?? shownMonth } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(shownMonth.formatted(.dateTime.year().month(.wide))).font(.headline)
                    Spacer()
                    Button { shownMonth = Calendar.current.date(byAdding: .month, value: 1, to: shownMonth) ?? shownMonth } label: { Image(systemName: "chevron.right") }
                        .disabled(Calendar.current.compare(shownMonth, to: Date(), toGranularity: .month) != .orderedAscending)
                }

                Picker("Mutató", selection: $metric) {
                    ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    card("Havi lépések", "\(days.reduce(0) { $0 + $1.steps })", "figure.walk")
                    card("Havi távolság", String(format: "%.2f km", days.reduce(0.0) { $0 + ble.distanceKm(for: $1.steps) }), "location")
                    card("Havi kalória", "\(days.reduce(0) { $0 + ble.calories(for: $1.steps) }) kcal", "flame")
                }

                Chart(days) { day in
                    BarMark(
                        x: .value("Nap", Calendar.current.component(.day, from: day.date)),
                        y: .value(metric.rawValue, chartValue(day))
                    )
                    .cornerRadius(3)
                }
                .frame(height: 320)
                .chartXAxis {
                    AxisMarks(values: .stride(by: 2)) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .padding(.vertical, 8)

                Text("A korábbi napok helyben megmaradnak; szinkronkor csak a mai nap frissül.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var diagnostics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Bluetooth diagnosztika").font(.headline)
                    Spacer()
                    if let raw = ble.batteryRaw { Text("Akku raw: \(raw)").font(.caption).foregroundStyle(.secondary) }
                }
                Text(ble.diagnosticLog.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text(ble.status).font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var today: ActivityDay? { ble.activityDays.first { Calendar.current.isDateInToday($0.date) } }

    private var batteryIcon: String {
        guard let level = ble.batteryLevel else { return "battery.0" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private var monthDaysFilled: [ActivityDay] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: shownMonth)
        guard let start = cal.date(from: comps), let range = cal.range(of: .day, in: .month, for: start) else { return [] }
        let data = ble.days(in: shownMonth)
        let map = Dictionary(uniqueKeysWithValues: data.map { (cal.startOfDay(for: $0.date), $0) })
        return range.compactMap { day in
            guard let date = cal.date(byAdding: .day, value: day - 1, to: start) else { return nil }
            let key = cal.startOfDay(for: date)
            return map[key] ?? ActivityDay(date: key, steps: 0, calories: 0)
        }
    }

    private func chartValue(_ d: ActivityDay) -> Double {
        switch metric {
        case .steps: return Double(d.steps)
        case .distance: return ble.distanceKm(for: d.steps)
        case .calories: return Double(ble.calories(for: d.steps))
        }
    }

    private func card(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: icon); Text(title).font(.caption).foregroundStyle(.secondary) }
            Text(value).font(.title2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
