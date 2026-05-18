package com.tmart234.openflowmobile.ml

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Codable types matching the inference contract published by upstream OpenFlow.
 * See https://github.com/tmart234/OpenFlow/blob/dev/docs/INFERENCE.md
 */

/** manifest.json - bundled with every model-YYYY.MM.DD release. */
@Serializable
data class Manifest(
    @SerialName("model_version") val modelVersion: String,
    @SerialName("created_utc") val createdUtc: String,
    @SerialName("tf_version") val tfVersion: String,
    @SerialName("coremltools_version") val coremltoolsVersion: String? = null,
    @SerialName("tflite_mode") val tfliteMode: String,
    val schema: Schema,
    val files: List<FileEntry>,
) {
    @Serializable
    data class Schema(
        @SerialName("encoder_days") val encoderDays: Int,
        @SerialName("decoder_days") val decoderDays: Int,
        @SerialName("encoder_features") val encoderFeatures: List<String>,
        @SerialName("decoder_features") val decoderFeatures: List<String>,
        @SerialName("target_features") val targetFeatures: List<String>,
        @SerialName("num_stations") val numStations: Int,
        @SerialName("num_basins") val numBasins: Int,
    )

    @Serializable
    data class FileEntry(
        val name: String,
        val sha256: String,
        val bytes: Long,
    )
}

/**
 * scalers.json - per-column normalization parameters. Indicator columns
 * (sm_observed, reservoir_observed) are intentionally absent and bypass scaling.
 */
typealias Scalers = Map<String, ScalerParams>

@Serializable
data class ScalerParams(
    val mean: Double,
    val scale: Double,
    val transform: String, // "log1p" | "identity"
)

/**
 * station_index.json / basin_index.json - site_id (or HUC8) to embedding index.
 * Index 0 is reserved upstream for unseen keys; never appears as a value.
 */
typealias IndexMap = Map<String, Int>

/** Returns the embedding index for [key], or 0 if unseen. */
fun IndexMap.indexFor(key: String): Int = this[key] ?: 0

/** training_config.json - duplicates fields in Manifest.schema for legacy compat. */
@Serializable
data class TrainingConfig(
    @SerialName("encoder_days") val encoderDays: Int,
    @SerialName("decoder_days") val decoderDays: Int,
    @SerialName("encoder_features") val encoderFeatures: List<String>,
    @SerialName("decoder_features") val decoderFeatures: List<String>,
    @SerialName("target_features") val targetFeatures: List<String>,
)

/** One day of decoded forecast in cfs. */
data class DailyForecast(
    val epochDay: Long, // days since 1970-01-01 UTC
    val minFlowCFS: Double,
    val maxFlowCFS: Double,
)

/**
 * Assembled raw input window. Values are unscaled - scaling happens inside
 * ModelBundle to keep the contract translation centralized.
 */
data class FeatureWindow(
    val siteId: String,
    val basinId: String,
    /** [encoderDays] rows x [encoderFeatures] columns, raw values. */
    val encoderRows: Array<DoubleArray>,
    /** [decoderDays] rows x [decoderFeatures] columns, raw values. */
    val decoderRows: Array<DoubleArray>,
    /** One value per target feature, raw cfs. Used as the persistence baseline. */
    val persistenceTargets: DoubleArray,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as FeatureWindow
        return siteId == other.siteId &&
            basinId == other.basinId &&
            encoderRows.contentDeepEquals(other.encoderRows) &&
            decoderRows.contentDeepEquals(other.decoderRows) &&
            persistenceTargets.contentEquals(other.persistenceTargets)
    }

    override fun hashCode(): Int {
        var result = siteId.hashCode()
        result = 31 * result + basinId.hashCode()
        result = 31 * result + encoderRows.contentDeepHashCode()
        result = 31 * result + decoderRows.contentDeepHashCode()
        result = 31 * result + persistenceTargets.contentHashCode()
        return result
    }
}
