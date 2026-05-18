import SwiftUI
import Combine

struct MLListView: View {
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var riverDataModel: RiverDataModel
    @State private var searchTerm: String = ""
    @State private var stationIDs: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            modelStatusBanner

            NavigationView {
                VStack {
                    TextField("Search by station name...", text: $searchTerm)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                        .padding(.horizontal)

                    List(filteredRivers.indices, id: \.self) { index in
                        let splitName = Utility.splitStationName(filteredRivers[index].stationName)
                        NavigationLink(destination: RiverDetailView(river: filteredRivers[index], isMLRiver: true)
                            .environmentObject(modelManager)) {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(splitName.0).font(.headline)
                                        Text(splitName.1).font(.subheadline)
                                        if !splitName.2.isEmpty {
                                            Text(splitName.2).font(.subheadline)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                    }
                }
                .navigationBarTitle("ML Rivers")
                .onAppear {
                    riverDataModel.fetchMLStationIDs { fetchedIDs in
                        self.stationIDs = fetchedIDs
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelStatusBanner: some View {
        switch modelManager.state {
        case .idle, .loadingFromCache:
            statusRow(icon: "hourglass", text: "Loading model…", color: .secondary)
        case .checkingForUpdate:
            EmptyView()
        case .downloading(let version):
            statusRow(icon: "arrow.down.circle", text: "Downloading \(version)…", color: .blue)
        case .ready(let version):
            statusRow(icon: "checkmark.seal", text: "Model \(version) ready", color: .green)
        case .notAvailable:
            statusRow(icon: "exclamationmark.triangle",
                      text: "No forecast model available yet.",
                      color: .orange)
        case .error(let message):
            statusRow(icon: "xmark.octagon", text: message, color: .red)
        }
    }

    private func statusRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(.footnote).foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
    }

    var filteredRivers: [RiverData] {
        riverDataModel.rivers.filter { river in
            stationIDs.contains(river.siteNumber) &&
            (searchTerm.isEmpty || river.stationName.lowercased().contains(searchTerm.lowercased()))
        }
    }
}
