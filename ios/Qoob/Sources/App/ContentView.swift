//
//  ContentView.swift
//  Qoob
//
//  The SwiftUI HUD layered over the SceneKit game: score, timer, tiles left,
//  the fading mantra, control toggles, an on-screen D-pad, and the
//  start / win / lose overlays.
//
//  Control schemes (any combination):
//    • Tilt   — gyroscope (real device only)
//    • Buttons — the on-screen D-pad
//    • Swipe  — always active, handled in GameView
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = GameViewModel()

    var body: some View {
        ZStack {
            GameView(viewModel: viewModel)
                .ignoresSafeArea()

            if viewModel.phase == .playing {
                VStack {
                    statusBar
                    controlChips
                    targetLegend
                    Spacer()
                    if viewModel.showButtons {
                        dPad
                            .padding(.bottom, 12)
                    }
                }
                .padding()

                mantraView
                    .offset(y: -80)
                    .allowsHitTesting(false)
            }

            overlay
        }
        .statusBarHidden(true)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack {
            pill(label: "SCORE", value: "\(viewModel.score)")
            Spacer()
            pill(label: "LEFT", value: "\(viewModel.tilesRemaining)")
            Spacer()
            pill(label: "TIME", value: timeString(viewModel.timeRemaining))
                .foregroundColor(viewModel.timeRemaining < 10 ? .red : .white)
        }
    }

    private func pill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.6)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Control toggles

    private var controlChips: some View {
        HStack(spacing: 10) {
            toggleChip(title: "Tilt",
                       on: viewModel.tiltEnabled,
                       enabled: !viewModel.motionUnavailable) {
                viewModel.tiltEnabled.toggle()
            }
            toggleChip(title: "Buttons",
                       on: viewModel.showButtons,
                       enabled: true) {
                viewModel.showButtons.toggle()
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private func toggleChip(title: String, on: Bool, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(on && enabled ? Color.green : Color.gray.opacity(0.6))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundColor(.white)
            .opacity(enabled ? 1 : 0.4)
        }
        .disabled(!enabled)
    }

    // MARK: - Target legend

    /// The distinct depictions still to be found this level.
    @ViewBuilder
    private var targetLegend: some View {
        if !viewModel.targetLegend.isEmpty {
            HStack(spacing: 8) {
                Text("FIND")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                ForEach(viewModel.targetLegend, id: \.self) { index in
                    Image(uiImage: SymbolTextures.icon(index))
                        .resizable()
                        .frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
        }
    }

    // MARK: - D-pad

    private var dPad: some View {
        VStack(spacing: 10) {
            dirButton(.forward, "chevron.up")
            HStack(spacing: 64) {
                dirButton(.left, "chevron.left")
                dirButton(.right, "chevron.right")
            }
            dirButton(.back, "chevron.down")
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func dirButton(_ direction: RollDirection, _ icon: String) -> some View {
        Button(action: { viewModel.roll(direction) }) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
                .frame(width: 62, height: 62)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundColor(.white)
        }
    }

    // MARK: - Mantra

    private var mantraView: some View {
        Text(viewModel.mantra)
            .font(.system(size: 30, weight: .light, design: .serif))
            .italic()
            .foregroundColor(.white)
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
        case .won:
            panel(title: "Level \(viewModel.levelIndex + 1) complete",
                  subtitle: "Score \(viewModel.score)\nBreathe. Ready for more?",
                  button: "Next level")
        case .lost:
            panel(title: "Time's up",
                  subtitle: "Score \(viewModel.score)\nNo rush — try again.",
                  button: "Retry")
        case .playing:
            EmptyView()
        }
    }

    private func panel(title: String, subtitle: String, button: String) -> some View {
        VStack(spacing: 22) {
            Text(title)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)

            controlPicker

            if viewModel.motionUnavailable {
                Text("No motion sensor detected — use the buttons or swipes.\n(Tilt needs a real device.)")
                    .font(.system(size: 13))
                    .foregroundColor(.yellow.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            Button(action: { viewModel.startTapped() }) {
                Text(button)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.white))
            }
        }
        .padding(36)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(32)
    }

    /// Control-scheme chooser shown on the menus.
    private var controlPicker: some View {
        VStack(spacing: 8) {
            Text("CONTROLS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            HStack(spacing: 10) {
                toggleChip(title: "Tilt",
                           on: viewModel.tiltEnabled,
                           enabled: !viewModel.motionUnavailable) {
                    viewModel.tiltEnabled.toggle()
                }
                toggleChip(title: "Buttons",
                           on: viewModel.showButtons,
                           enabled: true) {
                    viewModel.showButtons.toggle()
                }
            }
            Text("Swipe anywhere works too.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Helpers

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    ContentView()
}
