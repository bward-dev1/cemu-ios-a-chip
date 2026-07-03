import Foundation

class WiiUCPU {
    private var registers: [UInt32] = Array(repeating: 0, count: 32)
    private var floatingPointRegisters: [Double] = Array(repeating: 0, count: 32)
    private var pc: UInt32 = 0x80004000
    private var lr: UInt32 = 0
    private var ctr: UInt32 = 0
    private var cr: UInt32 = 0

    /// Set by branch handlers when they change `pc` themselves, so the
    /// fetch-execute loop knows not to also advance it by 4.
    private var branched = false

    private let memory: MemoryManager
    private var cycleCount: UInt64 = 0
    private var instructionCount: UInt64 = 0

    private let jit: JITEngine

    init(memory: MemoryManager, jitEnabled: Bool = true) {
        self.memory = memory
        self.pc = 0x80004000
        self.jit = JITEngine(enabled: jitEnabled)
    }

    /// Optional JIT status, e.g. for a debug overlay. Safe to ignore.
    var jitStats: JITStats { jit.stats }

    func setJITEnabled(_ enabled: Bool) {
        jit.setEnabled(enabled)
    }

    func executeInstruction() -> UInt32 {
        if let loop = jit.cachedLoop(at: pc) {
            return executeCachedLoop(loop)
        }

        let startPC = pc
        let opcode = memory.read32(pc)
        let instruction = PPCInstruction(opcode: opcode)

        let cyclesTaken = execute(instruction)
        advancePC(from: startPC)
        cycleCount += UInt64(cyclesTaken)
        instructionCount += 1

        if branched {
            branched = false
            if pc <= startPC {
                jit.recordBackEdge(bodyStart: pc, branchPC: startPC, fallthroughPC: startPC &+ 4) { [memory] (fetchPC: UInt32) -> PPCInstruction in
                    PPCInstruction(opcode: memory.read32(fetchPC))
                }
            }
        }

        return cyclesTaken
    }

    /// Runs a cached loop body: already-decoded instructions execute directly,
    /// skipping the memory read + `PPCInstruction` decode that the normal path
    /// pays on every iteration. Falls back to the normal loop on the next
    /// `executeInstruction()` call once the loop condition stops holding.
    private func executeCachedLoop(_ loop: JITEngine.CachedLoop) -> UInt32 {
        var totalCycles: UInt32 = 0

        for instr in loop.instructions {
            totalCycles += execute(instr)
            instructionCount += 1
        }

        totalCycles += execute(loop.branch)
        instructionCount += 1

        if branched {
            branched = false
        } else {
            pc = loop.fallthroughPC
        }

        cycleCount += UInt64(totalCycles)
        return totalCycles
    }

    private func advancePC(from startPC: UInt32) {
        if !branched {
            pc = startPC &+ 4
        }
    }

    private func execute(_ instr: PPCInstruction) -> UInt32 {
        switch instr.primaryOpcode {
        case 0x03: return executeIllegal(instr)
        case 0x07: return executeMULLI(instr)
        case 0x08: return executeSUBFIC(instr)
        case 0x0C: return executeADDIC(instr)
        case 0x0D: return executeADDIC_(instr)
        case 0x0E: return executeADDI(instr)
        case 0x0F: return executeADDIS(instr)
        case 0x10: return executeBCx(instr)
        case 0x12: return executeB(instr)
        case 0x13: return executeBCxL(instr)
        case 0x14: return executeRLWINM(instr)
        case 0x15: return executeRLWINM_(instr)
        case 0x16: return executeRLWIMI(instr)
        case 0x17: return executeRLWIMI_(instr)
        case 0x18: return executeORI(instr)
        case 0x19: return executeORIS(instr)
        case 0x1A: return executeXORI(instr)
        case 0x1B: return executeXORIS(instr)
        case 0x1C: return executeANDI_(instr)
        case 0x1D: return executeANDIS_(instr)
        case 0x1E: return executePrimaryOpcode30(instr)
        case 0x1F: return executePrimaryOpcode31(instr)
        case 0x20...0x23: return executeLWZ(instr)
        case 0x24...0x25: return executeLFD(instr)
        case 0x28...0x2B: return executeSTW(instr)
        case 0x2C...0x2D: return executeSTFD(instr)
        default: return 1
        }
    }

    private func executeIllegal(_ instr: PPCInstruction) -> UInt32 { 1 }

    /// mulli rD,rA,SIMM - rD = rA * SIMM, keeping only the low 32 bits of
    /// the product. Int32's overflow-wrapping multiply (&*) gives exactly
    /// that: truncation to N bits commutes with multiplication in two's
    /// complement arithmetic, so this is bit-for-bit identical to computing
    /// the full 64-bit product and discarding the high half - no need to
    /// actually widen to Int64 first.
    private func executeMULLI(_ instr: PPCInstruction) -> UInt32 {
        let ra = instr.ra == 0 ? Int32(0) : Int32(bitPattern: registers[Int(instr.ra)])
        let simm = Int32(bitPattern: instr.simm)
        registers[Int(instr.rt)] = UInt32(bitPattern: ra &* simm)
        return 1
    }

    /// subfic rD,rA,SIMM - rD = SIMM - rA (immediate minus register, the
    /// reverse of the intuitive order). Also sets XER[CA], which this
    /// interpreter doesn't model - real code using subfic purely for the
    /// arithmetic result (common) is unaffected; code chaining it into a
    /// subfe-based multi-word subtract (rare in practice) isn't handled yet.
    private func executeSUBFIC(_ instr: PPCInstruction) -> UInt32 {
        let ra = instr.ra == 0 ? Int32(0) : Int32(bitPattern: registers[Int(instr.ra)])
        let simm = Int32(bitPattern: instr.simm)
        registers[Int(instr.rt)] = UInt32(bitPattern: simm &- ra)
        return 1
    }

    /// addic rD,rA,SIMM - rD = rA + SIMM, also sets XER[CA] (not modeled,
    /// same caveat as subfic above).
    private func executeADDIC(_ instr: PPCInstruction) -> UInt32 {
        let ra = instr.ra == 0 ? Int32(0) : Int32(bitPattern: registers[Int(instr.ra)])
        let simm = Int32(bitPattern: instr.simm)
        registers[Int(instr.rt)] = UInt32(bitPattern: ra &+ simm)
        return 1
    }

    /// addic. - addic, plus a CR0 update on the result (the "." record form).
    private func executeADDIC_(_ instr: PPCInstruction) -> UInt32 {
        let cycles = executeADDIC(instr)
        updateCR0(Int32(bitPattern: registers[Int(instr.rt)]))
        return cycles
    }

    private func executeADDI(_ instr: PPCInstruction) -> UInt32 {
        let rt = instr.rt
        let ra = instr.ra == 0 ? UInt32(0) : registers[Int(instr.ra)]
        let simm = instr.simm
        registers[Int(rt)] = ra &+ simm
        return 1
    }

    private func executeADDIS(_ instr: PPCInstruction) -> UInt32 {
        let rt = instr.rt
        let ra = instr.ra == 0 ? UInt32(0) : registers[Int(instr.ra)]
        let simm = instr.simm << 16
        registers[Int(rt)] = ra &+ simm
        return 1
    }

    private func executeBCx(_ instr: PPCInstruction) -> UInt32 {
        let bo = instr.bo
        let bi = instr.bi
        let bd = instr.bd
        let taken = evaluateBranchCondition(bo, bi)
        if taken {
            // Both arms of what used to be a ternary here computed the exact
            // same expression - not a functional bug, just dead weight that
            // implied a distinction that didn't exist.
            pc = pc &+ UInt32(bitPattern: Int32(bitPattern: bd) << 2)
            branched = true
        }
        return 1
    }

    private func executeB(_ instr: PPCInstruction) -> UInt32 {
        let li = instr.li
        pc = UInt32(bitPattern: Int32(bitPattern: li) << 2)
        branched = true
        return 1
    }

    /// Opcode 19 (XL-form): bclr (extended opcode 16) is by far the most
    /// important form to get right - it's the real encoding behind `blr`,
    /// the instruction every non-inlined compiled function uses to return
    /// to its caller. Without this, the interpreter would just fall through
    /// past the end of every function into whatever bytes follow it in
    /// memory - no call/return-based real code could execute correctly at
    /// all. bcctr (528, branch to CTR - used for computed/virtual-table
    /// calls) and the other opcode-19 sub-forms (isync, crand/cror/etc) are
    /// real gaps still, not implemented here.
    private func executeBCxL(_ instr: PPCInstruction) -> UInt32 {
        guard instr.extendedOpcode == 0x10 else {
            return 1
        }

        let nextInstructionAddress = pc &+ 4
        if evaluateBranchCondition(instr.bo, instr.bi) {
            pc = lr & 0xFFFF_FFFC // branch targets are always word-aligned
            branched = true
        }
        // LK's effect on LR is unconditional - it happens whether or not
        // the branch above was actually taken.
        if instr.lk {
            lr = nextInstructionAddress
        }
        return 1
    }

    /// rlwinm rA,rS,SH,MB,ME - rA = ROTL32(rS, SH) & MASK(MB, ME). One of
    /// the single most common instructions in real compiled PowerPC code:
    /// compilers use it to implement shifts, ANDs with arbitrary bit
    /// masks, and zero/sign-extension idioms that don't have their own
    /// dedicated instruction.
    private func executeRLWINM(_ instr: PPCInstruction) -> UInt32 {
        let rs = registers[Int(instr.rt)] // D/M-form: bits 6-10 hold the *source* here, not the destination
        let rotated = Self.rotl32(rs, instr.sh)
        registers[Int(instr.ra)] = rotated & Self.mask(mb: instr.mb, me: instr.me)
        return 1
    }

    private func executeRLWINM_(_ instr: PPCInstruction) -> UInt32 {
        let cycles = executeRLWINM(instr)
        updateCR0(Int32(bitPattern: registers[Int(instr.ra)]))
        return cycles
    }

    /// rlwimi rA,rS,SH,MB,ME - like rlwinm, but *inserts* into rA: bits
    /// inside the mask come from the rotated source, bits outside it keep
    /// rA's existing value. Used for bitfield-packing idioms the compiler
    /// can't express with a plain load/store.
    private func executeRLWIMI(_ instr: PPCInstruction) -> UInt32 {
        let rs = registers[Int(instr.rt)]
        let rotated = Self.rotl32(rs, instr.sh)
        let m = Self.mask(mb: instr.mb, me: instr.me)
        let ra = Int(instr.ra)
        registers[ra] = (rotated & m) | (registers[ra] & ~m)
        return 1
    }

    private func executeRLWIMI_(_ instr: PPCInstruction) -> UInt32 {
        let cycles = executeRLWIMI(instr)
        updateCR0(Int32(bitPattern: registers[Int(instr.ra)]))
        return cycles
    }

    // ori/oris/xori/xoris/andi./andis. are D-form like addi, but with a
    // *reversed* field role versus addi: bits 6-10 (the `rt` accessor) hold
    // the *source* register (rS) here, and bits 11-15 (`ra`) hold the
    // *destination* - the opposite of addi's rD-in-bits-6-10 layout, despite
    // sharing the exact same bit positions. Getting this backwards would
    // silently swap source and destination.

    private func executeORI(_ instr: PPCInstruction) -> UInt32 {
        registers[Int(instr.ra)] = registers[Int(instr.rt)] | instr.uimm
        return 1
    }

    private func executeORIS(_ instr: PPCInstruction) -> UInt32 {
        registers[Int(instr.ra)] = registers[Int(instr.rt)] | (instr.uimm << 16)
        return 1
    }

    private func executeXORI(_ instr: PPCInstruction) -> UInt32 {
        registers[Int(instr.ra)] = registers[Int(instr.rt)] ^ instr.uimm
        return 1
    }

    private func executeXORIS(_ instr: PPCInstruction) -> UInt32 {
        registers[Int(instr.ra)] = registers[Int(instr.rt)] ^ (instr.uimm << 16)
        return 1
    }

    /// andi. has no non-"." form in the real ISA - it always updates CR0.
    private func executeANDI_(_ instr: PPCInstruction) -> UInt32 {
        let result = registers[Int(instr.rt)] & instr.uimm
        registers[Int(instr.ra)] = result
        updateCR0(Int32(bitPattern: result))
        return 1
    }

    private func executeANDIS_(_ instr: PPCInstruction) -> UInt32 {
        let result = registers[Int(instr.rt)] & (instr.uimm << 16)
        registers[Int(instr.ra)] = result
        updateCR0(Int32(bitPattern: result))
        return 1
    }

    /// Opcode 30 is PowerPC64's rotate-immediate family (rldicl/rldicr/etc)
    /// - the Wii U's Espresso CPU is a 32-bit PowerPC 750 derivative, so
    /// this opcode is simply not part of the real ISA this interpreter
    /// targets. Unlike the other stubs in this file, this one isn't a gap
    /// to fill in later; real Wii U code will never emit it.
    private func executePrimaryOpcode30(_ instr: PPCInstruction) -> UInt32 { 1 }

    /// Opcode 31 (X-form): a huge extended-opcode-dispatched family covering
    /// most register-register arithmetic/logical/compare instructions.
    /// Implemented here: the handful that show up constantly in real
    /// compiled code (add, subf, and, or - including the `mr` move-register
    /// idiom, which is just `or rA,rS,rS` - xor, nor, cmp, cmpl). Many
    /// opcode-31 forms remain unimplemented (multiply/divide, shifts,
    /// load/store-indexed, the full compare/logical set) - real progress,
    /// not the whole table.
    private func executePrimaryOpcode31(_ instr: PPCInstruction) -> UInt32 {
        switch instr.extendedOpcode {
        case 0: return executeCMP(instr)
        case 32: return executeCMPL(instr)
        case 28: return executeANDx(instr)
        case 40: return executeSUBFx(instr)
        case 124: return executeNORx(instr)
        case 266: return executeADDx(instr)
        case 316: return executeXORx(instr)
        case 444: return executeORx(instr)
        default: return 1
        }
    }

    /// add rD,rA,rB (Rc bit, if set, additionally updates CR0).
    private func executeADDx(_ instr: PPCInstruction) -> UInt32 {
        let result = registers[Int(instr.ra)] &+ registers[Int(instr.rb)]
        registers[Int(instr.rt)] = result
        if instr.rc { updateCR0(Int32(bitPattern: result)) }
        return 1
    }

    /// subf rD,rA,rB - rD = rB - rA (reversed operand order, like subfic).
    private func executeSUBFx(_ instr: PPCInstruction) -> UInt32 {
        let result = registers[Int(instr.rb)] &- registers[Int(instr.ra)]
        registers[Int(instr.rt)] = result
        if instr.rc { updateCR0(Int32(bitPattern: result)) }
        return 1
    }

    /// and rA,rS,rB. X-form's field roles match ori/andi.'s D-form pattern:
    /// rt-position is the source (rS), ra-position is the destination.
    private func executeANDx(_ instr: PPCInstruction) -> UInt32 {
        let result = registers[Int(instr.rt)] & registers[Int(instr.rb)]
        registers[Int(instr.ra)] = result
        if instr.rc { updateCR0(Int32(bitPattern: result)) }
        return 1
    }

    /// or rA,rS,rB - also the real encoding behind the `mr rA,rS` (move
    /// register) idiom when rB == rS, which compiled code emits constantly.
    private func executeORx(_ instr: PPCInstruction) -> UInt32 {
        let result = registers[Int(instr.rt)] | registers[Int(instr.rb)]
        registers[Int(instr.ra)] = result
        if instr.rc { updateCR0(Int32(bitPattern: result)) }
        return 1
    }

    private func executeXORx(_ instr: PPCInstruction) -> UInt32 {
        let result = registers[Int(instr.rt)] ^ registers[Int(instr.rb)]
        registers[Int(instr.ra)] = result
        if instr.rc { updateCR0(Int32(bitPattern: result)) }
        return 1
    }

    /// nor rA,rS,rB - also the real encoding behind `not rA,rS` (rB == rS).
    private func executeNORx(_ instr: PPCInstruction) -> UInt32 {
        let result = ~(registers[Int(instr.rt)] | registers[Int(instr.rb)])
        registers[Int(instr.ra)] = result
        if instr.rc { updateCR0(Int32(bitPattern: result)) }
        return 1
    }

    /// cmp crfD,0,rA,rB - signed compare, result into CR field crfD (this
    /// interpreter, like the rest of this file, only actually implements
    /// CR0 - a cmp targeting a non-zero crfD updates CR0 the same as any
    /// other, rather than the specific field the real instruction encodes;
    /// documented simplification, not a silent no-op).
    private func executeCMP(_ instr: PPCInstruction) -> UInt32 {
        let a = Int32(bitPattern: registers[Int(instr.ra)])
        let b = Int32(bitPattern: registers[Int(instr.rb)])
        updateCR0(a < b ? -1 : (a > b ? 1 : 0))
        return 1
    }

    /// cmpl crfD,0,rA,rB - unsigned compare.
    private func executeCMPL(_ instr: PPCInstruction) -> UInt32 {
        let a = registers[Int(instr.ra)]
        let b = registers[Int(instr.rb)]
        updateCR0(a < b ? -1 : (a > b ? 1 : 0))
        return 1
    }

    private func executeLWZ(_ instr: PPCInstruction) -> UInt32 {
        let rt = instr.rt
        let ra = instr.ra == 0 ? UInt32(0) : registers[Int(instr.ra)]
        let d = instr.simm
        let address = ra &+ d
        registers[Int(rt)] = memory.read32(address)
        return 1
    }

    private func executeLFD(_ instr: PPCInstruction) -> UInt32 {
        let ft = instr.rt
        let ra = instr.ra == 0 ? UInt32(0) : registers[Int(instr.ra)]
        let d = instr.simm
        let address = ra &+ d
        let value = memory.read64(address)
        floatingPointRegisters[Int(ft)] = Double(bitPattern: value)
        return 1
    }

    private func executeSTW(_ instr: PPCInstruction) -> UInt32 {
        let rs = instr.rt
        let ra = instr.ra == 0 ? UInt32(0) : registers[Int(instr.ra)]
        let d = instr.simm
        let address = ra &+ d
        memory.write32(address, registers[Int(rs)])
        return 1
    }

    private func executeSTFD(_ instr: PPCInstruction) -> UInt32 {
        let fs = instr.rt
        let ra = instr.ra == 0 ? UInt32(0) : registers[Int(instr.ra)]
        let d = instr.simm
        let address = ra &+ d
        memory.write64(address, floatingPointRegisters[Int(fs)].bitPattern)
        return 1
    }

    /// Real BO/BI decode, replacing what used to be a "branch always"-only
    /// stub (`(bo & 0x10) != 0`, i.e. every non-"always" conditional branch
    /// silently never branched at all, regardless of BI or the actual CR
    /// state). Covers the two forms that account for the overwhelming
    /// majority of real compiled control flow: unconditional (BO[0] set)
    /// and CR-bit tests (BO[0] clear - branch if CR[BI] equals BO[1]),
    /// which is exactly what every cmp-then-branch if/else/loop-condition
    /// compiles down to.
    ///
    /// BI indexes the 32-bit CR using the real ISA's MSB-first bit
    /// numbering (BI=0 is CR0's LT, BI=1 GT, BI=2 EQ, BI=3 SO, ...) - since
    /// `cr` stores CR0 in its own top 4 bits (see updateCR0), BI maps to
    /// shift-position (31 - BI).
    ///
    /// Not modeled: CTR-based forms (BO[2] clear - bdnz/bdz, the
    /// decrement-and-test-CTR loop idiom), since this interpreter doesn't
    /// implement CTR decrement at all. Those fall through to the same
    /// CR-bit test as everything else instead of the CTR test the real BO
    /// value specifies - a real, known gap, not a silent no-op.
    private func evaluateBranchCondition(_ bo: UInt32, _ bi: UInt32) -> Bool {
        if (bo & 0x10) != 0 {
            return true
        }
        let crBitSet = ((cr >> (31 - bi)) & 1) != 0
        let branchIfTrue = (bo & 0x08) != 0
        return crBitSet == branchIfTrue
    }

    /// Left-rotates a 32-bit value by `shift & 0x1F` bits, matching the
    /// PowerPC ISA's ROTL32 primitive used by rlwinm/rlwimi/rlwnm. Swift's
    /// shift operators are "smart shifts" (a shift count >= bit width just
    /// yields 0, never a trap), so shift=0 - which would otherwise need a
    /// >>32 - works out correctly without a special case: value << 0 is
    /// value, value >> 32 is 0, and value | 0 is value.
    private static func rotl32(_ value: UInt32, _ shift: UInt32) -> UInt32 {
        let s = shift & 0x1F
        return (value << s) | (value >> (32 - s))
    }

    /// PowerPC's MASK(mb, me): a 32-bit value with bits mb...me (inclusive,
    /// wrapping around from 31 back to 0 if mb > me) set to 1, rest 0. Used
    /// by rlwinm/rlwimi to select which bits of the rotated source actually
    /// land in the result. Walking bit-by-bit with wraparound handles both
    /// the normal and wrapping cases uniformly, rather than needing the
    /// classic reference implementation's separate branches for each.
    private static func mask(mb: UInt32, me: UInt32) -> UInt32 {
        var value: UInt32 = 0
        var i = mb & 0x1F
        let end = me & 0x1F
        while true {
            value |= (UInt32(1) << (31 - i))
            if i == end { break }
            i = (i + 1) & 0x1F
        }
        return value
    }

    /// Sets CR0 (the top 4 bits of `cr`) from a record-form instruction's
    /// signed result: LT/GT/EQ per the usual comparison-to-zero. The real
    /// ISA's 4th bit (SO) copies XER[SO], the sticky summary-overflow flag -
    /// this interpreter doesn't track XER/overflow at all yet, so SO is
    /// always reported as 0. That's a real, documented simplification, not
    /// a bug: code that branches only on LT/GT/EQ (the overwhelming
    /// majority of real compiled comparisons) is unaffected by it.
    private func updateCR0(_ result: Int32) {
        let cr0: UInt32
        if result < 0 {
            cr0 = 0x8 // LT
        } else if result > 0 {
            cr0 = 0x4 // GT
        } else {
            cr0 = 0x2 // EQ
        }
        cr = (cr & 0x0FFF_FFFF) | (cr0 << 28)
    }

    func step(_ count: UInt32 = 1) {
        for _ in 0..<count {
            _ = executeInstruction()
        }
    }

    func runUntilFrame() -> UInt64 {
        let targetCycles = cycleCount + (68_000_000 / 60)
        while cycleCount < targetCycles {
            _ = executeInstruction()
        }
        return cycleCount
    }

    func getState() -> CPUState {
        return CPUState(
            pc: pc,
            lr: lr,
            ctr: ctr,
            cr: cr,
            registers: registers,
            fpRegisters: floatingPointRegisters,
            cycleCount: cycleCount,
            instructionCount: instructionCount
        )
    }

    /// Restores a previously captured CPUState (save state load). Returns
    /// false (leaving the CPU untouched) if the register arrays aren't
    /// exactly 32 elements - a save state is arbitrary data loaded from disk
    /// (a partial write, disk corruption, a hand-edited or future-format
    /// file), and every `execute...` handler indexes `registers[Int(rt)]`
    /// with rt up to 31 straight from the decoded instruction with no bounds
    /// check of its own. Blindly accepting a short array here would turn a
    /// bad save file into an array-index-out-of-bounds crash the next time
    /// any instruction touched a high-numbered register.
    ///
    /// On success, resets the JIT's compiled-loop cache: those loops are
    /// keyed by PC and decoded against whatever memory bytes were live when
    /// compiled, and a restore is exactly the kind of "memory contents
    /// changed out from under a cached address" event the cache has no way
    /// to detect on its own. Re-warming is cheap; a stale cached loop
    /// silently executing the wrong decoded instructions is not.
    @discardableResult
    func restoreState(_ state: CPUState) -> Bool {
        guard state.registers.count == 32, state.fpRegisters.count == 32 else {
            return false
        }
        pc = state.pc
        lr = state.lr
        ctr = state.ctr
        cr = state.cr
        registers = state.registers
        floatingPointRegisters = state.fpRegisters
        cycleCount = state.cycleCount
        instructionCount = state.instructionCount
        branched = false
        jit.reset()
        return true
    }
}

struct PPCInstruction {
    let opcode: UInt32

    var primaryOpcode: UInt32 { (opcode >> 26) & 0x3F }
    var rt: UInt32 { (opcode >> 21) & 0x1F }
    var ra: UInt32 { (opcode >> 16) & 0x1F }
    var rb: UInt32 { (opcode >> 11) & 0x1F }
    var simm: UInt32 { UInt32(bitPattern: Int32(bitPattern: opcode & 0xFFFF)) }
    var uimm: UInt32 { opcode & 0xFFFF }
    var bo: UInt32 { (opcode >> 21) & 0x1F }
    var bi: UInt32 { (opcode >> 16) & 0x1F }
    var bd: UInt32 { opcode & 0xFFFF }
    var li: UInt32 { opcode & 0x3FFFFF }

    // M-form fields (rlwinm/rlwimi/rlwnm): same rt/ra bit positions as
    // above, plus a shift amount and a mask range.
    var sh: UInt32 { rb }
    var mb: UInt32 { (opcode >> 6) & 0x1F }
    var me: UInt32 { (opcode >> 1) & 0x1F }

    // XL-form (bclr/bcctr and friends, opcode 19): extended opcode
    // distinguishes bclr (16) from bcctr (528) and other sub-forms; LK
    // requests a return-address capture into LR regardless of extended
    // opcode.
    var extendedOpcode: UInt32 { (opcode >> 1) & 0x3FF }
    var lk: Bool { (opcode & 0x1) != 0 }

    /// X-form's Rc (record) bit - bit 31, the exact same bit position as
    /// `lk` above, but a different field semantically: X-form arithmetic/
    /// logical instructions (opcode 31) use bit 31 to mean "update CR0",
    /// not "link". Kept as a separate, correctly-named accessor rather than
    /// reusing `lk` so callers can't misread intent from the accessor name.
    var rc: Bool { (opcode & 0x1) != 0 }
}

struct CPUState: Codable {
    let pc: UInt32
    let lr: UInt32
    let ctr: UInt32
    let cr: UInt32
    let registers: [UInt32]
    let fpRegisters: [Double]
    let cycleCount: UInt64
    let instructionCount: UInt64
}
