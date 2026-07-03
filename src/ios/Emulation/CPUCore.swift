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
    private func executeMULLI(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeSUBFIC(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeADDIC(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeADDIC_(_ instr: PPCInstruction) -> UInt32 { 1 }

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

    private func executeBCxL(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeRLWINM(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeRLWINM_(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeRLWIMI(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeRLWIMI_(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeORI(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeORIS(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeXORI(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeXORIS(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeANDI_(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executeANDIS_(_ instr: PPCInstruction) -> UInt32 { 1 }

    private func executePrimaryOpcode30(_ instr: PPCInstruction) -> UInt32 { 1 }
    private func executePrimaryOpcode31(_ instr: PPCInstruction) -> UInt32 { 1 }

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

    private func evaluateBranchCondition(_ bo: UInt32, _ bi: UInt32) -> Bool {
        return (bo & 0x10) != 0
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
