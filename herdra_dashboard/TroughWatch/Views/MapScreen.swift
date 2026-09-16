import SwiftUI
import MapKit

/// Every trough on one map. The visible area grows automatically so that home
/// and all troughs stay in frame as more are added.
struct MapScreen: View {
    @EnvironmentObject private var store: TroughStore
    @EnvironmentObject private var locator: LocationManager

    @State private var camera: MapCameraPosition = .automatic
    @State private var selection: UUID?
    @State private var satellite = false
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            Map(position: $camera, selection: $selection) {
                if let home = store.home {
                    Annotation(home.label, coordinate: home.coordinate.clCoordinate) {
                        HomeMarker()
                    }
                }

                ForEach(store.troughs) { trough in
                    if trough.status.needsAttention {
                        MapCircle(center: trough.coordinate.clCoordinate, radius: attentionRadius)
                            .foregroundStyle(trough.status.tint.opacity(0.22))
                            .stroke(trough.status.tint, lineWidth: 2)
                    }

                    Annotation(trough.name, coordinate: trough.coordinate.clCoordinate) {
                        TroughMarker(trough: trough, isSelected: selection == trough.id)
                    }
                    .tag(trough.id)
                }

                UserAnnotation()
            }
            .mapStyle(satellite ? .hybrid(elevation: .flat) : .standard(elevation: .flat))
            .mapControls {
                MapUserLocationButton()
                MapCompass()
                MapScaleView()
            }
            .safeAreaInset(edge: .bottom) {
                if let trough = selectedTrough {
                    SelectedTroughCard(trough: trough, distance: store.distanceFromHome(to: trough)) {
                        selection = nil
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        satellite.toggle()
                    } label: {
                        Label("Map style", systemImage: satellite ? "globe.europe.africa.fill" : "map")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        fitAll(animated: true)
                    } label: {
                        Label("Fit all", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add trough", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) { AddTroughView() }
            .onAppear { fitAll(animated: false) }
            .onChange(of: store.troughs.count) { fitAll(animated: true) }
            .animation(.snappy, value: selection)
        }
    }

    private var selectedTrough: Trough? {
        guard let selection else { return nil }
        return store.troughs.first { $0.id == selection }
    }

    /// Ring size scales a little with how spread out the troughs are.
    private var attentionRadius: CLLocationDistance {
        let span = MapFitter.region(for: store.allCoordinates).span.latitudeDelta
        return max(12, min(120, span * 111_000 * 0.06))
    }

    private func fitAll(animated: Bool) {
        let region = MapFitter.region(for: store.allCoordinates)
        if animated {
            withAnimation(.easeInOut) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }
}

// MARK: - Region fitting

enum MapFitter {
    /// Bounding box around every point, padded, with a sane floor and ceiling.
    static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 48.137, longitude: 11.575),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }

        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude

        for coordinate in coordinates {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let padding = 1.5
        let minimumSpan = 0.0035   // roughly 350 m across, so a single pin isn't zoomed to the grass
        let maximumSpan = 4.0

        let span = MKCoordinateSpan(
            latitudeDelta: min(max((maxLat - minLat) * padding, minimumSpan), maximumSpan),
            longitudeDelta: min(max((maxLon - minLon) * padding, minimumSpan), maximumSpan)
        )

        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Markers

struct HomeMarker: View {
    var body: some View {
        Image(systemName: "house.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(8)
            .background(Color.accentColor, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2, y: 1)
    }
}

struct TroughMarker: View {
    let trough: Trough
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(trough.status.tint)
                .frame(width: isSelected ? 38 : 30, height: isSelected ? 38 : 30)
                .overlay(Circle().stroke(.white, lineWidth: 2.5))
                .shadow(radius: 3, y: 1)
            Image(systemName: "drop.fill")
                .font(.system(size: isSelected ? 17 : 14, weight: .bold))
                .foregroundStyle(.white)
        }
        .animation(.snappy, value: isSelected)
    }
}

// MARK: - Selected trough card

struct SelectedTroughCard: View {
    @EnvironmentObject private var store: TroughStore
    let trough: Trough
    let distance: Double?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(trough.name, systemImage: trough.status.symbol)
                    .font(.headline)
                    .foregroundStyle(trough.status.tint)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(trough.status.label)
                .font(.subheadline)

            HStack(spacing: 10) {
                Text(trough.deviceID)
                if let distance {
                    Text("·")
                    Text("\(Format.distance(distance)) from home")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            NavigationLink {
                TroughDetailView(troughID: trough.id)
            } label: {
                Text("Open details")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(trough.status.needsAttention ? trough.status.tint : Color.clear, lineWidth: 2)
        )
        .shadow(radius: 8, y: 3)
    }
}
