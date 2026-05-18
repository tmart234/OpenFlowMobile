//
//  FeaturePipeline.swift
//  OpenFlowMobile
//
//  Assembles a FeatureWindow for inference from live data sources
//  (USGS / CODWR streamflow, NOAA temps, NRCS SWE, NASA SMAP soil moisture
//  via a credentialed proxy, USDM drought, USBR RISE reservoirs).
//
//  Phase 2 builds the real implementation. Phase 1 ships only the protocol
//  and an "unavailable" stub so the rest of the inference stack compiles
//  and surfaces a clean error state in the UI.
//

import Foundation

protocol FeaturePipeline {
    /// Build a window aligned to the model contract for the given site.
    /// `referenceDate` is the cutoff between the 60-day encoder window
    /// (history, ending at referenceDate) and the 14-day decoder window
    /// (forecast, starting referenceDate + 1).
    func assembleWindow(
        siteId: String,
        basinId: String,
        schema: MLContract.Manifest.Schema,
        referenceDate: Date
    ) async throws -> FeatureWindow
}

struct UnavailableFeaturePipeline: FeaturePipeline {
    func assembleWindow(
        siteId: String,
        basinId: String,
        schema: MLContract.Manifest.Schema,
        referenceDate: Date
    ) async throws -> FeatureWindow {
        throw FeaturePipelineError.notImplemented
    }
}

enum FeaturePipelineError: LocalizedError {
    case notImplemented
    case missingData(source: String, site: String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Live forecast feature pipeline is not implemented yet (Phase 2)."
        case .missingData(let source, let site):
            return "Missing \(source) data for site \(site)."
        }
    }
}
