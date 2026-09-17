import Foundation
import CoreLocation

/// Holds the home location, every trough and a week of readings per trough,
/// and writes them to JSON files in Documents so they survive app launches.
final class TroughStore: ObservableObject {

    @Published var home: HomeBase? { didSet { saveIfReady() } }
    @Published var troughs: [Trough] = [] {
        didSet {
            saveIfReady()
            refreshAssessments()
        }
    }

    /// Oldest to newest, per trough ID.
    @Published private(set) var history: [UUID: [Sample]] = [:]
    /// What the app makes of each trough right now, rebuilt whenever a trough
    /// or its history changes.
    @Published private(set) var assessments: [UUID: TroughAssessment] = [:]

    private var isLoading = false
    private var assessedAt = Date.distantPast
    private var compactedAt = Date.distantPast
    private var historySaveTask: Task<Void, Never>?

    /// Packets are at least 30 s apart. One within this much of the last
    /// stored sample is the same packet seen again — its arrival time is
    /// worked out from its age, which can wobble a second or two between
    /// launches.
    private static let duplicateWindow: TimeInterval = 10

    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let fileURL = documents.appendingPathComponent("troughwatch-state.json")
    private let historyURL = documents.appendingPathComponent("troughwatch-history.json")

    /// Earlier builds could fill history with a made-up week. It can't be told
    /// apart from real readings, so all stored readings are cleared once.
    private static let purgedMadeUpDataKey = "troughwatch.purgedMadeUpData.v1"

    init() {
        load()
        if !UserDefaults.standard.bool(forKey: Self.purgedMadeUpDataKey) {
            clearReadings()
            UserDefaults.standard.set(true, forKey: Self.purgedMadeUpDataKey)
        }
    }

    // MARK: - Derived values

    var activeTroughs: [Trough] { troughs.filter(\.isActive) }

    func assessment(for trough: Trough) -> TroughAssessment {
        assessments[trough.id] ?? Assessment.evaluate(history[trough.id] ?? [], isActive: trough.isActive,
                                                   fullLevelCM: trough.fullLevelCM)
    }

    func status(of trough: Trough) -> WaterStatus {
        assessment(for: trough).status
    }

    func samples(for trough: Trough) -> [Sample] {
        history[trough.id] ?? []
    }

    var alertCount: Int { troughs.filter { status(of: $0) == .bad }.count }
    var warningCount: Int { troughs.filter { status(of: $0) == .warning }.count }
    var healthyCount: Int { troughs.filter { status(of: $0) == .good }.count }
    var silentCount: Int { troughs.filter { status(of: $0) == .unknown }.count }

    /// Worst first, so the trough that needs a visit is at the top.
    var troughsByUrgency: [Trough] {
        troughs.enumerated()
            .sorted { a, b in
                let sa = status(of: a.element).severity, sb = status(of: b.element).severity
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

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
        history[trough.id] = nil
        scheduleHistorySave()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets { history[troughs[index].id] = nil }
        troughs.remove(atOffsets: offsets)
        scheduleHistorySave()
    }

    func moveTrough(_ trough: Trough, to location: CLLocation) {
        guard let index = troughs.firstIndex(where: { $0.id == trough.id }) else { return }
        troughs[index].coordinate = Coordinate(location)
    }

    /// Saves a new calibration and recalculates the trough's stored depth and
    /// turbidity from their raw voltages, so the history and the colours
    /// follow straight away.
    func setCalibration(_ calibration: SensorCalibration?, for trough: Trough) {
        guard let index = troughs.firstIndex(where: { $0.id == trough.id }) else { return }
        let effective = calibration ?? .default
        if let samples = history[trough.id] {
            history[trough.id] = samples.map { effective.applied(to: $0) }
            scheduleHistorySave()
        }
        var updated = troughs[index]
        updated.calibration = calibration
        if var reading = updated.lastReading {
            effective.apply(to: &reading)
            updated.lastReading = reading
        }
        troughs[index] = updated     // saves and reassesses
    }

    /// How deep the water is when the trough is full. The level limits are
    /// shares of this, so the trough is judged again straight away.
    func setFullLevel(_ cm: Double, for trough: Trough) {
        guard cm.isFinite, cm > 0,
              let index = troughs.firstIndex(where: { $0.id == trough.id }) else { return }
        troughs[index].fullLevel = cm
    }

    /// The farmer cleaned the trough: judge it only on what comes after.
    func markCleaned(_ trough: Trough) {
        guard let index = troughs.firstIndex(where: { $0.id == trough.id }) else { return }
        troughs[index].cleanedAt = .now
    }

    func resetEverything() {
        isLoading = true
        troughs = []
        home = nil
        history = [:]
        isLoading = false
        save()
        saveHistory()
        refreshAssessments()
    }

    // MARK: - Incoming readings

    /// Files every packet in the receiver's buffer against the trough it
    /// belongs to and adds the new ones to that trough's history.
    ///
    /// Routing goes in three steps: a device ID in the LoRa line if the sender
    /// includes one, then the trough picked in Settings, then the first active
    /// trough.
    func apply(_ snapshot: FeedSnapshot, preferring troughID: UUID?) {
        var updatedTroughs = troughs
        var updatedHistory = history
        var changed = false

        for packet in snapshot.packets.sorted(by: { $0.reading.timestamp < $1.reading.timestamp }) {
            guard let index = routingIndex(for: packet.deviceID, preferring: troughID) else { continue }
            let id = troughs[index].id
            var reading = packet.reading
            troughs[index].sensorCalibration.apply(to: &reading)

            let lastSeen = [updatedHistory[id]?.last?.timestamp, updatedTroughs[index].lastReading?.timestamp]
                .compactMap { $0 }.max()
            if let lastSeen, reading.timestamp < lastSeen.addingTimeInterval(Self.duplicateWindow) {
                continue
            }

            if !reading.isEmpty {
                updatedHistory[id, default: []].append(Sample(reading))
            }
            updatedTroughs[index].lastReading = reading
            changed = true
        }

        guard changed else {
            // Nothing new, but "last heard" and outdated-ness still move on.
            if Date.now.timeIntervalSince(assessedAt) > 60 { refreshAssessments() }
            return
        }

        if Date.now.timeIntervalSince(compactedAt) > 3600 {
            updatedHistory = updatedHistory.mapValues { History.compacted($0) }
            compactedAt = .now
        }

        history = updatedHistory
        troughs = updatedTroughs     // saves and reassesses once
        scheduleHistorySave()
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

    /// Rebuilds every trough's assessment from its history since it was last
    /// cleaned.
    func refreshAssessments() {
        guard !isLoading else { return }
        let now = Date.now
        var result: [UUID: TroughAssessment] = [:]
        for trough in troughs {
            var samples = history[trough.id] ?? []
            if let cleaned = trough.cleanedAt {
                samples.removeAll { $0.timestamp < cleaned }
            }
            var assessment = Assessment.evaluate(samples, isActive: trough.isActive,
                                                 fullLevelCM: trough.fullLevelCM, now: now)
            if samples.isEmpty, trough.cleanedAt != nil, trough.isActive {
                assessment.summary = "Cleaned \(Format.relative(trough.cleanedAt!)). Waiting for new readings."
                assessment.lastHeard = history[trough.id]?.last?.timestamp
            }
            result[trough.id] = assessment
        }
        assessments = result
        assessedAt = now
    }

    // MARK: - Clearing readings

    /// Forgets every stored reading and last packet, keeping the troughs,
    /// their settings and the home. The receiver still holds its last 50
    /// packets, so the most recent real readings come back on the next poll.
    func clearReadings() {
        history = [:]
        for index in troughs.indices {
            troughs[index].lastReading = nil
        }
        saveHistory()
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
        write(SavedState(home: home, troughs: troughs), to: fileURL, pretty: true)
    }

    /// History is far bigger than the trough list and grows with every
    /// packet, so it's written at most every half minute, plus when the app
    /// goes to the background.
    private func scheduleHistorySave() {
        guard historySaveTask == nil else { return }
        historySaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            self?.historySaveTask = nil
            self?.saveHistory()
        }
    }

    /// Writes any pending history now.
    func flush() {
        guard historySaveTask != nil else { return }
        historySaveTask?.cancel()
        historySaveTask = nil
        saveHistory()
    }

    private func saveHistory() {
        let keyed = Dictionary(uniqueKeysWithValues: history.map { ($0.key.uuidString, $0.value) })
        write(keyed, to: historyURL, pretty: false)
    }

    private func write<T: Encodable>(_ value: T, to url: URL, pretty: Bool) {
        do {
            let encoder = JSONEncoder()
            if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
            encoder.dateEncodingStrategy = pretty ? .iso8601 : .secondsSince1970
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            print("TroughWatch: could not save \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    private func load() {
        isLoading = true
        defer {
            isLoading = false
            refreshAssessments()
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(SavedState.self, from: Data(contentsOf: fileURL))
                home = state.home
                troughs = state.troughs
            } catch {
                print("TroughWatch: could not load state — \(error.localizedDescription)")
            }
        }

        if FileManager.default.fileExists(atPath: historyURL.path) {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let keyed = try decoder.decode([String: [Sample]].self, from: Data(contentsOf: historyURL))
                // Converted again from the raw values on every launch, so a
                // change to the default calibration reaches stored readings.
                let calibrations = Dictionary(troughs.map { ($0.id, $0.sensorCalibration) }, uniquingKeysWith: { a, _ in a })
                history = Dictionary(uniqueKeysWithValues: keyed.compactMap { key, samples in
                    UUID(uuidString: key).map { id in
                        let calibration = calibrations[id] ?? .default
                        return (id, History.compacted(samples).map { calibration.applied(to: $0) })
                    }
                })
                compactedAt = .now
            } catch {
                print("TroughWatch: could not load history — \(error.localizedDescription)")
            }
        }
    }
}
