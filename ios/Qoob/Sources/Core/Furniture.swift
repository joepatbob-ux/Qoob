//
//  Furniture.swift
//  Qoob
//
//  Living-room obstacles the cat rolls around. Each piece occupies an
//  axis-aligned block of cells that the cube cannot enter. Pure model — the
//  renderer draws a placeholder (or a bundled model) from this description.
//

import UIKit

enum FurnitureKind: String, CaseIterable {
    // Living room
    case sofa, coffeeTable, armchair
    // Kitchen
    case counter, diningTable, fridge
    // Bedroom
    case bed, dresser, nightstand
    // Yard
    case gardenBench, bush, planter

    /// Placeholder colour (used when no 3D model is supplied).
    var color: UIColor {
        switch self {
        case .sofa:        return UIColor(red: 0.36, green: 0.45, blue: 0.52, alpha: 1) // slate
        case .coffeeTable: return UIColor(red: 0.52, green: 0.38, blue: 0.26, alpha: 1) // walnut
        case .armchair:    return UIColor(red: 0.70, green: 0.52, blue: 0.32, alpha: 1) // mustard
        case .counter:     return UIColor(red: 0.80, green: 0.78, blue: 0.72, alpha: 1) // laminate
        case .diningTable: return UIColor(red: 0.55, green: 0.40, blue: 0.28, alpha: 1) // oak
        case .fridge:      return UIColor(red: 0.86, green: 0.88, blue: 0.90, alpha: 1) // steel
        case .bed:         return UIColor(red: 0.40, green: 0.48, blue: 0.66, alpha: 1) // duvet blue
        case .dresser:     return UIColor(red: 0.48, green: 0.35, blue: 0.26, alpha: 1) // wood
        case .nightstand:  return UIColor(red: 0.52, green: 0.40, blue: 0.30, alpha: 1) // wood
        case .gardenBench: return UIColor(red: 0.46, green: 0.50, blue: 0.44, alpha: 1) // weathered
        case .bush:        return UIColor(red: 0.28, green: 0.50, blue: 0.28, alpha: 1) // foliage
        case .planter:     return UIColor(red: 0.68, green: 0.42, blue: 0.32, alpha: 1) // terracotta
        }
    }

    /// Height in world units (the cube is 1.0 tall).
    var height: CGFloat {
        switch self {
        case .sofa:        return 0.6
        case .coffeeTable: return 0.34
        case .armchair:    return 0.58
        case .counter:     return 0.7
        case .diningTable: return 0.5
        case .fridge:      return 0.95
        case .bed:         return 0.45
        case .dresser:     return 0.7
        case .nightstand:  return 0.5
        case .gardenBench: return 0.5
        case .bush:        return 0.62
        case .planter:     return 0.5
        }
    }

    /// Whether this kind should render a back cushion (sofas/chairs/benches).
    var hasBack: Bool {
        switch self {
        case .sofa, .armchair, .gardenBench, .bed: return true
        default: return false
        }
    }

    /// Optional bundled model name (e.g. "sofa.usdz"); loaded if present.
    var modelBaseName: String { rawValue }

    /// Possible footprints (cols × rows). Orientation is chosen at random.
    var footprints: [(cols: Int, rows: Int)] {
        switch self {
        case .sofa:        return [(3, 1), (1, 3)]
        case .coffeeTable: return [(2, 1), (1, 2)]
        case .armchair:    return [(1, 1)]
        case .counter:     return [(3, 1), (1, 3)]
        case .diningTable: return [(2, 2)]
        case .fridge:      return [(1, 1)]
        case .bed:         return [(2, 3), (3, 2)]
        case .dresser:     return [(2, 1), (1, 2)]
        case .nightstand:  return [(1, 1)]
        case .gardenBench: return [(3, 1), (1, 3)]
        case .bush:        return [(1, 1)]
        case .planter:     return [(1, 1)]
        }
    }
}

struct Furniture {
    let kind: FurnitureKind
    let origin: GridCell   // min-corner cell
    let cols: Int
    let rows: Int

    var cells: [GridCell] {
        var out: [GridCell] = []
        for r in 0..<rows {
            for c in 0..<cols {
                out.append(GridCell(col: origin.col + c, row: origin.row + r))
            }
        }
        return out
    }

    /// Footprint centre in grid coordinates (may be a half-cell).
    var centerCol: Double { Double(origin.col) + Double(cols - 1) / 2.0 }
    var centerRow: Double { Double(origin.row) + Double(rows - 1) / 2.0 }
}
