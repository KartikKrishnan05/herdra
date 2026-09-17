import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Troughs", systemImage: "drop.fill") }

            MapScreen()
                .tabItem { Label("Map", systemImage: "map.fill") }

            DeveloperView()
                .tabItem { Label("Developer", systemImage: "waveform.path.ecg") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

/// Main page: one-glance summary plus a row per device.
struct OverviewView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var receiver: ReceiverClient
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Group {
                if store.troughs.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Troughs")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add trough", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddTroughView()
            }
        }
    }

    private var list: some View {
        List {
            Section {
                SummaryBar()
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            } footer: {
                if receiver.settings.isEnabled {
                    ReceiverStatusRow(state: receiver.state)
                }
            }

            Section("Troughs") {
                let ordered = store.troughsByUrgency
                ForEach(ordered) { trough in
                    NavigationLink {
                        TroughDetailView(troughID: trough.id)
                    } label: {
                        TroughRow(trough: trough, assessment: store.assessment(for: trough))
                    }
                }
                .onDelete { offsets in
                    offsets.map { ordered[$0] }.forEach(store.delete)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "drop.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("No troughs yet")
                .font(.title2.bold())
            Text("Drop a device in the first trough, stand next to it, and save the spot.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showingAdd = true
            } label: {
                Label("Add the first trough", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
    }
}

/// Counts across every trough, colour-coded.
struct SummaryBar: View {
    @EnvironmentObject private var store: TroughStore

    var body: some View {
        HStack(spacing: 10) {
            tile(count: store.healthyCount, label: WaterStatus.good.shortLabel, tint: .green, symbol: WaterStatus.good.symbol)
            tile(count: store.warningCount, label: WaterStatus.warning.shortLabel, tint: .orange, symbol: WaterStatus.warning.symbol)
            tile(count: store.alertCount, label: WaterStatus.bad.shortLabel, tint: .red, symbol: WaterStatus.bad.symbol)
        }
    }

    private func tile(count: Int, label: String, tint: Color, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TroughRow: View {
    let trough: Trough
    let assessment: TroughAssessment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: assessment.status.symbol)
                .font(.title2)
                .foregroundStyle(assessment.status.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trough.name)
                        .font(.headline)
                    Spacer()
                    Text(assessment.status.shortLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(assessment.status.tint)
                }
                Text(assessment.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let lastHeard = assessment.lastHeard {
                    Text("Updated \(Format.relative(lastHeard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(trough.isActive ? 1 : 0.5)
    }
}
