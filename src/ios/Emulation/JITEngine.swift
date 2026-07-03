import Foundation

/// Lightweight "threaded interpretation" JIT for the PowerPC core.
///
/// True ahead-of-time native code generation is out of scope for a sideloaded,
/// unsigned build — but the two costs that dominate a naive fetch-decode-execute
/// loop (re-reading the opcode word from memory and re-decoding it into a
/// `PPCInstruction`) can be eliminated for any loop the CPU has already run a
/// few times. This watches for backward branches (loop back-edges) and, once a
/// loop has looped past `hotThreshold` times, caches its already-decoded
/// instruction stream so later iterations skip straight to `execute(_:)`.
///
/// Enabled by default; auto-tunes its threshold lower on A-series chips
/// (A8-A12), which have the least headroom to spare on redundant decode work.
final class JITEngine {
    struct CachedLoop {
        let instructions: [PPCInstruction]
        let branch: PPCInstruction
        let fallthroughPC: UInt32
    }

    /// Safety cap so a mis-detected "loop" (e.g. a large forward jump that
    /// looks backward due to address wraparound) can't blow up into a
    /// multi-million-entry cached block.
    private let maxLoopBodyInstructions = 4096

    private var backEdgeHits: [UInt32: Int] = [:]
    private var loopCache: [UInt32: CachedLoop] = [:]

    let hotThreshold: Int
    private(set) var isEnabled: Bool
    private(set) var compiledLoopCount = 0

    init(enabled: Bool = true, hotThreshold: Int? = nil) {
        self.isEnabled = enabled
        self.hotThreshold = hotThreshold ?? (AChipProfile.isAChip ? 3 : 8)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { reset() }
    }

    func reset() {
        backEdgeHits.removeAll(keepingCapacity: true)
        loopCache.removeAll(keepingCapacity: true)
        compiledLoopCount = 0
    }

    func cachedLoop(at pc: UInt32) -> CachedLoop? {
        guard isEnabled else { return nil }
        return loopCache[pc]
    }

    /// Call when a backward branch (`bodyStart <= branchPC`) is taken, i.e. a
    /// loop back-edge. Once a given loop start has back-edged `hotThreshold`
    /// times, compiles the loop body (bodyStart...branchPC) into a cached
    /// instruction array so future iterations skip memory fetch + decode.
    func recordBackEdge(
        bodyStart: UInt32,
        branchPC: UInt32,
        fallthroughPC: UInt32,
        fetchDecode: (UInt32) -> PPCInstruction
    ) {
        guard isEnabled, bodyStart <= branchPC, loopCache[bodyStart] == nil else { return }

        let hits = (backEdgeHits[bodyStart] ?? 0) + 1
        backEdgeHits[bodyStart] = hits
        guard hits >= hotThreshold else { return }

        let bodyInstructionCount = Int((branchPC &- bodyStart) / 4)
        guard bodyInstructionCount <= maxLoopBodyInstructions else { return }

        var instructions: [PPCInstruction] = []
        instructions.reserveCapacity(bodyInstructionCount)
        var pc = bodyStart
        while pc < branchPC {
            instructions.append(fetchDecode(pc))
            pc = pc &+ 4
        }

        loopCache[bodyStart] = CachedLoop(
            instructions: instructions,
            branch: fetchDecode(branchPC),
            fallthroughPC: fallthroughPC
        )
        compiledLoopCount += 1
    }

    var stats: JITStats {
        JITStats(
            isEnabled: isEnabled,
            isAChip: AChipProfile.isAChip,
            compiledLoops: compiledLoopCount,
            trackedBackEdges: backEdgeHits.count,
            hotThreshold: hotThreshold
        )
    }
}

struct JITStats {
    let isEnabled: Bool
    let isAChip: Bool
    let compiledLoops: Int
    let trackedBackEdges: Int
    let hotThreshold: Int

    var description: String {
        guard isEnabled else { return "JIT: disabled" }
        return "JIT: \(compiledLoops) loop(s) compiled, \(trackedBackEdges) tracked, threshold=\(hotThreshold), aChip=\(isAChip)"
    }
}

/// A-series chip detection so the JIT can auto-tune itself. A-chips have far
/// less headroom than M-series, so a lower hot threshold (compile sooner) pays
/// off much faster in practice.
enum AChipProfile {
    static let isAChip: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        // iPhone/iPad identifiers for the A8-A12 generation (last major run of
        // devices without an M-series or later-A "hexa/octa-core with huge
        // cache" design where this optimization matters least).
        let aChipDeviceIDs = [
            "iPad4,", "iPad5,", "iPad6,", "iPad7,",
            "iPhone7,", "iPhone8,", "iPhone9,", "iPhone10,", "iPhone11,"
        ]
        return aChipDeviceIDs.contains { model.hasPrefix($0) }
        #endif
    }()
}
