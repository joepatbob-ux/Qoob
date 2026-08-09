//
//  GameViewModel.swift
//  Qoob
//
//  Observable bridge between the SceneKit game and the SwiftUI HUD.
//

import SwiftUI

enum GamePhase {
    case ready       // waiting to start / calibrate
    case playing     // endless — there is no win/lose phase
}

/// Where the on-screen D-pad sits along the bottom.
enum DPadSide: String, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .left:   return "Left"
        case .center: return "Center"
        case .right:  return "Right"
        }
    }
}

/// How far the board leans off straight-down. Top-down is the default.
enum BoardTilt: String, CaseIterable, Identifiable {
    case flat, slight, angled
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .flat:   return "Top-down"
        case .slight: return "Slight tilt"
        case .angled: return "Angled"
        }
    }
    /// Lean off vertical, in radians.
    var radians: Double {
        switch self {
        case .flat:   return 0
        case .slight: return 0.22
        case .angled: return 0.42
        }
    }
}

@MainActor
final class GameViewModel: ObservableObject {
    @Published var phase: GamePhase = .ready
    @Published var score: Int = 0
    // Score broken out by source (these sum to `score`); surfaced in the HUD's
    // tappable score bubble. Points plus the counts that read as "×N".
    @Published var scoreMatches: Int = 0     // base points for matched target tiles
    @Published var scoreStreak: Int = 0      // streak bonus on top of matches
    @Published var scoreToys: Int = 0        // toys pushed onto a goal (+150 each)
    @Published var scoreKnockoffs: Int = 0   // toys knocked off furniture (+100 each)
    @Published var toysPushed: Int = 0
    @Published var knockoffs: Int = 0
    @Published var showScoreBreakdown: Bool = false
    @Published var levelIndex: Int = 0
    @Published var environmentName: String = Environment.forLevel(0).displayName
    @Published var elapsed: TimeInterval = 0   // gentle count-up since level start
    @Published var tilesRemaining: Int = 0
    @Published var itemsRemaining: Int = 0    // toys not yet on a goal
    @Published var mantra: String = ""
    @Published var showMantra: Bool = false
    @Published var motionUnavailable: Bool = false

    // Control scheme. Both can be on at once; swipe gestures are always active.
    @Published var tiltEnabled: Bool = true
    @Published var showButtons: Bool = true

    // Feedback preferences (surfaced in Settings, honoured by the controller).
    @Published var soundEnabled: Bool = true
    @Published var hapticsEnabled: Bool = true

    /// Selected floor style (Settings). Persisted so it survives launches.
    @Published var floorTheme: FloorTheme {
        didSet { UserDefaults.standard.set(floorTheme.rawValue, forKey: Self.floorThemeKey) }
    }
    private static let floorThemeKey = "floorTheme"

    /// On-screen D-pad position (Settings). Persisted.
    @Published var dpadSide: DPadSide {
        didSet { UserDefaults.standard.set(dpadSide.rawValue, forKey: Self.dpadSideKey) }
    }
    private static let dpadSideKey = "dpadSide"

    /// Board camera lean (Settings). Persisted. Default top-down.
    @Published var boardTilt: BoardTilt {
        didSet { UserDefaults.standard.set(boardTilt.rawValue, forKey: Self.boardTiltKey) }
    }
    private static let boardTiltKey = "boardTilt"

    /// Whether the Settings sheet is presented.
    @Published var showSettings: Bool = false

    /// Set by ContentView so the HUD buttons can drive the game.
    weak var controller: GameController?

    init() {
        let defaults = UserDefaults.standard
        floorTheme = defaults.string(forKey: Self.floorThemeKey)
            .flatMap(FloorTheme.init(rawValue:)) ?? .default
        dpadSide = defaults.string(forKey: Self.dpadSideKey)
            .flatMap(DPadSide.init(rawValue:)) ?? .center
        boardTilt = defaults.string(forKey: Self.boardTiltKey)
            .flatMap(BoardTilt.init(rawValue:)) ?? .flat
    }

    func startTapped() {
        controller?.startGame(atLevel: levelIndex)
    }

    /// Manual control entry point (D-pad buttons and swipes).
    func roll(_ direction: RollDirection) {
        controller?.requestRoll(direction)
    }

    func flash(mantra text: String) {
        mantra = text
        withAnimation(.easeInOut(duration: 0.4)) { showMantra = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            withAnimation(.easeInOut(duration: 0.6)) { self?.showMantra = false }
        }
    }
}
