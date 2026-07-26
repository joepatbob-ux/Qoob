//
//  MotionManager.swift
//  Qoob
//
//  Wraps CoreMotion. Reads the device's gravity vector and turns tilt into a
//  discrete roll direction. A neutral baseline is captured on calibration so
//  the game feels right however the player is holding the device.
//
//  Note: device-motion (attitude/gravity) needs no privacy permission, so
//  there is no usage prompt. It requires a real device — the Simulator has
//  no gyroscope.
//

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
