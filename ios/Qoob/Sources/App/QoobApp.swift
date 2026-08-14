//
//  QoobApp.swift
//  Qoob
//
//  App entry point (SwiftUI lifecycle).
//

import SwiftUI

@main
struct QoobApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .persistentSystemOverlays(.hidden)
        }
    }
}
