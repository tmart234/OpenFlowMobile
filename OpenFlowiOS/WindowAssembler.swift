//
//  WindowAssembler.swift
//  OpenFlowMobile
//
//  Aligns the 7 raw daily series produced by DataFetchers onto a single
//  daily grid, fills gaps per upstream's rules, computes indicator columns
//  + doy_sin/cos, and produces a FeatureWindow shaped exactly by
//  Manifest.Schema.encoder_features / decoder_features.
//

import Foundation

struct WindowAssembler {

    struct EncoderInputs {
        let flowMin: DailySeries
        let flowMax: DailySeries
        let tmin: DailySeries
        let tmax: DailySeries
        let precip: DailySeries
        let swe: DailySeries
        let soilMoisture: DailySeries
        let drought: DailySeries
    }

    struct DecoderInputs {
        let tmin: DailySeries
        let tmax: DailySeries
        let precip: DailySeries
    }

    let schema: MLContract.Manifest.Schema

    func assemble(
        site: SiteMetadata,
        encoderEnd: Date,
        encoder: EncoderInputs,
        decoder: DecoderInputs
    ) -> FeatureWindow {
        let encDays = days(endingAt: encoderEnd, count: schema.encoderDays)
        let decStart = Self.utc.date(byAdding: .day, value: 1, to: encDays.last!)!
        let decDays = days(startingAt: decStart, count: schema.decoderDays)

        // Pre-fill every encoder column onto the encoder day grid.
        let encCols: [String: [Double]] = [
            "Min Flow":      ffill(encoder.flowMin,     on: encDays),
            "Max Flow":      ffill(encoder.flowMax,     on: encDays),
            "TMIN":          ffill(encoder.tmin,        on: encDays),
            "TMAX":          ffill(encoder.tmax,        on: encDays),
            "precipitation": zeroFill(encoder.precip,   on: encDays),
            "SWE":           ffill(encoder.swe,         on: encDays, fallback: 0),
            "drought_index": ffill(encoder.drought,     on: encDays, fallback: 0),
            "soil_moisture": ffill(encoder.soilMoisture, on: encDays, fallback: 0),
        ]
        let smapObserved: [Bool] = encDays.map { (encoder.soilMoisture[$0] ?? nil) != nil }

        let encoderRows: [[Double]] = encDays.enumerated().map { (i, day) in
            schema.encoderFeatures.map { col in
                encoderCellValue(column: col, dayIndex: i, day: day,
                                 cols: encCols, smapObserved: smapObserved)
            }
        }

        let decCols: [String: [Double]] = [
            "TMIN":          ffill(decoder.tmin,    on: decDays),
            "TMAX":          ffill(decoder.tmax,    on: decDays),
            "precipitation": zeroFill(decoder.precip, on: decDays),
        ]
        let decoderRows: [[Double]] = decDays.enumerated().map { (i, day) in
            schema.decoderFeatures.map { col in
                decoderCellValue(column: col, dayIndex: i, day: day, cols: decCols)
            }
        }

        // persistence_input = last encoder row's raw target values in cfs.
        // ModelBundle re-scales it the same way as the encoder cells.
        let persistenceTargets = schema.targetFeatures.map { col -> Double in
            (encCols[col]?.last) ?? 0
        }

        return FeatureWindow(
            siteId: "\(site.agency):\(site.siteId)",
            basinId: site.huc8 ?? "",
            encoderRows: encoderRows,
            decoderRows: decoderRows,
            persistenceTargets: persistenceTargets
        )
    }

    // MARK: - per-cell value

    private func encoderCellValue(
        column: String, dayIndex: Int, day: Date,
        cols: [String: [Double]], smapObserved: [Bool]
    ) -> Double {
        if let arr = cols[column] { return arr[dayIndex] }
        switch column {
        case "sm_observed":
            return smapObserved[dayIndex] ? 1 : 0
        case "reservoir_storage", "reservoir_release", "reservoir_observed":
            // Upstream's reservoir_mapping.txt is fully commented out in dev,
            // so the model is trained with these as zeros for every site.
            // Revisit when upstream populates the mapping.
            return 0
        case "doy_sin": return doySin(day)
        case "doy_cos": return doyCos(day)
        default: return 0
        }
    }

    private func decoderCellValue(column: String, dayIndex: Int, day: Date, cols: [String: [Double]]) -> Double {
        if column == "doy_sin" { return doySin(day) }
        if column == "doy_cos" { return doyCos(day) }
        guard let arr = cols[column] else { return 0 }
        return arr[dayIndex]
    }

    // MARK: - day grid helpers

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func days(endingAt end: Date, count: Int) -> [Date] {
        let dayEnd = DataFetchers.dayKey(end)
        return (0..<count).reversed().map { off in
            Self.utc.date(byAdding: .day, value: -off, to: dayEnd)!
        }
    }

    private func days(startingAt start: Date, count: Int) -> [Date] {
        let dayStart = DataFetchers.dayKey(start)
        return (0..<count).map { off in
            Self.utc.date(byAdding: .day, value: off, to: dayStart)!
        }
    }

    // MARK: - gap fill

    /// Forward-fill, then back-fill, then `fallback` (or series median if nil).
    private func ffill(_ series: DailySeries, on days: [Date], fallback: Double? = nil) -> [Double] {
        var out: [Double?] = []
        var last: Double? = nil
        for day in days {
            if let v = series[day] ?? nil { last = v; out.append(v) }
            else { out.append(last) }
        }
        if out.contains(where: { $0 == nil }) {
            let firstReal = out.compactMap { $0 }.first
                ?? fallback
                ?? seriesMedian(series)
                ?? 0
            for i in 0..<out.count where out[i] == nil { out[i] = firstReal }
        }
        return out.map { $0! }
    }

    /// Missing precip days are 0 mm. Matches upstream's zero-fill rule.
    private func zeroFill(_ series: DailySeries, on days: [Date]) -> [Double] {
        days.map { (series[$0] ?? nil) ?? 0 }
    }

    private func seriesMedian(_ series: DailySeries) -> Double? {
        let values = series.values.compactMap { $0 }.sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    // MARK: - day-of-year (upstream normalize_data.add_day_of_year_features)

    private func doySin(_ day: Date) -> Double {
        let (n, len) = doyFraction(day)
        return sin(2 * .pi * Double(n - 1) / Double(len))
    }
    private func doyCos(_ day: Date) -> Double {
        let (n, len) = doyFraction(day)
        return cos(2 * .pi * Double(n - 1) / Double(len))
    }
    private func doyFraction(_ day: Date) -> (Int, Int) {
        let n = Self.utc.ordinality(of: .day, in: .year, for: day) ?? 1
        let len = Self.utc.range(of: .day, in: .year, for: day)?.count ?? 365
        return (n, len)
    }
}
