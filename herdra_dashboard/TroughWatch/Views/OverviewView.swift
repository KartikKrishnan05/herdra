import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            OverviewView()
                .tabItem { Label("Troughs", systemImage: "drop.fill") }

            MapScreen()
                .tabItem { Label("Map", systemImage: "map.fill") }

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

            Section("Devices") {
                ForEach(store.troughs) { trough in
                    NavigationLink {
                        TroughDetailView(troughID: trough.id)
                    } label: {
                        TroughRow(trough: trough, distance: store.distanceFromHome(to: trough))
                    }
                }
                .onDelete { store.delete(at: $0) }
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
            tile(count: store.troughs.count, label: "Devices", tint: .accentColor, symbol: "antenna.radiowaves.left.and.right")
            tile(count: store.healthyCount, label: "Fine", tint: .green, symbol: "checkmark.circle.fill")
            tile(count: store.warningCount, label: "Check", tint: .orange, symbol: "exclamationmark.triangle.fill")
            tile(count: store.alertCount, label: "Bad", tint: .red, symbol: "xmark.octagon.fill")
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
    let distance: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: trough.status.symbol)
                .font(.title3)
                .foregroundStyle(trough.status.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(trough.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(trough.deviceID)
                    if let distance {
                        Text("·")
                        Text("\(Format.distance(distance)) from home")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(trough.status.shortLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(trough.status.tint)
                if let reading = trough.lastReading {
                    Text(Format.relative(reading.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(trough.isActive ? 1 : 0.5)
    }
}
