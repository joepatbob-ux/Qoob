//
//  ContentView.swift
//  Qoob
//
//  The SwiftUI HUD layered over the game: a centred clock, a tappable score
//  bubble that expands to a points breakdown, the fading mantra, an on-screen
//  D-pad, a settings gear, and the start overlay. There is no time limit — the
//  game is meditative.
//
//  Control schemes (the on-screen pad is toggled in Settings; the rest are always on):
//    • Pad        — the on-screen circle pad or arrows, hold to keep rolling
//    • Swipe      — always active, handled in GameView
//    • Controller — a game pad, a TV remote or a keyboard (see ControllerInput)
//

import SwiftUI

// The Liquid Glass helper (`tintedGlass`) and the controls themselves live in
// GameControls.swift, which the HUD shares with them.

struct ContentView: View {
    @StateObject private var viewModel = GameViewModel()
    @SwiftUI.Environment(\.scenePhase) private var scenePhase
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    /// Drives the control sizes: an iPad (or a resized window on the Mac) gets the
    /// roomier set, a phone the compact one.
    @SwiftUI.Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Where each control sat when its current placement drag began, keyed by
    /// knob. Empty except while a control is being moved.
    @State private var dragOrigins: [String: CGPoint] = [:]
    /// Covers the screen until the first house is built and ready to play.
    @State private var showingSplash = true

    var body: some View {
        NavigationStack {
            ZStack {
                GameView(viewModel: viewModel)
                    .ignoresSafeArea()

                if viewModel.phase == .playing {
                    // The on-screen controls are touch-only, and tvOS has no touch
                    // — not even a `DragGesture` — so there they don't exist at all.
                    // An Apple TV plays with the remote or a game controller.
                    #if !os(tvOS)
                    if viewModel.arrangingControls {
                        arrangeShield
                    }
                    #endif

                    VStack(spacing: 10) {
                        toysBadge
                        #if !os(tvOS)
                        if viewModel.arrangingControls {
                            arrangeBanner
                        }
                        #endif
                        Spacer()
                        #if !os(tvOS)
                        if viewModel.showButtons {
                            controls
                                .padding(.bottom, 12)
                        }
                        #endif
                    }
                    .padding()

                    #if !os(tvOS)
                    // Free placement needs the whole play area, not the slot at
                    // the bottom of the HUD stack.
                    if viewModel.showButtons && viewModel.controlLayout == .custom {
                        placedControls
                    }
                    #endif

                    scoreBreakdownPanel

                    mantraView
                        .offset(y: -80)
                        .allowsHitTesting(false)
                }

                overlay

                if showingSplash { splash }
            }
            // Straight into the game: a splash while the first house is built, then it
            // fades and you're playing. There used to be a card here with the title, the
            // instructions and a Begin button — a modal in front of a game that needs no
            // setting up.
            //
            // The wait isn't padding. The room is shaped to the viewport's aspect ratio
            // when it's generated, and on the first pass the render view hasn't been laid
            // out yet, so `viewportAspect` would still be its portrait-phone default —
            // every iPad and Mac window would get a room shaped for a phone.
            .task {
                guard showingSplash else { return }
                try? await Task.sleep(for: .milliseconds(400))
                // Built behind the splash, so the room is already there when it lifts.
                viewModel.startTapped()
                // A short beat after that, so the splash doesn't snap away the instant
                // the build finishes. It doesn't need to be long: `present` itself costs
                // around 1.3s warm and nearer 5s cold — first run has every procedural
                // floor texture to draw and every model to parse — and the splash is
                // there to cover exactly that.
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.easeOut(duration: 0.5)) { showingSplash = false }
            }
            .environment(\.controlMetrics,
                         horizontalSizeClass == .regular ? .regular : .compact)
            .navigationTitle("")
            // Both of these are iOS/Catalyst-only: tvOS has no status bar and no
            // navigation-bar title mode to set.
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // Score, clock and gear all live in the bar, so the top of the
                // screen is one aligned row. The score used to be an overlay pinned
                // below the safe area, which left it sitting on its own line under
                // the other two.
                // Held back until the splash lifts. The toolbar belongs to the
                // NavigationStack, not to the ZStack the splash covers, so it drew on top
                // of it — and the game is already running behind the splash by then, so
                // the clock was ticking over the title.
                if viewModel.phase == .playing && !showingSplash {
                    ToolbarItem(placement: .topBarLeading) {
                        scoreBubble
                    }
                    ToolbarItem(placement: .principal) {
                        Text(timeString(viewModel.elapsed))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                if !showingSplash {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
        }
        #if !os(tvOS)
        .statusBarHidden(true)
        #endif
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
        }
        // The builder gets the whole screen — it's a plan of a house that's bigger
        // than the window, and a sheet's grabber would eat the top of it. Opened from
        // Settings, which dismisses itself first.
        #if !os(tvOS)
        .fullScreenCover(isPresented: $viewModel.showBuilder) {
            LevelBuilderView(viewModel: viewModel,
                             blueprint: viewModel.controller?.currentBlueprint()
                                 ?? HouseBlueprint())
        }
        #endif
        .onChange(of: viewModel.floorTheme) { _, theme in
            viewModel.controller?.setFloorTheme(theme)
        }
        .onChange(of: viewModel.catStyle) { _, style in
            viewModel.controller?.setCatStyle(style)
        }
        .onChange(of: viewModel.roomAppearance) { _, appearance in
            viewModel.controller?.setRoomAppearance(appearance)
        }
        .onChange(of: viewModel.boardTilt) { _, tilt in
            viewModel.controller?.setBoardTilt(tilt)
        }
        .onChange(of: viewModel.soundEnabled) { _, enabled in
            viewModel.controller?.setSoundEnabled(enabled)
        }
        // Hand the frame loop, motion feed, soundscape and clock back to the
        // system whenever the board isn't the player's focus: off screen, or
        // behind the Settings sheet (where a held tilt would otherwise keep
        // rolling Qoob out of sight).
        .onChange(of: scenePhase) { _, phase in
            updateRunState(scenePhase: phase, covered: isCovered)
        }
        .onChange(of: viewModel.showSettings) { _, _ in
            updateRunState(scenePhase: scenePhase, covered: isCovered)
        }
        .onChange(of: viewModel.showBuilder) { _, _ in
            updateRunState(scenePhase: scenePhase, covered: isCovered)
        }
    }

    /// Whether something is in front of the board. Either sheet counts: a held tilt
    /// behind the level builder would roll Qoob out of sight just as it would behind
    /// Settings.
    private var isCovered: Bool { viewModel.showSettings || viewModel.showBuilder }

    private func updateRunState(scenePhase phase: ScenePhase, covered: Bool) {
        guard let controller = viewModel.controller else { return }
        // A control still under a finger when a sheet opens or the app goes to the
        // background never gets its release, and a held direction would keep rolling
        // Qoob out of sight. Dropped whenever play stops.
        if phase != .active || covered { viewModel.releaseControls() }
        if phase == .active && !covered {
            controller.resume()
        } else {
            controller.pause()
        }
    }

    // MARK: - Score bubble

    /// The score, as a bar-height pill. Tapping it toggles the breakdown panel,
    /// which is drawn as an overlay just under the bar (see `scoreBreakdownPanel`).
    ///
    /// A popover was tried first, since it points back at the pill. On iPhone it
    /// placed itself over the bar regardless of `arrowEdge`, covering the pill it
    /// belongs to and clipping the clock beside it.
    private var scoreBubble: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.showScoreBreakdown.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(Self.hudFont(12))
                    .foregroundColor(Color(red: 0.95, green: 0.82, blue: 0.35))
                Text("\(viewModel.score)")
                    .font(Self.hudFont(15, .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    // The score grows without limit and a toolbar item won't widen for
                    // it. One line, and sized to its own content: with horizontal
                    // compression allowed it truncated to "…" the moment the score
                    // reached three digits, which it now does on the first toy — the
                    // scale factor couldn't shrink far enough to fit.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: true, vertical: true)
            }
            // Breathing room inside the pill. The glass background sizes itself to this
            // label, so without it the capsule sat hard against the star on one side and
            // the digits on the other — legible, but it read as cramped rather than as a
            // deliberate pill. Asymmetric on purpose: the star carries its own optical
            // margin, the digits don't.
            .padding(.leading, 10)
            .padding(.trailing, 12)
            // The label is 18pt tall, well under the 44pt minimum for a touch target,
            // and it opens the score breakdown — so it was a real control that was hard
            // to hit.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The breakdown, hanging under the bar on the leading side so it lines up with
    /// the pill that opens it.
    @ViewBuilder
    private var scoreBreakdownPanel: some View {
        if viewModel.showScoreBreakdown {
            scoreBreakdown
                .tintedGlass(nil, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The itemised points, one row per source (zero rows hidden).
    private var scoreBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            breakdownRow("Matches", value: viewModel.scoreMatches)
            if viewModel.scoreStreak > 0 {
                breakdownRow("Streak bonus", value: viewModel.scoreStreak)
            }
            // Always shown, and as progress rather than a bare count. Returning toys to
            // the basket is the standing objective of a house, so the breakdown is where
            // you'd look to see how it's going — hiding the row until the first delivery
            // meant it was absent exactly when you most wanted to know the total.
            //
            // `toysPushed` only increments on `collected`, so despite the name it counts
            // toys actually *returned*, not shoves. The label now says so.
            breakdownRow("Toys returned \(viewModel.toysPushed)/\(viewModel.toysTotal)",
                         value: viewModel.scoreToys)
            if viewModel.knockoffs > 0 {
                breakdownRow("Knock-offs ×\(viewModel.knockoffs)", value: viewModel.scoreKnockoffs)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func breakdownRow(_ label: String, value: Int) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(Self.hudFont(13, .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text("\(value)")
                .font(Self.hudFont(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    /// Optional "toys to push" bonus indicator.
    ///
    /// Hidden while the score breakdown is open. The breakdown hangs under the bar on the
    /// leading side and reaches across this badge, and both are translucent glass — so the
    /// two overlapped and the badge's text bled through the panel. Hiding rather than
    /// moving because the breakdown now carries the same figure as "Toys returned n/total",
    /// which makes the badge redundant at exactly the moment it's in the way.
    @ViewBuilder
    private var toysBadge: some View {
        if viewModel.itemsRemaining > 0 && !viewModel.showScoreBreakdown {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(Self.hudFont(12))
                    .foregroundColor(Color(red: 0.86, green: 0.30, blue: 0.42))
                Text("\(viewModel.itemsRemaining) toy\(viewModel.itemsRemaining == 1 ? "" : "s") for the basket (+150)")
                    .font(Self.hudFont(13, .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .tintedGlass(nil, in: Capsule())
            .padding(.top, 6)
        }
    }

    // MARK: - Controls

    // Everything from here to the end of the free-placement section is touch-only,
    // so none of it is compiled for tvOS (`DragGesture` doesn't exist there).
    #if !os(tvOS)

    /// The preset arrangements. `.custom` is drawn by `placedControls` instead,
    /// since it needs the whole play area.
    @ViewBuilder
    private var controls: some View {
        switch viewModel.controlLayout {
        case .dpadCenter, .dpadLeft, .dpadRight:
            singlePad
        case .splitThumbs:
            splitThumbControls
        case .corners:
            cornerControls
        case .custom:
            EmptyView()
        }
    }

    /// One pad — the circle, or the joined arrow cross — aligned per the chosen
    /// preset.
    private var singlePad: some View {
        Group {
            switch viewModel.controlStyle {
            case .wheel:
                DirectionWheel { viewModel.hold($0) }
            case .arrows:
                arrowCross
            }
        }
        .frame(maxWidth: .infinity,
               alignment: Alignment(horizontal: viewModel.controlLayout.alignment,
                                    vertical: .center))
        .padding(.horizontal, viewModel.controlLayout == .dpadCenter ? 0 : 20)
    }

    /// The classic joined cross.
    private var arrowCross: some View {
        VStack(spacing: 6) {
            arrow(.forward)
            HStack(spacing: 44) {
                arrow(.left)
                arrow(.right)
            }
            arrow(.back)
        }
    }

    /// Left/right under the left thumb, forward/back under the right — so neither
    /// hand has to reach across the board.
    private var splitThumbControls: some View {
        HStack {
            HStack(spacing: 12) {
                arrow(.left)
                arrow(.right)
            }
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                arrow(.forward)
                arrow(.back)
            }
        }
        .padding(.horizontal, 8)
    }

    /// Four separate buttons pushed out to the edges, leaving the centre of the
    /// board clear.
    private var cornerControls: some View {
        VStack(spacing: 14) {
            HStack {
                arrow(.left)
                Spacer()
                arrow(.forward)
            }
            HStack {
                arrow(.back)
                Spacer()
                arrow(.right)
            }
        }
        .padding(.horizontal, 8)
    }

    private func arrow(_ direction: RollDirection) -> some View {
        ArrowButton(direction: direction) { viewModel.hold($0) }
    }

    // MARK: - Free placement

    /// Every control where the player dropped it. Positions are fractions of the
    /// play area, so they survive rotation and follow the player between devices.
    private var placedControls: some View {
        GeometryReader { geo in
            ForEach(viewModel.activeKnobs) { knob in
                knobView(knob)
                    .overlay {
                        if viewModel.arrangingControls {
                            Circle()
                                .strokeBorder(.primary.opacity(0.5),
                                              style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                .padding(-6)
                        }
                    }
                    .position(x: viewModel.position(of: knob).x * geo.size.width,
                              y: viewModel.position(of: knob).y * geo.size.height)
                    // While arranging, a drag places the control; the knob itself
                    // stops answering touches (see `knobView`), so nothing rolls
                    // while it's being moved.
                    .gesture(viewModel.arrangingControls ? placementGesture(knob, in: geo.size) : nil)
            }
        }
    }

    @ViewBuilder
    private func knobView(_ knob: ControlKnob) -> some View {
        if let direction = knob.direction {
            ArrowButton(direction: direction,
                        isActive: !viewModel.arrangingControls) { viewModel.hold($0) }
        } else {
            DirectionWheel(isActive: !viewModel.arrangingControls) { viewModel.hold($0) }
        }
    }

    /// Moves a control by the drag's translation from where it started. Reading
    /// the touch location instead would need a named coordinate space, whose
    /// non-deprecated form is iOS 17+.
    private func placementGesture(_ knob: ControlKnob, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                let start = dragOrigins[knob.rawValue] ?? viewModel.position(of: knob)
                dragOrigins[knob.rawValue] = start
                viewModel.setPosition(
                    CGPoint(x: start.x + value.translation.width / size.width,
                            y: start.y + value.translation.height / size.height),
                    for: knob)
            }
            .onEnded { _ in dragOrigins[knob.rawValue] = nil }
    }

    /// While controls are being placed, a drag that misses one would otherwise
    /// reach the board's swipe recogniser and roll Qoob. This catches it. Not
    /// quite `.clear`, which some hit-testing paths skip.
    private var arrangeShield: some View {
        Color.black.opacity(0.001)
            .ignoresSafeArea()
    }

    /// The arrange-mode banner: what to do, and the way out.
    private var arrangeBanner: some View {
        HStack(spacing: 12) {
            Text("Drag each control where you like")
                .font(Self.hudFont(13, .medium))
                .foregroundStyle(.secondary)
            Button("Reset") { viewModel.resetControlPositions() }
                .font(Self.hudFont(13, .semibold))
            Button("Done") { viewModel.arrangingControls = false }
                .font(Self.hudFont(13, .bold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .tintedGlass(nil, in: Capsule())
    }

    #endif   // !os(tvOS) — end of the touch-only controls

    // MARK: - Mantra

    private var mantraView: some View {
        Text(viewModel.mantra)
            .font(Self.hudFont(30, .light, design: .serif))
            .italic()
            .foregroundStyle(.primary)
            .opacity(viewModel.showMantra ? 0.95 : 0)
            .shadow(color: .black.opacity(0.5), radius: 8)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlay: some View {
        // Nothing in front of the game. `.ready` only lasts as long as the splash, which
        // is drawn over the top of everything anyway.
        EmptyView()
    }

    /// The splash: the wordmark on the room's own backdrop colour.
    ///
    /// Opaque, because the game view behind it is mid-build — and matched to the
    /// backdrop the first room will use, so the fade lands on the same colour it
    /// started from rather than cutting between two.
    private var splash: some View {
        ZStack {
            Color(uiColor: Environment.livingRoom.background(splashAppearance))
                .ignoresSafeArea()
            Image(Self.wordmarkAsset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 340)
                .padding(48)
                .accessibilityLabel("Qoob")
                .accessibilityAddTraits(.isHeader)
        }
        .transition(.opacity)
    }

    /// Light or dark for the splash, from the same setting the rooms use.
    private var splashAppearance: Appearance {
        switch viewModel.roomAppearance {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return colorScheme == .dark ? .dark : .light
        }
    }


    // MARK: - Helpers

    /// HUD type is sized in points for a phone held in the hand. A television is
    /// across the room, where 13pt is unreadable — tvOS's own body style is 29pt
    /// against iOS's 17pt, which is where this ratio comes from. Every HUD size
    /// goes through `hudFont`, so on iPhone, iPad and the Mac nothing changes.
    private static let hudScale: CGFloat = {
        #if os(tvOS)
        return 1.8
        #else
        return 1
        #endif
    }()

    /// The title wordmark in the asset catalogue.
    private static let wordmarkAsset = "QoobWordmark"

    private static func hudFont(_ size: CGFloat,
                                _ weight: Font.Weight = .regular,
                                design: Font.Design = .default) -> Font {
        .system(size: size * hudScale, weight: weight, design: design)
    }



    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    ContentView()
}
