//
//  LevelBuilderView.swift
//  Qoob
//
//  The level builder: a plan-view editor that paints rooms, doors, furniture, mounds
//  and props onto a HouseBlueprint, validates it, and hands back the same `Level` the
//  generator produces — so an authored house is indistinguishable to the rest of the
//  game (see BlueprintTests).
//
//  This used to live in SettingsView.swift, whose header explained why: the Xcode
//  project listed every source file explicitly, so a new file meant editing the
//  project. The project is now generated from project.yml, which globs Sources, so
//  that reason is gone.
//

import SwiftUI

// The builder is touch-driven: painting a plan needs a drag, which tvOS has no
// equivalent for. The whole file is excluded there rather than each view guarded.
#if !os(tvOS)

/// What a touch on the plan does.
///
/// Two kinds: the ones you drag out as a rectangle (rooms, rugs) and the ones you
/// tap down (everything else). `isRectangular` is what the gesture branches on.
enum BuilderTool: Hashable, Identifiable {
    case room(Environment)
    case furniture(FurnitureKind)
    case rug
    case hill
    case door
    case start
    case basket
    case litterbox
    case toy
    case erase

    var id: String {
        switch self {
        case .room(let kind):      return "room.\(kind.rawValue)"
        case .furniture(let kind): return "furniture.\(kind.rawValue)"
        case .rug:                 return "rug"
        case .hill:                return "hill"
        case .door:                return "door"
        case .start:               return "start"
        case .basket:              return "basket"
        case .litterbox:           return "litterbox"
        case .toy:                 return "toy"
        case .erase:               return "erase"
        }
    }

    var title: String {
        switch self {
        case .room(let kind):      return kind.displayName
        case .furniture(let kind): return kind.displayName
        case .rug:                 return "Rug"
        case .hill:                return "Mound"
        case .door:                return "Door"
        case .start:               return "Start"
        case .basket:              return "Basket"
        case .litterbox:           return "Litterbox"
        case .toy:                 return "Toy"
        case .erase:               return "Erase"
        }
    }

    var systemImage: String {
        switch self {
        case .room:      return "square.dashed"
        case .furniture: return "square.fill"
        case .rug:       return "rectangle.portrait"
        case .hill:      return "mountain.2.fill"
        case .door:      return "door.left.hand.open"
        case .start:     return "pawprint.fill"
        case .basket:    return "basket.fill"
        case .litterbox: return "tray.fill"
        case .toy:       return "circle.fill"
        case .erase:     return "eraser.fill"
        }
    }

    /// Dragged out as a rectangle rather than tapped down.
    var isRectangular: Bool {
        switch self {
        case .room, .rug, .hill, .erase: return true
        default:                         return false
        }
    }
}

/// The level builder: a top-down plan of the house you can draw on.
///
/// Rooms are rectangles, because the renderer draws one floor slab per room and the
/// house was always meant to be right angles. Everything else is placed into them.
/// What's edited is a `HouseBlueprint` — the authored decisions only — and `Play`
/// turns it into a `Level` by the same rules the generator follows, so a hand-built
/// house behaves exactly like a generated one.
struct LevelBuilderView: View {
    @ObservedObject var viewModel: GameViewModel
    @SwiftUI.Environment(\.dismiss) private var dismiss

    @State private var blueprint: HouseBlueprint
    @State private var tool: BuilderTool = .room(.livingRoom)
    @State private var group: PaletteGroup = .rooms
    /// Swaps a piece of furniture to its other footprint, where it has one.
    @State private var rotated = false
    @State private var dragFrom: GridCell?
    @State private var dragTo: GridCell?
    @State private var issues: [String] = []
    @State private var showManage = false
    /// Bounded, so a long session of drawing can't grow without limit.
    @State private var undoStack: [HouseBlueprint] = []

    enum PaletteGroup: String, CaseIterable, Identifiable {
        case rooms = "Rooms", furniture = "Furniture", things = "Things"
        var id: String { rawValue }
    }

    init(viewModel: GameViewModel, blueprint: HouseBlueprint) {
        self.viewModel = viewModel
        _blueprint = State(initialValue: blueprint)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                plan
                Divider()
                issueBar
                palette
            }
            .navigationTitle(blueprint.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let previous = undoStack.popLast() {
                            blueprint = previous
                            issues = blueprint.validate()
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(undoStack.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Manage houses…") { showManage = true }
                        Button("Auto-connect rooms") {
                            edit { $0.autoConnect() }
                        }
                        Button("Save") { HouseLibrary.save(blueprint) }
                        Divider()
                        Button("Start over", role: .destructive) {
                            edit { $0 = HouseBlueprint(name: "New house",
                                                       width: $0.width, height: $0.height) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Play") {
                        // Autosave only once it's been changed. Opening the builder on
                        // the house you're standing in and playing straight back out
                        // shouldn't leave a copy on the shelf every time — but nobody
                        // should lose a house they just drew, either.
                        if !undoStack.isEmpty { HouseLibrary.save(blueprint) }
                        viewModel.controller?.startGame(blueprint: blueprint)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(blueprint.rooms.isEmpty)
                }
            }
            .sheet(isPresented: $showManage) {
                ManageHousesView(blueprint: $blueprint) { issues = blueprint.validate() }
            }
            .onAppear { issues = blueprint.validate() }
        }
    }

    // MARK: The plan

    /// The whole house, scaled to fit. Deliberately not scrollable: a drag has to
    /// mean "draw", and a scroll view's own pan would be forever fighting it for the
    /// same gesture. Seeing the whole plan at once is what a plan is for anyway.
    private var plan: some View {
        GeometryReader { geo in
            let cell = max(4, min(geo.size.width / CGFloat(blueprint.width),
                                  geo.size.height / CGFloat(blueprint.height)))
            let w = CGFloat(blueprint.width) * cell
            let h = CGFloat(blueprint.height) * cell
            Canvas { context, _ in draw(&context, cell: cell) }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .gesture(paintGesture(cell: cell))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func draw(_ context: inout GraphicsContext, cell: CGFloat) {
        func box(_ c: Int, _ r: Int, _ w: Int = 1, _ h: Int = 1, inset: CGFloat = 0) -> CGRect {
            CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                   width: CGFloat(w) * cell, height: CGFloat(h) * cell)
                .insetBy(dx: inset, dy: inset)
        }

        // Everything that isn't a room: the walls, in effect, since a wall in this
        // game is simply a cell that isn't floor.
        context.fill(Path(box(0, 0, blueprint.width, blueprint.height)),
                     with: .color(Color(white: 0.30)))

        for room in blueprint.rooms {
            let r = box(room.col, room.row, room.cols, room.rows)
            context.fill(Path(r), with: .color(Color(uiColor: room.kind.floorColor(.light))))
            context.stroke(Path(r), with: .color(.black.opacity(0.35)), lineWidth: 1)
        }

        // Doors sit on the wall line, so they're drawn as floor in the room's own
        // colour would be invisible — a warm notch reads as an opening.
        for door in blueprint.doors {
            context.fill(Path(box(door.col, door.row)),
                         with: .color(Color(red: 0.95, green: 0.72, blue: 0.35)))
        }

        // Mounds under the rugs and furniture, and shaded per tier so a two-step hill
        // reads as two steps rather than as one blob.
        for tier in blueprint.hills.sorted(by: { $0.level < $1.level }) {
            let r = box(tier.col, tier.row, tier.cols, tier.rows)
            context.fill(Path(r), with: .color(Color(red: 0.36, green: 0.44, blue: 0.26)
                                                  .opacity(0.30 + 0.22 * Double(tier.level))))
            context.stroke(Path(r), with: .color(.black.opacity(0.4)), lineWidth: 1)
        }

        for rug in blueprint.rugs {
            context.fill(Path(roundedRect: box(rug.col, rug.row, rug.cols, rug.rows, inset: cell * 0.1),
                              cornerSize: CGSize(width: cell * 0.3, height: cell * 0.3)),
                         with: .color(Color(red: 0.85, green: 0.62, blue: 0.25).opacity(0.55)))
        }

        for piece in blueprint.furniture {
            let r = box(piece.col, piece.row, piece.cols, piece.rows, inset: max(0.5, cell * 0.06))
            let path = Path(roundedRect: r, cornerSize: CGSize(width: cell * 0.25, height: cell * 0.25))
            context.fill(path, with: .color(Color(uiColor: piece.kind.color)))
            // Solid pieces are walls with leaves on. A dashed edge says "you can't
            // get on this one" without needing a legend.
            context.stroke(path,
                           with: .color(.black.opacity(0.5)),
                           style: piece.kind.isClimbable
                               ? StrokeStyle(lineWidth: 1)
                               : StrokeStyle(lineWidth: 1.4, dash: [2, 2]))
        }

        for toy in blueprint.toys {
            marker(&context, at: toy, cell: cell,
                   fill: Color(red: 0.86, green: 0.30, blue: 0.42), glyph: nil)
        }
        if let s = blueprint.start {
            marker(&context, at: s, cell: cell, fill: .white, glyph: "S")
        }
        if let b = blueprint.basket {
            marker(&context, at: b, cell: cell,
                   fill: Color(red: 0.55, green: 0.38, blue: 0.20), glyph: "B")
        }
        if let l = blueprint.litterbox {
            marker(&context, at: l, cell: cell,
                   fill: Color(red: 0.35, green: 0.55, blue: 0.85), glyph: "L")
        }

        // What the current drag would commit, so a rectangle can be sized before
        // it's let go of.
        if let a = dragFrom, let b = dragTo {
            let lo = GridCell(col: min(a.col, b.col), row: min(a.row, b.row))
            let cols = abs(a.col - b.col) + 1, rows = abs(a.row - b.row) + 1
            let r = tool.isRectangular ? box(lo.col, lo.row, cols, rows) : box(a.col, a.row)
            context.stroke(Path(r), with: .color(.accentColor), lineWidth: 2)
            context.fill(Path(r), with: .color(.accentColor.opacity(0.2)))
        }
    }

    private func marker(_ context: inout GraphicsContext, at gridCell: GridCell,
                        cell s: CGFloat, fill: Color, glyph: String?) {
        let r = CGRect(x: CGFloat(gridCell.col) * s, y: CGFloat(gridCell.row) * s,
                       width: s, height: s)
            .insetBy(dx: s * 0.14, dy: s * 0.14)
        context.fill(Path(ellipseIn: r), with: .color(fill))
        context.stroke(Path(ellipseIn: r), with: .color(.black.opacity(0.55)), lineWidth: 1)
        // Only worth a letter when there's room for one to be legible.
        if let glyph, s >= 11 {
            var resolved = context.resolve(
                Text(glyph).font(.system(size: s * 0.6, weight: .bold)))
            resolved.shading = .color(.black)
            context.draw(resolved, at: CGPoint(x: r.midX, y: r.midY))
        }
    }

    // MARK: Painting

    private func paintGesture(cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragFrom = gridCell(value.startLocation, cell: cell)
                dragTo = gridCell(value.location, cell: cell)
            }
            .onEnded { _ in
                if let a = dragFrom, let b = dragTo { commit(from: a, to: b) }
                dragFrom = nil
                dragTo = nil
            }
    }

    private func gridCell(_ point: CGPoint, cell: CGFloat) -> GridCell {
        GridCell(col: min(max(Int(point.x / cell), 0), blueprint.width - 1),
                 row: min(max(Int(point.y / cell), 0), blueprint.height - 1))
    }

    private func commit(from a: GridCell, to b: GridCell) {
        let lo = GridCell(col: min(a.col, b.col), row: min(a.row, b.row))
        let cols = abs(a.col - b.col) + 1
        let rows = abs(a.row - b.row) + 1

        switch tool {
        case .room(let kind):
            // A room needs to be a room. A stray tap would otherwise leave a 1×1
            // cupboard behind every time the palette was mis-hit.
            guard cols >= 3, rows >= 3 else { return }
            let room = HouseBlueprint.Room(kind: kind, col: lo.col, row: lo.row,
                                           cols: cols, rows: rows)
            guard room.isInside(width: blueprint.width, height: blueprint.height),
                  !blueprint.rooms.contains(where: { $0.overlaps(room) }) else { return }
            edit { $0.rooms.append(room) }

        case .rug:
            let w = max(cols, 2), h = max(rows, 2)
            edit { $0.rugs.append(HouseBlueprint.RugSpec(col: lo.col, row: lo.row,
                                                         cols: w, rows: h,
                                                         variant: ($0.rugs.count) % 3)) }

        case .hill:
            // Drawing a mound inside one that's already there raises the next step, so a
            // taller hill is built up the way it's climbed — and capped where the
            // generator caps itself.
            let under = blueprint.hills
                .filter { $0.cells.contains(GridCell(col: a.col, row: a.row)) }
                .map(\.level).max() ?? 0
            guard under < Level.maxTerraceLevel else { return }
            let w = max(cols, 3), h = max(rows, 3)
            edit { $0.hills.append(HouseBlueprint.TerraceSpec(col: lo.col, row: lo.row,
                                                             cols: w, rows: h,
                                                             level: under + 1)) }

        case .furniture(let kind):
            let prints = kind.footprints
            let print = prints[rotated && prints.count > 1 ? 1 : 0]
            let piece = HouseBlueprint.Piece(kind: kind, col: a.col, row: a.row,
                                             cols: print.cols, rows: print.rows)
            edit { $0.furniture.append(piece) }

        case .door:
            edit {
                if let i = $0.doors.firstIndex(of: a) { $0.doors.remove(at: i) }
                else { $0.doors.append(a) }
            }

        case .start:     edit { $0.start = a }
        case .basket:    edit { $0.basket = a }
        case .litterbox: edit { $0.litterbox = a }

        case .toy:
            edit {
                if let i = $0.toys.firstIndex(of: a) { $0.toys.remove(at: i) }
                else { $0.toys.append(a) }
            }

        case .erase:
            let area = Set((0..<rows).flatMap { r in
                (0..<cols).map { GridCell(col: lo.col + $0, row: lo.row + r) }
            })
            edit { bp in
                // Contents first, and a room only if the swipe found nothing in it.
                // Otherwise clearing a sofa off a rug would take the room with it.
                let before = (bp.furniture.count, bp.rugs.count, bp.toys.count,
                              bp.doors.count, bp.hills.count)
                bp.furniture.removeAll { $0.cells.contains(where: area.contains) }
                bp.rugs.removeAll { $0.cells.contains(where: area.contains) }
                bp.hills.removeAll { $0.cells.contains(where: area.contains) }
                bp.toys.removeAll(where: area.contains)
                bp.doors.removeAll(where: area.contains)
                if let s = bp.start, area.contains(s) { bp.start = nil }
                if let s = bp.basket, area.contains(s) { bp.basket = nil }
                if let s = bp.litterbox, area.contains(s) { bp.litterbox = nil }
                let after = (bp.furniture.count, bp.rugs.count, bp.toys.count,
                             bp.doors.count, bp.hills.count)
                if before == after {
                    bp.rooms.removeAll { $0.cells.contains(where: area.contains) }
                }
            }
        }
    }

    /// One edit: snapshot for undo, mutate, re-validate.
    private func edit(_ change: (inout HouseBlueprint) -> Void) {
        undoStack.append(blueprint)
        if undoStack.count > 30 { undoStack.removeFirst() }
        change(&blueprint)
        issues = blueprint.validate()
    }

    // MARK: Chrome

    @ViewBuilder
    private var issueBar: some View {
        if let first = issues.first {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(first)
                    .font(.footnote)
                    .lineLimit(2)
                if issues.count > 1 {
                    Spacer(minLength: 8)
                    Text("+\(issues.count - 1)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.12))
        }
    }

    private var palette: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $group) {
                    ForEach(PaletteGroup.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if case .furniture = tool {
                    Button {
                        rotated.toggle()
                    } label: {
                        Image(systemName: "rotate.right")
                            .symbolVariant(rotated ? .fill : .none)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    tool = .erase
                } label: {
                    Image(systemName: BuilderTool.erase.systemImage)
                }
                .buttonStyle(.bordered)
                .tint(tool == .erase ? .red : nil)
            }
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tools(in: group)) { chip($0) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .padding(.top, 8)
        .background(.bar)
    }

    private func tools(in group: PaletteGroup) -> [BuilderTool] {
        switch group {
        case .rooms:
            return Environment.allCases.map { .room($0) }
        case .furniture:
            // Ordered by room, so the palette reads the way the house does.
            return Environment.allCases
                .flatMap(\.furnitureKinds)
                .reduce(into: [FurnitureKind]()) { if !$0.contains($1) { $0.append($1) } }
                .map { .furniture($0) }
        case .things:
            return [.start, .basket, .litterbox, .toy, .rug, .hill, .door]
        }
    }

    private func chip(_ item: BuilderTool) -> some View {
        let selected = tool == item
        return Button {
            tool = item
        } label: {
            HStack(spacing: 5) {
                Image(systemName: item.systemImage)
                    .font(.caption)
                    .foregroundStyle(swatch(item) ?? .primary)
                Text(item.title)
                    .font(.footnote.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : nil)
    }

    /// The colour this tool draws with, so the palette matches the plan.
    private func swatch(_ item: BuilderTool) -> Color? {
        switch item {
        case .room(let kind):      return Color(uiColor: kind.floorColor(.light))
        case .furniture(let kind): return Color(uiColor: kind.color)
        default:                   return nil
        }
    }
}

/// The house's name and size, and the shelf of saved houses.
private struct ManageHousesView: View {
    @Binding var blueprint: HouseBlueprint
    var onChange: () -> Void
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var saved: [HouseBlueprint] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("This house") {
                    TextField("Name", text: $blueprint.name)
                    Stepper("Width \(blueprint.width)",
                            value: $blueprint.width, in: 12...120)
                    Stepper("Height \(blueprint.height)",
                            value: $blueprint.height, in: 12...120)
                    Button("Save") {
                        HouseLibrary.save(blueprint)
                        saved = HouseLibrary.load()
                    }
                    Button("Save as a copy") {
                        var copy = blueprint
                        copy.id = UUID()
                        copy.name += " copy"
                        HouseLibrary.save(copy)
                        saved = HouseLibrary.load()
                    }
                }

                Section("Saved houses") {
                    if saved.isEmpty {
                        Text("Nothing saved yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(saved) { house in
                        Button {
                            blueprint = house
                            onChange()
                            dismiss()
                        } label: {
                            HStack {
                                Text(house.name)
                                Spacer()
                                Text("\(house.rooms.count) rooms")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { HouseLibrary.delete(saved[i]) }
                        saved = HouseLibrary.load()
                    }
                }

                Section("Blank") {
                    Button("Start a blank house") {
                        blueprint = HouseBlueprint(name: "New house",
                                                   width: blueprint.width,
                                                   height: blueprint.height)
                        onChange()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Houses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onChange(); dismiss() }
                }
            }
            .onAppear { saved = HouseLibrary.load() }
        }
    }
}

#endif   // !os(tvOS) — the builder is touch-driven
