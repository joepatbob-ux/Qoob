//
//  GameViewModel.swift
//  Qoob
//
//  Observable bridge between the SceneKit game and the SwiftUI HUD.
//

import SwiftUI

enum GamePhase {
    case ready       // only while the splash covers the first house being built
    case playing     // endless — there is no win/lose phase
}

/// How the on-screen movement controls are arranged. Presets, so the game is
/// playable one tap out of Settings, plus `custom` — where the player drags each
/// control wherever they like (see `ControlKnob`).
enum ControlLayout: String, CaseIterable, Identifiable {
    case dpadCenter     // classic cross, centred along the bottom
    case dpadLeft       // classic cross, tucked to the left
    case dpadRight      // classic cross, tucked to the right
    case splitThumbs    // left/right under the left thumb, up/down under the right
    case corners        // four separate buttons spread into the bottom corners
    case custom         // wherever the player put them

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dpadCenter:  return "Centre"
        case .dpadLeft:    return "Left"
        case .dpadRight:   return "Right"
        case .splitThumbs: return "Split thumbs"
        case .corners:     return "Spread out"
        case .custom:      return "Wherever I put them"
        }
    }

    /// True for the layouts that draw a single pad, centred or tucked to a side.
    var isDPad: Bool {
        switch self {
        case .dpadCenter, .dpadLeft, .dpadRight:  return true
        case .splitThumbs, .corners, .custom:     return false
        }
    }

    /// Horizontal alignment for the single-pad layouts.
    var alignment: HorizontalAlignment {
        switch self {
        case .dpadLeft:  return .leading
        case .dpadRight: return .trailing
        default:         return .center
        }
    }
}

/// What shape the on-screen controls take.
enum ControlStyle: String, CaseIterable, Identifiable {
    case wheel      // one circle; the direction comes from where in it you touch
    case arrows     // four separate arrow buttons

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wheel:  return "Circle pad"
        case .arrows: return "Arrows"
        }
    }
}

/// A control the player can pick up and place. The four arrows are separate
/// knobs, so they can be scattered individually rather than only as a block.
enum ControlKnob: String, CaseIterable, Identifiable {
    case pad, up, down, left, right

    var id: String { rawValue }

    /// The roll this knob asks for; nil for the circle pad, which works out its
    /// own direction from the touch point.
    var direction: RollDirection? {
        switch self {
        case .pad:   return nil
        case .up:    return .forward
        case .down:  return .back
        case .left:  return .left
        case .right: return .right
        }
    }

    var displayName: String {
        switch self {
        case .pad:   return "Circle pad"
        case .up:    return "Up"
        case .down:  return "Down"
        case .left:  return "Left"
        case .right: return "Right"
        }
    }

    /// Where the knob sits before it's moved, as a fraction of the play area, so
    /// a placement holds up across devices and orientations.
    var defaultPosition: CGPoint {
        switch self {
        case .pad:   return CGPoint(x: 0.50, y: 0.83)
        case .up:    return CGPoint(x: 0.50, y: 0.74)
        case .down:  return CGPoint(x: 0.50, y: 0.90)
        case .left:  return CGPoint(x: 0.33, y: 0.82)
        case .right: return CGPoint(x: 0.67, y: 0.82)
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
    @Published var environmentName: String = ""
    @Published var elapsed: TimeInterval = 0   // gentle count-up since the room began
    @Published var tilesRemaining: Int = 0
    @Published var itemsRemaining: Int = 0    // toys still loose on the floor
    /// True for the brief cover raised while the litterbox swaps in the next house.
    /// `present` isn't free even warm, and unlike the launch splash nothing else
    /// hides that — see `GameController.enterNewHouse`.
    @Published var isEnteringHouse: Bool = false

    /// How many toys this house started with.
    ///
    /// Derived rather than stored: every toy is either still loose or has been returned,
    /// and `toysPushed` only counts the returned ones (it increments on `collected`). So
    /// the two always sum to the house's total, with no third state to keep in step.
    var toysTotal: Int { itemsRemaining + toysPushed }
    @Published var mantra: String = ""
    @Published var showMantra: Bool = false

    /// Whether the on-screen pad is shown. Swipes are always active, and a connected
    /// controller or keyboard always works (see `ControllerInput`).
    ///
    /// An Apple TV has no touch screen, so it starts off there and Settings doesn't
    /// offer it — the remote or a game controller is how you play.
    #if os(tvOS)
    @Published var showButtons: Bool = false
    #else
    @Published var showButtons: Bool = true
    #endif

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

    /// Whether rooms borrow the real local sky — real weather outdoors, real
    /// sunrise/sunset light indoors (Settings). Persisted, and off by default:
    /// it asks for location, and nothing that prompts should default to on.
    ///
    /// `.object(forKey:) as? Bool`, not `.bool(forKey:)` — the latter can't tell
    /// "never set" from "set to false", which matters the day this default
    /// changes. No other `Bool` in this file is persisted yet (`soundEnabled`/
    /// `hapticsEnabled` are in-memory only), so this is the first of its kind.
    @Published var weatherMatching: Bool {
        didSet { UserDefaults.standard.set(weatherMatching, forKey: Self.weatherMatchingKey) }
    }
    private static let weatherMatchingKey = "weatherMatching"

    /// Set by `GameController` from `LocalWeatherProvider`, so the Settings
    /// footnote can explain itself when there's nothing to show. A live fact,
    /// not a preference — not persisted.
    @Published var weatherStatus: WeatherStatus = .off

    /// On-screen control arrangement (Settings). Persisted.
    @Published var controlLayout: ControlLayout {
        didSet { UserDefaults.standard.set(controlLayout.rawValue, forKey: Self.controlLayoutKey) }
    }
    private static let controlLayoutKey = "controlLayout"

    /// Circle pad or separate arrows (Settings). Persisted.
    @Published var controlStyle: ControlStyle {
        didSet { UserDefaults.standard.set(controlStyle.rawValue, forKey: Self.controlStyleKey) }
    }
    private static let controlStyleKey = "controlStyle"

    /// Where each control sits under `.custom` layout, as a fraction of the play
    /// area. Persisted. Missing entries fall back to the knob's default spot.
    @Published private var knobPositions: [String: CGPoint] {
        didSet { Self.save(knobPositions) }
    }
    private static let knobPositionsKey = "controlKnobPositions"

    /// True while the player is dragging controls into place. Not persisted —
    /// arranging is a moment, not a mode you come back to.
    @Published var arrangingControls: Bool = false

    /// The controls on screen: one pad, or the four arrows.
    var activeKnobs: [ControlKnob] {
        controlStyle == .wheel ? [.pad] : [.up, .down, .left, .right]
    }

    func position(of knob: ControlKnob) -> CGPoint {
        knobPositions[knob.rawValue] ?? knob.defaultPosition
    }

    /// Records a placement, kept far enough inside the edges that the control
    /// can always be grabbed again.
    func setPosition(_ point: CGPoint, for knob: ControlKnob) {
        knobPositions[knob.rawValue] = CGPoint(x: min(max(point.x, 0.06), 0.94),
                                               y: min(max(point.y, 0.06), 0.96))
    }

    func resetControlPositions() {
        knobPositions = [:]
    }

    /// Hands custom placement to the player: switch to the custom layout and
    /// start arranging.
    func beginArrangingControls() {
        showButtons = true
        controlLayout = .custom
        arrangingControls = true
    }

    // Stored as flat [x, y] pairs — CGPoint isn't a plist type, and a dictionary
    // of arrays keeps the defaults file readable.
    private static func save(_ positions: [String: CGPoint]) {
        let flat = positions.mapValues { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(flat, forKey: knobPositionsKey)
    }

    private static func loadPositions() -> [String: CGPoint] {
        let stored = UserDefaults.standard.dictionary(forKey: knobPositionsKey) ?? [:]
        return stored.compactMapValues { value in
            guard let pair = value as? [Double], pair.count == 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
    }

    /// Board camera lean (Settings). Persisted. Default top-down.
    @Published var boardTilt: BoardTilt {
        didSet { UserDefaults.standard.set(boardTilt.rawValue, forKey: Self.boardTiltKey) }
    }
    private static let boardTiltKey = "boardTilt"

    /// Whether the Settings sheet is presented.
    @Published var showSettings: Bool = false

    /// Whether the level builder is presented. Opened from Settings, which dismisses
    /// itself first — two sheets from one host can't both be up.
    @Published var showBuilder: Bool = false

    /// Set by ContentView so the HUD buttons can drive the game.
    weak var controller: GameController?

    init() {
        let defaults = UserDefaults.standard
        // Pinned to `.default` — "this room's own floor". A previously-saved choice is
        // ignored on purpose, so anyone who had picked Grass doesn't keep a lawn in
        // their living room now the picker is gone.
        floorTheme = .default
        catStyle = defaults.string(forKey: Self.catStyleKey)
            .flatMap(CatStyle.init(rawValue:)) ?? .cream
        roomAppearance = defaults.string(forKey: Self.roomAppearanceKey)
            .flatMap(RoomAppearance.init(rawValue:)) ?? .system
        controlLayout = defaults.string(forKey: Self.controlLayoutKey)
            .flatMap(ControlLayout.init(rawValue:)) ?? .dpadCenter
        controlStyle = defaults.string(forKey: Self.controlStyleKey)
            .flatMap(ControlStyle.init(rawValue:)) ?? .wheel
        knobPositions = Self.loadPositions()
        boardTilt = defaults.string(forKey: Self.boardTiltKey)
            .flatMap(BoardTilt.init(rawValue:)) ?? .flat
        weatherMatching = defaults.object(forKey: Self.weatherMatchingKey) as? Bool ?? false
    }

    func startTapped() {
        controller?.startGame()
    }

    /// One roll, for the gestures that are genuinely one-shot — a swipe.
    func roll(_ direction: RollDirection) {
        controller?.requestRoll(direction)
    }

    /// Which way the on-screen controls are being held, or nil when nothing is.
    ///
    /// Deliberately not `@Published`: only the frame loop reads it, and publishing it
    /// would invalidate the whole HUD on every press and release.
    private(set) var heldDirection: RollDirection?

    /// Reports a held control. Passing nil releases.
    ///
    /// This doesn't roll anything itself — the frame loop polls `heldDirection` the
    /// same way it polls the tilt and the game controller, so all three share one
    /// cadence and one set of pacing rules.
    ///
    /// The circle pad used to keep its own 160ms repeat timer instead, which is a
    /// second mechanism guessing at a cadence the controller already owns. It guessed
    /// wrong: a roll takes 0.16s plus a 0.05s rest, so every other 160ms repeat arrived
    /// too early, was refused, and left the next one to land at 320ms. Held rolling ran
    /// at half the speed it could, unevenly. The arrow buttons had no repeat at all.
    func hold(_ direction: RollDirection?) {
        heldDirection = direction
    }

    /// Drops any held control. Called when play stops, so a finger still down when
    /// Settings opens doesn't leave Qoob rolling behind the sheet.
    func releaseControls() {
        heldDirection = nil
    }

    func flash(mantra text: String) {
        mantra = text
        withAnimation(.easeInOut(duration: 0.4)) { showMantra = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            withAnimation(.easeInOut(duration: 0.6)) { self?.showMantra = false }
        }
    }
}
