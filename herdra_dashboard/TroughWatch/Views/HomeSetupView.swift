import SwiftUI
import UIKit
import CoreLocation

/// Runs once, at the house: capture the home point everything else is measured from.
struct HomeSetupView: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var locator: LocationManager

    @State private var label = "Home"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "house.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.tint)
                Text("Start at the house")
                    .font(.largeTitle.bold())
                Text("Stand at the house and save this spot. Every trough you add later is shown as a distance and direction from here.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            TextField("Name for this place", text: $label)
                .textFieldStyle(.roundedBorder)

            LocationReadoutView()

            Spacer()

            switch locator.authorization {
            case .notDetermined:
                Button("Allow location access") { locator.requestAuthorization() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

            case .denied, .restricted:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Location is turned off for this app. Turn it on in Settings, then come back.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }

            default:
                Button {
                    if let location = locator.location {
                        store.setHome(location, label: label.isEmpty ? "Home" : label)
                    }
                } label: {
                    Label("Save this as home", systemImage: "mappin.and.ellipse")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(locator.location == nil)

                if !locator.hasUsableFix {
                    Text("Wait a moment for the fix to tighten up before saving — outdoors is best.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .onAppear { locator.startUpdating() }
    }
}

/// Live GPS readout shared by the setup and add-trough screens.
struct LocationReadoutView: View {
    @EnvironmentObject private var locator: LocationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: locator.hasUsableFix ? "location.fill" : "location.slash")
                    .foregroundStyle(locator.hasUsableFix ? Color.green : Color.orange)
                Text(locator.coordinateText)
                    .font(.system(.body, design: .monospaced))
            }
            Text(locator.accuracyText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let error = locator.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
