//
//  ScoreMenuView.swift
//  Qoob
//
//  Sheet opened from the score chip: this-run stats, bests, settings, controls.
//

import SwiftUI

struct ScoreMenuView: View {
    @ObservedObject var viewModel: GameViewModel
    @Environment(\.dismiss) private var dismiss

    private let ink = Color(red: 0.22, green: 0.20, blue: 0.18)
    private let inkMuted = Color(red: 0.45, green: 0.42, blue: 0.38)
    private let cream = Color(red: 0.97, green: 0.94, blue: 0.90)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    nowSection
                    bestsSection
                    controlsSection
                    settingsSection
                }
                .padding(24)
            }
            .background(cream.ignoresSafeArea())
            .navigationTitle("score")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(ink)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("this run")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statCard("score", "\(viewModel.score)")
                statCard("time", timeString(viewModel.elapsed))
                statCard("left", "\(viewModel.tilesRemaining)")
                statCard("moves", "\(viewModel.movesThisLevel)")
            }
            if let avg = viewModel.avgMovesBetweenScoresThisLevel {
                footnote("avg \(formatAvg(avg)) moves between scores this level")
            } else if viewModel.mergesThisLevel > 0 {
                footnote("\(viewModel.mergesThisLevel) score\(viewModel.mergesThisLevel == 1 ? "" : "s") so far")
            }
        }
    }

    private var bestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("bests")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                statCard("best time", viewModel.bestTime.map(timeString) ?? "—")
                statCard("best score", viewModel.bestScore > 0 ? "\(viewModel.bestScore)" : "—")
                statCard("fewest moves", viewModel.bestMoves.map(String.init) ?? "—")
                statCard("levels", "\(viewModel.levelsCleared)")
            }
            if let avg = viewModel.averageMovesBetweenScores {
                footnote("avg \(formatAvg(avg)) moves between scores overall")
            }
            if let avgT = viewModel.averageTimePerLevel {
                footnote("avg \(timeString(avgT)) per cleared level")
            }
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("controls")
            Text("On-screen buttons")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(ink)
            VStack(spacing: 8) {
                ForEach(ButtonLayout.allCases) { layout in
                    layoutRow(layout)
                }
            }
            footnote("Swipe always works. Tilt is below.")
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("settings")
            Toggle(isOn: Binding(
                get: { viewModel.tiltEnabled },
                set: { viewModel.setTiltEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tilt to roll")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(ink)
                    Text(viewModel.motionUnavailable
                         ? "Unavailable on this device"
                         : "Hold the phone — tilt rolls the cat")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(inkMuted)
                }
            }
            .tint(Color(red: 0.55, green: 0.68, blue: 0.55))
            .disabled(viewModel.motionUnavailable)
            .padding(14)
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(inkMuted)
            .tracking(1)
    }

    private func statCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(inkMuted)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func layoutRow(_ layout: ButtonLayout) -> some View {
        let selected = viewModel.buttonLayout == layout
        return Button {
            viewModel.setButtonLayout(layout)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(layout.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(layout.detail)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(inkMuted)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? Color(red: 0.55, green: 0.68, blue: 0.55) : ink.opacity(0.25))
            }
            .foregroundColor(ink)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.85 : 0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(ink.opacity(selected ? 0.12 : 0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .rounded))
            .foregroundColor(inkMuted)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func formatAvg(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}
