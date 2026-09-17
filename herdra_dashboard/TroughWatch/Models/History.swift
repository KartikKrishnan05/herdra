import Foundation
import SwiftUI

// MARK: - Sample

/// The measurement part of one reading, as kept in a trough's history. Short
/// coding keys, because a week of these is written to disk.
struct Sample: Codable, Hashable {
    var timestamp: Date
    var temperatureC: Double?
    var turbidityPercent: Double?
    var waterLevelCM: Double?
    var algae: Double?
    var quality: Double?
    var cameraError: Bool?
    /// The raw voltages the level and turbidity above were worked out from,
    /// kept so history can be recalculated when the calibration changes.
    /// Nil for readings from before the sender sent millivolts.
    var levelMV: Double?
    var turbidityMV: Double?
    /// The camera's own ALGAE value that `algae` was worked out from.
    var cameraAlgae: Double?

    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case temperatureC = "temp"
        case turbidityPercent = "turb"
        case waterLevelCM = "level"
        case algae
        case quality = "q"
        case cameraError = "camErr"
        case levelMV = "lmv"
        case turbidityMV = "tmv"
        case cameraAlgae = "acam"
    }

    init(timestamp: Date,
         temperatureC: Double? = nil,
         turbidityPercent: Double? = nil,
         waterLevelCM: Double? = nil,
         algae: Double? = nil,
         quality: Double? = nil,
         cameraError: Bool? = nil,
         levelMV: Double? = nil,
         turbidityMV: Double? = nil,
         cameraAlgae: Double? = nil) {
        self.timestamp = timestamp
        self.temperatureC = temperatureC
        self.turbidityPercent = turbidityPercent
        self.waterLevelCM = waterLevelCM
        self.algae = algae
        self.quality = quality
        self.cameraError = cameraError
        self.levelMV = levelMV
        self.turbidityMV = turbidityMV
        self.cameraAlgae = cameraAlgae
    }

    init(_ reading: Reading) {
        self.init(
            timestamp: reading.timestamp,
            temperatureC: reading.temperatureC,
            turbidityPercent: reading.turbidityPercent,
            waterLevelCM: reading.waterLevelCM,
            algae: reading.algae,
            quality: reading.quality,
            cameraError: reading.cameraErrorCode.map { $0 != 0 },
            levelMV: reading.levelMV,
            turbidityMV: reading.turbidityMV,
            cameraAlgae: reading.cameraAlgae
        )
    }

    /// The algae number, but only when the camera worked and the station
    /// trusted the measurement — a failed image says nothing about algae.
    var trustedAlgae: Double? {
        if cameraError == true { return nil }
        if let quality, quality < Assessment.minimumQuality { return nil }
        return algae
    }
}

// MARK: - Metric

/// The four things a farmer cares about, and how to pull each out of a sample.
enum Metric: String, CaseIterable, Identifiable {
    case level
    case algae
    case clarity
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .level: return "Water level"
        case .algae: return "Algae"
        case .clarity: return "Clarity"
        case .temperature: return "Temperature"
        }
    }

    var symbol: String {
        switch self {
        case .level: return "water.waves"
        case .algae: return "leaf.fill"
        case .clarity: return "drop.fill"
        case .temperature: return "thermometer.medium"
        }
    }

    var unit: String {
        switch self {
        case .level: return "cm"
        case .algae: return "%"
        case .clarity: return "% murky"
        case .temperature: return "°C"
        }
    }

    var chartTint: Color {
        switch self {
        case .level: return .blue
        case .algae: return .green
        case .clarity: return .brown
        case .temperature: return .orange
        }
    }

    func value(_ sample: Sample) -> Double? {
        switch self {
        case .level: return sample.waterLevelCM
        case .algae: return sample.trustedAlgae
        case .clarity: return sample.turbidityPercent
        case .temperature: return sample.temperatureC
        }
    }
}

// MARK: - Keeping a week

enum History {

    /// How far back the app remembers.
    static let retention: TimeInterval = 7 * 24 * 3600
    /// Everything newer than this is kept packet by packet.
    static let fullDetail: TimeInterval = 24 * 3600
    /// Older than `fullDetail`, packets are merged into one sample per slot.
    static let slot: TimeInterval = 10 * 60

    /// Drops anything past a week and merges day-old packets into 10-minute
    /// medians. Running it twice changes nothing: a merged sample sits at the
    /// start of its slot, alone.
    static func compacted(_ samples: [Sample], now: Date = .now) -> [Sample] {
        let oldest = now.addingTimeInterval(-retention)
        let detailed = now.addingTimeInterval(-fullDetail)

        var result: [Sample] = []
        var slotStart: TimeInterval?
        var pending: [Sample] = []

        func flush() {
            guard let slotStart, !pending.isEmpty else { return }
            result.append(pending.count == 1 ? pending[0] : merge(pending, at: Date(timeIntervalSince1970: slotStart)))
            pending = []
        }

        for sample in samples where sample.timestamp >= oldest {
            guard sample.timestamp < detailed else {
                flush()
                slotStart = nil
                result.append(sample)
                continue
            }
            let start = (sample.timestamp.timeIntervalSince1970 / slot).rounded(.down) * slot
            if start != slotStart {
                flush()
                slotStart = start
            }
            pending.append(sample)
        }
        flush()
        return result
    }

    private static func merge(_ samples: [Sample], at start: Date) -> Sample {
        let errors = samples.compactMap(\.cameraError)
        return Sample(
            timestamp: start,
            temperatureC: Stats.median(samples.compactMap(\.temperatureC)),
            turbidityPercent: Stats.median(samples.compactMap(\.turbidityPercent)),
            waterLevelCM: Stats.median(samples.compactMap(\.waterLevelCM)),
            // Merge only trusted algae values, or a failed image would drag
            // the slot's median around once its error flag is gone.
            algae: Stats.median(samples.compactMap(\.trustedAlgae)),
            quality: Stats.median(samples.compactMap(\.quality)),
            cameraError: errors.isEmpty ? nil : errors.filter { $0 }.count * 2 > errors.count,
            levelMV: Stats.median(samples.compactMap(\.levelMV)),
            turbidityMV: Stats.median(samples.compactMap(\.turbidityMV)),
            cameraAlgae: Stats.median(samples.compactMap { $0.trustedAlgae == nil ? nil : $0.cameraAlgae })
        )
    }
}

// MARK: - Statistics

enum Stats {

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// One median per hour. Evens out both single odd packets and the slower
    /// 10-minute samples from further back, so days can be compared fairly.
    static func hourly(_ samples: [Sample], _ metric: Metric) -> [(time: Date, value: Double)] {
        medians(samples, metric, every: 3600)
    }

    /// One median per `interval`, placed in the middle of its slot.
    static func medians(_ samples: [Sample], _ metric: Metric, every interval: TimeInterval) -> [(time: Date, value: Double)] {
        var buckets: [Int: [Double]] = [:]
        for sample in samples {
            guard let value = metric.value(sample) else { continue }
            buckets[Int(sample.timestamp.timeIntervalSince1970 / interval), default: []].append(value)
        }
        return buckets.keys.sorted().compactMap { slot in
            guard let value = median(buckets[slot]!) else { return nil }
            return (Date(timeIntervalSince1970: (Double(slot) + 0.5) * interval), value)
        }
    }

    /// Least-squares slope, in units per hour. Needs a few points spread over
    /// at least `minimumSpan` hours, or the answer is noise.
    static func slopePerHour(_ points: [(time: Date, value: Double)], minimumPoints: Int = 4, minimumSpan: Double) -> Double? {
        guard points.count >= minimumPoints,
              let first = points.first, let last = points.last,
              last.time.timeIntervalSince(first.time) / 3600 >= minimumSpan else { return nil }

        let xs = points.map { $0.time.timeIntervalSince(first.time) / 3600 }
        let ys = points.map(\.value)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var numerator = 0.0, denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        return denominator > 0 ? numerator / denominator : nil
    }
}
