//
//  FlowGraphView.swift
//  OpenFlowMobile
//
//  Renders the 14-day forecast for a river. Phase 1 wires the contract-correct
//  ML stack (ModelManager + ModelBundle) but the runtime FeaturePipeline that
//  assembles live input data lands in Phase 2 — so the forecast is intentionally
//  unavailable until then. The previous version of this file fed the model
//  placeholder inputs ([1,2,3,4,5]) and rendered the resulting garbage as a
//  prediction; that has been removed.
//

import SwiftUI

struct FlowGraphView: View {
    let river: RiverData
    @EnvironmentObject var modelManager: ModelManager
    @State private var forecast: [DailyForecast] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let pipeline: FeaturePipeline = UnavailableFeaturePipeline()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forecast")
                .font(.headline)

            switch modelManager.state {
            case .ready:
                forecastContent
            case .downloading(let v):
                Text("Downloading model \(v)…").foregroundColor(.secondary)
            case .checkingForUpdate, .loadingFromCache, .idle:
                Text("Loading model…").foregroundColor(.secondary)
            case .notAvailable:
                Text("Forecast model not yet published upstream.")
                    .foregroundColor(.secondary)
            case .error(let m):
                Text(m).foregroundColor(.red)
            }
        }
        .padding(.vertical)
        .task(id: modelManager.bundle?.version) {
            await refreshForecast()
        }
    }

    @ViewBuilder
    private var forecastContent: some View {
        if isLoading {
            ProgressView()
        } else if let errorMessage = errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundColor(.secondary)
        } else if forecast.isEmpty {
            Text("No forecast available.")
                .foregroundColor(.secondary)
        } else {
            ForEach(forecast, id: \.date) { day in
                HStack {
                    Text(day.date, style: .date).font(.footnote)
                    Spacer()
                    Text("\(Int(day.minFlowCFS))–\(Int(day.maxFlowCFS)) cfs")
                        .font(.footnote.monospacedDigit())
                }
            }
        }
    }

    private func refreshForecast() async {
        guard let bundle = modelManager.bundle else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // basinId is unknown to the app today — the Phase-2 station registry
            // will resolve site -> HUC8. For now pass empty string, which the
            // model treats as the unseen-basin embedding (index 0).
            let window = try await pipeline.assembleWindow(
                siteId: river.siteNumber,
                basinId: "",
                schema: bundle.manifest.schema,
                referenceDate: Date())
            let start = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: 1, to: Date()) ?? Date()
            forecast = try bundle.forecast(window, forecastStart: start)
        } catch {
            errorMessage = error.localizedDescription
            forecast = []
        }
    }
}
