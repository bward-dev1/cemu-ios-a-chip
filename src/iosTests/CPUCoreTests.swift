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

    /// M-form: rlwinm/rlwimi (primary 21/20). rs occupies the same bit
    /// position as `rt` in D-form encode() above.
    private func encodeM(primary: UInt32, rs: UInt32, ra: UInt32, sh: UInt32, mb: UInt32, me: UInt32, rc: UInt32 = 0) -> UInt32 {
        (primary << 26) | (rs << 21) | (ra << 16) | (sh << 11) | (mb << 6) | (me << 1) | rc
    }

    /// X-form: opcode-31 register-register instructions, dispatched by
    /// extended opcode.
    private func encodeX(rt: UInt32, ra: UInt32, rb: UInt32, extOp: UInt32, rc: UInt32 = 0) -> UInt32 {
        (0x1F << 26) | (rt << 21) | (ra << 16) | (rb << 11) | (extOp << 1) | rc
    }

    /// XL-form: bclr/bcctr (primary 19).
    private func encodeXL(bo: UInt32, bi: UInt32, extOp: UInt32, lk: UInt32 = 0) -> UInt32 {
        (0x13 << 26) | (bo << 21) | (bi << 16) | (extOp << 1) | lk
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

    /// bo=0x0C means "branch if CR[BI] is set"; on a fresh CPU (cr=0, every
    /// flag clear) that condition is false, so the branch must not be
    /// taken. (Originally used bo=0x04 against evaluateBranchCondition's
    /// old "branch always"-only stub, which treated *every* non-"always" BO
    /// value as untaken regardless of BI/CR - that stub has since been
    /// replaced with real BO/BI decoding, under which bo=0x04 - "branch if
    /// CR bit is *clear*" - would actually branch here, since the bit
    /// genuinely is clear. Switched to bo=0x0C so this test still exercises
    /// a genuine "condition false, don't branch" case rather than one that
    /// only failed to branch by coincidence of the old stub's limitations.)
    func testConditionalBranchNotTakenFallsThrough() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        let bd: UInt32 = (0x2000 >> 2) & 0xFFFF
        memory.write32(0x8000_4000, encode(primary: 0x10, rt: 0x0C, ra: 0, simm: bd)) // BC, bo=0x0C bi=0, cr=0 -> condition false

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().pc, 0x8000_4004, "a conditional branch whose CR-bit condition isn't met must just fall through to pc+4")
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

    // MARK: - Newly-implemented opcodes (previously no-op stubs)

    /// rlwinm r4,r3,0,16,31 - a common real-world idiom (SH=0, MB=16, ME=31)
    /// that just masks to the low 16 bits, i.e. zero-extends a halfword.
    func testRLWINMMasksToLowHalfword() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0F, rt: 3, ra: 0, simm: 0xFFFF)) // r3 = 0xFFFF0000 (ADDIS r3,r0,0xFFFF)
        memory.write32(0x8000_4004, encode(primary: 0x0E, rt: 3, ra: 3, simm: 0x1234 & 0x7FFF)) // r3 |= low bits via ADDI (avoid sign-extend surprises)
        memory.write32(0x8000_4008, encodeM(primary: 0x15, rs: 3, ra: 4, sh: 0, mb: 16, me: 31)) // rlwinm r4,r3,0,16,31

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        for _ in 0..<3 { _ = cpu.executeInstruction() }

        let r3 = cpu.getState().registers[3]
        let r4 = cpu.getState().registers[4]
        XCTAssertEqual(r4, r3 & 0x0000_FFFF, "rlwinm SH=0,MB=16,ME=31 must mask to exactly the low 16 bits")
    }

    /// rlwinm r4,r3,8,24,31 - rotate left 8 then mask to low byte: this is
    /// the standard "extract byte 1" idiom, and specifically exercises SH!=0
    /// together with a mask, not just the SH=0 passthrough-mask case above.
    func testRLWINMRotatesThenMasks() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        // Build r3 = 0x12345678 via ADDIS + ORI (ADDI sign-extends, which
        // would corrupt a value with bit 15 set when loading the low half).
        memory.write32(0x8000_4000, encode(primary: 0x0F, rt: 3, ra: 0, simm: 0x1234)) // r3 = 0x12340000
        memory.write32(0x8000_4004, encode(primary: 0x18, rt: 3, ra: 3, simm: 0x5678)) // r3 |= 0x5678 (ORI)
        memory.write32(0x8000_4008, encodeM(primary: 0x15, rs: 3, ra: 4, sh: 8, mb: 24, me: 31)) // rlwinm r4,r3,8,24,31

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        for _ in 0..<3 { _ = cpu.executeInstruction() }

        XCTAssertEqual(cpu.getState().registers[3], 0x1234_5678)
        // rotl32(0x12345678, 8) = 0x34567812 (the top byte 0x12 wraps around
        // to the bottom), then masking to the low byte (24...31) keeps just
        // that relocated 0x12 - verified by hand against rotl32's actual
        // shift-based definition, not assumed from the mnemonic.
        XCTAssertEqual(cpu.getState().registers[4], 0x12, "rotating 0x12345678 left 8 then masking to the low byte must land the original top byte (0x12) there")
    }

    /// rlwimi must preserve rA's bits *outside* the mask, unlike rlwinm
    /// which zeroes them - this is the whole point of the "insert" form.
    func testRLWIMIPreservesBitsOutsideMask() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 3, ra: 0, simm: 0x000A)) // r3 = 0x0000000A (source to insert - ADDI, not ADDIS, so it lands in the low nibble)
        memory.write32(0x8000_4004, encode(primary: 0x0F, rt: 4, ra: 0, simm: 0x1234)) // r4 = 0x12340000
        memory.write32(0x8000_4008, encode(primary: 0x18, rt: 4, ra: 4, simm: 0x5678)) // r4 = 0x12345678 (destination, pre-populated)
        memory.write32(0x8000_400C, encodeM(primary: 0x14, rs: 3, ra: 4, sh: 0, mb: 28, me: 31)) // rlwimi r4,r3,0,28,31 - insert low nibble of r3 into r4

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        for _ in 0..<4 { _ = cpu.executeInstruction() }

        XCTAssertEqual(cpu.getState().registers[4], 0x1234_567A, "rlwimi must keep r4's high bits untouched and only overwrite the masked low nibble")
    }

    /// ori/andi. use the *opposite* rt/ra role from addi despite sharing the
    /// same D-form bit layout - this is the highest-risk place to
    /// accidentally swap source and destination, so it gets its own
    /// dedicated regression test rather than relying on the rlwinm tests
    /// above (which use ADDIS+ORI only as setup, not as the thing verified).
    func testORIUsesRtAsSourceAndRaAsDestination() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 3, ra: 0, simm: 0x0F0F)) // r3 = 0x0F0F
        memory.write32(0x8000_4004, encode(primary: 0x18, rt: 3, ra: 5, simm: 0x00F0)) // ori r5,r3,0xF0 -> r5 = r3 | 0xF0, r3 untouched

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().registers[3], 0x0F0F, "ori must read its source from the rt-position register (r3) and leave it unmodified")
        XCTAssertEqual(cpu.getState().registers[5], 0x0FFF, "ori must write its result to the ra-position register (r5), not r3")
    }

    /// andi. has no non-recording form in the real ISA - every andi. must
    /// update CR0, unconditionally, unlike andi/ori's optional "_" record
    /// forms elsewhere in this file.
    func testANDIAlwaysUpdatesCR0() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 3, ra: 0, simm: 0x00FF)) // r3 = 0xFF
        memory.write32(0x8000_4004, encode(primary: 0x1C, rt: 3, ra: 4, simm: 0x0000)) // andi. r4,r3,0 -> result is 0

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().registers[4], 0)
        XCTAssertEqual(cpu.getState().cr & 0xF000_0000, 0x2000_0000, "andi. producing zero must set CR0's EQ bit")
    }

    /// add rD,rA,rB via opcode 31's extended-opcode dispatch (extOp=266).
    func testOpcode31ADDAddsTwoRegisters() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 3, ra: 0, simm: 100)) // r3 = 100
        memory.write32(0x8000_4004, encode(primary: 0x0E, rt: 4, ra: 0, simm: 23))  // r4 = 23
        memory.write32(0x8000_4008, encodeX(rt: 5, ra: 3, rb: 4, extOp: 266))       // add r5,r3,r4

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        for _ in 0..<3 { _ = cpu.executeInstruction() }

        XCTAssertEqual(cpu.getState().registers[5], 123)
    }

    /// or rA,rS,rS (rB==rS) is the real encoding behind the `mr` (move
    /// register) idiom - verifies opcode 31's OR path specifically, since
    /// it shares the same rt-is-source/ra-is-destination role reversal as
    /// the D-form logical-immediate instructions.
    func testOpcode31ORImplementsMoveRegisterIdiom() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 3, ra: 0, simm: 77)) // r3 = 77
        memory.write32(0x8000_4004, encodeX(rt: 3, ra: 6, rb: 3, extOp: 444))      // or r6,r3,r3 == mr r6,r3

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().registers[6], 77, "or rA,rS,rS must copy rS's value into rA (the `mr` idiom)")
    }

    /// cmp sets CR0 from a signed comparison; a subsequent bc must be able
    /// to branch on it. This is the mechanism every real if/while/for
    /// compiles down to, so it's tested end-to-end (compare -> branch)
    /// rather than just checking the CR0 bits in isolation.
    func testCMPThenConditionalBranchTakesPathOnEqual() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encode(primary: 0x0E, rt: 3, ra: 0, simm: 5)) // r3 = 5
        memory.write32(0x8000_4004, encode(primary: 0x0E, rt: 4, ra: 0, simm: 5)) // r4 = 5
        memory.write32(0x8000_4008, encodeX(rt: 0, ra: 3, rb: 4, extOp: 0))       // cmp cr0,r3,r4 (rt/crfD field unused by this interpreter)
        // bc with BO=0x0C (0b01100: branch if CR0[EQ] set, ignore CTR),
        // BI=2 (CR0's EQ bit index), offset +0x100.
        memory.write32(0x8000_400C, encode(primary: 0x10, rt: 0x0C, ra: 2, simm: 0x100 >> 2))

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        for _ in 0..<4 { _ = cpu.executeInstruction() }

        XCTAssertEqual(cpu.getState().pc, 0x8000_400C &+ 0x100, "equal operands must set CR0[EQ], and the following bc must take the branch")
    }

    /// bclr (opcode 19, extended opcode 16) is the real encoding behind
    /// `blr` - the instruction every non-inlined function uses to return to
    /// its caller. This is arguably the single highest-value fix in this
    /// batch: without it, no call/return-based real code could execute past
    /// its first function's end.
    func testBCLRReturnsToLinkRegister() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        // bl-equivalent setup: manually seed LR as if a prior `bl` had
        // already run, since this interpreter's opcode-18 handler
        // (executeB) doesn't implement LK yet - only bclr's own LK path
        // (tested separately below) does. Then execute a bare blr
        // (bclr with BO=0x14 "always", LK=0) and confirm it jumps to LR.
        memory.write32(0x8000_4000, encodeXL(bo: 0x14, bi: 0, extOp: 0x10, lk: 0)) // blr

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        let seeded = CPUState(
            pc: 0x8000_4000,
            lr: 0x8000_9000,
            ctr: 0,
            cr: 0,
            registers: Array(repeating: 0, count: 32),
            fpRegisters: Array(repeating: 0.0, count: 32),
            cycleCount: 0,
            instructionCount: 0
        )
        XCTAssertTrue(cpu.restoreState(seeded))

        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().pc, 0x8000_9000, "blr (bclr, BO=always) must branch to whatever address is in LR")
    }

    /// bclrl (LK=1) must capture the *return* address (its own next
    /// instruction) into LR, not the branch target - and must do so even
    /// though this specific call doesn't end up branching anywhere new
    /// interesting, since LK's effect is unconditional on the branch outcome.
    func testBCLRWithLinkBitCapturesReturnAddress() {
        let memory = MemoryManager(size: 0x1000_0000, baseAddress: 0x8000_0000)
        memory.write32(0x8000_4000, encodeXL(bo: 0x14, bi: 0, extOp: 0x10, lk: 1)) // bclrl, branches to LR=0 initially

        let cpu = WiiUCPU(memory: memory, jitEnabled: false)
        _ = cpu.executeInstruction()

        XCTAssertEqual(cpu.getState().lr, 0x8000_4004, "LK=1 must set LR to this instruction's own address + 4, regardless of where the branch itself went")
    }
}
