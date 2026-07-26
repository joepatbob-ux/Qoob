//
//  GameViewModel.swift
//  TiltCube
//
//  Observable bridge between the SceneKit game and the SwiftUI HUD.
//

import SwiftUI

enum GamePhase {
    case ready       // waiting to start / calibrate
    case playing
    case won
    case lost
}

@MainActor
final class GameViewModel: ObservableObject {
    @Published var phase: GamePhase = .ready
    @Published var score: Int = 0
    @Published var levelIndex: Int = 0
    @Published var timeRemaining: TimeInterval = 0
    @Published var tilesRemaining: Int = 0
    @Published var mantra: String = ""
    @Published var showMantra: Bool = false
    @Published var motionUnavailable: Bool = false

    /// Set by ContentView so the HUD buttons can drive the game.
    weak var controller: GameController?

    func startTapped() {
        controller?.startGame(atLevel: phase == .won ? levelIndex + 1 : levelIndex)
    }

    func flash(mantra text: String) {
        mantra = text
        withAnimation(.easeInOut(duration: 0.4)) { showMantra = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            withAnimation(.easeInOut(duration: 0.6)) { self?.showMantra = false }
        }
    }
}
