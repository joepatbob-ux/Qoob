//
//  GameView.swift
//  TiltCube
//
//  Hosts the SceneKit SCNView inside SwiftUI and wires it to a GameController.
//

import SwiftUI
import SceneKit

struct GameView: UIViewRepresentable {
    @ObservedObject var viewModel: GameViewModel

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        let controller = GameController(view: view, viewModel: viewModel)
        context.coordinator.controller = controller
        viewModel.controller = controller
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var controller: GameController?
    }
}
