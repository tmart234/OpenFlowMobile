//
//  MLContractScalingTests.swift
//  OpenFlowiOSTests
//
//  Swift mirror of OpenFlowAndroid/.../MLContractTest.kt - validates manifest
//  parsing + the scale/invert roundtrip against the spec in
//  https://github.com/tmart234/OpenFlow/blob/dev/docs/INFERENCE.md
//

import XCTest
@testable import OpenFlowMobile

final class MLContractScalingTests: XCTestCase {

    func testManifestParsesWithAllContractFields() throws {
        let raw = #"""
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
            {"name": "lstm_model.mlpackage.zip", "sha256": "abc123", "bytes": 524288}
          ]
        }
        """#.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(MLContract.Manifest.self, from: raw)

        XCTAssertEqual(manifest.modelVersion, "model-2026.05.18")
        XCTAssertEqual(manifest.tfliteMode, "builtins")
        XCTAssertEqual(manifest.schema.encoderDays, 60)
        XCTAssertEqual(manifest.schema.decoderDays, 14)
        XCTAssertEqual(manifest.schema.targetFeatures, ["Min Flow", "Max Flow"])
        XCTAssertEqual(manifest.schema.numStations, 100)
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertEqual(manifest.files[0].bytes, 524288)
    }

    func testManifestToleratesAbsentCoremltoolsVersion() throws {
        let raw = #"""
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
        """#.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(MLContract.Manifest.self, from: raw)
        XCTAssertNil(manifest.coremltoolsVersion)
    }

    func testScalersParseAsColumnMap() throws {
        let raw = #"""
        {
          "Min Flow":  {"mean": 4.5,  "scale": 1.2, "transform": "log1p"},
          "Max Flow":  {"mean": 5.0,  "scale": 1.3, "transform": "log1p"},
          "TMIN":      {"mean": 32.0, "scale": 8.0, "transform": "identity"}
        }
        """#.data(using: .utf8)!
        let scalers = try JSONDecoder().decode(MLContract.Scalers.self, from: raw)
        XCTAssertEqual(scalers.columns.count, 3)
        XCTAssertEqual(scalers.columns["Min Flow"]?.transform, .log1p)
        XCTAssertEqual(scalers.columns["TMIN"]?.mean, 32.0, accuracy: 1e-9)
    }

    func testIndexForReturnsZeroForUnseenKeys() throws {
        let raw = #"{"USGS:09163500": 1, "DWR:ARKCANCO": 2}"#.data(using: .utf8)!
        let map = try JSONDecoder().decode(MLContract.IndexMap.self, from: raw)
        XCTAssertEqual(map.index(for: "USGS:09163500"), 1)
        XCTAssertEqual(map.index(for: "DWR:ARKCANCO"), 2)
        XCTAssertEqual(map.index(for: "USGS:99999999"), 0)
        XCTAssertEqual(map.index(for: ""), 0)
    }

    func testScaleInvertRoundtripLog1p() {
        let p = MLContract.Scalers.Params(mean: 4.5, scale: 1.2, transform: .log1p)
        for raw in [0.0, 1.0, 100.0, 5000.0, 12345.6] {
            let z = scale(raw, p)
            let recovered = invert(z, p)
            XCTAssertEqual(recovered, raw, accuracy: 1e-6,
                           "log1p roundtrip failed for \(raw)")
        }
    }

    func testScaleInvertRoundtripIdentity() {
        let p = MLContract.Scalers.Params(mean: 32.0, scale: 8.0, transform: .identity)
        for raw in [-40.0, 0.0, 50.0, 110.0] {
            let z = scale(raw, p)
            let recovered = invert(z, p)
            XCTAssertEqual(recovered, raw, accuracy: 1e-9)
        }
    }

    // Free-standing copies of the contract arithmetic - tests verify the spec,
    // not whatever ModelBundle does internally.
    private func scale(_ raw: Double, _ p: MLContract.Scalers.Params) -> Double {
        let x = p.transform == .log1p ? log1p(raw) : raw
        return (x - p.mean) / p.scale
    }
    private func invert(_ z: Double, _ p: MLContract.Scalers.Params) -> Double {
        let x = z * p.scale + p.mean
        return p.transform == .log1p ? expm1(x) : x
    }
}
