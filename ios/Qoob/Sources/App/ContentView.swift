//
//  ContentView.swift
//  Qoob
//
//  The SwiftUI HUD layered over the game: a centred clock, a tappable score
//  bubble that expands to a points breakdown, the fading mantra, an on-screen
//  D-pad, a settings gear, and the start overlay. There is no time limit — the
//  game is meditative.
//
//  Control schemes live in Settings (any combination):
//    • Tilt   — gyroscope (real device only)
//    • Buttons — the on-screen D-pad
//    • Swipe  — always active, handled in GameView
//

import SwiftUI

private extension View {
    /// Tinted Liquid Glass on iOS 26+, falling back to a frosted material on
    /// older systems. Pass `nil` for a plain (untinted) glass, and set
    /// `interactive` on controls so the glass reacts to touch.
    @ViewBuilder
    func tintedGlass(_ tint: Color?, in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            let glass: Glass = {
                let base = tint.map { Glass.regular.tint($0) } ?? .regular
                return interactive ? base.interactive() : base
            }()
            glassEffect(glass, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// The system's interactive Liquid Glass button styling (iOS 26+), tinted,
    /// with a frosted-material fallback on older systems. Applied to a `Button`,
    /// this gives the authentic press-flex and specular response that a manual
    /// `glassEffect` on the label does not.
    @ViewBuilder
    func liquidGlassButton(tint: Color?, prominent: Bool, in fallbackShape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                // Prominent glass fills with the tint, so the colour reads
                // clearly — the plain `.glass` variant barely tints its body.
                buttonStyle(.glassProminent).tint(tint)
            } else {
                buttonStyle(.glass)
            }
        } else {
            buttonStyle(.plain).background(.ultraThinMaterial, in: fallbackShape)
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = GameViewModel()
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ZStack {
                GameView(viewModel: viewModel)
                    .ignoresSafeArea()

                if viewModel.phase == .playing {
                    VStack(spacing: 10) {
                        toysBadge
                        Spacer()
                        if viewModel.showButtons {
                            controls
                                .padding(.bottom, 12)
                        }
                    }
                    .padding()

                    scoreBreakdownPanel

                    mantraView
                        .offset(y: -80)
                        .allowsHitTesting(false)
                }

                overlay
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Score, clock and gear all live in the bar, so the top of the
                // screen is one aligned row. The score used to be an overlay pinned
                // below the safe area, which left it sitting on its own line under
                // the other two.
                if viewModel.phase == .playing {
                    ToolbarItem(placement: .topBarLeading) {
                        scoreBubble
                    }
                    ToolbarItem(placement: .principal) {
                        Text(timeString(viewModel.elapsed))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .onChange(of: viewModel.floorTheme) { _, theme in
            viewModel.controller?.setFloorTheme(theme)
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
            updateRunState(scenePhase: phase, settingsShown: viewModel.showSettings)
        }
        .onChange(of: viewModel.showSettings) { _, shown in
            updateRunState(scenePhase: scenePhase, settingsShown: shown)
        }
    }

    private func updateRunState(scenePhase phase: ScenePhase, settingsShown: Bool) {
        guard let controller = viewModel.controller else { return }
        if phase == .active && !settingsShown {
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
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.95, green: 0.82, blue: 0.35))
                Text("\(viewModel.score)")
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
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
            if viewModel.toysPushed > 0 {
                breakdownRow("Toys ×\(viewModel.toysPushed)", value: viewModel.scoreToys)
            }
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    /// Optional "toys to push" bonus indicator.
    @ViewBuilder
    private var toysBadge: some View {
        if viewModel.itemsRemaining > 0 {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color(red: 0.86, green: 0.30, blue: 0.42))
                Text("\(viewModel.itemsRemaining) toy\(viewModel.itemsRemaining == 1 ? "" : "s") to push (+150)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .tintedGlass(nil, in: Capsule())
            .padding(.top, 6)
        }
    }

    // MARK: - D-pad

    @ViewBuilder
    private var controls: some View {
        switch viewModel.controlLayout {
        case .dpadCenter, .dpadLeft, .dpadRight:
            dPad
        case .splitThumbs:
            splitThumbControls
        case .corners:
            cornerControls
        }
    }

    /// The classic joined cross, aligned per the chosen preset.
    private var dPad: some View {
        VStack(spacing: 10) {
            dirButton(.forward, "chevron.up")
            HStack(spacing: 64) {
                dirButton(.left, "chevron.left")
                dirButton(.right, "chevron.right")
            }
            dirButton(.back, "chevron.down")
        }
        .frame(maxWidth: .infinity,
               alignment: Alignment(horizontal: viewModel.controlLayout.alignment,
                                    vertical: .center))
        .padding(.horizontal, viewModel.controlLayout == .dpadCenter ? 0 : 20)
    }

    /// Left/right under the left thumb, forward/back under the right — so neither
    /// hand has to reach across the board.
    private var splitThumbControls: some View {
        HStack {
            HStack(spacing: 14) {
                dirButton(.left, "chevron.left")
                dirButton(.right, "chevron.right")
            }
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                dirButton(.forward, "chevron.up")
                dirButton(.back, "chevron.down")
            }
        }
        .padding(.horizontal, 8)
    }

    /// Four separate buttons pushed out to the edges, leaving the centre of the
    /// board clear.
    private var cornerControls: some View {
        VStack(spacing: 18) {
            HStack {
                dirButton(.left, "chevron.left")
                Spacer()
                dirButton(.forward, "chevron.up")
            }
            HStack {
                dirButton(.back, "chevron.down")
                Spacer()
                dirButton(.right, "chevron.right")
            }
        }
        .padding(.horizontal, 8)
    }

    private func dirButton(_ direction: RollDirection, _ icon: String) -> some View {
        Button(action: { viewModel.roll(direction) }) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
        }
        // Neutral (untinted) Liquid Glass — no accent colour.
        .liquidGlassButton(tint: nil, prominent: false, in: Circle())
    }

    // MARK: - Mantra

    private var mantraView: some View {
        Text(viewModel.mantra)
            .font(.system(size: 30, weight: .light, design: .serif))
            .italic()
            .foregroundStyle(.primary)
            .opacity(viewModel.showMantra ? 0.95 : 0)
            .shadow(color: .black.opacity(0.5), radius: 8)
    }

    // MARK: - Overlays

    @ViewBuilder
    private var overlay: some View {
        switch viewModel.phase {
        case .ready:
            panel(title: "Qoob",
                  subtitle: "Roll the cat so the pictured side lands\nface-down on each glowing tile.",
                  button: "Begin")
        case .playing:
            EmptyView()
        }
    }

    private func panel(title: String, subtitle: String, button: String) -> some View {
        VStack(spacing: 22) {
            if !viewModel.environmentName.isEmpty {
                Text(viewModel.environmentName.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.motionUnavailable {
                Text("No motion sensor detected — use the buttons or swipes.\n(Tilt needs a real device.)")
                    .font(.system(size: 13))
                    .foregroundColor(.yellow.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            Button(action: { viewModel.startTapped() }) {
                Text(button)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.primary))
            }
        }
        .padding(36)
        .tintedGlass(nil, in: RoundedRectangle(cornerRadius: 28))
        .padding(32)
    }

    // MARK: - Helpers

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    ContentView()
}
