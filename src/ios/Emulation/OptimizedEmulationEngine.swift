import Foundation
import MetalKit
import os.log

final class OptimizedEmulationEngine: NSObject, ObservableObject {
    @Published var isRunning: Bool = false
    @Published var frameRate: Int = 0
    @Published var currentGame: String = ""

    private var cpu: WiiUCPU?
    private var memory: MemoryManager?
    private var currentRomPath: String = ""
    private var emulationThread: Thread?
    private var shouldStop: Bool = false

    private var frameCount: Int = 0
    private var lastFPSUpdate: Date = Date()
    private var frameBuffer: MTLTexture?

    private let gpuContext: OptimizedGPUContext
    private let logger = Logger(subsystem: "com.brandon.cemuemulator", category: "EmulationEngine")

    private var instructionCache: [UInt32: UInt32] = [:]
    private let cacheLock = NSLock()

    override init() {
        self.gpuContext = OptimizedGPUContext()
        super.init()
    }

    /// Returns false if the ROM file couldn't be read (missing, unreadable,
    /// permissions). Callers must check this before calling `startEmulation()`
    /// - previously this always "succeeded" from the caller's point of view,
    /// so a bad ROM silently ran the emulation loop against zeroed memory
    /// while the UI reported .running.
    @discardableResult
    func loadROM(_ romPath: String) -> Bool {
        currentRomPath = romPath
        currentGame = URL(fileURLWithPath: romPath).lastPathComponent

        memory = MemoryManager(size: 0x1000_0000)
        cpu = WiiUCPU(memory: memory!)

        let loaded = loadROMFile(romPath)
        if loaded {
            logger.info("ROM loaded: \(self.currentGame)")
        }
        return loaded
    }

    @discardableResult
    private func loadROMFile(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            logger.error("Failed to load ROM: \(path)")
            return false
        }

        guard let memory = memory else { return false }

        let romData = [UInt8](data)
        let chunkSize = 1_000_000

        for (index, chunk) in romData.chunked(into: chunkSize).enumerated() {
            let offset = UInt32(index * chunkSize)
            memory.writeBuffer(0x80004000 + offset, buffer: Array(chunk))
        }

        logger.info("ROM data loaded: \(romData.count) bytes")
        return true
    }

    func startEmulation() {
        guard memory != nil, cpu != nil else { return }

        isRunning = true
        shouldStop = false

        emulationThread = Thread { [weak self] in
            self?.optimizedEmulationLoop()
        }
        emulationThread?.qualityOfService = .userInteractive
        emulationThread?.start()
    }

    func stopEmulation() {
        shouldStop = true
        isRunning = false
        emulationThread?.cancel()
        instructionCache.removeAll(keepingCapacity: true)
    }

    private func optimizedEmulationLoop() {
        let targetCyclesPerFrame = 68_000_000 / 60
        var accumulatedCycles: UInt64 = 0

        while !shouldStop && isRunning {
            autoreleasepool {
                guard let cpu = cpu else { return }

                let frameCycles = cpu.runUntilFrame()
                accumulatedCycles += UInt64(frameCycles)

                DispatchQueue.main.async { [weak self] in
                    self?.updateFrameRate()
                    self?.renderFrame()
                }

                let sleepTime = max(1, 16_667 - Int(accumulatedCycles * 1000 / 68_000_000))
                usleep(UInt32(sleepTime))

                if accumulatedCycles >= UInt64(targetCyclesPerFrame) {
                    accumulatedCycles = 0
                }
            }
        }
    }

    private func updateFrameRate() {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSUpdate)

        if elapsed >= 1.0 {
            frameRate = frameCount
            frameCount = 0
            lastFPSUpdate = now
            logger.debug("FPS: \(self.frameRate)")
        }
    }

    private func renderFrame() {
        guard let memory = memory else { return }
        frameBuffer = gpuContext.renderOptimizedFrame(memory: memory)
    }

    func getFrameTexture() -> MTLTexture? {
        return frameBuffer
    }

    func getState() -> CPUState? {
        return cpu?.getState()
    }

    /// Optional JIT compilation status (loops compiled, whether it's enabled).
    var jitStats: JITStats? {
        cpu?.jitStats
    }

    func setJITEnabled(_ enabled: Bool) {
        cpu?.setJITEnabled(enabled)
    }

    func reset() {
        stopEmulation()
        memory?.reset()
        frameCount = 0
        frameRate = 0
    }

    deinit {
        stopEmulation()
    }
}

class OptimizedGPUContext {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private var renderPipelineState: MTLRenderPipelineState?
    private var framePool: [MTLTexture] = []
    private var currentFrameIndex = 0
    private let framePoolSize = 3

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.commandQueue?.label = "CemuEmulatorCommandQueue"

        setupFramePool()
        setupRenderPipeline()
    }

    private func setupFramePool() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1280,
            height: 720,
            mipmapped: false
        )
        // .private, not .memoryless: these textures are read back by
        // MetalRenderer in a *separate* render pass on a later frame, and
        // memoryless textures only exist for the duration of the pass that
        // wrote them (no host- or later-pass-readable backing store).
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private

        for _ in 0..<framePoolSize {
            if let texture = device.makeTexture(descriptor: descriptor) {
                framePool.append(texture)
            }
        }
    }

    private func setupRenderPipeline() {
        let library = device.makeDefaultLibrary()

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library?.makeFunction(name: "screenVertex")
        pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "screenFragment")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Error creating render pipeline: \(error)")
        }
    }

    func renderOptimizedFrame(memory: MemoryManager) -> MTLTexture? {
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return nil }

        let texture = framePool[currentFrameIndex]
        currentFrameIndex = (currentFrameIndex + 1) % framePoolSize

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }

        if let pipelineState = renderPipelineState {
            renderEncoder.setRenderPipelineState(pipelineState)
        }
        renderEncoder.setFrontFacing(.counterClockwise)
        renderEncoder.setCullMode(.back)

        let quad: [Float] = [
            -1.0, 1.0, 0, 1,
            -1.0, -1.0, 0, 0,
            1.0, -1.0, 1, 0,
            -1.0, 1.0, 0, 1,
            1.0, -1.0, 1, 0,
            1.0, 1.0, 1, 1
        ]

        guard let vertexBuffer = device.makeBuffer(bytes: quad, length: MemoryLayout<Float>.size * quad.count, options: .storageModeShared) else {
            return nil
        }

        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        renderEncoder.endEncoding()

        commandBuffer.commit()

        return texture
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
