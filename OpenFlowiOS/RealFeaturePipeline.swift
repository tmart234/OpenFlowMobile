//
//  RealFeaturePipeline.swift
//  OpenFlowMobile
//
//  Concrete FeaturePipeline that fetches every required series in parallel,
//  hands them to WindowAssembler, and returns the model-ready FeatureWindow.
//
//  Replaces the Phase 1 UnavailableFeaturePipeline. Wired into FlowGraphView.
//

import Foundation

struct RealFeaturePipeline: FeaturePipeline {
    let registry: StationRegistry

    func assembleWindow(
        siteId: String,
        basinId: String,
        schema: MLContract.Manifest.Schema,
        referenceDate: Date
    ) async throws -> FeatureWindow {
        guard let site = registry.site(for: siteId) else {
            throw RegistryError.siteUnknown(siteId)
        }
        guard let lat = site.lat, let lon = site.lon else {
            throw RegistryError.missingField(site: siteId, field: "lat/lon")
        }

        let cal = Calendar(identifier: .gregorian)
        let encEnd = cal.date(
            byAdding: .day,
            value: -registry.encoderWindowEndOffsetDays,
            to: referenceDate
        ) ?? referenceDate
        let encStart = cal.date(byAdding: .day, value: -(schema.encoderDays - 1), to: encEnd) ?? encEnd

        async let flowSeries = fetchFlow(site: site, start: encStart, end: encEnd)
        async let ghcndSeries: (DailySeries, DailySeries, DailySeries) = {
            guard let ghcnd = site.ghcndId else { return ([:], [:], [:]) }
            return try await DataFetchers.ghcndTempPrecip(stationId: ghcnd, start: encStart, end: encEnd)
        }()
        async let sweSeries: DailySeries = {
            site.snotelTriplets.isEmpty
                ? [:]
                : (try? await DataFetchers.snotelSwe(triplets: site.snotelTriplets, start: encStart, end: encEnd)) ?? [:]
        }()
        async let droughtSeries: DailySeries = {
            guard let huc = site.huc8 else { return [:] }
            return (try? await DataFetchers.usdmDrought(huc8: huc, start: encStart, end: encEnd)) ?? [:]
        }()
        async let smapSeries: DailySeries = {
            guard let huc = site.huc8 else { return [:] }
            return (try? await DataFetchers.smapSoilMoisture(huc8: huc)) ?? [:]
        }()
        async let forecastSeries = DataFetchers.openMeteoForecast(
            lat: lat, lon: lon, days: schema.decoderDays
        )

        let (flowMin, flowMax) = try await flowSeries
        let (ghcndTmin, ghcndTmax, ghcndPrecip) = try await ghcndSeries
        let (forecastTmin, forecastTmax, forecastPrecip) = try await forecastSeries

        let assembler = WindowAssembler(schema: schema)
        return assembler.assemble(
            site: site,
            encoderEnd: encEnd,
            encoder: WindowAssembler.EncoderInputs(
                flowMin: flowMin, flowMax: flowMax,
                tmin: ghcndTmin, tmax: ghcndTmax, precip: ghcndPrecip,
                swe: await sweSeries,
                soilMoisture: await smapSeries,
                drought: await droughtSeries
            ),
            decoder: WindowAssembler.DecoderInputs(
                tmin: forecastTmin, tmax: forecastTmax, precip: forecastPrecip
            )
        )
    }

    private func fetchFlow(site: SiteMetadata, start: Date, end: Date) async throws
        -> (min: DailySeries, max: DailySeries) {
        switch site.agency {
        case "USGS":
            return try await DataFetchers.usgsFlow(siteId: site.siteId, start: start, end: end)
        case "DWR":
            return try await DataFetchers.dwrFlow(abbrev: site.siteId, start: start, end: end)
        default:
            throw RegistryError.missingField(site: "\(site.agency):\(site.siteId)", field: "supported agency")
        }
    }
}
