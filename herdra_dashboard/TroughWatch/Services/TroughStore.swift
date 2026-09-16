import Foundation
import CoreLocation

/// Holds the home location and every trough, and writes them to a JSON file
/// in Documents so the list survives app launches.
final class TroughStore: ObservableObject {

    @Published var home: HomeBase? { didSet { saveIfReady() } }
    @Published var troughs: [Trough] = [] { didSet { saveIfReady() } }

    private var isLoading = false

    private let fileURL: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("troughwatch-state.json")
    }()

    init() {
        load()
    }

    // MARK: - Derived values

    var activeTroughs: [Trough] { troughs.filter(\.isActive) }

    var alertCount: Int { troughs.filter { $0.status == .bad }.count }
    var warningCount: Int { troughs.filter { $0.status == .warning }.count }
    var healthyCount: Int { troughs.filter { $0.status == .good }.count }
    var silentCount: Int { troughs.filter { $0.status == .unknown }.count }

    /// Home first, then every trough — used to fit the map.
    var allCoordinates: [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        if let home { result.append(home.coordinate.clCoordinate) }
        result.append(contentsOf: troughs.map(\.coordinate.clCoordinate))
        return result
    }

    func distanceFromHome(to trough: Trough) -> CLLocationDistance? {
        guard let home else { return nil }
        return home.coordinate.distance(to: trough.coordinate)
    }

    func suggestedName() -> String {
        "Trough \(troughs.count + 1)"
    }

    func suggestedDeviceID() -> String {
        String(format: "DEV-%03d", troughs.count + 1)
    }

    // MARK: - Editing

    func setHome(_ location: CLLocation, label: String = "Home") {
        home = HomeBase(label: label, coordinate: Coordinate(location))
    }

    @discardableResult
    func addTrough(name: String, deviceID: String, location: CLLocation, note: String = "") -> Trough {
        let trough = Trough(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceID: deviceID.trimmingCharacters(in: .whitespacesAndNewlines),
            coordinate: Coordinate(location),
            note: note
        )
        troughs.append(trough)
        return trough
    }

    func update(_ trough: Trough) {
        guard let index = troughs.firstIndex(where: { $0.id == trough.id }) else { return }
        troughs[index] = trough
    }

    func delete(_ trough: Trough) {
        troughs.removeAll { $0.id == trough.id }
    }

    func delete(at offsets: IndexSet) {
        troughs.remove(atOffsets: offsets)
    }

    func moveTrough(_ trough: Trough, to location: CLLocation) {
        guard let index = troughs.firstIndex(where: { $0.id == trough.id }) else { return }
        troughs[index].coordinate = Coordinate(location)
    }

    func resetEverything() {
        isLoading = true
        troughs = []
        home = nil
        isLoading = false
        save()
    }

    // MARK: - Incoming readings

    /// Files the newest packet from each device against the trough it belongs
    /// to. Packets already applied are skipped, so a status set by hand holds
    /// until something new actually arrives.
    ///
    /// Routing goes in three steps: a device ID in the LoRa line if the sender
    /// includes one, then the trough picked in Settings, then the first active
    /// trough.
    func apply(_ snapshot: FeedSnapshot, preferring troughID: UUID?) {
        var newestByDevice: [String: FeedPacket] = [:]
        for packet in snapshot.packets {
            newestByDevice[packet.deviceID?.uppercased() ?? ""] = packet
        }

        for packet in newestByDevice.values.sorted(by: { $0.number < $1.number }) {
            guard let index = routingIndex(for: packet.deviceID, preferring: troughID) else { continue }
            guard troughs[index].lastReading?.packetKey != packet.reading.packetKey else { continue }
            troughs[index].lastReading = packet.reading
        }
    }

    private func routingIndex(for deviceID: String?, preferring troughID: UUID?) -> Int? {

        if let deviceID,
           let match = troughs.firstIndex(where: {
               $0.deviceID.compare(deviceID, options: .caseInsensitive) == .orderedSame
           }) {
            return match
        }

        if let troughID, let match = troughs.firstIndex(where: { $0.id == troughID }) {
            return match
        }

        return troughs.firstIndex(where: \.isActive)
    }

    /// The trough the receiver feed is currently being filed against, for the
    /// screens that want to show it.
    func stationTrough(preferring troughID: UUID?) -> Trough? {
        if let troughID, let match = troughs.first(where: { $0.id == troughID }) {
            return match
        }
        return troughs.first(where: \.isActive)
    }

    // MARK: - Stand-in for the receiver

    /// For trying the app out with no station on the network: fills every
    /// active trough with a packet shaped like a real one, then lets
    /// `StatusRule` colour it, so what you see matches what the rules do.
    func simulateIncomingReadings() {
        for index in troughs.indices where troughs[index].isActive {
            let roll = Double.random(in: 0...1)
            let healthy = roll < 0.65

            let reading = Reading(
                timestamp: .now,
                temperatureC: Double.random(in: 4...24),
                turbidityNTU: healthy ? Double.random(in: 0...90) : Double.random(in: 520...900),
                waterLevelCM: roll > 0.85 ? Double.random(in: 1...9) : Double.random(in: 12...60),
                algae: Double.random(in: 0...45),
                confidence: Double.random(in: 55...99),
                quality: healthy ? Double.random(in: 62...98) : Double.random(in: 20...49),
                cameraFresh: roll < 0.9,
                cameraErrorCode: roll > 0.95 ? 3 : 0,
                cameraAgeSeconds: Double.random(in: 1...300),
                rssi: Double.random(in: -115 ... -60),
                snr: Double.random(in: -8...11),
                rawMessage: "SIMULATED",
                serverTime: Date.now.formatted(date: .omitted, time: .standard)
            )

            troughs[index].lastReading = StatusRule.applied(to: reading)
        }
    }

    func setStatus(_ status: WaterStatus, for trough: Trough) {
        guard let index = troughs.firstIndex(where: { $0.id == trough.id }) else { return }
        var reading = troughs[index].lastReading ?? Reading()
        reading.status = status
        reading.timestamp = .now
        troughs[index].lastReading = reading
    }

    // MARK: - Persistence

    private struct SavedState: Codable {
        var home: HomeBase?
        var troughs: [Trough]
    }

    private func saveIfReady() {
        guard !isLoading else { return }
        save()
    }

    private func save() {
        let state = SavedState(home: home, troughs: troughs)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("TroughWatch: could not save state — \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(SavedState.self, from: data)
            home = state.home
            troughs = state.troughs
        } catch {
            print("TroughWatch: could not load state — \(error.localizedDescription)")
        }
    }
}
