import Foundation
import CoreLocation
import SwiftUI

// MARK: - Coordinate

/// Codable stand-in for CLLocationCoordinate2D so troughs can be saved to disk.
struct Coordinate: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy in metres at the moment the point was captured.
    var accuracy: Double?

    init(latitude: Double, longitude: Double, accuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
    }

    init(_ location: CLLocation) {
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.accuracy = location.horizontalAccuracy
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    func distance(to other: Coordinate) -> CLLocationDistance {
        clLocation.distance(from: other.clLocation)
    }
}

// MARK: - Water status

enum WaterStatus: String, Codable, CaseIterable, Identifiable {
    case good
    case warning
    case bad
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .good: return "Water is fine"
        case .warning: return "Needs a look"
        case .bad: return "Water is bad"
        case .unknown: return "No data yet"
        }
    }

    var shortLabel: String {
        switch self {
        case .good: return "Fine"
        case .warning: return "Check"
        case .bad: return "Bad"
        case .unknown: return "No data"
        }
    }

    var tint: Color {
        switch self {
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        case .unknown: return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    /// Bad and warning troughs get a highlight ring drawn on the map.
    var needsAttention: Bool { self == .bad || self == .warning }
}

// MARK: - Reading

/// One measurement packet from the receiver, shaped like the fields the web
/// dashboard reads out of `/api/data` — same names, same units.
struct Reading: Codable, Hashable {
    var timestamp: Date = .now
    var status: WaterStatus = .unknown

    /// TEMP, in °C.
    var temperatureC: Double?
    /// TURB, in NTU.
    var turbidityNTU: Double?
    /// LEVEL, in centimetres (not a percentage — the sensor reports depth).
    var waterLevelCM: Double?

    /// ALGAE, the camera's algae index.
    var algae: Double?
    /// CONF, how sure the camera is of that index, 0–100.
    var confidence: Double?
    /// QUALITY, the station's own score for the whole measurement, 0–100.
    var quality: Double?

    /// CAM_FRESH — the image behind the algae number was taken just now.
    var cameraFresh: Bool?
    /// CAM_ERR — 0 means the camera is healthy.
    var cameraErrorCode: Int?
    /// CAM_AGE, seconds since the image was captured.
    var cameraAgeSeconds: Double?

    /// Radio strength of the packet that carried this reading, in dBm.
    var rssi: Double?
    /// Signal-to-noise ratio of that packet, in dB.
    var snr: Double?

    /// The raw `TEMP=..,TURB=..` line, kept so the station can be debugged
    /// from the phone the same way the dashboard shows it.
    var rawMessage: String?

    /// Wall-clock time the packet reached the receiver ("14:03:57").
    var serverTime: String?

    /// Identifies the receiver packet this came from, so polling the same
    /// buffer again doesn't re-file (and overwrite a hand-set status with)
    /// a packet that has already been applied.
    var packetKey: String?

    var cameraIsHealthy: Bool? {
        guard let cameraErrorCode else { return nil }
        return cameraErrorCode == 0
    }

    /// True when the packet carried no usable measurement at all.
    var isEmpty: Bool {
        temperatureC == nil && turbidityNTU == nil && waterLevelCM == nil
            && algae == nil && quality == nil && cameraErrorCode == nil
    }
}

// MARK: - Status rules

/// The one place that decides good / check / bad. These are the same tests the
/// web dashboard runs for its alert banner, in the same order, so a trough is
/// never red on one screen and green on the other.
enum StatusRule {

    /// Turbidity above this is treated as bad water.
    static let turbidityLimitNTU: Double = 500
    /// Below this depth the trough counts as critically low.
    static let lowLevelCM: Double = 10
    /// A measurement scoring under this is not trusted.
    static let minimumQuality: Double = 50

    /// The status and the sentence explaining it, for one reading.
    static func evaluate(_ reading: Reading) -> (status: WaterStatus, reason: String) {

        if reading.isEmpty {
            return (.unknown, "No measurements in the last packet")
        }

        if let code = reading.cameraErrorCode, code != 0 {
            return (.bad, "Camera system error")
        }

        if let quality = reading.quality, quality < minimumQuality {
            return (.bad, "Poor measurement quality")
        }

        if let turbidity = reading.turbidityNTU, turbidity > turbidityLimitNTU {
            return (.bad, "Water turbidity is very high")
        }

        if let level = reading.waterLevelCM {
            if level < lowLevelCM {
                return (.bad, "Water level is critically low")
            }
        } else {
            return (.warning, "Water level measurement unavailable")
        }

        return (.good, "Water station operating normally")
    }

    /// Copy of `reading` with its status filled in from the rules above.
    static func applied(to reading: Reading) -> Reading {
        var copy = reading
        copy.status = evaluate(reading).status
        return copy
    }
}

// MARK: - Trough

struct Trough: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var deviceID: String
    var coordinate: Coordinate
    var installedAt: Date = .now
    var isActive: Bool = true
    var note: String = ""
    var lastReading: Reading?

    var status: WaterStatus {
        guard isActive else { return .unknown }
        return lastReading?.status ?? .unknown
    }
}

// MARK: - Home

struct HomeBase: Codable, Hashable {
    var label: String = "Home"
    var coordinate: Coordinate
    var savedAt: Date = .now
}

// MARK: - Formatting helpers

enum Format {
    static func distance(_ metres: CLLocationDistance) -> String {
        let measurement = Measurement(value: metres, unit: UnitLength.meters)
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = metres < 1000 ? 0 : 1
        return formatter.string(from: measurement)
    }

    static func coordinate(_ coordinate: Coordinate) -> String {
        String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    static func accuracy(_ metres: Double?) -> String {
        guard let metres, metres > 0 else { return "accuracy unknown" }
        return String(format: "±%.0f m", metres)
    }

    /// A measurement, or "N/A" the way the dashboard shows a missing one.
    static func reading(_ value: Double?, unit: String, decimals: Int) -> String {
        guard let value, value.isFinite else { return "N/A" }
        let number = String(format: "%.\(decimals)f", value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// "3 h 12 min", for the receiver's uptime.
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds < 60 ? [.second] : [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, seconds)) ?? "—"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
