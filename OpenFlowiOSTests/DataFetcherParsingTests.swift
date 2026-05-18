//
//  DataFetcherParsingTests.swift
//  OpenFlowiOSTests
//
//  Tests the pure parsers extracted from DataFetchers. Fixtures are inline
//  here rather than in a separate Resources/ folder so test failures show
//  exactly what was being parsed; the parsers are small enough to keep
//  per-test fixtures readable.
//

import XCTest
@testable import OpenFlowMobile

final class DataFetcherParsingTests: XCTestCase {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - USGS NWIS IV RDB

    func testParseUsgsRdbGroupsToPerDayMinAndMax() {
        // Two days, 4 readings per day - parser should pick min + max per day.
        let rdb = """
        # comment
        # another comment
        agency_cd\tsite_no\tdatetime\ttz_cd\t211804_00060\t211804_00060_cd
        5s\t15s\t20d\t6s\t14n\t10s
        USGS\t09114500\t2026-05-15 00:00\tMDT\t100\tP
        USGS\t09114500\t2026-05-15 12:00\tMDT\t150\tP
        USGS\t09114500\t2026-05-15 18:00\tMDT\t110\tP
        USGS\t09114500\t2026-05-16 06:00\tMDT\t200\tP
        USGS\t09114500\t2026-05-16 18:00\tMDT\t180\tP
        """
        let (mins, maxs) = DataFetchers.parseUsgsRdb(rdb)
        XCTAssertEqual(mins[day(2026, 5, 15)] ?? nil, 100)
        XCTAssertEqual(maxs[day(2026, 5, 15)] ?? nil, 150)
        XCTAssertEqual(mins[day(2026, 5, 16)] ?? nil, 180)
        XCTAssertEqual(maxs[day(2026, 5, 16)] ?? nil, 200)
        XCTAssertEqual(mins.count, 2)
    }

    func testParseUsgsRdbFindsValueColumnByHeaderSuffix() {
        // Multi-gage site with two _00060 columns - parser picks the first.
        let rdb = """
        agency_cd\tsite_no\tdatetime\ttz_cd\tts_A_00060\tts_A_00060_cd\tts_B_00060\tts_B_00060_cd
        5s\t15s\t20d\t6s\t14n\t10s\t14n\t10s
        USGS\t09000000\t2026-05-15 00:00\tMDT\t100\tP\t999\tP
        """
        let (mins, _) = DataFetchers.parseUsgsRdb(rdb)
        XCTAssertEqual(mins[day(2026, 5, 15)] ?? nil, 100)
    }

    func testParseUsgsRdbEmptyResponseReturnsEmptyDictionaries() {
        let (mins, maxs) = DataFetchers.parseUsgsRdb("")
        XCTAssertTrue(mins.isEmpty)
        XCTAssertTrue(maxs.isEmpty)
    }

    func testParseUsgsRdbSkipsRowsWithUnparseableValues() {
        let rdb = """
        agency_cd\tsite_no\tdatetime\ttz_cd\t211804_00060\t211804_00060_cd
        5s\t15s\t20d\t6s\t14n\t10s
        USGS\t09000000\t2026-05-15 00:00\tMDT\tIce\tP
        USGS\t09000000\t2026-05-15 12:00\tMDT\t100\tP
        """
        let (mins, _) = DataFetchers.parseUsgsRdb(rdb)
        XCTAssertEqual(mins[day(2026, 5, 15)] ?? nil, 100)
    }

    // MARK: - CODWR JSON (one value per day; min == max)

    func testParseDwrJsonEmitsMinEqualMaxPerDay() throws {
        let raw = #"""
        {
          "ResultList": [
            {"measDate": "2026-05-15T00:00:00", "value": 1234.5},
            {"measDate": "2026-05-16T00:00:00", "value": 1100.0}
          ]
        }
        """#.data(using: .utf8)!
        let (mins, maxs) = try DataFetchers.parseDwrJson(raw)
        XCTAssertEqual(mins[day(2026, 5, 15)] ?? nil, 1234.5)
        XCTAssertEqual(maxs[day(2026, 5, 15)] ?? nil, 1234.5)
        XCTAssertEqual(mins[day(2026, 5, 16)] ?? nil, 1100.0)
    }

    func testParseDwrJsonSkipsRowsMissingDateOrValue() throws {
        let raw = #"""
        {
          "ResultList": [
            {"measDate": "2026-05-15T00:00:00", "value": null},
            {"measDate": null, "value": 99.9},
            {"measDate": "2026-05-16T00:00:00", "value": 1100.0}
          ]
        }
        """#.data(using: .utf8)!
        let (mins, _) = try DataFetchers.parseDwrJson(raw)
        XCTAssertEqual(mins.count, 1)
        XCTAssertEqual(mins[day(2026, 5, 16)] ?? nil, 1100.0)
    }

    // MARK: - NCEI GHCND

    func testParseGhcndJsonConvertsPrcpInchesToMm() throws {
        // Real NCEI response: TMIN/TMAX in F, PRCP in inches with units=standard.
        let raw = #"""
        [
          {"DATE":"2026-05-10","STATION":"USC00053307","TMAX":"77","TMIN":"48","PRCP":"0.50"},
          {"DATE":"2026-05-11","STATION":"USC00053307","TMAX":"73","TMIN":"42","PRCP":"0.00"}
        ]
        """#.data(using: .utf8)!
        let (tmin, tmax, prcp) = try DataFetchers.parseGhcndJson(raw)
        XCTAssertEqual(tmin[day(2026, 5, 10)] ?? nil, 48.0)
        XCTAssertEqual(tmax[day(2026, 5, 10)] ?? nil, 77.0)
        // 0.5 inches * 25.4 = 12.7 mm.
        XCTAssertEqual(prcp[day(2026, 5, 10)] ?? nil ?? 0, 12.7, accuracy: 1e-9)
        XCTAssertEqual(prcp[day(2026, 5, 11)] ?? nil, 0.0)
    }

    func testParseGhcndJsonHandlesMissingFields() throws {
        let raw = #"""
        [
          {"DATE":"2026-05-10","STATION":"USC00053307","TMAX":"77","TMIN":null,"PRCP":null}
        ]
        """#.data(using: .utf8)!
        let (tmin, _, prcp) = try DataFetchers.parseGhcndJson(raw)
        XCTAssertNil(tmin[day(2026, 5, 10)] ?? nil)
        XCTAssertNil(prcp[day(2026, 5, 10)] ?? nil)
    }

    // MARK: - Open-Meteo forecast

    func testParseOpenMeteoJsonExtractsAllThreeSeries() throws {
        let raw = #"""
        {
          "daily": {
            "time": ["2026-05-18", "2026-05-19", "2026-05-20"],
            "temperature_2m_max": [51.2, 65.0, 68.1],
            "temperature_2m_min": [40.9, 37.6, 45.4],
            "precipitation_sum": [0.0, 2.3, null]
          }
        }
        """#.data(using: .utf8)!
        let (tmin, tmax, prcp) = try DataFetchers.parseOpenMeteoJson(raw)
        XCTAssertEqual(tmin[day(2026, 5, 18)] ?? nil, 40.9)
        XCTAssertEqual(tmax[day(2026, 5, 19)] ?? nil, 65.0)
        XCTAssertEqual(prcp[day(2026, 5, 18)] ?? nil, 0.0)
        XCTAssertEqual(prcp[day(2026, 5, 19)] ?? nil, 2.3)
        // null precip + nil fallback - the parser uses ?? 0 to default
        XCTAssertEqual(prcp[day(2026, 5, 20)] ?? nil, 0.0)
    }

    func testParseOpenMeteoJsonHandlesMissingPrecipitationField() throws {
        // Older deployments omit precipitation_sum entirely.
        let raw = #"""
        {
          "daily": {
            "time": ["2026-05-18"],
            "temperature_2m_max": [51.2],
            "temperature_2m_min": [40.9]
          }
        }
        """#.data(using: .utf8)!
        let (_, _, prcp) = try DataFetchers.parseOpenMeteoJson(raw)
        XCTAssertEqual(prcp[day(2026, 5, 18)] ?? nil, 0.0)
    }
}
