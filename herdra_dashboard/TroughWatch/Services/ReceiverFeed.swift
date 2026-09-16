import Foundation

// MARK: - Where the receiver lives

/// Everything the app needs to find the Heltec receiver, kept in UserDefaults.
///
/// The receiver runs its own Wi-Fi access point (`HERDRA-RX`) and serves its
/// packet buffer at `http://192.168.4.1/data`, so out of the box there is
/// nothing to type — join that network and the feed comes through.
struct ReceiverSettings: Equatable {

    /// Host as typed — "192.168.4.1", "herdra.local", or a full "http://…" URL.
    var address: String = ReceiverSettings.defaultAddress
    /// Whether to poll at all.
    var isEnabled: Bool = true
    /// Which trough packets without a device ID belong to. `nil` means "the
    /// first active trough".
    var stationTroughID: UUID?
    /// How often to ask, in seconds. The receiver's own web page uses 1.
    var pollInterval: TimeInterval = 2

    /// The access point address hard-coded in the receiver firmware.
    static let defaultAddress = "192.168.4.1"
    static let defaultPort = 80

    // New key names: the old ones pointed at the dashboard server on port
    // 50001, which would never answer on the receiver's network.
    private enum Key {
        static let address = "heltec.address"
        static let enabled = "heltec.enabled"
        static let trough = "heltec.stationTroughID"
        static let interval = "heltec.pollInterval"
    }

    static func load(from defaults: UserDefaults = .standard) -> ReceiverSettings {
        var settings = ReceiverSettings()
        if let address = defaults.string(forKey: Key.address), !address.isEmpty {
            settings.address = address
        }
        if defaults.object(forKey: Key.enabled) != nil {
            settings.isEnabled = defaults.bool(forKey: Key.enabled)
        }
        if let raw = defaults.string(forKey: Key.trough) {
            settings.stationTroughID = UUID(uuidString: raw)
        }
        let interval = defaults.double(forKey: Key.interval)
        settings.pollInterval = interval > 0 ? interval : 2
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(address, forKey: Key.address)
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(stationTroughID?.uuidString, forKey: Key.trough)
        defaults.set(pollInterval, forKey: Key.interval)
    }

    /// Turns whatever was typed into the receiver's `/data` URL, filling in the
    /// scheme when it is missing. Port 80 is HTTP's default, so none is added.
    var dataURL: URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }

        guard var components = URLComponents(string: text), components.host != nil else { return nil }

        // Ignore any path that was pasted — the endpoint is always /data.
        components.path = "/data"
        components.query = nil
        components.fragment = nil

        return components.url
    }

    /// The address the way it will actually be used, for showing back.
    var resolvedDescription: String {
        dataURL?.absoluteString ?? "Not a usable address"
    }
}

// MARK: - What comes back

/// One packet in the receiver's buffer, for the history chart.
struct FeedHistoryPoint: Hashable, Identifiable {
    var id: Int
    var time: String
    var temperature: Double?
    var turbidity: Double?
    var algae: Double?
    var quality: Double?
}

/// One LoRa packet, decoded into a reading.
struct FeedPacket {
    /// The receiver's running packet number.
    var number: Int
    var reading: Reading
    /// Device ID if the LoRa line carried one.
    var deviceID: String?
}

/// Receiver-wide counters from the `/data` response.
struct ReceiverInfo: Equatable {
    /// Packets received since boot or the last clear, not just the ones held.
    var totalPackets: Int
    /// Phones currently joined to the access point.
    var clients: Int
    /// Seconds since the receiver booted.
    var uptimeSeconds: TimeInterval
}

/// A decoded `/data` response.
struct FeedSnapshot {
    /// Oldest to newest, at most the 50 the receiver keeps.
    var packets: [FeedPacket]
    var history: [FeedHistoryPoint]
    var info: ReceiverInfo

    var latest: FeedPacket? { packets.last }
    var isWaitingForFirstPacket: Bool { packets.isEmpty }
}

// MARK: - JSON decoding

/// The body `handleData()` in the firmware writes:
/// `{"total":N,"uptime":ms,"clients":N,"packets":[{"id","rssi","snr","age","msg"}]}`
struct HeltecResponse: Decodable {
    var total: Int
    var uptime: Double
    var clients: Int
    var packets: [HeltecPacket]
}

struct HeltecPacket: Decodable {
    var id: Int
    var rssi: Double
    var snr: Double
    /// Milliseconds since the receiver heard it.
    var age: Double
    var msg: String
}

// MARK: - Reading the LoRa line

/// The receiver no longer has a server in front of it to parse packets, so the
/// app does it: the sender's `TEMP=21.4,TURB=12,LEVEL=35,...` line is split
/// here into the fields a `Reading` holds.
enum LoRaMessage {

    private static let idKeys: Set<String> = ["ID", "DEV", "DEVICE", "NODE", "STATION"]

    /// Every `KEY=VALUE` (or `KEY:VALUE`) pair, keys upper-cased. Pairs may be
    /// separated by commas, semicolons, spaces or newlines.
    static func fields(in message: String?) -> [String: String] {
        guard let message else { return [:] }
        var result: [String: String] = [:]
        let separators = CharacterSet(charactersIn: ",;\n\r\t ")
        for part in message.components(separatedBy: separators) {
            guard let split = part.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let key = part[..<split].trimmingCharacters(in: .whitespaces).uppercased()
            let value = part[part.index(after: split)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    static func deviceID(in message: String?) -> String? {
        let fields = fields(in: message)
        for key in idKeys {
            guard let value = fields[key], !value.isEmpty, value.uppercased() != "NA" else { continue }
            return value
        }
        return nil
    }

    /// First key present with a number in it. Tolerates a trailing unit
    /// ("21.4C", "35cm") and treats "NA" / "nan" as missing.
    static func number(_ fields: [String: String], _ keys: String...) -> Double? {
        for key in keys {
            guard var text = fields[key] else { continue }
            switch text.lowercased() {
            case "true", "yes", "on": return 1
            case "false", "no", "off": return 0
            default: break
            }
            while let last = text.last, !(last.isNumber || last == ".") {
                text.removeLast()
            }
            if let value = Double(text), value.isFinite { return value }
        }
        return nil
    }

    /// The measurement half of a reading; radio and timing are filled in by
    /// the caller, which knows them from the receiver rather than the line.
    static func reading(from message: String) -> Reading {
        let f = fields(in: message)
        return Reading(
            temperatureC: number(f, "TEMP", "TEMPERATURE", "T"),
            turbidityNTU: number(f, "TURB", "TURBIDITY", "NTU"),
            waterLevelCM: number(f, "LEVEL", "WATER_LEVEL", "WL"),
            algae: number(f, "ALGAE", "ALG"),
            confidence: number(f, "CONF", "CONFIDENCE"),
            quality: number(f, "QUALITY", "QUAL", "Q"),
            cameraFresh: number(f, "CAM_FRESH", "FRESH").map { $0 != 0 },
            cameraErrorCode: number(f, "CAM_ERR", "CAM_ERROR", "ERR").map { Int($0) },
            cameraAgeSeconds: number(f, "CAM_AGE"),
            rawMessage: message
        )
    }
}

// MARK: - The client

/// Polls the receiver's `/data` on a timer, the same way its own web page
/// does, and hands each decoded snapshot to whoever set `onSnapshot`.
@MainActor
final class ReceiverClient: ObservableObject {

    enum ConnectionState: Equatable {
        case off
        case connecting
        case online(lastUpdate: String?)
        case waiting
        case failed(String)

        var isOnline: Bool {
            if case .online = self { return true }
            return false
        }
    }

    @Published private(set) var state: ConnectionState = .off
    @Published private(set) var history: [FeedHistoryPoint] = []
    @Published private(set) var info: ReceiverInfo?
    @Published private(set) var lastSnapshotAt: Date?

    @Published var settings: ReceiverSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            restart()
        }
    }

    /// Called on the main actor for every successful poll, with the trough
    /// nominated in Settings so the handler doesn't have to reach back into
    /// the client for it.
    var onSnapshot: ((FeedSnapshot, UUID?) -> Void)?

    private var pollTask: Task<Void, Never>?
    private let session: URLSession

    /// When each packet arrived, worked out once from its `age` and then kept,
    /// so the same packet doesn't get a slightly different time on every poll.
    /// Keyed by packet number plus the receiver-uptime it arrived at, which
    /// stays unique across a receiver reboot or a clear.
    private var arrivals: [String: Date] = [:]

    init(settings: ReceiverSettings = .load()) {
        self.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Control

    func start() {
        restart()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        state = .off
    }

    /// One poll, right now, without waiting for the timer — used by the
    /// "Check the connection" button.
    func refreshNow() async {
        await poll()
    }

    private func restart() {
        pollTask?.cancel()
        pollTask = nil

        guard settings.isEnabled else {
            state = .off
            return
        }

        guard settings.dataURL != nil else {
            state = .failed("That address isn't a host the app can reach")
            return
        }

        state = .connecting

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                let seconds = max(1, self.settings.pollInterval)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    // MARK: One round trip

    private func poll() async {
        guard let url = settings.dataURL else {
            state = .failed("That address isn't a host the app can reach")
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                state = .failed("Receiver answered \(http.statusCode)")
                return
            }

            // A corrupted LoRa packet can put bytes in `msg` that aren't valid
            // UTF-8, which JSONDecoder rejects outright. Swap them for U+FFFD.
            let cleaned = Data(String(decoding: data, as: UTF8.self).utf8)
            let feed = try JSONDecoder().decode(HeltecResponse.self, from: cleaned)
            let snapshot = makeSnapshot(from: feed)

            history = snapshot.history
            info = snapshot.info
            lastSnapshotAt = .now

            if let latest = snapshot.latest {
                state = .online(lastUpdate: "packet #\(latest.number), \(Format.relative(latest.reading.timestamp))")
            } else {
                state = .waiting
            }

            onSnapshot?(snapshot, settings.stationTroughID)

        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch is DecodingError {
            state = .failed("That address answered, but not like the HERDRA receiver")
        } catch {
            state = .failed(Self.describe(error))
        }
    }

    // MARK: Turning the response into readings

    private func makeSnapshot(from feed: HeltecResponse) -> FeedSnapshot {
        let now = Date.now
        var seen: [String: Date] = [:]

        let packets = feed.packets.map { raw -> FeedPacket in
            let key = "\(raw.id)@\(Int(((feed.uptime - raw.age) / 1000).rounded()))"
            let arrived = arrivals[key] ?? now.addingTimeInterval(-raw.age / 1000)
            seen[key] = arrived

            var reading = LoRaMessage.reading(from: raw.msg)
            reading.timestamp = arrived
            reading.rssi = raw.rssi
            reading.snr = raw.snr
            reading.serverTime = arrived.formatted(date: .omitted, time: .standard)
            reading.packetKey = key

            return FeedPacket(
                number: raw.id,
                reading: StatusRule.applied(to: reading),
                deviceID: LoRaMessage.deviceID(in: raw.msg)
            )
        }

        // Forget packets the receiver has dropped out of its buffer.
        arrivals = seen

        let history = packets.map { packet in
            FeedHistoryPoint(
                id: packet.number,
                time: packet.reading.serverTime ?? "",
                temperature: packet.reading.temperatureC,
                turbidity: packet.reading.turbidityNTU,
                algae: packet.reading.algae,
                quality: packet.reading.quality
            )
        }

        return FeedSnapshot(
            packets: packets,
            history: history,
            info: ReceiverInfo(
                totalPackets: feed.total,
                clients: feed.clients,
                uptimeSeconds: feed.uptime / 1000
            )
        )
    }

    private static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else {
            return "Couldn't read the receiver's answer"
        }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost:
            return "No receiver at that address — is the phone on HERDRA-RX?"
        case .timedOut:
            return "The receiver didn't answer — is the phone on HERDRA-RX?"
        case .notConnectedToInternet, .networkConnectionLost:
            return "The phone isn't on the receiver's Wi-Fi"
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS blocked the plain-HTTP connection"
        default:
            return urlError.localizedDescription
        }
    }
}

// MARK: - Describing the state on screen

extension ReceiverClient.ConnectionState {

    var label: String {
        switch self {
        case .off: return "Off"
        case .connecting: return "Connecting…"
        case .waiting: return "Connected · waiting for a packet"
        case .online(let time): return time.map { "Online · \($0)" } ?? "Online"
        case .failed(let reason): return reason
        }
    }

    var symbol: String {
        switch self {
        case .off: return "antenna.radiowaves.left.and.right.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .waiting: return "clock.badge.questionmark"
        case .online: return "antenna.radiowaves.left.and.right"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
