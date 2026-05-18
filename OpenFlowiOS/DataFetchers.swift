//
//  DataFetchers.swift
//  OpenFlowMobile
//
//  Per-source adapters that translate public APIs into the same
//  [Date: Double?] daily series shape so WindowAssembler can compose them
//  without caring about the source.
//
//  Each fetcher matches the units and semantics upstream OpenFlow uses at
//  training time so the model sees the same distributions at inference:
//
//  - Flow:  CFS, daily min/max (USGS IV instantaneous values aggregated
//           by Date; DWR daily archive returns one value/day -> min=max).
//  - Temp:  Fahrenheit (matches NCEI GHCND scale used in training).
//  - Precip: mm/day (NCEI tenths-of-mm /10).
//  - SWE:   inches (NRCS AWDB native unit, no conversion).
//  - Drought: 0..500 weighted index (USDM weekly, ffilled to daily upstream).
//  - SMAP:  m^3/m^3 (precomputed by scripts/fetch_smap.py).
//

import Foundation

/// One-value-per-day daily series. nil = no observation that day.
typealias DailySeries = [Date: Double?]

enum FetcherError: LocalizedError {
    case http(Int, String)
    case decode(String)
    case missingMetadata(String)

    var errorDescription: String? {
        switch self {
        case .http(let c, let url): return "HTTP \(c) for \(url)"
        case .decode(let m): return "Decode failure: \(m)"
        case .missingMetadata(let m): return "Missing metadata: \(m)"
        }
    }
}

enum DataFetchers {

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")!
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayKey(_ date: Date) -> Date {
        let comps = utc.dateComponents([.year, .month, .day], from: date)
        return utc.date(from: comps) ?? date
    }

    private static func get(_ url: URL, accept: String = "application/json") async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("OpenFlowMobile/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetcherError.http(http.statusCode, url.absoluteString)
        }
        return data
    }

    // MARK: - USGS / DWR streamflow (Min Flow, Max Flow)

    /// Aggregates USGS IV (15-min) discharge values into per-day min and max
    /// in CFS. Matches upstream `get_flow.get_daily_flow_data()`.
    static func usgsFlow(siteId: String, start: Date, end: Date) async throws -> (min: DailySeries, max: DailySeries) {
        var comps = URLComponents(string: "https://nwis.waterservices.usgs.gov/nwis/iv/")!
        comps.queryItems = [
            URLQueryItem(name: "sites", value: siteId),
            URLQueryItem(name: "parameterCd", value: "00060"),
            URLQueryItem(name: "startDT", value: isoDay.string(from: start)),
            URLQueryItem(name: "endDT", value: isoDay.string(from: end)),
            URLQueryItem(name: "format", value: "rdb"),
        ]
        let data = try await get(comps.url!, accept: "text/plain")
        let text = String(data: data, encoding: .utf8) ?? ""
        return parseUsgsRdb(text)
    }

    /// Pure parser for USGS NWIS IV RDB text. Exposed for tests; called from
    /// usgsFlow after the HTTP GET.
    static func parseUsgsRdb(_ text: String) -> (min: DailySeries, max: DailySeries) {
        var mins: [Date: Double] = [:]
        var maxs: [Date: Double] = [:]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")

        var valueCol: Int? = nil
        for raw in text.components(separatedBy: "\n") {
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            let cols = raw.components(separatedBy: "\t")
            // Header is "agency_cd\tsite_no\tdatetime\ttz_cd\t{ts_id}_00060\t..."
            // Multi-gage sites may have several "*_00060" columns; we take the
            // first non-qualifier one.
            if cols.first == "agency_cd" {
                valueCol = cols.firstIndex(where: { $0.hasSuffix("_00060") })
                continue
            }
            // Format-spec row: "5s\t15s\t20d\t...".
            if cols.first?.hasSuffix("s") == true && cols.count >= 4 { continue }
            guard let vi = valueCol, cols.count > vi,
                  let dt = formatter.date(from: cols[2]),
                  let v = Double(cols[vi]) else { continue }
            let day = dayKey(dt)
            mins[day] = min(mins[day] ?? .infinity, v)
            maxs[day] = max(maxs[day] ?? -.infinity, v)
        }
        return (mins.mapValues { Optional($0) }, maxs.mapValues { Optional($0) })
    }

    /// CODWR daily archive. Returns Min=Max=daily value per upstream's
    /// `get_CODWR_flow.get_historical_data()`.
    static func dwrFlow(abbrev: String, start: Date, end: Date) async throws -> (min: DailySeries, max: DailySeries) {
        var comps = URLComponents(string: "https://dwr.state.co.us/Rest/GET/api/v2/surfacewater/surfacewatertsday/")!
        comps.queryItems = [
            URLQueryItem(name: "abbrev", value: abbrev),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "min-measDate", value: isoDay.string(from: start)),
            URLQueryItem(name: "max-measDate", value: isoDay.string(from: end)),
            URLQueryItem(name: "pageSize", value: "50000"),
        ]
        let data = try await get(comps.url!)
        return try parseDwrJson(data)
    }

    static func parseDwrJson(_ data: Data) throws -> (min: DailySeries, max: DailySeries) {
        struct Resp: Decodable { struct Row: Decodable { let measDate: String?; let value: Double? }
            let ResultList: [Row] }
        let resp = try JSONDecoder().decode(Resp.self, from: data)

        var series: [Date: Double] = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        for row in resp.ResultList {
            guard let s = row.measDate, let v = row.value,
                  let date = f.date(from: String(s.prefix(19))) else { continue }
            series[dayKey(date)] = v
        }
        let asSeries: DailySeries = series.mapValues { Optional($0) }
        return (asSeries, asSeries)
    }

    // MARK: - NCEI GHCND historical TMIN / TMAX / PRCP

    static func ghcndTempPrecip(stationId: String, start: Date, end: Date) async throws
        -> (tmin: DailySeries, tmax: DailySeries, precip: DailySeries) {
        var comps = URLComponents(string: "https://www.ncei.noaa.gov/access/services/data/v1")!
        comps.queryItems = [
            URLQueryItem(name: "dataset", value: "daily-summaries"),
            URLQueryItem(name: "stations", value: stationId),
            URLQueryItem(name: "dataTypes", value: "TMIN,TMAX,PRCP"),
            URLQueryItem(name: "startDate", value: isoDay.string(from: start)),
            URLQueryItem(name: "endDate", value: isoDay.string(from: end)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "units", value: "standard"),  // F + inches per NCEI's "standard"
        ]
        let data = try await get(comps.url!)
        return try parseGhcndJson(data)
    }

    static func parseGhcndJson(_ data: Data) throws -> (tmin: DailySeries, tmax: DailySeries, precip: DailySeries) {
        struct Row: Decodable {
            let DATE: String
            let TMIN: String?
            let TMAX: String?
            let PRCP: String?
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)

        var tmin: DailySeries = [:], tmax: DailySeries = [:], prcp: DailySeries = [:]
        for row in rows {
            guard let day = isoDay.date(from: row.DATE) else { continue }
            let key = dayKey(day)
            tmin[key] = row.TMIN.flatMap { Double($0) }
            tmax[key] = row.TMAX.flatMap { Double($0) }
            // NCEI "standard" units => PRCP in inches. Upstream stores mm/day.
            prcp[key] = row.PRCP.flatMap { Double($0) }.map { $0 * 25.4 }
        }
        return (tmin, tmax, prcp)
    }

    // MARK: - NRCS AWDB SNOTEL SWE (inches)

    /// Mean WTEQ across all triplets in the basin, matching
    /// upstream `get_swe.get_swe_timeseries()`.
    static func snotelSwe(triplets: [String], start: Date, end: Date) async throws -> DailySeries {
        guard !triplets.isEmpty else { return [:] }
        var comps = URLComponents(string: "https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1/data")!
        comps.queryItems = [
            URLQueryItem(name: "stationTriplets", value: triplets.joined(separator: ",")),
            URLQueryItem(name: "elements", value: "WTEQ"),
            URLQueryItem(name: "duration", value: "DAILY"),
            URLQueryItem(name: "beginDate", value: isoDay.string(from: start)),
            URLQueryItem(name: "endDate", value: isoDay.string(from: end)),
        ]
        let data = try await get(comps.url!)

        struct StationData: Decodable {
            struct ElementSeries: Decodable {
                struct Value: Decodable { let date: String?; let value: Double? }
                let element: String?
                let values: [Value]?
            }
            let stationTriplet: String?
            let data: [ElementSeries]?
        }
        let stations = try JSONDecoder().decode([StationData].self, from: data)

        var sums: [Date: Double] = [:]
        var counts: [Date: Int] = [:]
        for st in stations {
            for elem in st.data ?? [] where (elem.element ?? "") == "WTEQ" {
                for entry in elem.values ?? [] {
                    guard let ds = entry.date, let v = entry.value,
                          let day = isoDay.date(from: String(ds.prefix(10))) else { continue }
                    let key = dayKey(day)
                    sums[key, default: 0] += v
                    counts[key, default: 0] += 1
                }
            }
        }
        var out: DailySeries = [:]
        for (day, sum) in sums {
            let n = counts[day] ?? 1
            out[day] = n > 0 ? sum / Double(n) : nil
        }
        return out
    }

    // MARK: - USDM drought (0..500 weighted index)

    /// USDM is weekly; this returns one value per Wednesday (US Drought
    /// Monitor's release day). WindowAssembler forward-fills up to 14 days.
    static func usdmDrought(huc8: String, start: Date, end: Date) async throws -> DailySeries {
        let mdy = DateFormatter()
        mdy.dateFormat = "M/d/yyyy"
        mdy.timeZone = TimeZone(identifier: "UTC")
        mdy.locale = Locale(identifier: "en_US_POSIX")

        var comps = URLComponents(string: "https://usdmdataservices.unl.edu/api/HUCStatistics/GetWeeklyHUCStatistics")!
        comps.queryItems = [
            URLQueryItem(name: "aoi", value: huc8),
            URLQueryItem(name: "hucLevel", value: "8"),
            URLQueryItem(name: "startdate", value: mdy.string(from: start)),
            URLQueryItem(name: "enddate", value: mdy.string(from: end)),
            URLQueryItem(name: "statisticsType", value: "2"),
        ]
        let data = try await get(comps.url!)

        struct Row: Decodable {
            let MapDate: String?  // YYYYMMDD or "2025-08-26T00:00:00"
            let None: Double?
            let D0: Double?
            let D1: Double?
            let D2: Double?
            let D3: Double?
            let D4: Double?
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)

        var out: DailySeries = [:]
        for row in rows {
            guard let md = row.MapDate else { continue }
            let day = parseUsdmDate(md)
            guard let day else { continue }
            let weighted = (row.D0 ?? 0) * 1 + (row.D1 ?? 0) * 2 + (row.D2 ?? 0) * 3
                         + (row.D3 ?? 0) * 4 + (row.D4 ?? 0) * 5
            out[dayKey(day)] = weighted
        }
        return out
    }

    private static func parseUsdmDate(_ s: String) -> Date? {
        if s.count == 8, let _ = Int(s) {
            let yyyymmdd = DateFormatter()
            yyyymmdd.dateFormat = "yyyyMMdd"
            yyyymmdd.timeZone = TimeZone(identifier: "UTC")
            yyyymmdd.locale = Locale(identifier: "en_US_POSIX")
            return yyyymmdd.date(from: s)
        }
        return isoDay.date(from: String(s.prefix(10)))
    }

    // MARK: - SMAP (precomputed by scripts/fetch_smap.py)

    /// Reads `https://raw.githubusercontent.com/<repo>/smap-data/{huc8}.json`.
    /// Apps never call NASA EarthData directly.
    static func smapSoilMoisture(huc8: String, repo: String = "tmart234/OpenFlowMobile") async throws -> DailySeries {
        let url = URL(string: "https://raw.githubusercontent.com/\(repo)/smap-data/\(huc8).json")!
        let data = try await get(url)
        struct Payload: Decodable {
            struct Row: Decodable { let date: String; let soilMoisture: Double?; let observed: Bool }
            let series: [Row]
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try dec.decode(Payload.self, from: data)

        var out: DailySeries = [:]
        for row in payload.series {
            guard let day = isoDay.date(from: row.date) else { continue }
            out[dayKey(day)] = row.observed ? row.soilMoisture : nil
        }
        return out
    }

    // MARK: - Open-Meteo 14-day forecast

    /// `forecast_days` up to 16. Returns Fahrenheit + mm/day to match the
    /// historical GHCND scale upstream trains on.
    static func openMeteoForecast(lat: Double, lon: Double, days: Int = 14) async throws
        -> (tmin: DailySeries, tmax: DailySeries, precip: DailySeries) {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_sum"),
            URLQueryItem(name: "forecast_days", value: String(days)),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "precipitation_unit", value: "mm"),
            URLQueryItem(name: "timezone", value: "America/Denver"),
        ]
        let data = try await get(comps.url!)
        return try parseOpenMeteoJson(data)
    }

    static func parseOpenMeteoJson(_ data: Data) throws
        -> (tmin: DailySeries, tmax: DailySeries, precip: DailySeries) {
        struct Resp: Decodable {
            struct Daily: Decodable {
                let time: [String]
                let temperature_2m_max: [Double?]
                let temperature_2m_min: [Double?]
                let precipitation_sum: [Double?]?
            }
            let daily: Daily
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)

        var tmin: DailySeries = [:], tmax: DailySeries = [:], prcp: DailySeries = [:]
        for (i, ds) in resp.daily.time.enumerated() {
            guard let day = isoDay.date(from: ds) else { continue }
            let key = dayKey(day)
            tmin[key] = resp.daily.temperature_2m_min[i]
            tmax[key] = resp.daily.temperature_2m_max[i]
            prcp[key] = resp.daily.precipitation_sum?[i] ?? 0
        }
        return (tmin, tmax, prcp)
    }
}
