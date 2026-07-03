import Foundation

/// Backs the emulated address space with a single flat array, rebased to
/// `baseAddress` so real Wii U effective addresses (main RAM starts around
/// 0x8000_0000) don't require literally allocating a multi-gigabyte buffer.
///
/// Every accessor subtracts `baseAddress` before indexing into `memory` -
/// without this, a CPU whose PC starts at 0x8000_4000 against a 256MB backing
/// array would have every single read/write silently fail its bounds check
/// (addr way beyond memorySize) and be treated as reading/writing zero. That
/// was a real, previously-undiscovered bug: the emulated CPU never actually
/// fetched a byte of loaded ROM data, ever, because nothing rebased the
/// address space to match the backing store's actual size.
class MemoryManager {
    private var memory: [UInt8]
    private let memorySize: Int
    private let baseAddress: UInt32
    private let mmioHandlers: NSMutableDictionary

    init(size: Int = 0x2000_0000, baseAddress: UInt32 = 0x8000_0000) {
        self.memorySize = size
        self.baseAddress = baseAddress
        self.memory = Array(repeating: 0, count: size)
        self.mmioHandlers = NSMutableDictionary()
        setupMemoryMap()
    }

    private func setupMemoryMap() {
        let gpuBase = 0x0C00_0000
        let ioBase = 0x0D00_0000

        registerMMIOHandler(range: gpuBase..<(gpuBase + 0x200_0000), name: "GPU")
        registerMMIOHandler(range: ioBase..<(ioBase + 0x200_0000), name: "IO")
    }

    private func registerMMIOHandler(range: Range<Int>, name: String) {
        mmioHandlers[name] = MMIOHandler(range: range, name: name)
    }

    /// Rebased index into `memory`, or nil if `address` falls outside this
    /// manager's backing store.
    private func localOffset(_ address: UInt32) -> Int? {
        let offset = Int(address) - Int(baseAddress)
        return offset >= 0 ? offset : nil
    }

    func read8(_ address: UInt32) -> UInt8 {
        guard let addr = localOffset(address), addr < memorySize else { return 0 }
        return memory[addr]
    }

    func read16(_ address: UInt32) -> UInt16 {
        guard let addr = localOffset(address), addr < memorySize - 1 else { return 0 }
        let low = UInt16(memory[addr])
        let high = UInt16(memory[addr + 1])
        return (high << 8) | low
    }

    func read32(_ address: UInt32) -> UInt32 {
        guard let addr = localOffset(address), addr < memorySize - 3 else { return 0 }

        if let handler = findMMIOHandler(for: Int(address)) {
            return handler.read32(Int(address))
        }

        let b0 = UInt32(memory[addr])
        let b1 = UInt32(memory[addr + 1])
        let b2 = UInt32(memory[addr + 2])
        let b3 = UInt32(memory[addr + 3])
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }

    func read64(_ address: UInt32) -> UInt64 {
        guard let addr = localOffset(address), addr < memorySize - 7 else { return 0 }
        let low = read32(address)
        let high = read32(address &+ 4)
        return (UInt64(high) << 32) | UInt64(low)
    }

    func readBuffer(_ address: UInt32, length: Int) -> [UInt8] {
        guard let addr = localOffset(address), addr + length <= memorySize else { return [] }
        return Array(memory[addr..<(addr + length)])
    }

    func write8(_ address: UInt32, _ value: UInt8) {
        guard let addr = localOffset(address), addr < memorySize else { return }
        memory[addr] = value
    }

    func write16(_ address: UInt32, _ value: UInt16) {
        guard let addr = localOffset(address), addr + 1 < memorySize else { return }
        memory[addr] = UInt8(value & 0xFF)
        memory[addr + 1] = UInt8((value >> 8) & 0xFF)
    }

    func write32(_ address: UInt32, _ value: UInt32) {
        guard let addr = localOffset(address), addr + 3 < memorySize else { return }

        if let handler = findMMIOHandler(for: Int(address)) {
            handler.write32(Int(address), value)
            return
        }

        memory[addr] = UInt8(value & 0xFF)
        memory[addr + 1] = UInt8((value >> 8) & 0xFF)
        memory[addr + 2] = UInt8((value >> 16) & 0xFF)
        memory[addr + 3] = UInt8((value >> 24) & 0xFF)
    }

    func write64(_ address: UInt32, _ value: UInt64) {
        write32(address, UInt32(value & 0xFFFFFFFF))
        write32(address &+ 4, UInt32((value >> 32) & 0xFFFFFFFF))
    }

    func writeBuffer(_ address: UInt32, buffer: [UInt8]) {
        guard let addr = localOffset(address), addr + buffer.count <= memorySize else { return }
        memory.replaceSubrange(addr..<(addr + buffer.count), with: buffer)
    }

    private func findMMIOHandler(for address: Int) -> MMIOHandler? {
        for handler in mmioHandlers.allValues {
            if let h = handler as? MMIOHandler, h.range.contains(address) {
                return h
            }
        }
        return nil
    }

    func reset() {
        memory = Array(repeating: 0, count: memorySize)
    }

    func getMemorySize() -> Int {
        return memorySize
    }

    /// Raw snapshot of the entire backing store, for save states. The caller
    /// is expected to compress this before persisting it - a 256MB raw dump
    /// per save slot isn't reasonable, and in practice the buffer is mostly
    /// zeros (only the loaded ROM plus whatever the interpreter has actually
    /// touched is non-zero), so it compresses extremely well.
    func snapshotRawBytes() -> Data {
        Data(memory)
    }

    /// Restores a snapshot taken via `snapshotRawBytes()`. Returns false
    /// (and leaves memory untouched) if the byte count doesn't match this
    /// manager's size - a mismatch means the snapshot came from a
    /// differently-sized MemoryManager and restoring it would silently
    /// corrupt or truncate state.
    @discardableResult
    func restoreRawBytes(_ data: Data) -> Bool {
        guard data.count == memorySize else { return false }
        memory = [UInt8](data)
        return true
    }
}

class MMIOHandler {
    let range: Range<Int>
    let name: String

    init(range: Range<Int>, name: String) {
        self.range = range
        self.name = name
    }

    func read8(_ address: Int) -> UInt8 { 0 }
    func read16(_ address: Int) -> UInt16 { 0 }
    func read32(_ address: Int) -> UInt32 { 0 }

    func write8(_ address: Int, _ value: UInt8) {}
    func write16(_ address: Int, _ value: UInt16) {}
    func write32(_ address: Int, _ value: UInt32) {}
}
