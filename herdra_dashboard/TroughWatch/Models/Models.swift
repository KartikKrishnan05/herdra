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

    /// The headline a farmer sees — what to do, not what was measured.
    var label: String {
        switch self {
        case .good: return "All good"
        case .warning: return "Keep an eye on it"
        case .bad: return "Needs attention"
        case .unknown: return "No recent news"
        }
    }

    var shortLabel: String {
        switch self {
        case .good: return "Good"
        case .warning: return "Watch"
        case .bad: return "Act now"
        case .unknown: return "No news"
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

    /// For picking the worst of several: bad beats warning beats good, and
    /// unknown only wins when there is nothing else.
    var severity: Int {
        switch self {
        case .unknown: return 0
        case .good: return 1
        case .warning: return 2
        case .bad: return 3
        }
    }
}

// MARK: - Reading

/// One measurement packet from the receiver: the raw fields of the sender's
/// LoRa line, plus the depth and turbidity the app works out from them.
struct Reading: Codable, Hashable {
    var timestamp: Date = .now

    /// TEMP, in °C, straight from the DS18B20.
    var temperatureC: Double?
    /// LVL_MV, the level sensor's output in mV at GPIO3.
    var levelMV: Double?
    /// TURB_MV, the turbidity sensor's output in mV at GPIO4 (after the divider).
    var turbidityMV: Double?

    /// Worked out by the app from `turbidityMV` with the trough's
    /// `SensorCalibration`: 0 is clear water, 100 is as murky as the
    /// calibration goes. Not NTU. Older firmware sent this as TURB.
    var turbidityPercent: Double?
    /// Worked out by the app from `levelMV`, in centimetres. Older firmware
    /// sent this as LEVEL.
    var waterLevelCM: Double?

    /// ALGAE as sent: the share of the camera image with algae-like colour,
    /// 0–100. A clean surface still reads around 10.
    var cameraAlgae: Double?
    /// Worked out by the app from `cameraAlgae` with the trough's
    /// `SensorCalibration`: 0 is clean, 100 is fully covered.
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

    /// N_LVL, N_TURB, N_TEMP, N_CAM — how many of the sender's five rounds
    /// gave a valid value for each sensor.
    var validLevelRounds: Int?
    var validTurbidityRounds: Int?
    var validTemperatureRounds: Int?
    var validCameraRounds: Int?
    /// BATCH, the sender's running batch number since it booted.
    var batch: Int?

    /// Radio strength of the packet that carried this reading, in dBm.
    var rssi: Double?
    /// Signal-to-noise ratio of that packet, in dB.
    var snr: Double?

    /// The raw `TEMP=..,TURB=..` line, kept so the station can be debugged
    /// from the phone.
    var rawMessage: String?

    /// Wall-clock time the packet reached the receiver ("14:03:57").
    var serverTime: String?

    /// Identifies the receiver packet this came from.
    var packetKey: String?

    var cameraIsHealthy: Bool? {
        guard let cameraErrorCode else { return nil }
        return cameraErrorCode == 0
    }

    /// True when the packet carried no usable measurement at all.
    var isEmpty: Bool {
        temperatureC == nil && turbidityPercent == nil && waterLevelCM == nil
            && levelMV == nil && turbidityMV == nil && cameraAlgae == nil && algae == nil && quality == nil && cameraErrorCode == nil
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
    /// When the farmer last said they cleaned the trough. History from before
    /// this is kept for the chart but ignored when judging the water, so old
    /// algae doesn't keep the trough red.
    var cleanedAt: Date?
    /// Nil until someone changes it on the Developer tab.
    var calibration: SensorCalibration?
    /// How deep the water is when this trough is full, in cm, as set under
    /// Settings. Nil means `defaultFullLevelCM`.
    var fullLevel: Double?

    var sensorCalibration: SensorCalibration { calibration ?? .default }
    var fullLevelCM: Double { fullLevel ?? Self.defaultFullLevelCM }

    static let defaultFullLevelCM: Double = 18
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
