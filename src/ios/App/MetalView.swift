import SwiftUI
import MetalKit

struct MetalViewIOS: UIViewRepresentable {
    var gameManager: GameManager

    func makeUIView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }
        let view = MTKView()
        view.device = device
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .black
        view.enableSetNeedsDisplay = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.gameManager = gameManager
    }

    func makeCoordinator() -> MetalRenderer {
        let renderer = MetalRenderer()
        renderer.gameManager = gameManager
        return renderer
    }
}
