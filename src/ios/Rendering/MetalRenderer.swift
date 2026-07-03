import Foundation
import MetalKit

class MetalRenderer: NSObject, MTKViewDelegate {
    var gameManager: Any?

    override init() {
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        guard let device = view.device,
              let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        renderEncoder.endEncoding()

        if let metalDrawable = drawable as? CAMetalDrawable {
            commandBuffer.present(metalDrawable)
        }

        commandBuffer.commit()
    }
}
