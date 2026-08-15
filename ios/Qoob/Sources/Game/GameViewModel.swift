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

/// How the on-screen movement controls are arranged. Presets, so the game is
/// playable one tap out of Settings; free placement is layered on top of these
/// later rather than replacing them.
enum ControlLayout: String, CaseIterable, Identifiable {
    case dpadCenter     // classic cross, centred along the bottom
    case dpadLeft       // classic cross, tucked to the left
    case dpadRight      // classic cross, tucked to the right
    case splitThumbs    // left/right under the left thumb, up/down under the right
    case corners        // four separate buttons spread into the bottom corners

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dpadCenter:  return "D-pad, centre"
        case .dpadLeft:    return "D-pad, left"
        case .dpadRight:   return "D-pad, right"
        case .splitThumbs: return "Split thumbs"
        case .corners:     return "Spread out"
        }
    }

    /// True for the layouts that draw a single joined cross.
    var isDPad: Bool {
        switch self {
        case .dpadCenter, .dpadLeft, .dpadRight: return true
        case .splitThumbs, .corners:             return false
        }
    }

    /// Horizontal alignment for the D-pad layouts.
    var alignment: HorizontalAlignment {
        switch self {
        case .dpadLeft:  return .leading
        case .dpadRight: return .trailing
        default:         return .center
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

    @Published var catStyle: CatStyle {
        didSet { UserDefaults.standard.set(catStyle.rawValue, forKey: Self.catStyleKey) }
    }
    private static let catStyleKey = "catStyle"

    @Published var roomAppearance: RoomAppearance {
        didSet { UserDefaults.standard.set(roomAppearance.rawValue, forKey: Self.roomAppearanceKey) }
    }
    private static let roomAppearanceKey = "roomAppearance"

    /// On-screen control arrangement (Settings). Persisted.
    @Published var controlLayout: ControlLayout {
        didSet { UserDefaults.standard.set(controlLayout.rawValue, forKey: Self.controlLayoutKey) }
    }
    private static let controlLayoutKey = "controlLayout"

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
        catStyle = defaults.string(forKey: Self.catStyleKey)
            .flatMap(CatStyle.init(rawValue:)) ?? .cream
        roomAppearance = defaults.string(forKey: Self.roomAppearanceKey)
            .flatMap(RoomAppearance.init(rawValue:)) ?? .system
        controlLayout = defaults.string(forKey: Self.controlLayoutKey)
            .flatMap(ControlLayout.init(rawValue:)) ?? .dpadCenter
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
