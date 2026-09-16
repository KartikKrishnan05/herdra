import SwiftUI
import MapKit
import Charts

struct TroughDetailView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var locator: LocationManager
    @EnvironmentObject private var receiver: ReceiverClient
    @Environment(\.dismiss) private var dismiss

    let troughID: UUID
    @State private var showingDeleteConfirm = false

    private var trough: Trough? {
        store.troughs.first { $0.id == troughID }
    }

    var body: some View {
        Group {
            if let trough {
                content(for: trough)
            } else {
                ContentUnavailableView("Trough removed", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func content(for trough: Trough) -> some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: trough.status.symbol)
                        .font(.largeTitle)
                        .foregroundStyle(trough.status.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trough.status.label)
                            .font(.headline)
                        if let reading = trough.lastReading {
                            Text(StatusRule.evaluate(reading).reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Last packet \(Format.relative(reading.timestamp))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("Nothing has arrived from this device yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Location") {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: trough.coordinate.clCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)
                ))) {
                    Annotation(trough.name, coordinate: trough.coordinate.clCoordinate) {
                        TroughMarker(trough: trough, isSelected: false)
                    }
                }
                .frame(height: 180)
                .listRowInsets(EdgeInsets())

                LabeledContent("Coordinates", value: Format.coordinate(trough.coordinate))
                LabeledContent("Fix quality", value: Format.accuracy(trough.coordinate.accuracy))
                if let distance = store.distanceFromHome(to: trough) {
                    LabeledContent("From home", value: Format.distance(distance))
                }
                LabeledContent("Added", value: trough.installedAt.formatted(date: .abbreviated, time: .shortened))

                Button {
                    if let location = locator.location {
                        store.moveTrough(trough, to: location)
                    }
                } label: {
                    Label("Move pin to where I'm standing", systemImage: "location.circle")
                }
                .disabled(locator.location == nil)
            }

            if let reading = trough.lastReading {

                Section {
                    LabeledContent("Temperature", value: Format.reading(reading.temperatureC, unit: "°C", decimals: 1))
                    LabeledContent("Turbidity", value: Format.reading(reading.turbidityNTU, unit: "NTU", decimals: 1))
                    LabeledContent("Water level", value: Format.reading(reading.waterLevelCM, unit: "cm", decimals: 1))
                } header: {
                    Text("Water")
                } footer: {
                    if let time = reading.serverTime {
                        Text("Reached the receiver at \(time).")
                    }
                }

                Section("Camera") {
                    LabeledContent("Algae index", value: Format.reading(reading.algae, unit: "", decimals: 1))
                    LabeledContent("Confidence", value: Format.reading(reading.confidence, unit: "%", decimals: 0))
                    LabeledContent("Measurement quality", value: Format.reading(reading.quality, unit: "%", decimals: 0))

                    if let healthy = reading.cameraIsHealthy {
                        LabeledContent("Camera") {
                            Label(
                                healthy ? "OK" : "Error \(reading.cameraErrorCode ?? 0)",
                                systemImage: healthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(healthy ? Color.green : Color.red)
                        }
                    }

                    if let fresh = reading.cameraFresh {
                        LabeledContent("Image", value: fresh ? "Fresh" : "Not fresh")
                    }
                    if let age = reading.cameraAgeSeconds {
                        LabeledContent("Image age", value: String(format: "%.0f s", age))
                    }
                }

                if reading.rssi != nil || reading.snr != nil {
                    Section {
                        LabeledContent("Signal (RSSI)", value: Format.reading(reading.rssi, unit: "dBm", decimals: 0))
                        LabeledContent("Noise margin (SNR)", value: Format.reading(reading.snr, unit: "dB", decimals: 1))
                    } header: {
                        Text("Radio")
                    } footer: {
                        Text("How well the last packet came in over LoRa. Nearer to zero is stronger.")
                    }
                }

                if isStationTrough(trough), !receiver.history.isEmpty {
                    Section("Recent history") {
                        FeedHistoryChart(points: receiver.history)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                }

                if let raw = reading.rawMessage, !raw.isEmpty {
                    Section("Raw packet") {
                        Text(raw)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Device") {
                LabeledContent("Device ID", value: trough.deviceID)
                Toggle("Active", isOn: Binding(
                    get: { trough.isActive },
                    set: { newValue in
                        var copy = trough
                        copy.isActive = newValue
                        store.update(copy)
                    }
                ))
                if !trough.note.isEmpty {
                    Text(trough.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Water status", selection: Binding(
                    get: { trough.status },
                    set: { store.setStatus($0, for: trough) }
                )) {
                    ForEach(WaterStatus.allCases) { status in
                        Text(status.shortLabel).tag(status)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Set status by hand")
            } footer: {
                Text("Useful when you have walked out and looked. The next packet from the receiver overwrites it. Bad and check both draw a ring on the map.")
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Remove trough", systemImage: "trash")
                }
            }
        }
        .navigationTitle(trough.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(trough.name)?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.delete(trough)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        }
    }

    /// The history chart only makes sense on the trough the feed is filed
    /// against — the receiver keeps one buffer, not one per device.
    private func isStationTrough(_ trough: Trough) -> Bool {
        store.stationTrough(preferring: receiver.settings.stationTroughID)?.id == trough.id
    }
}

// MARK: - History

/// The last packets the receiver is holding (up to 50), charted by series.
struct FeedHistoryChart: View {

    enum Series: String, CaseIterable, Identifiable {
        case temperature = "Temp"
        case turbidity = "Turbidity"
        case algae = "Algae"
        case quality = "Quality"

        var id: String { rawValue }

        var tint: Color {
            switch self {
            case .temperature: return .orange
            case .turbidity: return .brown
            case .algae: return .green
            case .quality: return .blue
            }
        }

        func value(_ point: FeedHistoryPoint) -> Double? {
            switch self {
            case .temperature: return point.temperature
            case .turbidity: return point.turbidity
            case .algae: return point.algae
            case .quality: return point.quality
            }
        }
    }

    let points: [FeedHistoryPoint]
    @State private var series: Series = .temperature

    private var plotted: [FeedHistoryPoint] {
        points.filter { series.value($0) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            Picker("Series", selection: $series) {
                ForEach(Series.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if plotted.isEmpty {
                Text("No \(series.rawValue.lowercased()) values in the history yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
            } else {
                Chart(plotted) { point in
                    LineMark(
                        x: .value("Sample", point.id),
                        y: .value(series.rawValue, series.value(point) ?? 0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(series.tint)

                    AreaMark(
                        x: .value("Sample", point.id),
                        y: .value(series.rawValue, series.value(point) ?? 0)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(series.tint.opacity(0.15))
                }
                .chartXAxis(.hidden)
                .frame(height: 140)

                HStack {
                    Text(plotted.first?.time ?? "")
                    Spacer()
                    Text("\(plotted.count) samples")
                    Spacer()
                    Text(plotted.last?.time ?? "")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
