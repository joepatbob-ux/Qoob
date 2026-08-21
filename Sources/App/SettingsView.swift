//
//  SettingsView.swift
//  Qoob
//
//  The Settings sheet: control scheme and feedback preferences, presented from the
//  HUD gear button. Uses standard SwiftUI containers, which adopt Liquid Glass
//  automatically on iOS 26+.
//
//  Its "Level builder…" button sets `showBuilder`; ContentView does the presenting,
//  full-screen. The builder itself lives in LevelBuilderView.swift.
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
                    // The on-screen controls are meaningless on an Apple TV — no touch
                    // screen — so the rows aren't shown rather than shown-but-dead.
                    #if !os(tvOS)
                    Toggle("On-screen controls", isOn: $viewModel.showButtons)
                    if viewModel.showButtons {
                        Picker("Style", selection: $viewModel.controlStyle) {
                            ForEach(ControlStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        Picker("Position", selection: $viewModel.controlLayout) {
                            ForEach(ControlLayout.allCases) { layout in
                                Text(layout.displayName).tag(layout)
                            }
                        }
                        Button("Move controls…") {
                            viewModel.beginArrangingControls()
                            dismiss()
                        }
                        if viewModel.controlLayout == .custom {
                            Button("Reset positions") {
                                viewModel.resetControlPositions()
                            }
                        }
                        Text(viewModel.controlStyle == .wheel
                             ? "The circle pad rolls whichever way you touch or slide toward. Hold to keep rolling."
                             : "Hold an arrow to keep rolling. Each one can be placed on its own.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text("Swipe anywhere always works.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #else
                    Text("Roll with the remote's directional pad, or a connected game controller.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #endif
                }

                Section("Feedback") {
                    Toggle("Sound", isOn: $viewModel.soundEnabled)
                    Toggle("Haptics", isOn: $viewModel.hapticsEnabled)
                }

                // Touch-only, so it isn't offered on an Apple TV.
                #if !os(tvOS)
                Section("Houses") {
                    // Same pattern as "Move controls…": set the flag and get out of
                    // the way, because one host view can't have two sheets up at once.
                    Button("Level builder…") {
                        viewModel.showBuilder = true
                        dismiss()
                    }
                    Text("Lay out your own house, or open the one you're in and change it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #endif

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
                    // No floor picker. The ground belongs to the room — carpet indoors,
                    // grass out in the yard — and letting it be chosen was what put
                    // grass in the living room and hardwood in the yard. `FloorTheme`
                    // stays as the renderer's internal switch, pinned to `.default`,
                    // which means "whatever this room's floor is".
                    Picker("Board angle", selection: $viewModel.boardTilt) {
                        ForEach(BoardTilt.allCases) { tilt in
                            Text(tilt.displayName).tag(tilt)
                        }
                    }
                }

                // Needs a location, which tvOS has no meaningful prompt flow for.
                #if !os(tvOS)
                Section("Weather") {
                    Toggle("Match local weather", isOn: $viewModel.weatherMatching)
                    Text("Rooms borrow the real sky: rain and snow out in the yard, warm light through the window at sunrise and sunset, and lightning in a storm. Uses your approximate location, never a precise one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if viewModel.weatherMatching {
                        weatherStatusFootnote
                        Link("Weather", destination: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!)
                            .font(.footnote)
                    }
                }
                #endif
            }
            .navigationTitle("Settings")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    #if !os(tvOS)
    /// What to say about weather status when there's nothing on screen to show
    /// it — a permission that was never granted, or a fetch that isn't working.
    @ViewBuilder
    private var weatherStatusFootnote: some View {
        switch viewModel.weatherStatus {
        case .denied:
            Text("Location is off for Qoob, so the usual light is being used. Turn it on in Settings › Privacy & Security › Location Services.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .unavailable:
            Text("The weather couldn't be reached, so the usual light is being used.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .off, .requesting, .live:
            EmptyView()
        }
    }
    #endif
}

#Preview {
    SettingsView(viewModel: GameViewModel())
}
