//
//  GameView.swift
//  Qoob
//
//  The SwiftUI ⇄ rendering boundary. It picks a concrete GameRenderer
//  (RealityKitRenderer today), embeds that renderer's ARView, injects the
//  renderer into the engine-agnostic GameController, and adds swipe-to-roll
//  gestures.
//
//  To try a different engine later, construct a different GameRenderer here;
//  nothing else in the app changes.
//

import SwiftUI
import RealityKit

struct GameView: UIViewRepresentable {
    @ObservedObject var viewModel: GameViewModel

    func makeUIView(context: Context) -> ARView {
        let renderer = RealityKitRenderer()
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

    func updateUIView(_ uiView: ARView, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject {
        var renderer: RealityKitRenderer?
        var controller: GameController?

        // Swipe up = roll away (up the board); mapping mirrors the camera view.
        @objc func swipeUp()    { controller?.requestRoll(.forward) }
        @objc func swipeDown()  { controller?.requestRoll(.back) }
        @objc func swipeLeft()  { controller?.requestRoll(.left) }
        @objc func swipeRight() { controller?.requestRoll(.right) }
    }
}
