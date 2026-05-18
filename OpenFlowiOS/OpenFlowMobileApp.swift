//
//  OpenFlowMobileApp.swift
//  OpenFlowMobile
//
//  Created by Tyler Martin on 3/29/23.
//

import SwiftUI

@main
struct OpenFlowMobileApp: App {
    @StateObject private var modelManager = ModelManager()
    @StateObject private var riverDataModel = RiverDataModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                MLListView()
                    .environmentObject(riverDataModel)
                    .environmentObject(modelManager)
                    .tabItem {
                        Label("Forecast", systemImage: "waveform.path.ecg")
                    }
                RiverListView()
                    .environmentObject(riverDataModel)
                    .tabItem {
                        Label("Rivers", systemImage: "waveform.path.ecg")
                    }
                FavoriteView()
                    .environmentObject(riverDataModel)
                    .tabItem {
                        Label("Favorites", systemImage: "star.fill")
                    }
                ProfileView()
                    .tabItem {
                        Label("Profile", systemImage: "person.crop.circle")
                    }
            }
            .task {
                await modelManager.bootstrap()
            }
        }
    }
}
