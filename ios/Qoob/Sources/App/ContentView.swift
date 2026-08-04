//
//  ContentView.swift
//  Qoob
//
//  Minimal play HUD: tappable score opens stats / settings / controls.
//  On-screen buttons are D-pad or split edges (or off). Classic Soft styling.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = GameViewModel()

    private let ink = Color(red: 0.22, green: 0.20, blue: 0.18)
    private let inkMuted = Color(red: 0.45, green: 0.42, blue: 0.38)
    private let cream = Color(red: 0.97, green: 0.94, blue: 0.90)

    var body: some View {
        ZStack {
            GameView(viewModel: viewModel)
                .ignoresSafeArea()

            if viewModel.phase == .playing {
                playingHUD
            }

            overlay
        }
        .statusBarHidden(true)
        .sheet(isPresented: $viewModel.showScoreMenu) {
            ScoreMenuView(viewModel: viewModel)
        }
    }

    // MARK: - Playing HUD

    private var playingHUD: some View {
        ZStack {
            // Top: score chip + quiet seek legend
            VStack {
                HStack(alignment: .top) {
                    scoreChip
                    Spacer()
                    seekChip
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            mantraView
                .allowsHitTesting(false)

            // Controls
            switch viewModel.buttonLayout {
            case .off:
                EmptyView()
            case .dPad:
                VStack {
                    Spacer()
                    dPad
                        .padding(.bottom, 20)
                }
            case .split:
                splitPad
                    .padding(.horizontal, 10)
                    .padding(.vertical, 24)
            }
        }
    }

    private var scoreChip: some View {
        Button(action: { viewModel.openScoreMenu() }) {
            VStack(alignment: .leading, spacing: 2) {
                Text("score")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(inkMuted)
                Text("\(viewModel.score)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(cream.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ink.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var seekChip: some View {
        if let seek = viewModel.targetLegend.first {
            HStack(spacing: 8) {
                Image(uiImage: SymbolTextures.icon(viewModel.topFaceIndex))
                    .resizable()
                    .frame(width: 26, height: 26)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(inkMuted)
                Image(uiImage: SymbolTextures.icon(seek))
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(cream.opacity(0.88), in: Capsule())
            .overlay(Capsule().stroke(ink.opacity(0.06), lineWidth: 1))
        }
    }

    // MARK: - D-pad

    private var dPad: some View {
        VStack(spacing: 8) {
            dirButton(.forward, "chevron.up")
            HStack(spacing: 56) {
                dirButton(.left, "chevron.left")
                dirButton(.right, "chevron.right")
            }
            dirButton(.back, "chevron.down")
        }
    }

    // MARK: - Split (edge) controls

    private var splitPad: some View {
        VStack {
            dirButton(.forward, "chevron.up")
            Spacer()
            HStack {
                dirButton(.left, "chevron.left")
                Spacer()
                dirButton(.right, "chevron.right")
            }
            Spacer()
            dirButton(.back, "chevron.down")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dirButton(_ direction: RollDirection, _ icon: String) -> some View {
        Button(action: { viewModel.roll(direction) }) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 56, height: 56)
                .background(cream.opacity(0.92), in: Circle())
                .overlay(Circle().stroke(ink.opacity(0.08), lineWidth: 1))
                .foregroundColor(ink)
        }
    }

    // MARK: - Mantra

    private var mantraView: some View {
        Text(viewModel.mantra)
            .font(.system(size: 28, weight: .light, design: .serif))
            .italic()
            .foregroundColor(ink)
            .opacity(viewModel.showMantra ? 0.9 : 0)
            .shadow(color: cream.opacity(0.9), radius: 6)
            .offset(y: -40)
    }

    // MARK: - Start / win overlays

    @ViewBuilder
    private var overlay: some View {
        switch viewModel.phase {
        case .ready:
            panel(title: "Qoob",
                  subtitle: "A quiet rolling puzzle.\nMatch the cat’s top face to each soft pulse.\nTake your time — there’s no rush.",
                  button: "Begin")
        case .won:
            panel(title: "Level \(viewModel.levelIndex + 1)",
                  subtitle: wonSubtitle,
                  button: "Continue")
        case .playing:
            EmptyView()
        }
    }

    private func panel(title: String, subtitle: String, button: String) -> some View {
        VStack(spacing: 20) {
            if !viewModel.environmentName.isEmpty {
                Text(viewModel.environmentName.lowercased())
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .tracking(1.5)
                    .foregroundColor(inkMuted)
            }
            Text(title)
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .foregroundColor(ink)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundColor(inkMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)

            if viewModel.motionUnavailable && viewModel.phase == .ready {
                Text("No motion sensor — swipe or use on-screen buttons.\nOpen score → controls anytime.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(inkMuted)
                    .multilineTextAlignment(.center)
            }

            Button(action: { viewModel.startTapped() }) {
                Text(button)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(cream)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(ink))
            }
            .padding(.top, 4)
        }
        .padding(36)
        .background(cream.opacity(0.94), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(ink.opacity(0.06), lineWidth: 1)
        )
        .padding(32)
    }

    private var wonSubtitle: String {
        var lines = ["Score \(viewModel.score)"]
        if let last = viewModel.lastTime {
            lines.append("Time \(timeString(last)) · \(viewModel.movesThisLevel) moves")
        }
        if viewModel.isNewBest {
            lines.append("A new best time")
        } else if let best = viewModel.bestTime {
            lines.append("Best \(timeString(best))")
        }
        return lines.joined(separator: "\n")
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    ContentView()
}
