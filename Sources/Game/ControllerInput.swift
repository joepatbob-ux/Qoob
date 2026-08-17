//
//  ControllerInput.swift
//  Qoob
//
//  Rolls from a game controller, an Apple TV remote, or a keyboard.
//
//  The third control scheme, alongside swipe and the on-screen pad — and the only
//  one an Apple TV has, since it has no touch screen. On iPhone, iPad and the Mac it
//  comes along for free.
//
//  Ask it for a direction each frame and it reports whichever way is being *held*.
//  That means holding a direction rolls at the game's own cadence
//  (`GameController.restBetweenRolls`) rather than spraying rolls, and there is no
//  separate event-driven path to keep in step. The on-screen pad reports its held
//  direction the same way, through `GameViewModel.hold`.
//

import GameController

@MainActor
final class ControllerInput {

    /// How far a stick must be pushed before it counts. Generous: this is a
    /// four-direction game, so precision isn't the point.
    private let stickThreshold: Float = 0.5

    /// How much more dominant the other axis must be before the held direction gives
    /// way. Picking the axis by `abs(x) >= abs(y)` alone is exactly ambiguous on the
    /// diagonal, and an analogue stick is *noisy* — held near 45° the dominant axis
    /// alternated frame to frame, so the direction flip-flopped and Qoob stuttered
    /// between two of them instead of walking. Worse here than on the touch wheel,
    /// because a thumb on glass at least holds still.
    private let switchMargin: Float = 1.35

    /// The direction reported last frame, so `switchMargin` has something to hold on to.
    private var lastDirection: RollDirection?

    /// Connected controllers, kept current by the connect/disconnect notices
    /// rather than rebuilt every frame — `GCController.controllers()` allocates,
    /// and this is polled sixty times a second.
    private var controllers: [GCController] = GCController.controllers()
    private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [NSNotification.Name.GCControllerDidConnect,
                     NSNotification.Name.GCControllerDidDisconnect] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in
                    self?.controllers = GCController.controllers()
                }
            }
            observers.append(token)
        }
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    /// True when there's something to play with — used for the hint on the start
    /// panel, not to gate input.
    var hasController: Bool { !controllers.isEmpty }

    /// The direction currently held, or nil. Checks every connected controller and
    /// then the keyboard, so it doesn't matter what the player picks up.
    func rollDirection() -> RollDirection? {
        let direction = currentDirection()
        // Remembered for the hysteresis above. Cleared on release, so letting go and
        // pushing again always picks the axis fresh.
        lastDirection = direction
        return direction
    }

    private func currentDirection() -> RollDirection? {
        for controller in controllers {
            if let direction = rollDirection(from: controller.physicalInputProfile) {
                return direction
            }
        }
        return keyboardDirection()
    }

    /// Reads whichever of the standard directional inputs the device has: the
    /// d-pad (a game pad's, or the ring on a Siri Remote) and the left thumbstick.
    private func rollDirection(from profile: GCPhysicalInputProfile) -> RollDirection? {
        for name in [GCInputDirectionPad, GCInputLeftThumbstick] {
            guard let pad = profile.dpads[name] else { continue }
            // Screen up is up the board, matching the swipe and the wheel. A stick's y
            // axis is positive upwards, so `up` is `.forward`.
            let x = pad.xAxis.value
            let y = pad.yAxis.value

            // Keep last frame's direction while it's still pushed and still roughly
            // dominant. A real d-pad snaps to one axis and never needs this; a stick does.
            if let last = lastDirection, holds(last, x: x, y: y) { return last }

            if abs(x) >= abs(y) {
                if x >= stickThreshold { return .right }
                if x <= -stickThreshold { return .left }
            } else {
                if y >= stickThreshold { return .forward }
                if y <= -stickThreshold { return .back }
            }
        }
        return nil
    }

    /// Whether `direction` is still pushed past the threshold and still dominant enough,
    /// allowing `switchMargin`.
    private func holds(_ direction: RollDirection, x: Float, y: Float) -> Bool {
        switch direction {
        case .right:   return x >= stickThreshold && abs(x) * switchMargin > abs(y)
        case .left:    return x <= -stickThreshold && abs(x) * switchMargin > abs(y)
        case .forward: return y >= stickThreshold && abs(y) * switchMargin > abs(x)
        case .back:    return y <= -stickThreshold && abs(y) * switchMargin > abs(x)
        }
    }

    /// Arrow keys or WASD. Mostly for the Mac, though a keyboard paired with an
    /// iPad or an Apple TV works the same way.
    private func keyboardDirection() -> RollDirection? {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return nil }
        func pressed(_ codes: [GCKeyCode]) -> Bool {
            codes.contains { keyboard.button(forKeyCode: $0)?.isPressed == true }
        }
        if pressed([.upArrow, .keyW])    { return .forward }
        if pressed([.downArrow, .keyS])  { return .back }
        if pressed([.leftArrow, .keyA])  { return .left }
        if pressed([.rightArrow, .keyD]) { return .right }
        return nil
    }
}
