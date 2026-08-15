//
//  SettingsView.swift
//  Qoob
//
//  The Settings sheet: control scheme and feedback preferences. Presented from
//  the HUD gear button. Uses a standard SwiftUI Form, which adopts Liquid Glass
//  automatically on iOS 26+.
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: GameViewModel
    // Fully qualified: the game core defines its own `Environment` enum, which
    // would otherwise shadow SwiftUI's `@Environment` property wrapper.
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Controls") {
                    Toggle("Tilt to roll", isOn: $viewModel.tiltEnabled)
                        .disabled(viewModel.motionUnavailable)
                    Toggle("On-screen buttons", isOn: $viewModel.showButtons)
                    if viewModel.showButtons {
                        Picker("Layout", selection: $viewModel.controlLayout) {
                            ForEach(ControlLayout.allCases) { layout in
                                Text(layout.displayName).tag(layout)
                            }
                        }
                    }
                    if viewModel.motionUnavailable {
                        Text("Tilt needs a real device with a motion sensor.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Swipe anywhere always works.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Feedback") {
                    Toggle("Sound", isOn: $viewModel.soundEnabled)
                    Toggle("Haptics", isOn: $viewModel.hapticsEnabled)
                }

                Section("Appearance") {
                    Picker("Cat", selection: $viewModel.catStyle) {
                        ForEach(CatStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    Picker("Carpet mode", selection: $viewModel.roomAppearance) {
                        ForEach(RoomAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                    Picker("Floor", selection: $viewModel.floorTheme) {
                        ForEach(FloorTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    Picker("Board angle", selection: $viewModel.boardTilt) {
                        ForEach(BoardTilt.allCases) { tilt in
                            Text(tilt.displayName).tag(tilt)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: GameViewModel())
}
