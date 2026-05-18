//
//  WindowAssemblerTests.swift
//  OpenFlowiOSTests
//
//  Hand-crafted DailySeries -> assert the resulting FeatureWindow has the
//  right shape, the right cell values, and the right indicator flags.
//

import XCTest
@testable import OpenFlowMobile

final class WindowAssemblerTests: XCTestCase {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ offsetFromEnd: Int, end: Date) -> Date {
        utc.date(byAdding: .day, value: offsetFromEnd, to: end)!
    }

    private func makeSchema(
        enc: [String] = ["Min Flow", "Max Flow", "TMIN", "TMAX", "precipitation",
                          "SWE", "soil_moisture", "sm_observed", "drought_index",
                          "reservoir_storage", "reservoir_release", "reservoir_observed",
                          "doy_sin", "doy_cos"],
        dec: [String] = ["TMIN", "TMAX", "precipitation", "doy_sin", "doy_cos"],
        encDays: Int = 5,
        decDays: Int = 3
    ) -> MLContract.Manifest.Schema {
        MLContract.Manifest.Schema(
            encoderDays: encDays, decoderDays: decDays,
            encoderFeatures: enc, decoderFeatures: dec,
            targetFeatures: ["Min Flow", "Max Flow"],
            numStations: 10, numBasins: 5
        )
    }

    private func siteMetadata(huc8: String = "14010005") -> SiteMetadata {
        SiteMetadata(
            agency: "USGS", siteId: "09163500", name: "Test",
            lat: 39.13, lon: -109.02, huc8: huc8,
            snotelTriplets: [], ghcndId: nil, ghcndDistanceKm: nil, notes: []
        )
    }

    // MARK: - shape

    func testAssembleProducesCorrectShape() {
        let schema = makeSchema()
        let encEnd = day(0, end: Date(timeIntervalSince1970: 1_750_000_000))
        let encStart = day(-4, end: encEnd)

        var flow: DailySeries = [:]
        for off in 0..<5 {
            flow[day(off, end: encStart)] = Double(100 + off)
        }

        let window = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: encEnd,
            encoder: .init(flowMin: flow, flowMax: flow,
                           tmin: [:], tmax: [:], precip: [:],
                           swe: [:], soilMoisture: [:], drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )

        XCTAssertEqual(window.encoderRows.count, 5)
        XCTAssertEqual(window.encoderRows.first?.count, 14)
        XCTAssertEqual(window.decoderRows.count, 3)
        XCTAssertEqual(window.decoderRows.first?.count, 5)
        XCTAssertEqual(window.persistenceTargets.count, 2)
        XCTAssertEqual(window.siteId, "USGS:09163500")
        XCTAssertEqual(window.basinId, "14010005")
    }

    // MARK: - column ordering matches schema (not hardcoded)

    func testEncoderColumnsRespectSchemaOrder() {
        // Reverse the canonical order to prove the assembler is dynamic.
        let schema = makeSchema(
            enc: ["TMAX", "Min Flow", "doy_sin"],  // 3 columns in this order
            dec: ["TMIN"]
        )
        let encEnd = day(0, end: Date(timeIntervalSince1970: 1_750_000_000))
        let encStart = day(-4, end: encEnd)

        var flow: DailySeries = [:]
        var tmax: DailySeries = [:]
        for off in 0..<5 {
            flow[day(off, end: encStart)] = 100.0
            tmax[day(off, end: encStart)] = 75.0
        }
        let window = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: encEnd,
            encoder: .init(flowMin: flow, flowMax: flow,
                           tmin: [:], tmax: tmax, precip: [:],
                           swe: [:], soilMoisture: [:], drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )
        // Column 0 = TMAX = 75, column 1 = Min Flow = 100, column 2 = doy_sin ∈ [-1, 1].
        XCTAssertEqual(window.encoderRows[0][0], 75.0)
        XCTAssertEqual(window.encoderRows[0][1], 100.0)
        XCTAssertTrue((-1.0...1.0).contains(window.encoderRows[0][2]))
    }

    // MARK: - gap fill

    func testForwardFillAppliesToInteriorGaps() {
        let schema = makeSchema(
            enc: ["Min Flow"], dec: ["TMIN"], encDays: 5, decDays: 1
        )
        let encEnd = day(0, end: Date(timeIntervalSince1970: 1_750_000_000))
        let encStart = day(-4, end: encEnd)

        // Observe only day 0 and day 4; days 1-3 should fwd-fill from day 0.
        var flow: DailySeries = [:]
        flow[day(0, end: encStart)] = 100.0
        flow[day(4, end: encStart)] = 500.0

        let window = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: encEnd,
            encoder: .init(flowMin: flow, flowMax: flow,
                           tmin: [:], tmax: [:], precip: [:],
                           swe: [:], soilMoisture: [:], drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )
        XCTAssertEqual(window.encoderRows.map { $0[0] }, [100, 100, 100, 100, 500])
    }

    func testBackFillCoversLeadingGaps() {
        let schema = makeSchema(
            enc: ["Min Flow"], dec: ["TMIN"], encDays: 4, decDays: 1
        )
        let encEnd = day(0, end: Date(timeIntervalSince1970: 1_750_000_000))
        let encStart = day(-3, end: encEnd)

        var flow: DailySeries = [:]
        flow[day(2, end: encStart)] = 50.0  // first observation is day 2

        let window = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: encEnd,
            encoder: .init(flowMin: flow, flowMax: flow,
                           tmin: [:], tmax: [:], precip: [:],
                           swe: [:], soilMoisture: [:], drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )
        XCTAssertEqual(window.encoderRows.map { $0[0] }, [50, 50, 50, 50])
    }

    // MARK: - indicators

    func testSmObservedFlagsRealRetrievalsOnly() {
        let schema = makeSchema(
            enc: ["soil_moisture", "sm_observed"], dec: ["TMIN"], encDays: 4, decDays: 1
        )
        let encEnd = day(0, end: Date(timeIntervalSince1970: 1_750_000_000))
        let encStart = day(-3, end: encEnd)

        // Real SMAP retrieval on day 0 + day 2 only.
        var smap: DailySeries = [:]
        smap[day(0, end: encStart)] = 0.21
        smap[day(2, end: encStart)] = 0.23

        let window = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: encEnd,
            encoder: .init(flowMin: [:], flowMax: [:],
                           tmin: [:], tmax: [:], precip: [:],
                           swe: [:], soilMoisture: smap, drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )
        // Day-by-day: [observed=1, ffilled=0, observed=1, ffilled=0].
        let indicators = window.encoderRows.map { $0[1] }
        XCTAssertEqual(indicators, [1, 0, 1, 0])
        // Soil moisture column ffills forward (day 1 reads day 0's value).
        XCTAssertEqual(window.encoderRows[1][0], 0.21, accuracy: 1e-9)
    }

    func testReservoirColumnsAreHardcodedZero() {
        let schema = makeSchema(
            enc: ["reservoir_storage", "reservoir_release", "reservoir_observed"],
            dec: ["TMIN"], encDays: 3, decDays: 1
        )
        let encEnd = day(0, end: Date(timeIntervalSince1970: 1_750_000_000))

        let window = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: encEnd,
            encoder: .init(flowMin: [:], flowMax: [:],
                           tmin: [:], tmax: [:], precip: [:],
                           swe: [:], soilMoisture: [:], drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )
        for row in window.encoderRows {
            XCTAssertEqual(row, [0, 0, 0])
        }
    }

    // MARK: - doy_sin / doy_cos

    func testDoySinCosWrapAroundNewYear() {
        let schema = makeSchema(
            enc: ["doy_sin", "doy_cos"], dec: ["doy_sin"], encDays: 1, decDays: 1
        )
        // Jan 1 -> angle ~ 0 -> sin ~ 0, cos ~ 1
        let jan1 = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let win = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: jan1,
            encoder: .init(flowMin: [:], flowMax: [:],
                           tmin: [:], tmax: [:], precip: [:],
                           swe: [:], soilMoisture: [:], drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )
        XCTAssertEqual(win.encoderRows[0][0], 0, accuracy: 1e-9)
        XCTAssertEqual(win.encoderRows[0][1], 1, accuracy: 1e-9)
    }

    // MARK: - persistence

    func testPersistenceTargetsAreLastEncoderDayRawValues() {
        let schema = makeSchema(
            enc: ["Min Flow", "Max Flow"], dec: ["TMIN"], encDays: 3, decDays: 1
        )
        let encEnd = day(0, end: Date(timeIntervalSince1970: 1_750_000_000))
        let encStart = day(-2, end: encEnd)
        var minFlow: DailySeries = [:], maxFlow: DailySeries = [:]
        for off in 0..<3 {
            minFlow[day(off, end: encStart)] = Double(100 + off)
            maxFlow[day(off, end: encStart)] = Double(200 + off)
        }
        let win = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: encEnd,
            encoder: .init(flowMin: minFlow, flowMax: maxFlow,
                           tmin: [:], tmax: [:], precip: [:],
                           swe: [:], soilMoisture: [:], drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )
        // Last encoder day = encEnd = day 2 of the window.
        XCTAssertEqual(win.persistenceTargets, [102, 202])
    }

    // MARK: - unknown columns degrade gracefully

    func testUnknownEncoderColumnIsZeroed() {
        let schema = makeSchema(
            enc: ["mystery_future_feature"], dec: ["TMIN"], encDays: 2, decDays: 1
        )
        let encEnd = day(0, end: Date(timeIntervalSince1970: 1_750_000_000))
        let win = WindowAssembler(schema: schema).assemble(
            site: siteMetadata(),
            encoderEnd: encEnd,
            encoder: .init(flowMin: [:], flowMax: [:],
                           tmin: [:], tmax: [:], precip: [:],
                           swe: [:], soilMoisture: [:], drought: [:]),
            decoder: .init(tmin: [:], tmax: [:], precip: [:])
        )
        XCTAssertEqual(win.encoderRows.map { $0[0] }, [0, 0])
    }
}
