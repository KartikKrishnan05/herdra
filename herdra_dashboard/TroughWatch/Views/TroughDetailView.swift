import SwiftUI
import MapKit
import Charts

/// What a farmer sees when opening a trough: is it OK, what to do, and how
/// things have been going — in words and colours. The raw sensor values are on
/// the Developer tab.
struct TroughDetailView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var locator: LocationManager

    let troughID: UUID
    @State private var chartMetric: Metric = .algae
    @State private var showingCleanConfirm = false

    private var trough: Trough? {
        store.troughs.first { $0.id == troughID }
    }

    var body: some View {
        Group {
            if let trough {
                content(for: trough, assessment: store.assessment(for: trough))
            } else {
                ContentUnavailableView("Trough removed", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func content(for trough: Trough, assessment: TroughAssessment) -> some View {
        List {
            Section {
                StatusHero(assessment: assessment)
                    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
            }

            if !assessment.todo.isEmpty {
                Section("What to do") {
                    ForEach(assessment.todo, id: \.self) { item in
                        Label(item, systemImage: "hand.point.right.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.primary)
                    }
                }
            }

            if !assessment.findings.isEmpty {
                Section {
                    FindingGrid(findings: assessment.findings, selected: $chartMetric, dimmed: assessment.isOutdated,
                                fullLevelCM: trough.fullLevelCM)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                        .listRowBackground(Color.clear)
                } header: {
                    Text("At a glance")
                } footer: {
                    Text("Tap one to see how it has changed.")
                }

                Section("How it has been going") {
                    if let finding = assessment.finding(chartMetric) {
                        Label(finding.detail, systemImage: finding.metric.symbol)
                            .foregroundStyle(finding.status.needsAttention ? finding.status.tint : .primary)
                    }
                    TrendChart(samples: store.samples(for: trough), metric: $chartMetric, cleanedAt: trough.cleanedAt,
                               fullLevelCM: trough.fullLevelCM)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }
            }

            Section {
                Button {
                    showingCleanConfirm = true
                } label: {
                    Label("I cleaned this trough", systemImage: "sparkles")
                        .font(.body.weight(.semibold))
                }
            } footer: {
                if let cleaned = trough.cleanedAt {
                    Text("Last cleaned \(Format.relative(cleaned)). Readings from before then no longer count.")
                } else {
                    Text("After cleaning, tap this so old algae and dirt readings stop counting.")
                }
            }

            Section("Where it is") {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: trough.coordinate.clCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)
                ))) {
                    Annotation(trough.name, coordinate: trough.coordinate.clCoordinate) {
                        TroughMarker(status: assessment.status, isSelected: false)
                    }
                }
                .frame(height: 160)
                .listRowInsets(EdgeInsets())

                if let distance = store.distanceFromHome(to: trough) {
                    LabeledContent("From home", value: Format.distance(distance))
                }
                if !trough.note.isEmpty {
                    Text(trough.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                NavigationLink {
                    TroughTechnicalView(troughID: trough.id)
                } label: {
                    Label("Device settings", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .navigationTitle(trough.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Open on whatever needs attention, so the chart explains the colour.
            if let worst = assessment.findings.max(by: { $0.status.severity < $1.status.severity }),
               worst.status.needsAttention {
                chartMetric = worst.metric
            }
        }
        .confirmationDialog("Cleaned \(trough.name)?", isPresented: $showingCleanConfirm, titleVisibility: .visible) {
            Button("Yes, I cleaned it") { store.markCleaned(trough) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app starts judging the water fresh from now on. The history stays in the chart.")
        }
    }
}

// MARK: - Status

private struct StatusHero: View {
    let assessment: TroughAssessment

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: assessment.status.symbol)
                .font(.system(size: 56))
                .foregroundStyle(assessment.status.tint)
            Text(assessment.status.label)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            if assessment.todo.isEmpty {
                Text(assessment.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let lastHeard = assessment.lastHeard {
                Text("Updated \(Format.relative(lastHeard))")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Findings

private struct FindingGrid: View {
    let findings: [Finding]
    @Binding var selected: Metric
    let dimmed: Bool
    let fullLevelCM: Double

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(findings) { finding in
                Button {
                    selected = finding.metric
                } label: {
                    FindingTile(finding: finding, isSelected: selected == finding.metric, fullLevelCM: fullLevelCM)
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(dimmed ? 0.6 : 1)
    }
}

private struct FindingTile: View {
    let finding: Finding
    let isSelected: Bool
    let fullLevelCM: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(finding.metric.title, systemImage: finding.metric.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(finding.word)
                .font(.title3.bold())
                .foregroundStyle(finding.status == .good ? Color.primary : finding.status.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 4) {
                if let symbol = finding.trend.symbol, let word = finding.trend.word {
                    Image(systemName: symbol)
                    Text(word)
                }
                Spacer(minLength: 0)
                if let value = valueText {
                    Text(value)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(finding.status.tint.opacity(finding.status == .unknown ? 0.08 : 0.14),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    /// Only the numbers a farmer reads without help: degrees and centimetres.
    private var valueText: String? {
        guard let value = finding.value else { return nil }
        switch finding.metric {
        case .temperature: return String(format: "%.0f °C", value)
        case .level: return String(format: "%.0f of %.0f cm", value, fullLevelCM)
        case .algae, .clarity: return nil
        }
    }
}

// MARK: - Chart

private struct TrendChart: View {

    enum Range: String, CaseIterable, Identifiable {
        case hour = "Last hour"
        case day = "Last day"
        case week = "Last week"

        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .hour: return 3600
            case .day: return 24 * 3600
            case .week: return 7 * 24 * 3600
            }
        }
        /// Medians per slot over the longer ranges, so single odd packets
        /// don't make spikes. Nil: every batch is drawn as it came.
        var slot: TimeInterval? {
            switch self {
            case .hour: return nil
            case .day: return 5 * 60
            case .week: return 3 * 3600
            }
        }
    }

    let samples: [Sample]
    @Binding var metric: Metric
    let cleanedAt: Date?
    let fullLevelCM: Double
    @State private var range: Range = .hour

    private var points: [(time: Date, value: Double)] {
        let from = Date.now.addingTimeInterval(-range.seconds)
        let recent = samples.filter { $0.timestamp >= from }
        guard let slot = range.slot else {
            return recent.compactMap { sample in metric.value(sample).map { (sample.timestamp, $0) } }
        }
        return Stats.medians(recent, metric, every: slot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Show", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            let points = points
            if points.count < 2 {
                Text("Not enough readings yet to draw this.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart {
                    ForEach(points, id: \.time) { point in
                        AreaMark(x: .value("Time", point.time), y: .value(metric.title, point.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(metric.chartTint.opacity(0.15))
                        LineMark(x: .value("Time", point.time), y: .value(metric.title, point.value))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(metric.chartTint)
                            .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }

                    ForEach(metric.limits(fullLevelCM: fullLevelCM), id: \.value) { limit in
                        RuleMark(y: .value("Limit", limit.value))
                            .foregroundStyle(limit.status.tint.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }

                    if let cleanedAt, cleanedAt >= points[0].time {
                        RuleMark(x: .value("Cleaned", cleanedAt))
                            .foregroundStyle(.secondary)
                            .annotation(position: .top, alignment: .leading) {
                                Text("Cleaned").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text("\(Int(number))")
                            }
                        }
                    }
                }
                .chartXAxis {
                    if range == .week {
                        AxisMarks(values: .stride(by: .day)) {
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        }
                    } else if range == .hour {
                        AxisMarks(values: .stride(by: .minute, count: 15)) {
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    } else {
                        AxisMarks(values: .stride(by: .hour, count: 6)) {
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                }
                .frame(height: 180)

                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String {
        var text = metric.chartExplanation
        if metric == .level {
            text += " Dashed lines: green is full, orange means keep an eye on it, red means act."
        } else if !metric.limits(fullLevelCM: fullLevelCM).isEmpty {
            text += " Dashed lines: orange means keep an eye on it, red means act."
        }
        return text
    }
}

private extension Metric {

    /// The lines the assessment draws its conclusions from.
    func limits(fullLevelCM full: Double) -> [(value: Double, status: WaterStatus)] {
        switch self {
        case .level: return [(full, .good),
                             (full * Assessment.gettingLowLevelShare, .warning),
                             (full * Assessment.lowLevelShare, .bad)]
        case .algae: return [(Assessment.someAlgae, .warning), (Assessment.lotsOfAlgae, .bad)]
        case .clarity: return [(Assessment.cloudyPercent, .warning), (Assessment.dirtyPercent, .bad)]
        case .temperature: return [(Assessment.hotC, .warning), (Assessment.nearFreezingC, .warning)]
        }
    }

    var chartExplanation: String {
        switch self {
        case .level: return "Water depth in centimetres. Higher is better."
        case .algae: return "How much of the surface the camera sees is covered in algae. Lower is better."
        case .clarity: return "How murky the water is. Lower is clearer."
        case .temperature: return "Water temperature in °C."
        }
    }
}

// MARK: - Device settings

/// Where the device is and what it's called — for whoever installs or moves
/// it. The raw sensor values are on the Developer tab.
struct TroughTechnicalView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var locator: LocationManager
    @Environment(\.dismiss) private var dismiss

    let troughID: UUID
    @State private var showingDeleteConfirm = false

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
        List {
            Section {
                NavigationLink {
                    SensorDataView(troughID: trough.id)
                } label: {
                    Label("Raw sensor data and calibration", systemImage: "waveform.path.ecg")
                }
            }

            Section {
                let samples = store.samples(for: trough)
                LabeledContent("Readings stored", value: "\(samples.count)")
                if let first = samples.first {
                    LabeledContent("Going back to", value: first.timestamp.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("History")
            } footer: {
                Text("The app keeps a week. Readings older than a day are merged into 10-minute medians.")
            }

            Section("Location") {
                LabeledContent("Coordinates", value: Format.coordinate(trough.coordinate))
                LabeledContent("Fix quality", value: Format.accuracy(trough.coordinate.accuracy))
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
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Label("Remove trough", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Device settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(trough.name)?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                store.delete(trough)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Its location and its week of readings are deleted.")
        }
    }
}
