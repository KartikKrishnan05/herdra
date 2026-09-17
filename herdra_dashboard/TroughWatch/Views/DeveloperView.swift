import SwiftUI

/// The Developer tab: the receiver's live buffer, and per trough the raw
/// values, how they were converted and what the app concluded — everything
/// the farmer screens turn into words, as it came off the sensors.
struct DeveloperView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var receiver: ReceiverClient
    @State private var showingClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ReceiverStatusRow(state: receiver.state)
                    if let info = receiver.info {
                        LabeledContent("Packets received", value: "\(info.totalPackets)")
                        LabeledContent("In buffer", value: "\(receiver.packets.count)")
                    }
                } header: {
                    Text("Receiver")
                }

                if !store.troughs.isEmpty {
                    Section("Sensor data per trough") {
                        ForEach(store.troughs) { trough in
                            NavigationLink {
                                SensorDataView(troughID: trough.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(trough.name)
                                        Spacer()
                                        Text(trough.deviceID)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    if let reading = trough.lastReading {
                                        Text(RawText.summary(reading))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    if receiver.packets.isEmpty {
                        Text("Nothing in the receiver's buffer.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(receiver.packets.reversed()) { packet in
                        PacketRow(packet: packet)
                    }
                } header: {
                    Text("Live packets, newest first")
                } footer: {
                    Text("As the sender sent them. Depth, turbidity and algae coverage are only worked out once a packet is filed against a trough, with that trough's calibration.")
                }
            }
            .navigationTitle("Developer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear readings", role: .destructive) {
                        showingClearConfirm = true
                    }
                }
            }
            .confirmationDialog("Clear all stored readings?", isPresented: $showingClearConfirm, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { store.clearReadings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Troughs, calibration and settings stay. The receiver's last 50 packets are read in again on the next poll.")
            }
        }
    }
}

private struct PacketRow: View {
    let packet: FeedPacket

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(packet.number)")
                    .font(.caption.weight(.semibold))
                if let device = packet.deviceID {
                    Text(device).font(.caption.monospaced())
                }
                Spacer()
                Text(Format.relative(packet.reading.timestamp))
                Text(Format.reading(packet.reading.rssi, unit: "dBm", decimals: 0))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(packet.reading.rawMessage ?? "")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - One trough

/// Raw values, conversions and conclusions for one trough.
struct SensorDataView: View {
    @EnvironmentObject private var store: TroughStore
    let troughID: UUID

    private var trough: Trough? {
        store.troughs.first { $0.id == troughID }
    }

    var body: some View {
        if let trough {
            content(for: trough)
        } else {
            ContentUnavailableView("Trough removed", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func content(for trough: Trough) -> some View {
        let calibration = trough.sensorCalibration
        List {
            if let reading = trough.lastReading {
                Section {
                    LabeledContent("TEMP", value: Format.reading(reading.temperatureC, unit: "°C", decimals: 2))
                    LabeledContent("LVL_MV", value: Format.reading(reading.levelMV, unit: "mV", decimals: 1))
                    LabeledContent("TURB_MV", value: Format.reading(reading.turbidityMV, unit: "mV", decimals: 1))
                    LabeledContent("ALGAE", value: Format.reading(reading.cameraAlgae, unit: "%", decimals: 2))
                    LabeledContent("CONF", value: Format.reading(reading.confidence, unit: "", decimals: 2))
                    LabeledContent("QUALITY", value: Format.reading(reading.quality, unit: "%", decimals: 2))
                    LabeledContent("CAM_FRESH", value: RawText.flag(reading.cameraFresh))
                    LabeledContent("CAM_ERR", value: reading.cameraErrorCode.map(String.init) ?? "N/A")
                    LabeledContent("CAM_AGE", value: Format.reading(reading.cameraAgeSeconds, unit: "s", decimals: 0))
                    LabeledContent("Valid rounds (lvl/turb/temp/cam)", value: RawText.rounds(reading))
                    if let batch = reading.batch {
                        LabeledContent("BATCH", value: "\(batch)")
                    }
                } header: {
                    Text("Last packet — as sent")
                } footer: {
                    if let time = reading.serverTime {
                        Text("Reached the receiver at \(time), \(Format.relative(reading.timestamp)). Each value is the median of the sender's five rounds.")
                    }
                }

                Section {
                    if let mv = reading.levelMV {
                        LabeledContent("Water depth",
                                       value: "\(Format.reading(mv, unit: "mV", decimals: 0)) → \(Format.reading(calibration.depthCM(fromMV: mv), unit: "cm", decimals: 1))")
                    } else {
                        LabeledContent("Water depth", value: "\(Format.reading(reading.waterLevelCM, unit: "cm", decimals: 1)) (sent converted)")
                    }
                    if let mv = reading.turbidityMV {
                        LabeledContent("Sensor voltage",
                                       value: Format.reading(calibration.turbiditySensorVolts(fromPinMV: mv), unit: "V", decimals: 3))
                        LabeledContent("Turbidity",
                                       value: "\(Format.reading(mv, unit: "mV", decimals: 0)) → \(Format.reading(calibration.turbidityPercent(fromMV: mv), unit: "%", decimals: 1))")
                    } else {
                        LabeledContent("Turbidity", value: "\(Format.reading(reading.turbidityPercent, unit: "%", decimals: 1)) (sent converted)")
                    }
                    if let raw = reading.cameraAlgae {
                        LabeledContent("Algae coverage",
                                       value: "\(Format.reading(raw, unit: "%", decimals: 1)) → \(Format.reading(calibration.algaeCoverage(fromCamera: raw), unit: "%", decimals: 0))")
                    }
                    NavigationLink {
                        CalibrationEditor(troughID: trough.id)
                    } label: {
                        Label(trough.calibration == nil ? "Calibration (defaults)" : "Calibration (custom)",
                              systemImage: "slider.horizontal.3")
                    }
                } header: {
                    Text("Converted in the app")
                }

                if reading.rssi != nil || reading.snr != nil {
                    Section("Radio") {
                        LabeledContent("RSSI", value: Format.reading(reading.rssi, unit: "dBm", decimals: 0))
                        LabeledContent("SNR", value: Format.reading(reading.snr, unit: "dB", decimals: 1))
                    }
                }

                if let raw = reading.rawMessage, !raw.isEmpty {
                    Section("Raw packet") {
                        Text(raw)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } else {
                Section {
                    Text("No packet has been filed against this trough yet.")
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        CalibrationEditor(troughID: trough.id)
                    } label: {
                        Label("Calibration", systemImage: "slider.horizontal.3")
                    }
                }
            }

            let assessment = store.assessment(for: trough)
            if !assessment.findings.isEmpty {
                Section {
                    ForEach(assessment.findings) { finding in
                        LabeledContent {
                            Text("\(finding.word) · \(finding.status.shortLabel)")
                                .foregroundStyle(finding.status.tint)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(finding.metric.title)
                                Text(Format.reading(finding.value, unit: finding.metric.unit, decimals: 1))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("What the farmer sees")
                } footer: {
                    Text("Values are the smoothed medians the assessment used, not the last packet.")
                }
            }

            let recent = Array(store.samples(for: trough).suffix(40).reversed())
            Section {
                if recent.isEmpty {
                    Text("No stored readings.").foregroundStyle(.secondary)
                }
                ForEach(recent, id: \.timestamp) { sample in
                    SampleRow(sample: sample)
                }
            } header: {
                Text("Stored readings, newest first")
            } footer: {
                Text("Level mV → cm · turbidity mV → % · °C · camera algae % → coverage % · quality. Older than a day, readings are 10-minute medians.")
            }
        }
        .navigationTitle("\(trough.name) sensors")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SampleRow: View {
    let sample: Sample

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sample.timestamp.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(line)
                .font(.caption.monospaced())
        }
    }

    private var line: String {
        let level = "\(RawText.number(sample.levelMV, 0))→\(RawText.number(sample.waterLevelCM, 1))cm"
        let turb = "\(RawText.number(sample.turbidityMV, 0))→\(RawText.number(sample.turbidityPercent, 0))%"
        let rest = "\(RawText.number(sample.temperatureC, 1))° A\(RawText.number(sample.cameraAlgae, 1))→\(RawText.number(sample.algae, 0))% Q\(RawText.number(sample.quality, 0))"
        return "\(level)  \(turb)  \(rest)\(sample.cameraError == true ? " CAM_ERR" : "")"
    }
}

// MARK: - Calibration

struct CalibrationEditor: View {
    @EnvironmentObject private var store: TroughStore
    @Environment(\.dismiss) private var dismiss

    let troughID: UUID
    @State private var draft = SensorCalibration.default
    @State private var loaded = false

    private var trough: Trough? {
        store.troughs.first { $0.id == troughID }
    }

    var body: some View {
        Form {
            Section {
                field("Dry (probe out of water)", value: $draft.levelZeroMV, unit: "mV")
                field("At reference depth", value: $draft.levelCalMV, unit: "mV")
                field("Reference depth", value: $draft.levelCalDepthCM, unit: "cm")
                if let mv = trough?.lastReading?.levelMV {
                    LabeledContent("Last packet",
                                   value: "\(Format.reading(mv, unit: "mV", decimals: 0)) → \(Format.reading(draft.depthCM(fromMV: mv), unit: "cm", decimals: 1))")
                }
            } header: {
                Text("Water level (GPIO3)")
            } footer: {
                Text("Read LVL_MV with the probe out of the water, then with it at a measured depth.")
            }

            Section {
                field("Clear water (0 %)", value: $draft.turbidityClearV, unit: "V")
                field("Dirtiest reference (100 %)", value: $draft.turbidityDirtyV, unit: "V")
                field("Divider factor", value: $draft.turbidityDividerFactor, unit: "×")
                if let mv = trough?.lastReading?.turbidityMV {
                    LabeledContent("Last packet",
                                   value: "\(Format.reading(draft.turbiditySensorVolts(fromPinMV: mv), unit: "V", decimals: 2)) → \(Format.reading(draft.turbidityPercent(fromMV: mv), unit: "%", decimals: 1))")
                }
            } header: {
                Text("Turbidity (GPIO4)")
            } footer: {
                Text("Voltages at the sensor, i.e. TURB_MV × divider factor ÷ 1000. The 10k/20k divider gives 1.5.")
            }

            Section {
                field("Clean, silver surface (0 %)", value: $draft.algaeCleanPercent, unit: "%")
                field("Fully covered (100 %)", value: $draft.algaeFullPercent, unit: "%")
                if let raw = trough?.lastReading?.cameraAlgae {
                    LabeledContent("Last packet",
                                   value: "\(Format.reading(raw, unit: "%", decimals: 1)) → \(Format.reading(draft.algaeCoverage(fromCamera: raw), unit: "%", decimals: 0))")
                }
            } header: {
                Text("Algae (camera)")
            } footer: {
                Text("The camera's ALGAE value for a clean surface and for one fully covered in algae. The app's algae limits (\(Int(Assessment.someAlgae)) % building up, \(Int(Assessment.lotsOfAlgae)) % a lot) apply to the coverage in between.")
            }

            Section {
                Button("Save and recalculate history") {
                    guard let trough else { return }
                    store.setCalibration(draft == .default ? nil : draft, for: trough)
                    dismiss()
                }
                .disabled(!isUsable)
                Button("Reset to defaults", role: .destructive) {
                    draft = .default
                }
            } footer: {
                if !isUsable {
                    Text("The reference reading must be higher than the dry reading, clear water higher than the dirty reference, and fully covered higher than clean.")
                        .foregroundStyle(.red)
                } else {
                    Text("Stored depth, turbidity and algae are recalculated from their raw values, so the charts and colours change with it.")
                }
            }
        }
        .navigationTitle("Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded, let trough else { return }
            draft = trough.sensorCalibration
            loaded = true
        }
    }

    private var isUsable: Bool {
        draft.depthCM(fromMV: draft.levelCalMV) != nil && draft.turbidityPercent(fromMV: 0) != nil
            && draft.turbidityDividerFactor > 0 && draft.algaeCoverage(fromCamera: 0) != nil
    }

    private func field(_ title: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
        }
    }
}

// MARK: - Text helpers

private enum RawText {
    static func number(_ value: Double?, _ decimals: Int) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.\(decimals)f", value)
    }

    static func flag(_ value: Bool?) -> String {
        value.map { $0 ? "1" : "0" } ?? "N/A"
    }

    static func rounds(_ r: Reading) -> String {
        [r.validLevelRounds, r.validTurbidityRounds, r.validTemperatureRounds, r.validCameraRounds]
            .map { $0.map(String.init) ?? "–" }
            .joined(separator: "/")
    }

    static func summary(_ r: Reading) -> String {
        "\(number(r.levelMV, 0)) mV · \(number(r.turbidityMV, 0)) mV · \(number(r.temperatureC, 1)) °C · A \(number(r.cameraAlgae, 1))"
    }
}
