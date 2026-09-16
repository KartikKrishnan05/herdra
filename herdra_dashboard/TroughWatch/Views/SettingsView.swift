import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var locator: LocationManager
    @EnvironmentObject private var receiver: ReceiverClient

    @State private var showingResetConfirm = false
    @State private var addressDraft = ""
    @State private var isTesting = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section("Home") {
                    if let home = store.home {
                        LabeledContent("Saved", value: home.label)
                        LabeledContent("Coordinates", value: Format.coordinate(home.coordinate))
                        LabeledContent("Set on", value: home.savedAt.formatted(date: .abbreviated, time: .shortened))
                        Button {
                            if let location = locator.location {
                                store.setHome(location, label: home.label)
                            }
                        } label: {
                            Label("Move home to where I'm standing", systemImage: "house.circle")
                        }
                        .disabled(locator.location == nil)
                    }
                }

                Section {
                    LabeledContent("Permission", value: authorizationText)
                    LabeledContent("Current fix", value: locator.coordinateText)
                    LabeledContent("Accuracy", value: locator.accuracyText)
                } header: {
                    Text("Location")
                }

                Section {
                    Toggle("Read from the receiver", isOn: Binding(
                        get: { receiver.settings.isEnabled },
                        set: { receiver.settings.isEnabled = $0 }
                    ))

                    HStack {
                        Text("Address")
                        Spacer()
                        TextField(ReceiverSettings.defaultAddress, text: $addressDraft)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($addressFocused)
                            .submitLabel(.done)
                            .onSubmit(commitAddress)
                    }

                    ReceiverStatusRow(state: receiver.state)

                    if let info = receiver.info, receiver.settings.isEnabled {
                        LabeledContent("Packets received", value: "\(info.totalPackets)")
                        LabeledContent("Receiver up for", value: Format.duration(info.uptimeSeconds))
                        LabeledContent("Phones connected", value: "\(info.clients)")
                    }

                    Button {
                        commitAddress()
                        addressFocused = false
                        isTesting = true
                        Task {
                            await receiver.refreshNow()
                            isTesting = false
                        }
                    } label: {
                        HStack {
                            Label("Check the connection now", systemImage: "arrow.clockwise")
                            if isTesting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }

                } header: {
                    Text("Receiver")
                } footer: {
                    Text("Join the receiver's Wi-Fi network, HERDRA-RX, in the iPhone's Settings. The app reads the packets it has heard from \(ReceiverSettings.defaultAddress) every \(Int(receiver.settings.pollInterval)) seconds. herdra.local works too.")
                }

                if !store.troughs.isEmpty {
                    Section {
                        Picker("Readings belong to", selection: Binding(
                            get: { receiver.settings.stationTroughID },
                            set: { receiver.settings.stationTroughID = $0 }
                        )) {
                            Text("First active trough").tag(UUID?.none)
                            ForEach(store.troughs) { trough in
                                Text(trough.name).tag(UUID?.some(trough.id))
                            }
                        }
                    } header: {
                        Text("Station")
                    } footer: {
                        Text("Packets without a device ID go to this trough. If the sender adds ID=DEV-002 (or DEV=, NODE=, STATION=) to its message, the packet goes to the trough with that device ID instead.")
                    }
                }

                Section {
                    Button {
                        store.simulateIncomingReadings()
                    } label: {
                        Label("Fake a round of readings", systemImage: "wave.3.right")
                    }
                    .disabled(store.troughs.isEmpty)
                } header: {
                    Text("Without a station")
                } footer: {
                    Text("Fills every active trough with a made-up packet, judged by the same rules as a real one, so you can see the map colours and the alert counts move with nothing on the network.")
                }

                Section {
                    Button(role: .destructive) {
                        showingResetConfirm = true
                    } label: {
                        Label("Erase home and all troughs", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                if addressDraft.isEmpty { addressDraft = receiver.settings.address }
            }
            .onChange(of: addressFocused) { _, focused in
                if !focused { commitAddress() }
            }
            .confirmationDialog("Erase everything?", isPresented: $showingResetConfirm, titleVisibility: .visible) {
                Button("Erase", role: .destructive) { store.resetEverything() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The home point and every saved trough are deleted from this phone.")
            }
        }
    }

    /// Only push the typed address into settings once, so the poll isn't
    /// restarted on every keystroke.
    private func commitAddress() {
        var trimmed = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            trimmed = ReceiverSettings.defaultAddress
            addressDraft = trimmed
        }
        guard trimmed != receiver.settings.address else { return }
        receiver.settings.address = trimmed
    }

    private var authorizationText: String {
        switch locator.authorization {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "While using the app"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }
}

/// One line saying whether the feed is coming through, with the reason when
/// it isn't.
struct ReceiverStatusRow: View {
    let state: ReceiverClient.ConnectionState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.symbol)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(state.label)
                .foregroundStyle(state.isOnline ? .primary : .secondary)
                .font(.subheadline)
            Spacer()
        }
    }

    private var tint: Color {
        switch state {
        case .online: return .green
        case .waiting, .connecting: return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }
}
