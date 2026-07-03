import XCTest
@testable import CemuEmulator

final class MemoryManagerTests: XCTestCase {
    func testWriteReadRoundTrip8() {
        let memory = MemoryManager(size: 0x1000, baseAddress: 0)
        memory.write8(0x20, 0xAB)
        XCTAssertEqual(memory.read8(0x20), 0xAB)
    }

    func testWriteReadRoundTrip16() {
        let memory = MemoryManager(size: 0x1000, baseAddress: 0)
        memory.write16(0x30, 0xBEEF)
        XCTAssertEqual(memory.read16(0x30), 0xBEEF)
    }

    func testWriteReadRoundTrip32() {
        let memory = MemoryManager(size: 0x1000, baseAddress: 0)
        memory.write32(0x10, 0xDEADBEEF)
        XCTAssertEqual(memory.read32(0x10), 0xDEADBEEF)
    }

    func testWriteReadRoundTrip64() {
        let memory = MemoryManager(size: 0x1000, baseAddress: 0)
        memory.write64(0x40, 0x0102030405060708)
        XCTAssertEqual(memory.read64(0x40), 0x0102030405060708)
    }

    func testWriteBufferReadBufferRoundTrip() {
        let memory = MemoryManager(size: 0x1000, baseAddress: 0)
        let bytes: [UInt8] = [1, 2, 3, 4, 5]
        memory.writeBuffer(0x50, buffer: bytes)
        XCTAssertEqual(memory.readBuffer(0x50, length: 5), bytes)
    }

    func testOutOfBoundsReadReturnsZeroInsteadOfCrashing() {
        let memory = MemoryManager(size: 0x100, baseAddress: 0)
        XCTAssertEqual(memory.read32(0xFFFF), 0)
        XCTAssertEqual(memory.read8(0xFFFF), 0)
    }

    func testOutOfBoundsWriteIsSilentlyIgnored() {
        let memory = MemoryManager(size: 0x100, baseAddress: 0)
        memory.write32(0xFFFF, 0xFFFFFFFF)
        XCTAssertEqual(memory.read32(0x0), 0, "an out-of-bounds write must not corrupt in-bounds memory")
    }

    func testResetZeroesMemory() {
        let memory = MemoryManager(size: 0x1000, baseAddress: 0)
        memory.write32(0x10, 0xDEADBEEF)
        memory.reset()
        XCTAssertEqual(memory.read32(0x10), 0)
    }

    /// Regression test for a real bug: WiiUCPU's pc starts at 0x8000_4000,
    /// but the production MemoryManager is only ~256MB. Before baseAddress
    /// rebasing existed, every access at that address range failed its
    /// bounds check silently - the emulated CPU never fetched a single real
    /// instruction from a loaded ROM, ever, because nothing translated the
    /// Wii U's effective address space down into the actually-allocated
    /// backing array.
    func testHighAddressesReachableWithMatchingBaseAddress() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        let wiiUEntryPoint: UInt32 = 0x8000_4000

        memory.write32(wiiUEntryPoint, 0xCAFEBABE)

        XCTAssertEqual(
            memory.read32(wiiUEntryPoint),
            0xCAFEBABE,
            "an address in the Wii U's real effective range must round-trip once baseAddress matches"
        )
    }

    func testAddressesBelowBaseAddressAreOutOfRange() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        // Below baseAddress - must not underflow/crash, must read as empty.
        XCTAssertEqual(memory.read32(0x1000), 0)
    }

    func testGetMemorySize() {
        let memory = MemoryManager(size: 0x2000, baseAddress: 0)
        XCTAssertEqual(memory.getMemorySize(), 0x2000)
    }
}
