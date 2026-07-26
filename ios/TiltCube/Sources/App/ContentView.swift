//
//  ContentView.swift
//  TiltCube
//
//  The SwiftUI HUD layered over the SceneKit game: score, timer, tiles left,
//  the fading mantra, and the start / win / lose overlays.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = GameViewModel()

    var body: some View {
        ZStack {
            GameView(viewModel: viewModel)
                .ignoresSafeArea()

            // Top status bar
            VStack {
                if viewModel.phase == .playing {
                    statusBar
                    Spacer()
                    mantraView
                        .padding(.bottom, 60)
                }
            }
            .padding()

            overlay
        }
        .statusBarHidden(true)
    }

    // MARK: - HUD pieces

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

    private var mantraView: some View {
        Text(viewModel.mantra)
            .font(.system(size: 30, weight: .light, design: .serif))
            .italic()
            .foregroundColor(.white)
            .opacity(viewModel.showMantra ? 0.95 : 0)
            .shadow(color: .black.opacity(0.5), radius: 8)
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

    // MARK: - Overlays

    @ViewBuilder
    private var overlay: some View {
        switch viewModel.phase {
        case .ready:
            panel(title: "TiltCube",
                  subtitle: "Tilt your device to roll the cube.\nLand a matching face on each glowing tile.",
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
        VStack(spacing: 24) {
            Text(title)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(subtitle)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)

            if viewModel.motionUnavailable {
                Text("⚠︎ No motion sensor detected.\nRun on a real device to tilt-and-roll.")
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
        .padding(40)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(32)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    ContentView()
}
