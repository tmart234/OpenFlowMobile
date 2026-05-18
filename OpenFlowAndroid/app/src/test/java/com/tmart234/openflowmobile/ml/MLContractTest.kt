package com.tmart234.openflowmobile.ml

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.expm1
import kotlin.math.ln1p

/**
 * Unit tests for the ML inference contract translation. These don't load
 * a real TFLite model; they validate JSON parsing and the scale/invert
 * arithmetic against the spec in
 * https://github.com/tmart234/OpenFlow/blob/dev/docs/INFERENCE.md
 */
class MLContractTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `manifest parses with all contract fields`() {
        val raw = """
            {
              "model_version": "model-2026.05.18",
              "created_utc": "2026-05-18T17:20:13Z",
              "tf_version": "2.14.0",
              "coremltools_version": "7.1",
              "tflite_mode": "builtins",
              "schema": {
                "encoder_days": 60,
                "decoder_days": 14,
                "encoder_features": ["Min Flow", "Max Flow", "TMIN", "TMAX"],
                "decoder_features": ["TMIN", "TMAX", "doy_sin", "doy_cos"],
                "target_features": ["Min Flow", "Max Flow"],
                "num_stations": 100,
                "num_basins": 20
              },
              "files": [
                {"name": "lstm_model.tflite", "sha256": "abc123", "bytes": 524288}
              ]
            }
        """.trimIndent()

        val manifest = json.decodeFromString(Manifest.serializer(), raw)

        assertEquals("model-2026.05.18", manifest.modelVersion)
        assertEquals("builtins", manifest.tfliteMode)
        assertEquals(60, manifest.schema.encoderDays)
        assertEquals(14, manifest.schema.decoderDays)
        assertEquals(listOf("Min Flow", "Max Flow"), manifest.schema.targetFeatures)
        assertEquals(100, manifest.schema.numStations)
        assertEquals(1, manifest.files.size)
        assertEquals(524288L, manifest.files[0].bytes)
    }

    @Test
    fun `manifest tolerates absent coremltools_version (TFLite-only releases)`() {
        val raw = """
            {
              "model_version": "model-2026.05.18",
              "created_utc": "2026-05-18T17:20:13Z",
              "tf_version": "2.14.0",
              "tflite_mode": "select_tf_ops",
              "schema": {
                "encoder_days": 60, "decoder_days": 14,
                "encoder_features": [], "decoder_features": [],
                "target_features": [], "num_stations": 0, "num_basins": 0
              },
              "files": []
            }
        """.trimIndent()
        val manifest = json.decodeFromString(Manifest.serializer(), raw)
        assertNull(manifest.coremltoolsVersion)
    }

    @Test
    fun `scalers parse as a column map`() {
        val raw = """
            {
              "Min Flow":  {"mean": 4.5,  "scale": 1.2, "transform": "log1p"},
              "Max Flow":  {"mean": 5.0,  "scale": 1.3, "transform": "log1p"},
              "TMIN":      {"mean": 32.0, "scale": 8.0, "transform": "identity"}
            }
        """.trimIndent()
        val scalers: Scalers = json.decodeFromString(raw)
        assertEquals(3, scalers.size)
        assertEquals("log1p", scalers["Min Flow"]?.transform)
        assertEquals(32.0, scalers["TMIN"]?.mean ?: 0.0, 1e-9)
    }

    @Test
    fun `indexFor returns 0 for unseen keys per the unseen-fallback rule`() {
        val map: IndexMap = mapOf("USGS:09163500" to 1, "DWR:ARKCANCO" to 2)
        assertEquals(1, map.indexFor("USGS:09163500"))
        assertEquals(2, map.indexFor("DWR:ARKCANCO"))
        assertEquals(0, map.indexFor("USGS:99999999"))
        assertEquals(0, map.indexFor(""))
    }

    @Test
    fun `scale and invert roundtrip is identity for log1p flow columns`() {
        val params = ScalerParams(mean = 4.5, scale = 1.2, transform = "log1p")
        val original = listOf(0.0, 1.0, 100.0, 5000.0, 12345.6)
        for (raw in original) {
            val z = scale(raw, params)
            val recovered = invert(z, params)
            assertTrue(
                "log1p roundtrip failed for $raw (got $recovered)",
                abs(recovered - raw) < 1e-6
            )
        }
    }

    @Test
    fun `scale and invert roundtrip is identity for identity columns`() {
        val params = ScalerParams(mean = 32.0, scale = 8.0, transform = "identity")
        val original = listOf(-40.0, 0.0, 50.0, 110.0)
        for (raw in original) {
            val z = scale(raw, params)
            val recovered = invert(z, params)
            assertTrue(abs(recovered - raw) < 1e-9)
        }
    }

    // Free-standing copies of the contract arithmetic so the test verifies
    // the spec itself, not whatever ModelBundle does internally.
    private fun scale(raw: Double, p: ScalerParams): Double {
        val x = if (p.transform == "log1p") ln1p(raw) else raw
        return (x - p.mean) / p.scale
    }

    private fun invert(z: Double, p: ScalerParams): Double {
        val x = z * p.scale + p.mean
        return if (p.transform == "log1p") expm1(x) else x
    }
}
