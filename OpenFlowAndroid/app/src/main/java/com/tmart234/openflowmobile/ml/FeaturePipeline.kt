package com.tmart234.openflowmobile.ml

/**
 * Assembles a [FeatureWindow] for inference from live data sources
 * (USGS / CODWR streamflow, NOAA temps, NRCS SWE, NASA SMAP soil moisture
 * via a credentialed proxy, USDM drought, USBR RISE reservoirs).
 *
 * Phase 2 builds the real implementation. Phase 1 ships only the interface
 * and an "unavailable" stub so the rest of the inference stack compiles
 * and surfaces a clean error state in the UI.
 */
interface FeaturePipeline {
    /**
     * Build a window aligned to the model contract for the given site.
     * [referenceEpochDay] is the cutoff between the 60-day encoder window
     * (history, ending at referenceEpochDay) and the 14-day decoder window
     * (forecast, starting referenceEpochDay + 1).
     */
    suspend fun assembleWindow(
        siteId: String,
        basinId: String,
        schema: Manifest.Schema,
        referenceEpochDay: Long,
    ): FeatureWindow
}

class UnavailableFeaturePipeline : FeaturePipeline {
    override suspend fun assembleWindow(
        siteId: String,
        basinId: String,
        schema: Manifest.Schema,
        referenceEpochDay: Long,
    ): FeatureWindow {
        throw FeaturePipelineException("Live forecast feature pipeline is not implemented yet (Phase 2).")
    }
}

class FeaturePipelineException(message: String) : RuntimeException(message)
