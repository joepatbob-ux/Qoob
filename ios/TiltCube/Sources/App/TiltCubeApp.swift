//
//  TiltCubeApp.swift
//  TiltCube
//
//  App entry point (SwiftUI lifecycle).
//

import SwiftUI

@main
struct TiltCubeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
    }
}
