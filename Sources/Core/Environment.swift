//
//  Environment.swift
//  Qoob
//
//  Themed settings for where the cat is playing — a living room, a kitchen, a
//  bedroom, a yard — changing the floor, backdrop mood, and which furniture and
//  obstacles appear. A pure content layer: no game rules change between them.
//  Picked per room, since there are no levels to advance through.
//

import UIKit

/// What the ground is made of.
///
/// A property of the room rather than a setting. There used to be a Floor picker,
/// which is how grass ended up in a living room and hardwood in the yard — the room
/// knows what it's floored with, and nothing else should get a say.
enum GroundSurface {
    case carpet, hardwood, tile      // indoor
    case grass, sand, paving         // outdoor
}

enum Environment: String, CaseIterable, Codable {
    // Indoor
    case livingRoom
    case kitchen
    case bedroom
    // Outdoor
    case yard
    case sandpit
    case patio

    /// Outdoor rooms are open ground — fenced rather than walled, and the only ones
    /// that grow grass.
    var isOutdoor: Bool {
        switch self {
        case .livingRoom, .kitchen, .bedroom: return false
        case .yard, .sandpit, .patio:         return true
        }
    }

    /// What this room is floored with.
    var ground: GroundSurface {
        switch self {
        case .livingRoom: return .carpet
        case .bedroom:    return .hardwood
        case .kitchen:    return .tile
        case .yard:       return .grass
        case .sandpit:    return .sand
        case .patio:      return .paving
        }
    }

    static var indoorCases: [Environment] { allCases.filter { !$0.isOutdoor } }
    static var outdoorCases: [Environment] { allCases.filter { $0.isOutdoor } }

    /// A room's environment, drawn from the seeded generator so a given room seed
    /// always furnishes the same kind of room.
    static func random(_ rng: inout SeededGenerator) -> Environment {
        allCases[Int(rng.next() % UInt64(allCases.count))]
    }

    /// One of the indoor or outdoor sets, for a house that wants a mix of both.
    static func random(_ rng: inout SeededGenerator, outdoor: Bool) -> Environment {
        let pool = outdoor ? outdoorCases : indoorCases
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    var displayName: String {
        switch self {
        case .livingRoom: return "Living Room"
        case .kitchen:    return "Kitchen"
        case .bedroom:    return "Bedroom"
        case .yard:       return "Yard"
        case .sandpit:    return "Sandpit"
        case .patio:      return "Patio"
        }
    }

    /// Furniture / obstacle kinds that appear in this environment.
    ///
    /// Outdoors has no furniture at all — only planting. A yard is ground: the point of
    /// it is the open space and the mound in it, not somewhere to sit. Sharing the indoor
    /// sets made the outdoor rooms the *most* crowded in the house, at 9.8 pieces for a
    /// yard and 10.2 for a patio against a bedroom's 4.9.
    ///
    /// `gardenBench` and `planter` are deliberately left in `FurnitureKind` rather than
    /// deleted: the level builder still offers them, so a hand-built garden can have a
    /// bench. It's the generator that shouldn't be scattering them.
    var furnitureKinds: [FurnitureKind] {
        switch self {
        // `box` is in every indoor set on purpose. It's one level, so it's the step that
        // makes the two-level furniture beside it reachable — and a cardboard box left
        // out is the least contrived thing to find in any room of a house.
        //
        // Not outdoors: a yard is ground, and adding props back to it would undo the
        // point of emptying it. Outdoor verticality comes from the mounds instead.
        // `lamp` is in the two rooms people actually put standard lamps in. It's the only
        // piece that carries a light of its own, which is what makes a night-time room
        // read as a home with a lamp left on rather than as a dark room.
        case .livingRoom: return [.sofa, .coffeeTable, .armchair, .box, .lamp]
        // The stool is here for the climb as much as for the look: it's the kitchen's
        // only one-level piece, and so the only way onto the table beside it. No lamp —
        // kitchens are lit from the ceiling, not by a standard lamp in the corner.
        case .kitchen:    return [.counter, .diningTable, .fridge, .oven, .diningChair, .box]
        case .bedroom:    return [.bed, .dresser, .nightstand, .box, .lamp]
        case .yard:       return [.bush, .tree]
        // Open sand, and nothing else. A tree growing out of a sandpit reads as a
        // mistake rather than a garden, and a shrub in one is no better.
        case .sandpit:    return []
        case .patio:      return [.bush, .tree]
        }
    }

    /// How many pieces a room of this kind wants for a given floor area.
    ///
    /// Outdoors is emphatically sparser — a few shrubs and a tree in a yard, and nothing
    /// forced: the `max(2, …)` floor that guarantees an indoor room isn't bare would
    /// otherwise plant two things in every sandpit.
    /// One piece per this many cells of floor.
    ///
    /// It has come down twice. `area / 30` was the original, but rooms never reached it —
    /// the big pieces ran out of anywhere to go — so the count that shipped was whatever
    /// placement managed. Adding a 1×1 box, which fits nearly anywhere, made the quota
    /// suddenly achievable and rooms 50% busier, so it went to `/42` to hold the old look.
    /// `/64` is the first figure chosen on purpose: a room should read as furnished and
    /// still be mostly floor, because the floor is where the game happens.
    func furnishingQuota(area: Int) -> Int {
        isOutdoor ? area / 140 : max(2, area / 64)
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
        case (.sandpit, .dark):     return UIColor(red: 0.46, green: 0.39, blue: 0.27, alpha: 1)
        case (.sandpit, .light):    return UIColor(red: 0.88, green: 0.79, blue: 0.58, alpha: 1)
        case (.patio, .dark):       return UIColor(red: 0.34, green: 0.33, blue: 0.32, alpha: 1)
        case (.patio, .light):      return UIColor(red: 0.72, green: 0.70, blue: 0.66, alpha: 1)
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
        case (.sandpit, .dark):     return UIColor(red: 0.38, green: 0.32, blue: 0.22, alpha: 1)
        case (.sandpit, .light):    return UIColor(red: 0.80, green: 0.71, blue: 0.50, alpha: 1)
        case (.patio, .dark):       return UIColor(red: 0.27, green: 0.26, blue: 0.25, alpha: 1)
        case (.patio, .light):      return UIColor(red: 0.62, green: 0.60, blue: 0.57, alpha: 1)
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
        case (.sandpit, .dark):     return UIColor(red: 0.20, green: 0.26, blue: 0.32, alpha: 1)
        case (.sandpit, .light):    return UIColor(red: 0.68, green: 0.82, blue: 0.90, alpha: 1)
        case (.patio, .dark):       return UIColor(red: 0.16, green: 0.20, blue: 0.26, alpha: 1)
        case (.patio, .light):      return UIColor(red: 0.66, green: 0.78, blue: 0.86, alpha: 1)
        }
    }

    /// Wall colour for the room's enclosing walls.
    ///
    /// The rule is a clear step *away* from the floor's brightness, in whichever
    /// direction there's room: darker than a pale floor in light mode, lighter than a
    /// dark one in dark mode.
    ///
    /// The original values were all a shade lighter than their floor, which is the
    /// instinct — walls catch more light than floors do — but from almost straight above
    /// you see a wall's top face, not its lit side. At 0.08 of luminance from the floor
    /// the wall simply vanished: a kitchen divider read as a white *gap* between two
    /// rooms rather than as a wall. Every pairing now clears 0.12.
    func wallColor(_ appearance: Appearance) -> UIColor {
        switch (self, appearance) {
        case (.livingRoom, .dark):  return UIColor(red: 0.40, green: 0.37, blue: 0.46, alpha: 1)
        case (.livingRoom, .light): return UIColor(red: 0.62, green: 0.56, blue: 0.49, alpha: 1)
        case (.kitchen, .dark):     return UIColor(red: 0.66, green: 0.68, blue: 0.72, alpha: 1)
        case (.kitchen, .light):    return UIColor(red: 0.66, green: 0.67, blue: 0.70, alpha: 1)
        case (.bedroom, .dark):     return UIColor(red: 0.48, green: 0.40, blue: 0.52, alpha: 1)
        case (.bedroom, .light):    return UIColor(red: 0.65, green: 0.56, blue: 0.62, alpha: 1)
        // Outdoor rooms are fenced rather than walled — timber, not plaster.
        case (.yard, .dark):        return UIColor(red: 0.55, green: 0.42, blue: 0.28, alpha: 1)
        case (.yard, .light):       return UIColor(red: 0.56, green: 0.42, blue: 0.27, alpha: 1)
        case (.sandpit, .dark):     return UIColor(red: 0.30, green: 0.23, blue: 0.15, alpha: 1)
        case (.sandpit, .light):    return UIColor(red: 0.60, green: 0.46, blue: 0.29, alpha: 1)
        case (.patio, .dark):       return UIColor(red: 0.50, green: 0.46, blue: 0.41, alpha: 1)
        case (.patio, .light):      return UIColor(red: 0.48, green: 0.44, blue: 0.39, alpha: 1)
        }
    }

    /// Optional floor-texture asset name (drop a PNG to override the colour).
    var floorTextureName: String { "floor_\(rawValue)" }
}
