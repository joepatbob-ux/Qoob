//
//  Environment.swift
//  Qoob
//
//  Themed settings for where the cat is playing. Environments cycle as the
//  player progresses — a living room, then a kitchen, a bedroom, a yard —
//  changing the floor, backdrop mood, and which furniture/obstacles appear.
//  A pure content layer: no game rules change between environments.
//

import UIKit

enum Environment: String, CaseIterable {
    case livingRoom
    case kitchen
    case bedroom
    case yard

    /// Environment for a given level index (advances every few levels, cycles).
    static func forLevel(_ index: Int) -> Environment {
        allCases[(index / 3) % allCases.count]
    }

    var displayName: String {
        switch self {
        case .livingRoom: return "Living Room"
        case .kitchen:    return "Kitchen"
        case .bedroom:    return "Bedroom"
        case .yard:       return "Yard"
        }
    }

    /// Furniture / obstacle kinds that appear in this environment.
    var furnitureKinds: [FurnitureKind] {
        switch self {
        case .livingRoom: return [.sofa, .coffeeTable, .armchair]
        case .kitchen:    return [.counter, .diningTable, .fridge]
        case .bedroom:    return [.bed, .dresser, .nightstand]
        case .yard:       return [.gardenBench, .bush, .planter]
        }
    }

    /// Floor-tile colour (used when no carpet/floor texture is supplied).
    var floorColor: UIColor {
        switch self {
        case .livingRoom: return UIColor(red: 0.20, green: 0.19, blue: 0.24, alpha: 1)
        case .kitchen:    return UIColor(red: 0.78, green: 0.79, blue: 0.82, alpha: 1)
        case .bedroom:    return UIColor(red: 0.30, green: 0.24, blue: 0.33, alpha: 1)
        case .yard:       return UIColor(red: 0.34, green: 0.52, blue: 0.30, alpha: 1)
        }
    }

    /// Surrounding ground colour (the plane beyond the play tiles).
    var groundColor: UIColor {
        switch self {
        case .livingRoom: return UIColor(red: 0.12, green: 0.11, blue: 0.16, alpha: 1)
        case .kitchen:    return UIColor(red: 0.55, green: 0.56, blue: 0.60, alpha: 1)
        case .bedroom:    return UIColor(red: 0.16, green: 0.13, blue: 0.19, alpha: 1)
        case .yard:       return UIColor(red: 0.26, green: 0.44, blue: 0.24, alpha: 1)
        }
    }

    /// Backdrop / clear colour behind the scene.
    var background: UIColor {
        switch self {
        case .livingRoom: return UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        case .kitchen:    return UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1)
        case .bedroom:    return UIColor(red: 0.08, green: 0.07, blue: 0.11, alpha: 1)
        case .yard:       return UIColor(red: 0.30, green: 0.44, blue: 0.54, alpha: 1) // sky
        }
    }

    /// Optional floor-texture asset name (drop a PNG to override the colour).
    var floorTextureName: String { "floor_\(rawValue)" }
}
