import SwiftUI
import CoreLocation

/// Used while standing at the trough: name the device and pin where it is.
struct AddTroughView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var locator: LocationManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var deviceID = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LocationReadoutView()
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Where you are standing")
                } footer: {
                    Text(locator.hasUsableFix
                         ? "Stand right at the trough when you save."
                         : "Hold still outdoors for a few seconds — the fix is still settling.")
                }

                Section("Device") {
                    TextField("Name", text: $name, prompt: Text(store.suggestedName()))
                    TextField("Device ID", text: $deviceID, prompt: Text(store.suggestedDeviceID()))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("Note") {
                    TextField("Field, gate, anything worth remembering", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Label("Save location and add device", systemImage: "mappin.and.ellipse")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(locator.location == nil)
                    .listRowBackground(Color.clear)
                }

                if let home = store.home, let location = locator.location {
                    Section {
                        LabeledContent("Distance from home",
                                       value: Format.distance(home.coordinate.distance(to: Coordinate(location))))
                    }
                }
            }
            .navigationTitle("New trough")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { locator.startUpdating() }
        }
    }

    private func save() {
        guard let location = locator.location else { return }
        let finalName = name.trimmingCharacters(in: .whitespaces).isEmpty ? store.suggestedName() : name
        let finalID = deviceID.trimmingCharacters(in: .whitespaces).isEmpty ? store.suggestedDeviceID() : deviceID
        store.addTrough(name: finalName, deviceID: finalID, location: location, note: note)
        dismiss()
    }
}
