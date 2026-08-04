//
//  Environment.swift
//  Qoob
//
//  Quiet room moods on a shared Classic Soft linen world. Environments cycle
//  as the player progresses — same calm field, soft tint shifts and furniture
//  sets. No game rules change between environments.
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

    /// Floor-tile colour — soft linen family, lightly tinted per room.
    var floorColor: UIColor {
        switch self {
        case .livingRoom: return UIColor(red: 0.90, green: 0.86, blue: 0.80, alpha: 1)
        case .kitchen:    return UIColor(red: 0.91, green: 0.89, blue: 0.85, alpha: 1)
        case .bedroom:    return UIColor(red: 0.91, green: 0.86, blue: 0.84, alpha: 1)
        case .yard:       return UIColor(red: 0.86, green: 0.88, blue: 0.80, alpha: 1)
        }
    }

    /// Surrounding ground — a step quieter than the play tiles.
    var groundColor: UIColor {
        switch self {
        case .livingRoom: return UIColor(red: 0.84, green: 0.80, blue: 0.74, alpha: 1)
        case .kitchen:    return UIColor(red: 0.85, green: 0.83, blue: 0.79, alpha: 1)
        case .bedroom:    return UIColor(red: 0.85, green: 0.80, blue: 0.78, alpha: 1)
        case .yard:       return UIColor(red: 0.78, green: 0.82, blue: 0.72, alpha: 1)
        }
    }

    /// Backdrop — warm paper, barely shifted per mood.
    var background: UIColor {
        switch self {
        case .livingRoom: return UIColor(red: 0.94, green: 0.91, blue: 0.86, alpha: 1)
        case .kitchen:    return UIColor(red: 0.95, green: 0.93, blue: 0.90, alpha: 1)
        case .bedroom:    return UIColor(red: 0.95, green: 0.91, blue: 0.90, alpha: 1)
        case .yard:       return UIColor(red: 0.90, green: 0.93, blue: 0.88, alpha: 1)
        }
    }

    /// Optional floor-texture asset name (drop a PNG to override the colour).
    var floorTextureName: String { "floor_\(rawValue)" }
}
