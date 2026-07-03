import Foundation
import MetalKit

/// Draws the emulator's rendered frame (from `GameManager.getFrameTexture()`)
/// onto the on-screen `MTKView`, letterboxed to preserve the Wii U's 16:9
/// aspect ratio inside whatever aspect ratio the device screen has.
final class MetalRenderer: NSObject, MTKViewDelegate {
    weak var gameManager: GameManager?

    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var commandQueue: MTLCommandQueue?

    override init() {
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device = view.device else { return }

        if pipelineState == nil {
            setupPipeline(device: device)
        }
        if commandQueue == nil {
            commandQueue = device.makeCommandQueue()
        }

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        if let pipelineState = pipelineState,
           let frameTexture = gameManager?.getFrameTexture() {
            renderEncoder.setRenderPipelineState(pipelineState)

            let quad = createLetterboxedQuad(
                viewSize: view.bounds.size,
                sourceWidth: frameTexture.width,
                sourceHeight: frameTexture.height
            )

            if let vertexBuffer = device.makeBuffer(bytes: quad, length: MemoryLayout<Float>.size * quad.count, options: .storageModeShared) {
                renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                renderEncoder.setFragmentTexture(frameTexture, index: 0)
                if let samplerState = samplerState {
                    renderEncoder.setFragmentSamplerState(samplerState, index: 0)
                }
                renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func setupPipeline(device: MTLDevice) {
        guard let library = device.makeDefaultLibrary() else { return }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: samplerDescriptor)
    }

    /// Builds a full-screen triangle-list quad (position.xy, texCoord.xy per
    /// vertex) scaled to preserve the source frame's aspect ratio within the
    /// view, matching `screenVertex`'s expected `VertexIn` layout.
    private func createLetterboxedQuad(viewSize: CGSize, sourceWidth: Int, sourceHeight: Int) -> [Float] {
        guard viewSize.width > 0, viewSize.height > 0, sourceWidth > 0, sourceHeight > 0 else {
            return [
                -1, 1, 0, 0,
                -1, -1, 0, 1,
                 1, -1, 1, 1,
                -1, 1, 0, 0,
                 1, -1, 1, 1,
                 1, 1, 1, 0
            ]
        }

        let viewAspect = Float(viewSize.width / viewSize.height)
        let sourceAspect = Float(sourceWidth) / Float(sourceHeight)

        var scaleX: Float = 1
        var scaleY: Float = 1
        if viewAspect > sourceAspect {
            scaleX = sourceAspect / viewAspect
        } else {
            scaleY = viewAspect / sourceAspect
        }

        return [
            -scaleX,  scaleY, 0, 0,
            -scaleX, -scaleY, 0, 1,
             scaleX, -scaleY, 1, 1,
            -scaleX,  scaleY, 0, 0,
             scaleX, -scaleY, 1, 1,
             scaleX,  scaleY, 1, 0
        ]
    }
}
