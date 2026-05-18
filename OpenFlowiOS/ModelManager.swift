//
//  ModelManager.swift
//  OpenFlowMobile
//
//  Owns the lifecycle of the active ModelBundle: load cached or bundled fallback
//  at startup, then check GitHub releases for a newer model-YYYY.MM.DD and swap
//  in when one is found.
//

import Foundation
import CryptoKit
import SwiftUI
import Zip

@MainActor
final class ModelManager: ObservableObject {
    enum State: Equatable {
        case idle
        case loadingFromCache
        case checkingForUpdate(currentVersion: String?)
        case downloading(version: String)
        case ready(version: String)
        case notAvailable
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var bundle: ModelBundle?

    private let releasesURL = URL(string: "https://api.github.com/repos/tmart234/OpenFlow/releases")!
    private let modelTagPrefix = "model-"
    private let modelsDirectory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.modelsDirectory = docs.appendingPathComponent("openflow-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    /// Call from .task { } at app launch. Loads what's available locally first
    /// so the UI is never blocked on the network, then checks for updates.
    func bootstrap() async {
        state = .loadingFromCache
        if let cached = loadCached() {
            bundle = cached
            state = .ready(version: cached.version)
        } else if let bundled = loadBundledFallback() {
            bundle = bundled
            state = .ready(version: bundled.version)
        } else {
            state = .notAvailable
        }
        await checkForUpdate()
    }

    func checkForUpdate() async {
        let resumeState = state
        state = .checkingForUpdate(currentVersion: bundle?.version)
        do {
            let releases = try await fetchModelReleases()
            guard let latest = releases.first else {
                state = (bundle == nil) ? .notAvailable : resumeState
                return
            }
            if bundle?.version == latest.tagName {
                state = resumeState
                return
            }
            try await downloadAndInstall(latest)
            if let updated = loadCached() {
                bundle = updated
                state = .ready(version: updated.version)
            } else {
                state = .error("Downloaded \(latest.tagName) but could not load it")
            }
        } catch {
            if bundle != nil {
                state = resumeState
            } else {
                state = .error("Update check failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Local sources

    private func loadCached() -> ModelBundle? {
        guard let dir = currentCacheDir() else { return nil }
        return try? ModelBundle(directory: dir)
    }

    private func loadBundledFallback() -> ModelBundle? {
        // Looks for OpenFlowModel.bundle in app resources. Phase 1 ships nothing
        // here — populated when the first model-YYYY.MM.DD release is snapshotted
        // into the binary.
        guard let url = Bundle.main.url(forResource: "OpenFlowModel", withExtension: "bundle") else {
            return nil
        }
        return try? ModelBundle(directory: url)
    }

    private func currentCacheDir() -> URL? {
        let pointer = modelsDirectory.appendingPathComponent("current.txt")
        guard let version = try? String(contentsOf: pointer, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return nil }
        let dir = modelsDirectory.appendingPathComponent(version, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    // MARK: - Remote sources

    private func fetchModelReleases() async throws -> [GHRelease] {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let all = try dec.decode([GHRelease].self, from: data)
        return all
            .filter { $0.tagName.hasPrefix(modelTagPrefix) && !$0.draft && !$0.prerelease }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func downloadAndInstall(_ release: GHRelease) async throws {
        state = .downloading(version: release.tagName)
        let targetDir = modelsDirectory.appendingPathComponent(release.tagName, isDirectory: true)
        if FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.removeItem(at: targetDir)
        }
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        guard let manifestAsset = release.assets.first(where: { $0.name == "manifest.json" }) else {
            throw ModelManagerError.missingAsset("manifest.json")
        }
        let manifestData = try await downloadData(from: manifestAsset.browserDownloadUrl)
        try manifestData.write(to: targetDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(MLContract.Manifest.self, from: manifestData)

        let assetsByName = Dictionary(uniqueKeysWithValues: release.assets.map { ($0.name, $0) })
        for file in manifest.files where file.name != "manifest.json" {
            guard let asset = assetsByName[file.name] else {
                throw ModelManagerError.missingAsset(file.name)
            }
            let data = try await downloadData(from: asset.browserDownloadUrl)
            try verifySha256(data, expected: file.sha256, name: file.name)
            try data.write(to: targetDir.appendingPathComponent(file.name))
        }

        let zipPath = targetDir.appendingPathComponent("lstm_model.mlpackage.zip")
        if FileManager.default.fileExists(atPath: zipPath.path) {
            try Zip.unzipFile(zipPath, destination: targetDir, overwrite: true, password: nil)
        }

        let pointer = modelsDirectory.appendingPathComponent("current.txt")
        try release.tagName.write(to: pointer, atomically: true, encoding: .utf8)
    }

    private func downloadData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModelManagerError.httpError(status: http.statusCode, url: url)
        }
        return data
    }

    private func verifySha256(_ data: Data, expected: String, name: String) throws {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual.lowercased() == expected.lowercased() else {
            throw ModelManagerError.checksumMismatch(name: name, expected: expected, actual: actual)
        }
    }
}

enum ModelManagerError: LocalizedError {
    case missingAsset(String)
    case checksumMismatch(name: String, expected: String, actual: String)
    case httpError(status: Int, url: URL)

    var errorDescription: String? {
        switch self {
        case .missingAsset(let n):
            return "Release is missing asset: \(n)"
        case .checksumMismatch(let n, let e, let a):
            return "SHA256 mismatch on \(n) (expected \(e.prefix(12))…, got \(a.prefix(12))…)"
        case .httpError(let s, let u):
            return "HTTP \(s) for \(u.lastPathComponent)"
        }
    }
}

private struct GHRelease: Decodable {
    let tagName: String
    let createdAt: Date
    let draft: Bool
    let prerelease: Bool
    let assets: [GHAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case createdAt = "created_at"
        case draft, prerelease, assets
    }
}

private struct GHAsset: Decodable {
    let name: String
    let browserDownloadUrl: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}
