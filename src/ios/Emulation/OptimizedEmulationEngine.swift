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

    private let stateRequestLock = NSLock()
    private var pendingCaptureCompletion: ((CPUState?, Data?) -> Void)?
    private var pendingRestore: (cpuState: CPUState, memoryData: Data, completion: (Bool) -> Void)?

    override init() {
        self.gpuContext = OptimizedGPUContext()
        super.init()
    }

    /// Captures a save state (CPU registers + full memory snapshot). Safe to
    /// call from any thread: the actual read happens on the emulation thread
    /// itself, serviced at the top of its next loop iteration, so it can
    /// never race an in-flight instruction's register/memory mutations.
    /// Fails immediately (nil, nil) if nothing is running.
    func captureState(completion: @escaping (CPUState?, Data?) -> Void) {
        guard isRunning else {
            DispatchQueue.main.async { completion(nil, nil) }
            return
        }
        stateRequestLock.lock()
        pendingCaptureCompletion = completion
        stateRequestLock.unlock()
    }

    /// Restores a previously captured save state. Same thread-safety
    /// approach as `captureState`. `completion` reports false if `memoryData`
    /// doesn't match this engine's memory size (e.g. a save state from a
    /// differently-configured build) or if nothing is running to restore into.
    func restoreState(cpuState: CPUState, memoryData: Data, completion: @escaping (Bool) -> Void) {
        guard isRunning else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        stateRequestLock.lock()
        pendingRestore = (cpuState, memoryData, completion)
        stateRequestLock.unlock()
    }

    private func servicePendingStateRequests() {
        stateRequestLock.lock()
        let captureCompletion = pendingCaptureCompletion
        let restore = pendingRestore
        pendingCaptureCompletion = nil
        pendingRestore = nil
        stateRequestLock.unlock()

        if let captureCompletion {
            let cpuSnapshot = cpu?.getState()
            let memorySnapshot = memory?.snapshotRawBytes()
            DispatchQueue.main.async { captureCompletion(cpuSnapshot, memorySnapshot) }
        }

        if let restore {
            let memoryRestored = memory?.restoreRawBytes(restore.memoryData) ?? false
            if memoryRestored {
                cpu?.restoreState(restore.cpuState)
            }
            DispatchQueue.main.async { restore.completion(memoryRestored) }
        }
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
                servicePendingStateRequests()

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

    /// Produces this frame's texture. There's no real Wii U GPU command
    /// translation implemented yet - `memory` isn't read here at all - so
    /// this currently just clears to black and hands the texture back.
    ///
    /// This used to *also* issue a full-screen quad draw through
    /// `screenFragment`, a shader that samples `colorTexture` /
    /// `textureSampler` - but nothing ever bound a texture or sampler to the
    /// encoder before that draw call. Sampling an unbound texture argument is
    /// undefined behavior in Metal; on-device that resolved to a consistent
    /// green/black noise pattern smeared across the whole frame every time a
    /// game launched (the "green screen of death"). Since there's no real
    /// frame content to texture that quad with anyway, the fix is simply not
    /// issuing the draw - the clear pass alone produces a well-defined black
    /// frame, which is what this stub is actually capable of rendering today.
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
