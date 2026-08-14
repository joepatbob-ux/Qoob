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
    func floorColor(_ appearance: Appearance) -> UIColor {
        switch (self, appearance) {
        case (.livingRoom, .dark):  return UIColor(red: 0.20, green: 0.19, blue: 0.24, alpha: 1)
        case (.livingRoom, .light): return UIColor(red: 0.80, green: 0.76, blue: 0.72, alpha: 1)
        case (.kitchen, .dark):     return UIColor(red: 0.44, green: 0.45, blue: 0.48, alpha: 1)
        case (.kitchen, .light):    return UIColor(red: 0.86, green: 0.85, blue: 0.82, alpha: 1)
        case (.bedroom, .dark):     return UIColor(red: 0.30, green: 0.24, blue: 0.33, alpha: 1)
        case (.bedroom, .light):    return UIColor(red: 0.85, green: 0.78, blue: 0.82, alpha: 1)
        case (.yard, .dark):        return UIColor(red: 0.24, green: 0.36, blue: 0.22, alpha: 1)
        case (.yard, .light):       return UIColor(red: 0.52, green: 0.68, blue: 0.42, alpha: 1)
        }
    }

    /// Surrounding ground colour (the plane beyond the play tiles).
    func groundColor(_ appearance: Appearance) -> UIColor {
        switch (self, appearance) {
        case (.livingRoom, .dark):  return UIColor(red: 0.12, green: 0.11, blue: 0.16, alpha: 1)
        case (.livingRoom, .light): return UIColor(red: 0.72, green: 0.68, blue: 0.64, alpha: 1)
        case (.kitchen, .dark):     return UIColor(red: 0.30, green: 0.31, blue: 0.34, alpha: 1)
        case (.kitchen, .light):    return UIColor(red: 0.76, green: 0.75, blue: 0.72, alpha: 1)
        case (.bedroom, .dark):     return UIColor(red: 0.16, green: 0.13, blue: 0.19, alpha: 1)
        case (.bedroom, .light):    return UIColor(red: 0.78, green: 0.71, blue: 0.75, alpha: 1)
        case (.yard, .dark):        return UIColor(red: 0.20, green: 0.32, blue: 0.19, alpha: 1)
        case (.yard, .light):       return UIColor(red: 0.44, green: 0.60, blue: 0.36, alpha: 1)
        }
    }

    /// Backdrop / clear colour behind the scene.
    func background(_ appearance: Appearance) -> UIColor {
        switch (self, appearance) {
        case (.livingRoom, .dark):  return UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        case (.livingRoom, .light): return UIColor(red: 0.89, green: 0.87, blue: 0.84, alpha: 1)
        case (.kitchen, .dark):     return UIColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1)
        case (.kitchen, .light):    return UIColor(red: 0.92, green: 0.92, blue: 0.90, alpha: 1)
        case (.bedroom, .dark):     return UIColor(red: 0.08, green: 0.07, blue: 0.11, alpha: 1)
        case (.bedroom, .light):    return UIColor(red: 0.90, green: 0.86, blue: 0.89, alpha: 1)
        case (.yard, .dark):        return UIColor(red: 0.18, green: 0.28, blue: 0.36, alpha: 1)
        case (.yard, .light):       return UIColor(red: 0.62, green: 0.79, blue: 0.90, alpha: 1) // sky
        }
    }

    /// Optional floor-texture asset name (drop a PNG to override the colour).
    var floorTextureName: String { "floor_\(rawValue)" }
}
