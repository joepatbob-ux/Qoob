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
    case sofa
    case coffeeTable
    case armchair
    case rugChest      // an ottoman / chest — small square block

    /// Placeholder colour (used when no 3D model is supplied).
    var color: UIColor {
        switch self {
        case .sofa:       return UIColor(red: 0.36, green: 0.45, blue: 0.52, alpha: 1) // slate fabric
        case .coffeeTable:return UIColor(red: 0.52, green: 0.38, blue: 0.26, alpha: 1) // walnut
        case .armchair:   return UIColor(red: 0.70, green: 0.52, blue: 0.32, alpha: 1) // mustard
        case .rugChest:   return UIColor(red: 0.55, green: 0.40, blue: 0.45, alpha: 1) // mauve
        }
    }

    /// Height in world units (the cube is 1.0 tall).
    var height: CGFloat {
        switch self {
        case .sofa:        return 0.6
        case .coffeeTable: return 0.34
        case .armchair:    return 0.58
        case .rugChest:    return 0.4
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
        case .rugChest:    return [(1, 1)]
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
