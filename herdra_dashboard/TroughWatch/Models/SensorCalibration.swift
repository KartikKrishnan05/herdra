import Foundation

/// Turns the sender's raw values into what the rules judge: a water depth, a
/// turbidity percentage and an algae coverage. The sender sends millivolts
/// (`LVL_MV`, `TURB_MV`) and the camera's own colour share (`ALGAE`), and each
/// trough keeps its own calibration here, so a sensor can be recalibrated from
/// the phone without reflashing anything.
///
/// The level and turbidity formulas are exactly the ones the firmware used.
struct SensorCalibration: Codable, Hashable {

    // Level sensor, in mV at GPIO3.

    /// Output with the probe out of the water.
    var levelZeroMV: Double = 116
    /// Output with the probe at `levelCalDepthCM`.
    var levelCalMV: Double = 372
    var levelCalDepthCM: Double = 18

    // Turbidity sensor, in volts at the sensor itself (before the divider).

    /// Output in clear water — reads as 0 %.
    var turbidityClearV: Double = 4.29
    /// Output in the dirtiest reference water — reads as 100 %.
    var turbidityDirtyV: Double = 1.06
    /// The 10k/20k divider in front of GPIO4: sensor volts = pin volts × this.
    var turbidityDividerFactor: Double = 1.5

    // Camera, in the camera's own ALGAE percentage.

    /// What the camera reports for a clean, silver surface — reads as 0 %
    /// coverage. The colour filter never quite reaches zero.
    var algaeCleanPercent: Double = 10
    /// What the camera reports when the surface is fully covered — reads as
    /// 100 % coverage.
    var algaeFullPercent: Double = 40

    static let `default` = SensorCalibration()

    init() {}

    /// Calibrations saved before a field existed still load, with that
    /// field's default — otherwise one missing key would lose every trough.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SensorCalibration()
        levelZeroMV = try c.decodeIfPresent(Double.self, forKey: .levelZeroMV) ?? d.levelZeroMV
        levelCalMV = try c.decodeIfPresent(Double.self, forKey: .levelCalMV) ?? d.levelCalMV
        levelCalDepthCM = try c.decodeIfPresent(Double.self, forKey: .levelCalDepthCM) ?? d.levelCalDepthCM
        turbidityClearV = try c.decodeIfPresent(Double.self, forKey: .turbidityClearV) ?? d.turbidityClearV
        turbidityDirtyV = try c.decodeIfPresent(Double.self, forKey: .turbidityDirtyV) ?? d.turbidityDirtyV
        turbidityDividerFactor = try c.decodeIfPresent(Double.self, forKey: .turbidityDividerFactor) ?? d.turbidityDividerFactor
        algaeCleanPercent = try c.decodeIfPresent(Double.self, forKey: .algaeCleanPercent) ?? d.algaeCleanPercent
        algaeFullPercent = try c.decodeIfPresent(Double.self, forKey: .algaeFullPercent) ?? d.algaeFullPercent
    }

    // MARK: Raw → physical

    /// Depth in cm, never below zero. Nil when the calibration can't be used.
    func depthCM(fromMV mv: Double) -> Double? {
        let span = levelCalMV - levelZeroMV
        guard mv.isFinite, span.isFinite, span > 0.001,
              levelCalDepthCM.isFinite, levelCalDepthCM > 0 else { return nil }
        return max(0, (mv - levelZeroMV) * levelCalDepthCM / span)
    }

    /// The turbidity sensor's own output, from the millivolts at the pin.
    func turbiditySensorVolts(fromPinMV mv: Double) -> Double {
        mv * turbidityDividerFactor / 1000
    }

    /// 0 (clear) – 100 (murky). Nil when the calibration can't be used.
    func turbidityPercent(fromMV mv: Double) -> Double? {
        let span = turbidityClearV - turbidityDirtyV
        guard mv.isFinite, span.isFinite, span > 0.001 else { return nil }
        let percent = 100 * (turbidityClearV - turbiditySensorVolts(fromPinMV: mv)) / span
        return min(100, max(0, percent))
    }

    /// 0 (clean) – 100 (fully covered). Nil when the calibration can't be used.
    func algaeCoverage(fromCamera percent: Double) -> Double? {
        let span = algaeFullPercent - algaeCleanPercent
        guard percent.isFinite, span.isFinite, span > 0.001 else { return nil }
        return min(100, max(0, 100 * (percent - algaeCleanPercent) / span))
    }

    // MARK: Applying it

    /// Fills in depth, turbidity and algae coverage from the raw values. A
    /// packet from older firmware that already carries `LEVEL` / `TURB` and no
    /// millivolts keeps those as they are.
    func apply(to reading: inout Reading) {
        if let mv = reading.levelMV { reading.waterLevelCM = depthCM(fromMV: mv) }
        if let mv = reading.turbidityMV { reading.turbidityPercent = turbidityPercent(fromMV: mv) }
        if let raw = reading.cameraAlgae { reading.algae = algaeCoverage(fromCamera: raw) }
    }

    func applied(to sample: Sample) -> Sample {
        var copy = sample
        if let mv = sample.levelMV { copy.waterLevelCM = depthCM(fromMV: mv) }
        if let mv = sample.turbidityMV { copy.turbidityPercent = turbidityPercent(fromMV: mv) }
        if let raw = sample.cameraAlgae { copy.algae = algaeCoverage(fromCamera: raw) }
        return copy
    }
}
