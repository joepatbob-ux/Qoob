//
//  QoobApp.swift
//  Qoob
//
//  App entry point (SwiftUI lifecycle). One scene, four destinations: iPhone,
//  iPad, Mac (via Catalyst) and Apple TV.
//

import SwiftUI

@main
struct QoobApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .persistentSystemOverlays(.hidden)
                #if targetEnvironment(macCatalyst)
                .onAppear { Self.constrainMacWindow() }
                #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Stops the Mac window being dragged down to a sliver.
    ///
    /// The board is re-framed to whatever shape the window is (see the renderer's
    /// `viewportDidChange`), so it survives any size — but much below this the HUD
    /// and the controls have nowhere to go. Catalyst has no SwiftUI equivalent of
    /// `windowResizability`, so this reaches the window scene directly.
    private static func constrainMacWindow() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 600)
        }
    }
    #endif
}
