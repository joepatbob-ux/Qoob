//
//  GameView.swift
//  TiltCube
//
//  Hosts the SceneKit SCNView inside SwiftUI, wires it to a GameController, and
//  adds four-direction swipe gestures as a manual control scheme.
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

        // Swipe-to-roll (always available, independent of tilt / buttons).
        let directions: [(UISwipeGestureRecognizer.Direction, Selector)] = [
            (.up,    #selector(Coordinator.swipeUp)),
            (.down,  #selector(Coordinator.swipeDown)),
            (.left,  #selector(Coordinator.swipeLeft)),
            (.right, #selector(Coordinator.swipeRight))
        ]
        for (dir, sel) in directions {
            let g = UISwipeGestureRecognizer(target: context.coordinator, action: sel)
            g.direction = dir
            view.addGestureRecognizer(g)
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var controller: GameController?

        // Swipe up = roll away (up the board); mapping mirrors the camera view.
        @objc func swipeUp()    { controller?.requestRoll(.forward) }
        @objc func swipeDown()  { controller?.requestRoll(.back) }
        @objc func swipeLeft()  { controller?.requestRoll(.left) }
        @objc func swipeRight() { controller?.requestRoll(.right) }
    }
}
