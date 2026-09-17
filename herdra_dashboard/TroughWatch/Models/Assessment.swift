import Foundation

/// Which way something has been going.
enum Trend {
    case rising, steady, falling, unknown

    var symbol: String? {
        switch self {
        case .rising: return "arrow.up.right"
        case .falling: return "arrow.down.right"
        case .steady: return "arrow.right"
        case .unknown: return nil
        }
    }

    var word: String? {
        switch self {
        case .rising: return "Rising"
        case .falling: return "Falling"
        case .steady: return "Steady"
        case .unknown: return nil
        }
    }
}

/// How one thing — level, algae, clarity or temperature — is doing, said in
/// words rather than numbers.
struct Finding: Identifiable {
    let metric: Metric
    var status: WaterStatus
    /// One or two words for the tile: "Clear", "Getting low".
    var word: String
    /// A plain sentence: what's going on, and what to do if anything.
    var detail: String
    var trend: Trend = .unknown
    /// The smoothed current value, for the small print.
    var value: Double?

    var id: Metric { metric }
}

/// Everything the app has concluded about one trough.
struct TroughAssessment {
    var status: WaterStatus
    /// The one sentence that matters most right now.
    var summary: String
    /// Things to do, most urgent first. Empty when all is well.
    var todo: [String]
    var findings: [Finding]
    var lastHeard: Date?
    /// Past the point where the data can be relied on to describe the trough.
    var isOutdated: Bool

    func finding(_ metric: Metric) -> Finding? {
        findings.first { $0.metric == metric }
    }
}

// MARK: - The rules

/// The one place that decides good / watch / act now. It looks at the whole
/// stored history rather than the last packet, so:
///
/// - a single odd packet (a cow stirring the water, a leaf over the camera)
///   is smoothed away by taking medians over the last hour or hours,
/// - slow changes over hours and days (algae building up, water warming, the
///   level creeping down) show up as trends even before a limit is crossed.
///
/// Change a threshold here and the list, the map and the detail screen follow.
enum Assessment {

    // Water level, as a share of the trough's full level (Settings), so a
    // shallow trough and a deep one are judged alike.
    static let lowLevelShare: Double = 0.35
    static let gettingLowLevelShare: Double = 0.65
    /// A level falling faster than this share of full per hour, for a few
    /// hours, points at a leak or a stuck float valve, whatever the level is.
    static let fastDropSharePerHour: Double = 0.10

    // Turbidity, 0 (clear) – 100 (murky).
    static let dirtyPercent: Double = 60
    static let cloudyPercent: Double = 30

    // Algae, coverage 0 (clean) – 100 (fully covered), after calibration.
    // Below `someAlgae` the trough is fine, whatever the trend.
    static let lotsOfAlgae: Double = 80
    static let someAlgae: Double = 40
    /// Below `someAlgae`, growth faster than this per day is mentioned, not warned about.
    static let algaeGrowthPerDay: Double = 2.5

    // Temperature, °C.
    static let freezingC: Double = 0.5
    static let nearFreezingC: Double = 3
    /// From here algae grows noticeably faster.
    static let warmC: Double = 20
    static let hotC: Double = 25

    /// A measurement scoring under this is not trusted.
    static let minimumQuality: Double = 50

    /// How many of the newest batches decide the algae and level tiles. The
    /// median of three changes as soon as two batches agree, so a real change
    /// shows after two batches while one odd one doesn't.
    static let recentBatches = 3

    /// No packet for this long and the colours stop meaning anything.
    static let outdatedAfter: TimeInterval = 24 * 3600

    static func evaluate(_ samples: [Sample], isActive: Bool = true,
                         fullLevelCM: Double = Trough.defaultFullLevelCM, now: Date = .now) -> TroughAssessment {
        guard isActive else {
            return TroughAssessment(status: .unknown, summary: "This trough is switched off in the app.",
                                    todo: [], findings: [], lastHeard: samples.last?.timestamp, isOutdated: true)
        }
        guard let latest = samples.last else {
            return TroughAssessment(status: .unknown, summary: "Nothing has arrived from this trough yet.",
                                    todo: [], findings: [], lastHeard: nil, isOutdated: true)
        }

        let context = Context(samples: samples, latest: latest)
        var findings = [level(context, fullCM: fullLevelCM), algae(context), clarity(context), temperature(context)]
        let device = deviceProblem(context)

        let outdated = now.timeIntervalSince(latest.timestamp) > outdatedAfter
        if outdated {
            for index in findings.indices { findings[index].status = .unknown }
        }

        let known = findings.filter { $0.status != .unknown }
        var status = known.map(\.status).max { $0.severity < $1.severity } ?? .unknown
        if let device, !outdated, device.severity > status.severity {
            status = device
        }

        // Worst first; among equals, the order of `Metric.allCases`.
        let worrying = findings
            .filter { $0.status.needsAttention }
            .sorted { $0.status.severity > $1.status.severity }
        var todo = worrying.map(\.detail)
        if let device = deviceAdvice(context), !outdated {
            todo.append(device)
        }

        let summary: String
        if outdated {
            summary = "Last heard from \(Format.relative(latest.timestamp)). Join the receiver's Wi-Fi to catch up."
        } else if let first = todo.first {
            summary = first
        } else if status == .unknown {
            summary = "The device is sending, but no water readings yet."
        } else {
            summary = "Water looks fine and nothing is changing for the worse."
        }

        return TroughAssessment(status: status, summary: summary, todo: outdated ? [] : todo,
                                findings: findings, lastHeard: latest.timestamp, isOutdated: outdated)
    }

    // MARK: Windows over the history

    private struct Context {
        let samples: [Sample]
        let latest: Sample

        /// Samples from the `hours` before the newest one. Measured back from
        /// the last packet rather than from now, so a trough that was last
        /// heard from this morning is still judged on this morning's water.
        func window(hours: Double) -> [Sample] {
            let from = latest.timestamp.addingTimeInterval(-hours * 3600)
            // Newest at the end, so walk back only as far as needed.
            var result: [Sample] = []
            for sample in samples.reversed() {
                guard sample.timestamp >= from else { break }
                result.append(sample)
            }
            return result.reversed()
        }

        /// The newest `recentBatches` values from the last hour, oldest first.
        func latestBatches(_ metric: Metric) -> [Double] {
            Array(window(hours: 1).compactMap { metric.value($0) }.suffix(recentBatches))
        }

        /// Median over the recent window, and how many values went into it.
        func current(_ metric: Metric, hours: Double) -> (value: Double, count: Int)? {
            let values = window(hours: hours).compactMap { metric.value($0) }
            guard let median = Stats.median(values) else { return nil }
            return (median, values.count)
        }

        /// Change per day over the last `hours`, from hourly medians.
        func perDay(_ metric: Metric, hours: Double, minimumSpan: Double) -> Double? {
            Stats.slopePerHour(Stats.hourly(window(hours: hours), metric), minimumSpan: minimumSpan).map { $0 * 24 }
        }
    }

    private static func trend(_ perDay: Double?, deadband: Double) -> Trend {
        guard let perDay else { return .unknown }
        if perDay > deadband { return .rising }
        if perDay < -deadband { return .falling }
        return .steady
    }

    private static func noReading(_ metric: Metric) -> Finding {
        Finding(metric: metric, status: .unknown, word: "No reading",
                detail: "The device hasn't sent a \(metric.title.lowercased()) reading lately.")
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    // MARK: Water level

    private static func level(_ c: Context, fullCM: Double) -> Finding {
        // Same as algae: the median of the newest three batches, so a real
        // change shows after two batches while one dip (cattle drinking) doesn't.
        // With fewer batches, both must be low to count as low.
        let recent = c.latestBatches(.level)
        guard let current = recent.count >= recentBatches ? Stats.median(recent) : recent.max() else {
            return noReading(.level)
        }
        let perHour = Stats.slopePerHour(
            c.window(hours: 3).compactMap { s in Metric.level.value(s).map { (s.timestamp, $0) } },
            minimumPoints: 6, minimumSpan: 1.5)
        let dayTrend = trend(perHour.map { $0 * 24 }, deadband: fullCM * 0.4)
        var finding = Finding(metric: .level, status: .good, word: "Enough water", detail: "", trend: dayTrend, value: current)

        if current < fullCM * lowLevelShare {
            finding.status = .bad
            finding.word = "Very low"
            finding.detail = "The water is very low. Check the supply and the float valve now."
        } else if let perHour, perHour <= -fullCM * fastDropSharePerHour {
            finding.status = .warning
            finding.word = "Dropping fast"
            finding.detail = "The water has been dropping for the last few hours. Look for a leak or a stuck valve."
            finding.trend = .falling
        } else if current < fullCM * gettingLowLevelShare {
            finding.status = .warning
            finding.word = "Getting low"
            finding.detail = "The water is getting low. Check it's refilling."
        } else {
            finding.detail = "There is enough water in the trough."
        }
        return finding
    }

    // MARK: Algae

    /// How many of the newest camera batches decide the algae tile. The median
    /// of three changes as soon as two batches agree, so a real change shows
    /// after two batches while one odd picture (a shadow, a leaf) doesn't.
    private static func algae(_ c: Context) -> Finding {
        let recent = c.latestBatches(.algae)
        // With fewer batches than that, both must be high to count as high.
        let current = recent.count >= recentBatches ? Stats.median(recent) : recent.min()
        guard let current else {
            if c.window(hours: 1).contains(where: { $0.algae != nil }) {
                return Finding(metric: .algae, status: .unknown, word: "Can't tell",
                               detail: "The camera's recent pictures weren't good enough to judge algae.")
            }
            return noReading(.algae)
        }

        let perDay = c.perDay(.algae, hours: 72, minimumSpan: 24)
        let warmDay = c.current(.temperature, hours: 24).map { $0.value >= warmC } ?? false
        var finding = Finding(metric: .algae, status: .good, word: "Fine", detail: "",
                              trend: trend(perDay, deadband: 1), value: current)
        let latestAlgae = Metric.algae.value(c.latest)

        if current >= lotsOfAlgae {
            finding.status = .bad
            finding.word = "A lot"
            finding.detail = "The latest pictures show a lot of algae. Clean the trough."
        } else if current >= someAlgae {
            finding.status = .warning
            finding.word = "Building up"
            finding.detail = warmDay
                ? "Algae is building up and the warm water will speed it up. Plan to clean in the next day or two."
                : "Algae is building up. Plan to clean the trough in the next few days."
        } else if let latestAlgae, latestAlgae >= someAlgae {
            finding.detail = "One high algae reading just now was ignored — probably a shadow or a leaf. It will show here if the next batch is high too."
        } else if let perDay, perDay >= algaeGrowthPerDay {
            finding.detail = "Not much algae, but it has been slowly increasing. Nothing to do yet."
        } else {
            finding.detail = "Not much algae. Nothing to do."
        }
        return finding
    }

    // MARK: Clarity

    private static func clarity(_ c: Context) -> Finding {
        guard let now = c.current(.clarity, hours: 1) else { return noReading(.clarity) }
        let perDay = c.perDay(.clarity, hours: 48, minimumSpan: 12)
        var finding = Finding(metric: .clarity, status: .good, word: "Clear", detail: "",
                              trend: trend(perDay, deadband: 5), value: now.value)

        if now.value >= dirtyPercent {
            finding.status = .bad
            finding.word = "Dirty"
            finding.detail = "The water has been dirty for the last hour. Clean the trough and refresh the water."
        } else if now.value >= cloudyPercent {
            finding.status = .warning
            finding.word = "Cloudy"
            finding.detail = (perDay ?? 0) > 5
                ? "The water is cloudy and getting worse. Clean the trough soon."
                : "The water is cloudy. Worth a look next time you pass."
        } else if let latest = Metric.clarity.value(c.latest), latest >= dirtyPercent {
            finding.detail = "Briefly stirred up just now, probably an animal drinking. Otherwise clear."
        } else {
            finding.detail = "The water is clear."
        }
        return finding
    }

    // MARK: Temperature

    private static func temperature(_ c: Context) -> Finding {
        guard let now = c.current(.temperature, hours: 1) else { return noReading(.temperature) }
        let perDay = c.perDay(.temperature, hours: 72, minimumSpan: 24)
        var finding = Finding(metric: .temperature, status: .good, word: "Cool", detail: "",
                              trend: trend(perDay, deadband: 1), value: now.value)

        if now.value <= freezingC {
            finding.status = .bad
            finding.word = "Freezing"
            finding.detail = "The water is at freezing point. Break the ice so the animals can drink."
        } else if now.value < nearFreezingC {
            finding.status = .warning
            finding.word = "Near freezing"
            finding.detail = "The water is close to freezing. Check for ice in the morning."
        } else if now.value >= hotC {
            finding.status = .warning
            finding.word = "Hot"
            finding.detail = "The water is hot. Animals drink less and algae grows fast — refresh the water or add shade."
        } else if now.value >= warmC {
            finding.word = "Warm"
            finding.detail = finding.trend == .rising
                ? "The water has been getting warmer over the last days, which helps algae grow."
                : "The water is warm."
        } else {
            finding.detail = "The water temperature is fine."
        }
        return finding
    }

    // MARK: The device itself

    private static func deviceProblem(_ c: Context) -> WaterStatus? {
        deviceAdvice(c) == nil ? nil : .warning
    }

    private static func deviceAdvice(_ c: Context) -> String? {
        let recent = c.window(hours: 1)
        guard recent.count >= 3 else { return nil }

        let errors = recent.compactMap(\.cameraError)
        if errors.count >= 3, errors.filter({ $0 }).count * 2 > errors.count {
            return "The camera keeps failing. Wipe the lens and check its cable."
        }
        if let quality = Stats.median(recent.compactMap(\.quality)), quality < minimumQuality {
            return "The device's readings are unreliable. Clean the sensors and check it's floating upright."
        }
        return nil
    }
}
