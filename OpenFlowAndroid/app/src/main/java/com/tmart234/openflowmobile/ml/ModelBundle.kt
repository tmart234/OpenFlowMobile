package com.tmart234.openflowmobile.ml

import kotlinx.serialization.json.Json
import org.tensorflow.lite.Interpreter
import java.io.Closeable
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import kotlin.math.expm1
import kotlin.math.ln1p

/**
 * Loaded TFLite model + companion JSONs, with the inference contract baked in.
 * The translation between raw feature values and the model's scaled tensors
 * lives here so callers never touch normalization directly.
 */
class ModelBundle private constructor(
    val manifest: Manifest,
    val trainingConfig: TrainingConfig,
    val scalers: Scalers,
    val stationIndex: IndexMap,
    val basinIndex: IndexMap,
    private val interpreter: Interpreter,
) : Closeable {

    val version: String get() = manifest.modelVersion

    /**
     * Run inference on an assembled window. Returns [Manifest.Schema.decoderDays]
     * days of decoded cfs forecasts starting at [forecastStartEpochDay].
     */
    fun forecast(window: FeatureWindow, forecastStartEpochDay: Long): List<DailyForecast> {
        val inputs = buildInputs(window)
        val schema = manifest.schema
        val output = Array(1) { Array(schema.decoderDays) { FloatArray(schema.targetFeatures.size) } }
        val outputs = mapOf("persistence_plus_delta" to output)
        val runner = interpreter.getSignatureRunner(
            interpreter.signatureKeys.firstOrNull() ?: "serving_default"
        )
        runner.run(inputs, outputs)
        return decodeOutput(output, forecastStartEpochDay)
    }

    private fun buildInputs(window: FeatureWindow): Map<String, Any> {
        val schema = manifest.schema

        require(window.encoderRows.size == schema.encoderDays) {
            "encoder_input expected ${schema.encoderDays} rows, got ${window.encoderRows.size}"
        }
        require(window.encoderRows.all { it.size == schema.encoderFeatures.size }) {
            "encoder_input expected ${schema.encoderFeatures.size} cols"
        }
        require(window.decoderRows.size == schema.decoderDays) {
            "decoder_input expected ${schema.decoderDays} rows, got ${window.decoderRows.size}"
        }
        require(window.decoderRows.all { it.size == schema.decoderFeatures.size }) {
            "decoder_input expected ${schema.decoderFeatures.size} cols"
        }
        require(window.persistenceTargets.size == schema.targetFeatures.size) {
            "persistence_input expected ${schema.targetFeatures.size} values"
        }

        val encoderArr = Array(1) {
            Array(schema.encoderDays) { d ->
                FloatArray(schema.encoderFeatures.size) { c ->
                    scale(window.encoderRows[d][c], schema.encoderFeatures[c]).toFloat()
                }
            }
        }
        val decoderArr = Array(1) {
            Array(schema.decoderDays) { d ->
                FloatArray(schema.decoderFeatures.size) { c ->
                    scale(window.decoderRows[d][c], schema.decoderFeatures[c]).toFloat()
                }
            }
        }
        val persArr = Array(1) {
            FloatArray(schema.targetFeatures.size) { c ->
                scale(window.persistenceTargets[c], schema.targetFeatures[c]).toFloat()
            }
        }
        val stationArr = IntArray(1) { stationIndex.indexFor(window.siteId) }
        val basinArr = IntArray(1) { basinIndex.indexFor(window.basinId) }

        return mapOf(
            "encoder_input" to encoderArr,
            "decoder_input" to decoderArr,
            "persistence_input" to persArr,
            "station_input" to stationArr,
            "basin_input" to basinArr,
        )
    }

    private fun decodeOutput(
        output: Array<Array<FloatArray>>,
        forecastStartEpochDay: Long,
    ): List<DailyForecast> {
        val schema = manifest.schema
        val minIdx = schema.targetFeatures.indexOf("Min Flow")
        val maxIdx = schema.targetFeatures.indexOf("Max Flow")
        check(minIdx >= 0 && maxIdx >= 0) {
            "Unexpected target_features: ${schema.targetFeatures}"
        }
        return List(schema.decoderDays) { d ->
            DailyForecast(
                epochDay = forecastStartEpochDay + d,
                minFlowCFS = invert(output[0][d][minIdx].toDouble(), "Min Flow"),
                maxFlowCFS = invert(output[0][d][maxIdx].toDouble(), "Max Flow"),
            )
        }
    }

    /**
     * Apply per-column scaling per the contract. Columns missing from
     * scalers.json (indicator columns) pass through unchanged.
     */
    private fun scale(raw: Double, column: String): Double {
        val params = scalers[column] ?: return raw
        val x = if (params.transform == "log1p") ln1p(raw) else raw
        return (x - params.mean) / params.scale
    }

    /** Inverse of [scale]. Recovers cfs from the model's scaled output. */
    private fun invert(z: Double, column: String): Double {
        val params = scalers[column] ?: return z
        val x = z * params.scale + params.mean
        return if (params.transform == "log1p") expm1(x) else x
    }

    override fun close() {
        interpreter.close()
    }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /**
         * Load from a directory containing the model bundle:
         *   manifest.json, training_config.json, scalers.json,
         *   station_index.json, basin_index.json, lstm_model.tflite
         */
        fun load(directory: File): ModelBundle {
            val manifest = json.decodeFromString(
                Manifest.serializer(),
                File(directory, "manifest.json").readText()
            )
            val trainingConfig = json.decodeFromString(
                TrainingConfig.serializer(),
                File(directory, "training_config.json").readText()
            )
            val scalers: Scalers = json.decodeFromString(
                File(directory, "scalers.json").readText()
            )
            val stationIndex: IndexMap = json.decodeFromString(
                File(directory, "station_index.json").readText()
            )
            val basinIndex: IndexMap = json.decodeFromString(
                File(directory, "basin_index.json").readText()
            )

            val modelFile = File(directory, "lstm_model.tflite")
            val mappedBuffer = FileChannel.open(modelFile.toPath(), StandardOpenOption.READ).use { ch ->
                ch.map(FileChannel.MapMode.READ_ONLY, 0, ch.size())
            }
            // Flex delegate auto-registers if tensorflow-lite-select-tf-ops is on
            // the classpath, which handles manifest.tflite_mode == "select_tf_ops".
            val interpreter = Interpreter(mappedBuffer)

            return ModelBundle(
                manifest = manifest,
                trainingConfig = trainingConfig,
                scalers = scalers,
                stationIndex = stationIndex,
                basinIndex = basinIndex,
                interpreter = interpreter,
            )
        }
    }
}
