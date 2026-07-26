//
//  GameView.swift
//  TiltCube
//
//  The SwiftUI ⇄ rendering boundary. It picks a concrete GameRenderer
//  (SceneKitRenderer today), embeds that renderer's view, injects the renderer
//  into the engine-agnostic GameController, and adds swipe-to-roll gestures.
//
//  To try a different engine later, construct a different GameRenderer here;
//  nothing else in the app changes.
//

import SwiftUI
import SceneKit

struct GameView: UIViewRepresentable {
    @ObservedObject var viewModel: GameViewModel

    func makeUIView(context: Context) -> SCNView {
        let renderer = SceneKitRenderer()
        let controller = GameController(renderer: renderer, viewModel: viewModel)

        context.coordinator.renderer = renderer
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
            renderer.view.addGestureRecognizer(g)
        }
        return renderer.view
    }

    func updateUIView(_ uiView: SCNView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var renderer: SceneKitRenderer?
        var controller: GameController?

        // Swipe up = roll away (up the board); mapping mirrors the camera view.
        @objc func swipeUp()    { controller?.requestRoll(.forward) }
        @objc func swipeDown()  { controller?.requestRoll(.back) }
        @objc func swipeLeft()  { controller?.requestRoll(.left) }
        @objc func swipeRight() { controller?.requestRoll(.right) }
    }
}
