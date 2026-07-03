import XCTest
@testable import CemuEmulator

final class CPUCoreTests: XCTestCase {
    /// PowerPC instruction encoding is (primaryOpcode << 26) | fields.
    /// Kept local to the test so it doesn't depend on PPCInstruction's
    /// convenience accessors (this constructs the raw word by hand to
    /// double-check the decode logic those accessors implement).
    private func encode(primary: UInt32, rt: UInt32 = 0, ra: UInt32 = 0, simm: UInt32 = 0) -> UInt32 {
        (primary << 26) | (rt << 21) | (ra << 16) | (simm & 0xFFFF)
    }

    func testExecuteADDILoadsImmediateIntoRegister() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        // ADDI r3, r0, 5 (primary opcode 0x0E)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 3, ra: 0, simm: 5))

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().registers[3], 5)
        XCTAssertEqual(cpu.getState().pc, 0x8000_4004, "a non-branch instruction should simply advance pc by 4")
    }

    func testExecuteADDIAddsToExistingRegisterValue() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        // Two ADDIs back to back: r3 = 0 + 5, then r4 = r3 + 10.
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 3, ra: 0, simm: 5))
        memory.write32(0x8000_4004, encode(primary: 0x0E, rt: 4, ra: 3, simm: 10))

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().registers[4], 15)
    }

    /// Regression test: executeInstruction() used to unconditionally do
    /// `pc = pc &+ 4` after every instruction, silently overwriting the pc
    /// that executeB()'s branch handler had just set - taken branches never
    /// actually took effect. This locks the fix in place.
    ///
    /// Note: executeB() computes its target as `li << 2` with nothing else
    /// added, and li is only a 22-bit field - so this stub can only ever
    /// branch within the low 16MB (0x0..<0x100_0000), never into the real
    /// Wii U 0x8000_0000+ range. That's a real limitation of this simplified
    /// interpreter, not something to work around here - the test picks a
    /// target inside that reachable window and asserts against the exact
    /// value the code actually computes.
    func testUnconditionalBranchActuallyChangesProgramCounter() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        let target: UInt32 = 0x1000
        let li = (target >> 2) & 0x3FFFFF
        memory.write32(0x8000_4000, (0x12 << 26) | li) // B (primary opcode 0x12)

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().pc, target, "a taken branch's target must stick, not get clobbered by pc+4")
    }

    /// Regression test for the bug this session's memory rebasing fixed:
    /// STW/LWZ must round-trip through the *real* backing store at the CPU's
    /// actual effective address, not silently no-op because the address
    /// space and the backing array's size didn't line up.
    ///
    /// r1 is built via ADDIS+ADDI (as real PowerPC code would) to land
    /// squarely inside the manager's [0x8000_0000, 0x9000_0000) window -
    /// ADDI alone only carries a 16-bit immediate, nowhere near enough to
    /// reach an address in that range in one instruction.
    func testStoreWordThenLoadWordRoundTrips() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0F, rt: 1, ra: 0, simm: 0x8000)) // r1 = 0x8000_0000
        memory.write32(0x8000_4004, encode(primary: 0x0E, rt: 1, ra: 1, simm: 0x1000)) // r1 += 0x1000
        memory.write32(0x8000_4008, encode(primary: 0x0E, rt: 2, ra: 0, simm: 42))     // r2 = 42
        memory.write32(0x8000_400C, encode(primary: 0x28, rt: 2, ra: 1, simm: 0))      // STW r2, 0(r1)
        memory.write32(0x8000_4010, encode(primary: 0x20, rt: 3, ra: 1, simm: 0))      // LWZ r3, 0(r1)

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        for _ in 0..<5 {
            _ = cpu.executeInstruction()
        }

        XCTAssertEqual(cpu.getState().registers[1], 0x8000_1000)
        XCTAssertEqual(cpu.getState().registers[3], 42, "a value stored via STW must be readable back via LWZ at the same address")
    }

    /// evaluateBranchCondition() treats BO bit 0x10 as "branch always" (a
    /// simplification of the real PowerPC BO decode table, consistent with
    /// this being a stub interpreter). BCx's bo/bi/bd fields share the exact
    /// same bit positions as ADDI's rt/ra/simm, so the existing encode()
    /// helper works unchanged - only the opcode and the taken/not-taken bit
    /// pattern differ.
    ///
    /// Unlike B (executeB), which sets pc to an *absolute* address, BC
    /// (executeBCx) adds its displacement to the *current* pc - PC-relative,
    /// matching real PowerPC BC semantics. Verified by reading executeBCx's
    /// source directly rather than assumed from the B test's shape.
    func testConditionalBranchTakenAdvancesToTarget() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        let startPC: UInt32 = 0x8000_4000
        let offset: UInt32 = 0x2000
        let bd = (offset >> 2) & 0xFFFF
        memory.write32(startPC, encode(primary: 0x10, rt: 0x14, ra: 0, simm: bd)) // BC, bo=0x14 (taken)

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().pc, startPC &+ offset, "a taken BC branch adds its offset to the current pc")
    }

    func testConditionalBranchNotTakenFallsThrough() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        let bd: UInt32 = (0x2000 >> 2) & 0xFFFF
        memory.write32(0x8000_4000, encode(primary: 0x10, rt: 0x04, ra: 0, simm: bd)) // BC, bo=0x04 (not taken)

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().pc, 0x8000_4004, "an untaken conditional branch must just fall through to pc+4")
    }

    func testGetStateThenRestoreStateRoundTrips() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 5, ra: 0, simm: 99)) // r5 = 99

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()
        let snapshot = cpu.getState()

        // Mutate further so restoring is actually observable.
        memory.write32(0x8000_4004, encode(primary: 0x0E, rt: 5, ra: 0, simm: 1))
        _ = cpu.executeInstruction()
        XCTAssertEqual(cpu.getState().registers[5], 1)

        XCTAssertTrue(cpu.restoreState(snapshot))
        XCTAssertEqual(cpu.getState().registers[5], 99)
        XCTAssertEqual(cpu.getState().pc, snapshot.pc)
    }

    /// Regression test for a real crash risk: restoreState() used to assign
    /// state.registers/state.fpRegisters straight into the CPU with no
    /// length check. A save state is arbitrary data loaded from disk (a
    /// partial write, disk corruption, a hand-edited or future-format file)
    /// - every execute...() handler indexes registers[Int(rt)] with rt up to
    /// 31 straight from the decoded instruction, so accepting a short array
    /// here would turn a bad save file into an array-index-out-of-bounds
    /// crash the next time any instruction touched a high-numbered register.
    func testRestoreStateRejectsMalformedRegisterCount() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 5, ra: 0, simm: 99)) // r5 = 99

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()

        let malformed = CPUState(
            pc: 0x8000_4000,
            lr: 0,
            ctr: 0,
            cr: 0,
            registers: Array(repeating: 0, count: 10), // too short - should be 32
            fpRegisters: Array(repeating: 0.0, count: 32),
            cycleCount: 0,
            instructionCount: 0
        )

        XCTAssertFalse(cpu.restoreState(malformed))
        XCTAssertEqual(cpu.getState().registers[5], 99, "a rejected restore must leave the CPU's existing state untouched")
        XCTAssertEqual(cpu.getState().registers.count, 32, "the register array itself must never shrink below 32")
    }
}
