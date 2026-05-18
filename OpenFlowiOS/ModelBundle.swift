//
//  ModelBundle.swift
//  OpenFlowMobile
//
//  Loaded model + its companion JSONs, with the inference contract baked in.
//  The translation between raw feature values and the model's scaled tensors
//  lives here so callers never touch normalization directly.
//

import Foundation
import CoreML

final class ModelBundle {
    let manifest: MLContract.Manifest
    let trainingConfig: MLContract.TrainingConfig
    let scalers: MLContract.Scalers
    let stationIndex: MLContract.IndexMap
    let basinIndex: MLContract.IndexMap

    var version: String { manifest.modelVersion }

    private let model: MLModel

    /// Initialize from a directory containing the model bundle:
    ///   manifest.json, training_config.json, scalers.json,
    ///   station_index.json, basin_index.json, lstm_model.mlpackage/
    init(directory: URL) throws {
        let dec = JSONDecoder()
        self.manifest = try dec.decode(MLContract.Manifest.self,
            from: try Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        self.trainingConfig = try dec.decode(MLContract.TrainingConfig.self,
            from: try Data(contentsOf: directory.appendingPathComponent("training_config.json")))
        self.scalers = try dec.decode(MLContract.Scalers.self,
            from: try Data(contentsOf: directory.appendingPathComponent("scalers.json")))
        self.stationIndex = try dec.decode(MLContract.IndexMap.self,
            from: try Data(contentsOf: directory.appendingPathComponent("station_index.json")))
        self.basinIndex = try dec.decode(MLContract.IndexMap.self,
            from: try Data(contentsOf: directory.appendingPathComponent("basin_index.json")))

        let mlpackageURL = directory.appendingPathComponent("lstm_model.mlpackage")
        let compiledURL = try MLModel.compileModel(at: mlpackageURL)
        self.model = try MLModel(contentsOf: compiledURL)
    }

    /// Run inference on an assembled window. Returns 14 days of decoded cfs forecasts
    /// keyed by date starting at `forecastStart` (typically tomorrow).
    func forecast(_ window: FeatureWindow, forecastStart: Date) throws -> [DailyForecast] {
        let provider = try buildInputs(window)
        let prediction = try model.prediction(from: provider)
        return try decodeOutput(prediction, forecastStart: forecastStart)
    }

    private func buildInputs(_ window: FeatureWindow) throws -> MLFeatureProvider {
        let schema = manifest.schema

        guard window.encoderRows.count == schema.encoderDays,
              window.encoderRows.allSatisfy({ $0.count == schema.encoderFeatures.count }) else {
            throw InferenceError.shapeMismatch(
                "encoder_input expected [\(schema.encoderDays), \(schema.encoderFeatures.count)]")
        }
        guard window.decoderRows.count == schema.decoderDays,
              window.decoderRows.allSatisfy({ $0.count == schema.decoderFeatures.count }) else {
            throw InferenceError.shapeMismatch(
                "decoder_input expected [\(schema.decoderDays), \(schema.decoderFeatures.count)]")
        }
        guard window.persistenceTargets.count == schema.targetFeatures.count else {
            throw InferenceError.shapeMismatch(
                "persistence_input expected \(schema.targetFeatures.count) values")
        }

        let encoderArr = try MLMultiArray(
            shape: [1, schema.encoderDays as NSNumber, schema.encoderFeatures.count as NSNumber],
            dataType: .float32)
        for d in 0..<schema.encoderDays {
            for c in 0..<schema.encoderFeatures.count {
                let scaled = scale(window.encoderRows[d][c], column: schema.encoderFeatures[c])
                encoderArr[[0, d as NSNumber, c as NSNumber]] = NSNumber(value: Float(scaled))
            }
        }

        let decoderArr = try MLMultiArray(
            shape: [1, schema.decoderDays as NSNumber, schema.decoderFeatures.count as NSNumber],
            dataType: .float32)
        for d in 0..<schema.decoderDays {
            for c in 0..<schema.decoderFeatures.count {
                let scaled = scale(window.decoderRows[d][c], column: schema.decoderFeatures[c])
                decoderArr[[0, d as NSNumber, c as NSNumber]] = NSNumber(value: Float(scaled))
            }
        }

        let persArr = try MLMultiArray(
            shape: [1, schema.targetFeatures.count as NSNumber],
            dataType: .float32)
        for c in 0..<schema.targetFeatures.count {
            let scaled = scale(window.persistenceTargets[c], column: schema.targetFeatures[c])
            persArr[[0, c as NSNumber]] = NSNumber(value: Float(scaled))
        }

        let stationArr = try MLMultiArray(shape: [1], dataType: .int32)
        stationArr[0] = NSNumber(value: stationIndex.index(for: window.siteId))

        let basinArr = try MLMultiArray(shape: [1], dataType: .int32)
        basinArr[0] = NSNumber(value: basinIndex.index(for: window.basinId))

        return try MLDictionaryFeatureProvider(dictionary: [
            "encoder_input": encoderArr,
            "decoder_input": decoderArr,
            "persistence_input": persArr,
            "station_input": stationArr,
            "basin_input": basinArr,
        ])
    }

    private func decodeOutput(_ prediction: MLFeatureProvider, forecastStart: Date) throws -> [DailyForecast] {
        guard let outputValue = prediction.featureValue(for: "persistence_plus_delta"),
              let arr = outputValue.multiArrayValue else {
            throw InferenceError.missingOutput
        }
        let schema = manifest.schema
        guard let minIdx = schema.targetFeatures.firstIndex(of: "Min Flow"),
              let maxIdx = schema.targetFeatures.firstIndex(of: "Max Flow") else {
            throw InferenceError.unexpectedTargets(schema.targetFeatures)
        }

        let cal = Calendar(identifier: .gregorian)
        var forecasts: [DailyForecast] = []
        forecasts.reserveCapacity(schema.decoderDays)
        for d in 0..<schema.decoderDays {
            let zMin = arr[[0, d as NSNumber, minIdx as NSNumber]].doubleValue
            let zMax = arr[[0, d as NSNumber, maxIdx as NSNumber]].doubleValue
            let date = cal.date(byAdding: .day, value: d, to: forecastStart) ?? forecastStart
            forecasts.append(DailyForecast(
                date: date,
                minFlowCFS: invert(zMin, column: "Min Flow"),
                maxFlowCFS: invert(zMax, column: "Max Flow")))
        }
        return forecasts
    }

    /// Apply per-column scaling per the contract. Columns missing from
    /// scalers.json (indicator columns) pass through unchanged.
    private func scale(_ raw: Double, column: String) -> Double {
        guard let params = scalers.columns[column] else { return raw }
        let x: Double
        switch params.transform {
        case .log1p: x = log1p(raw)
        case .identity: x = raw
        }
        return (x - params.mean) / params.scale
    }

    /// Inverse of scale(). Recovers cfs from the model's scaled output.
    private func invert(_ z: Double, column: String) -> Double {
        guard let params = scalers.columns[column] else { return z }
        let x = z * params.scale + params.mean
        switch params.transform {
        case .log1p: return expm1(x)
        case .identity: return x
        }
    }
}

enum InferenceError: LocalizedError {
    case shapeMismatch(String)
    case missingOutput
    case unexpectedTargets([String])

    var errorDescription: String? {
        switch self {
        case .shapeMismatch(let m): return "Input shape mismatch: \(m)"
        case .missingOutput: return "Model produced no 'persistence_plus_delta' output"
        case .unexpectedTargets(let t): return "Unexpected target_features: \(t)"
        }
    }
}
