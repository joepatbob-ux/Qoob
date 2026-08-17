//
//  GameControls.swift
//  Qoob
//
//  The on-screen movement controls, and the Liquid Glass chrome the HUD shares
//  with them.
//
//  Two shapes, chosen in Settings:
//    • Circle pad — one small disc. The direction comes from *where in the disc*
//      the finger is: touch (or slide to) the right of it and Qoob rolls right.
//    • Arrows — four separate buttons, which can be scattered individually when
//      custom placement is on.
//
//  Both hold: neither reports a *roll*, they report the direction currently being
//  held, and `GameController.tick` repeats it at the game's own cadence — the same
//  channel a held tilt and a held gamepad d-pad already used. That's why neither has
//  a repeat timer of its own, and why the glass sits on a shape inside a container
//  with the gesture on the container: an `interactive` glass effect installs its own
//  press handling and takes the touches off anything layered on top of it.
//

import SwiftUI

extension View {
    /// Tinted Liquid Glass on iOS 26+, falling back to a frosted material on
    /// older systems. Pass `nil` for a plain (untinted) glass, and set
    /// `interactive` on controls so the glass reacts to touch.
    @ViewBuilder
    func tintedGlass(_ tint: Color?, in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            let glass: Glass = {
                let base = tint.map { Glass.regular.tint($0) } ?? .regular
                return interactive ? base.interactive() : base
            }()
            glassEffect(glass, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

}

/// Control sizes, per class of screen. Deliberately compact on a phone: the board
/// fills the screen, and the old 56pt buttons on a 176pt-wide cross covered a good
/// part of it. An iPad has room to spare, and at phone sizes the pad reads as a
/// speck on a 13-inch screen.
struct ControlMetrics: Equatable {
    /// One arrow button, as drawn.
    let arrow: CGFloat
    /// Diameter of the circle pad.
    let wheel: CGFloat
    /// Extra touchable margin around an arrow, beyond what's drawn.
    ///
    /// The visual stays small on purpose — the board fills the screen and the old 56pt
    /// buttons covered a good part of it — but 44pt is Apple's *minimum* for a target,
    /// not a comfortable size for a control you hold over and over. Worse, the arrow's
    /// `contentShape` is a circle inscribed in that square, so the corners weren't
    /// tappable at all and the real area was about 79% of what it looked like.
    ///
    /// Slop separates the two: the arrow is drawn at `arrow` and answers touches within
    /// `arrow + 2 * hitSlop`.
    let hitSlop: CGFloat

    static let compact = ControlMetrics(arrow: 44, wheel: 116, hitSlop: 10)
    static let regular = ControlMetrics(arrow: 60, wheel: 164, hitSlop: 8)
}

private struct ControlMetricsKey: EnvironmentKey {
    static let defaultValue = ControlMetrics.compact
}

extension EnvironmentValues {
    /// The control sizes for this screen. `ContentView` sets it from the
    /// horizontal size class; the controls read it rather than being handed sizes
    /// through every layout.
    var controlMetrics: ControlMetrics {
        get { self[ControlMetricsKey.self] }
        set { self[ControlMetricsKey.self] = newValue }
    }
}

// The controls below are driven by touch, which tvOS doesn't have — it has no
// `DragGesture` at all. There they aren't built: an Apple TV plays with the remote
// or a game controller (see ControllerInput).
#if !os(tvOS)

/// A circular direction pad. There are no separate buttons inside it: the touch
/// point's angle from the centre picks one of the four rolls, so a thumb can
/// slide from one direction to the next without lifting.
struct DirectionWheel: View {
    /// False while the pad is being dragged into place, so the parent's drag
    /// gesture gets the touches instead of this one.
    var isActive: Bool = true
    /// Reports which way the pad is held, or nil on release. The frame loop turns that
    /// into a continuous roll at the game's own cadence — see `GameViewModel.hold`.
    let onHold: (RollDirection?) -> Void

    /// The direction currently under the finger, for the touch highlight.
    @State private var held: RollDirection?

    // Fully qualified: the game core has its own `Environment` enum, which would
    // otherwise shadow SwiftUI's property wrapper.
    @SwiftUI.Environment(\.controlMetrics) private var metrics

    /// Middle of the pad — a still thumb resting here doesn't roll anything.
    private let deadZone: CGFloat = 0.26

    private var diameter: CGFloat { metrics.wheel }

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .tintedGlass(nil, in: Circle(), interactive: true)

            // The quadrant under the finger, lit.
            if let held {
                DirectionQuadrant(direction: held)
            }

            // `deadZone` is a fraction of the *radius*, so the ring showing it is
            // `diameter * deadZone` across. It used to be drawn at twice that, which
            // told the player a much larger area was dead than actually was.
            Circle()
                .strokeBorder(.primary.opacity(0.16), lineWidth: 1)
                .frame(width: diameter * deadZone, height: diameter * deadZone)

            ForEach(Array(RollDirection.allCases.enumerated()), id: \.offset) { _, direction in
                Image(systemName: arrowIcon(direction))
                    .font(.system(size: diameter * 0.12, weight: .bold))
                    .foregroundStyle(held == direction ? .primary : .secondary)
                    .offset(padChevronOffset(direction, diameter: diameter))
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(isActive ? rollGesture : nil)
        .onDisappear { stop() }
    }

    private var rollGesture: some Gesture {
        // minimumDistance 0, so the pad answers the first touch rather than
        // waiting for a slide.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if let direction = direction(at: value.location) {
                    begin(direction)
                } else {
                    stop()
                }
            }
            .onEnded { _ in stop() }
    }

    /// Which roll a touch at `point` (in the pad's own coordinates) asks for, or
    /// nil inside the dead centre.
    /// How much more dominant the other axis has to be before the held direction gives
    /// way. Straight quadrant classification (`abs(dx) > abs(dy)`) is exactly ambiguous
    /// on the diagonal, so a thumb resting near 45° flipped between two directions on
    /// sub-pixel movement and Qoob stuttered between them. 1.35 means a deliberate move
    /// past the diagonal changes direction and a resting thumb doesn't.
    private let switchMargin: CGFloat = 1.35

    private func direction(at point: CGPoint) -> RollDirection? {
        let radius = diameter / 2
        let dx = point.x - radius
        let dy = point.y - radius
        guard sqrt(dx * dx + dy * dy) > radius * deadZone else { return nil }
        // Keep what's already held unless the touch has moved clearly out of it.
        if let held, stillHolds(held, dx: dx, dy: dy) { return held }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy < 0 ? .forward : .back        // screen up = up the board
    }

    /// Whether `direction` still has the dominant component, allowing `switchMargin`.
    private func stillHolds(_ direction: RollDirection, dx: CGFloat, dy: CGFloat) -> Bool {
        switch direction {
        case .right:   return dx > 0 && abs(dx) * switchMargin > abs(dy)
        case .left:    return dx < 0 && abs(dx) * switchMargin > abs(dy)
        case .back:    return dy > 0 && abs(dy) * switchMargin > abs(dx)
        case .forward: return dy < 0 && abs(dy) * switchMargin > abs(dx)
        }
    }

    private func begin(_ direction: RollDirection) {
        guard held != direction else { return }   // already rolling this way
        held = direction
        onHold(direction)
    }

    private func stop() {
        guard held != nil else { return }
        held = nil
        onHold(nil)
    }

}

/// The chevron a roll is drawn with, shared by the pad and the arrow buttons.
func arrowIcon(_ d: RollDirection) -> String {
    switch d {
    case .forward: return "chevron.up"
    case .back:    return "chevron.down"
    case .left:    return "chevron.left"
    case .right:   return "chevron.right"
    }
}

/// Where that chevron sits on the rim of a pad of this size.
func padChevronOffset(_ d: RollDirection, diameter: CGFloat) -> CGSize {
    let r = diameter * 0.34
    switch d {
    case .forward: return CGSize(width: 0, height: -r)
    case .back:    return CGSize(width: 0, height: r)
    case .left:    return CGSize(width: -r, height: 0)
    case .right:   return CGSize(width: r, height: 0)
    }
}

/// The lit arc over one side of the pad.
private struct DirectionQuadrant: View {
    let direction: RollDirection

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(.primary.opacity(0.55), lineWidth: 5)
            .rotationEffect(rotation)
            .padding(6)
    }

    /// A `Circle` path starts at 3 o'clock and runs clockwise, so the trimmed
    /// quarter already covers the down-right side — its *centre* line sits at 45°,
    /// and each angle below is measured from there. Measuring from the arc's start
    /// instead lit the side one step clockwise of the one being pressed.
    private var rotation: Angle {
        switch direction {
        case .right:   return .degrees(-45)     // centre at 3 o'clock
        case .back:    return .degrees(45)      // 6 o'clock
        case .left:    return .degrees(135)     // 9 o'clock
        case .forward: return .degrees(-135)    // 12 o'clock
        }
    }
}

/// One arrow. Used for the cross layouts and, in custom placement, on its own.
///
/// Not a `Button`. A button only fires on release, so holding an arrow did nothing at
/// all — you had to tap once per cell while the circle pad kept rolling. A press-and-hold
/// gesture is the only way to report *held*, which is what a continuous roll needs.
/// `interactive` glass keeps the press response the system button style was giving.
struct ArrowButton: View {
    let direction: RollDirection
    /// False while the button is being dragged into place.
    var isActive: Bool = true
    /// Reports the direction while held, nil on release.
    let onHold: (RollDirection?) -> Void

    @State private var isPressed = false

    @SwiftUI.Environment(\.controlMetrics) private var metrics

    /// Laid out the same way as `DirectionWheel`: the glass goes on a shape *inside* a
    /// container and the gesture goes on the container.
    ///
    /// Not a stylistic choice. Attaching the gesture on top of an `interactive` glass
    /// effect got no touches at all — interactive glass installs its own press handling
    /// and wins. The arrow held silently did nothing, which is the bug this was meant
    /// to fix.
    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .tintedGlass(nil, in: Circle(), interactive: isActive)
            face
        }
        .frame(width: metrics.arrow, height: metrics.arrow)
        // A press of its own, so the arrow reads as pressed while it's rolling.
        .scaleEffect(isPressed ? 0.92 : 1)
        .animation(.easeOut(duration: 0.12), value: isPressed)
        // Touchable well beyond what's drawn. The padding grows the footprint without
        // changing the visual, and `contentShape` then covers the grown square — so a
        // 44pt arrow answers a 64pt circle. Order matters: `contentShape` uses the
        // frame it's applied to, so it has to come after the padding, not before.
        .padding(metrics.hitSlop)
        .contentShape(Circle())
        // Being placed: no gesture here, so the parent's drag gets the touch. Marking
        // it non-hit-testable instead let the drag fall through to the board
        // underneath, where it read as a swipe and rolled Qoob.
        .gesture(isActive ? holdGesture : nil)
        .onDisappear { release() }
    }

    private var holdGesture: some Gesture {
        // minimumDistance 0, so it answers the first touch rather than a slide.
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed else { return }
                isPressed = true
                onHold(direction)
            }
            .onEnded { _ in release() }
    }

    private func release() {
        guard isPressed else { return }
        isPressed = false
        onHold(nil)
    }

    private var face: some View {
        Image(systemName: arrowIcon(direction))
            .font(.system(size: metrics.arrow * 0.39, weight: .bold))
            .foregroundStyle(.primary)
    }
}

/// Each roll's lit side, over the pad's four chevrons: the arc has to sit on the
/// chevron it belongs to.
#Preview("Pad highlight") {
    HStack(spacing: 16) {
        ForEach(Array(RollDirection.allCases.enumerated()), id: \.offset) { _, direction in
            ZStack {
                Circle().fill(.white.opacity(0.12))
                ForEach(Array(RollDirection.allCases.enumerated()), id: \.offset) { _, chevron in
                    Image(systemName: arrowIcon(chevron))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .offset(padChevronOffset(chevron, diameter: ControlMetrics.compact.wheel))
                }
                DirectionQuadrant(direction: direction)
            }
            .frame(width: ControlMetrics.compact.wheel, height: ControlMetrics.compact.wheel)
        }
    }
    .padding()
    .background(Color(red: 0.18, green: 0.20, blue: 0.24))
}

#Preview {
    VStack(spacing: 40) {
        DirectionWheel { _ in }
        HStack(spacing: 12) {
            ArrowButton(direction: .left) { _ in }
            ArrowButton(direction: .right) { _ in }
        }
    }
    .padding()
    .background(Color(red: 0.18, green: 0.20, blue: 0.24))
}

#Preview("Hold behaviour") {
    // Both controls report a held direction; the frame loop is what repeats it.
    struct Harness: View {
        @State private var held: RollDirection?
        var body: some View {
            VStack(spacing: 24) {
                Text(held.map { "holding \($0)" } ?? "released").monospaced()
                DirectionWheel { held = $0 }
                HStack(spacing: 12) {
                    ArrowButton(direction: .left) { held = $0 }
                    ArrowButton(direction: .right) { held = $0 }
                }
            }
        }
    }
    return Harness()
    .padding()
    .background(Color(red: 0.18, green: 0.20, blue: 0.24))
}

#endif   // !os(tvOS) — end of the touch-driven controls
