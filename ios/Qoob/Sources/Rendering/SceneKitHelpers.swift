//
//  SceneKitHelpers.swift
//  Qoob
//
//  `SCNVector3`'s components are `Float` on iOS, and mixing `Float`/`CGFloat`
//  or bare float literals in its initializer is a common source of ambiguous-
//  overload compile errors. `v3` funnels everything through the `Float`
//  initializer so call sites can pass plain numbers safely.
//

import SceneKit

@inline(__always)
func v3(_ x: Double, _ y: Double, _ z: Double) -> SCNVector3 {
    SCNVector3(Float(x), Float(y), Float(z))
}

/// Same idea for `SCNVector4` (used for `node.rotation`, an axis-angle 4-vector).
/// Built via the labelled memberwise initializer so there's no literal-overload
/// ambiguity, matching how `v3` shields SCNVector3 construction.
@inline(__always)
func v4(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> SCNVector4 {
    SCNVector4(x: Float(x), y: Float(y), z: Float(z), w: Float(w))
}
