//
//  MLContract.swift
//  OpenFlowMobile
//
//  Codable types matching the inference contract published by upstream OpenFlow.
//  See https://github.com/tmart234/OpenFlow/blob/dev/docs/INFERENCE.md
//

import Foundation

enum MLContract {
    /// manifest.json — bundled with every model-YYYY.MM.DD release.
    struct Manifest: Codable {
        let modelVersion: String
        let createdUtc: String
        let tfVersion: String
        let coremltoolsVersion: String?
        let tfliteMode: String
        let schema: Schema
        let files: [FileEntry]

        struct Schema: Codable {
            let encoderDays: Int
            let decoderDays: Int
            let encoderFeatures: [String]
            let decoderFeatures: [String]
            let targetFeatures: [String]
            let numStations: Int
            let numBasins: Int

            enum CodingKeys: String, CodingKey {
                case encoderDays = "encoder_days"
                case decoderDays = "decoder_days"
                case encoderFeatures = "encoder_features"
                case decoderFeatures = "decoder_features"
                case targetFeatures = "target_features"
                case numStations = "num_stations"
                case numBasins = "num_basins"
            }
        }

        struct FileEntry: Codable {
            let name: String
            let sha256: String
            let bytes: Int
        }

        enum CodingKeys: String, CodingKey {
            case modelVersion = "model_version"
            case createdUtc = "created_utc"
            case tfVersion = "tf_version"
            case coremltoolsVersion = "coremltools_version"
            case tfliteMode = "tflite_mode"
            case schema
            case files
        }
    }

    /// scalers.json — per-column normalization parameters. Indicator columns
    /// (sm_observed, reservoir_observed) are intentionally absent and bypass scaling.
    struct Scalers: Codable {
        let columns: [String: Params]

        struct Params: Codable {
            let mean: Double
            let scale: Double
            let transform: Transform
        }

        enum Transform: String, Codable {
            case log1p
            case identity
        }

        init(from decoder: Decoder) throws {
            columns = try decoder.singleValueContainer().decode([String: Params].self)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(columns)
        }
    }

    /// station_index.json / basin_index.json — site_id (or HUC8) to embedding index.
    /// Index 0 is reserved upstream for unseen keys; never appears as a value.
    struct IndexMap: Codable {
        let entries: [String: Int]

        init(from decoder: Decoder) throws {
            entries = try decoder.singleValueContainer().decode([String: Int].self)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(entries)
        }

        /// Returns the embedding index for the given key, or 0 if unseen.
        func index(for key: String) -> Int32 {
            Int32(entries[key] ?? 0)
        }
    }

    /// training_config.json — duplicates fields in Manifest.schema for legacy compat.
    struct TrainingConfig: Codable {
        let encoderDays: Int
        let decoderDays: Int
        let encoderFeatures: [String]
        let decoderFeatures: [String]
        let targetFeatures: [String]

        enum CodingKeys: String, CodingKey {
            case encoderDays = "encoder_days"
            case decoderDays = "decoder_days"
            case encoderFeatures = "encoder_features"
            case decoderFeatures = "decoder_features"
            case targetFeatures = "target_features"
        }
    }
}

/// One day of decoded forecast in cfs.
struct DailyForecast: Equatable {
    let date: Date
    let minFlowCFS: Double
    let maxFlowCFS: Double
}

/// Assembled raw input window. Values are unscaled — scaling happens inside ModelBundle
/// to keep the contract translation centralized.
struct FeatureWindow {
    let siteId: String
    let basinId: String
    /// schema.encoderDays rows × schema.encoderFeatures columns, raw values.
    let encoderRows: [[Double]]
    /// schema.decoderDays rows × schema.decoderFeatures columns, raw values.
    let decoderRows: [[Double]]
    /// One value per target feature, raw cfs. Used as the persistence baseline.
    let persistenceTargets: [Double]
}
