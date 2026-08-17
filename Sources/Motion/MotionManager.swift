//
//  MotionManager.swift
//  Qoob
//
//  UNUSED — tilt-to-roll was removed. Nothing references this type any more; the
//  game is played with the on-screen pad, swipes, or a controller/keyboard. The file
//  is still in the target only because the Xcode project lists its sources
//  explicitly, so removing it needs a change to `project.pbxproj` — safe to delete
//  from the project whenever convenient.
//
//  Wraps CoreMotion. Reads the device's gravity vector and turns tilt into a
//  discrete roll direction. A neutral baseline is captured on calibration so
//  the game feels right however the player is holding the device.
//
//  Note: device-motion (attitude/gravity) needs no privacy permission, so
//  there is no usage prompt. It requires a real device — the Simulator has
//  no gyroscope, and neither does a Mac or an Apple TV.
//
//  CoreMotion doesn't exist at all on tvOS, so the whole type is compiled twice:
//  the real one where the framework exists, and a stub that simply reports itself
//  unavailable where it doesn't. Everything above the manager — the controller's
//  tick, the Settings toggle, the "no motion sensor" note — already copes with an
//  unavailable sensor, so there's nothing else to branch.
//

#if canImport(CoreMotion)

import CoreMotion
import simd

final class MotionManager {

    /// Flip these if a tilt rolls the cube the wrong way on your device.
    var invertX = false
    var invertY = false

    /// How far past neutral the device must tilt before a roll triggers.
    /// Roughly "gravity units" (0...1). ~0.28 ≈ a comfortable ~16° lean.
    var threshold: Double = 0.28

    private let motion = CMMotionManager()
    private var baseline = SIMD2<Double>(0, 0)
    private var latest = SIMD2<Double>(0, 0)
    private(set) var isAvailable = false

    func start() {
        guard motion.isDeviceMotionAvailable else {
            isAvailable = false
            return
        }
        isAvailable = true
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self = self, let g = data?.gravity else { return }
            self.latest = SIMD2<Double>(g.x, g.y)
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    /// Treats the current pose as "flat / neutral".
    func calibrate() {
        baseline = latest
    }

    /// Tilt relative to the neutral baseline, sign-corrected.
    var tilt: SIMD2<Double> {
        var t = latest - baseline
        if invertX { t.x = -t.x }
        if invertY { t.y = -t.y }
        return t
    }

    /// The dominant roll direction if tilt exceeds the threshold, else `nil`.
    ///
    /// Tilting the device right/left rolls the cube right/left; tilting the top
    /// of the device away from you rolls the cube forward (up the board).
    func rollDirection() -> RollDirection? {
        let t = tilt
        if abs(t.x) >= abs(t.y) {
            if t.x > threshold { return .right }
            if t.x < -threshold { return .left }
        } else {
            if t.y > threshold { return .forward }
            if t.y < -threshold { return .back }
        }
        return nil
    }
}

#else

import simd

/// Stand-in for platforms with no CoreMotion (tvOS). It reports itself
/// unavailable, which switches the game to the controller, swipe and on-screen
/// paths — the same thing that happens in the Simulator.
final class MotionManager {
    var invertX = false
    var invertY = false
    var threshold: Double = 0.28

    let isAvailable = false

    func start() {}
    func stop() {}
    func calibrate() {}

    var tilt: SIMD2<Double> { SIMD2<Double>(0, 0) }

    func rollDirection() -> RollDirection? { nil }
}

#endif
