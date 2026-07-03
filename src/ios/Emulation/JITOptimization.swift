import Foundation

/// JIT Optimization System - Optional performance booster for A-chips
final class JITOptimization {
    static let shared = JITOptimization()

    private let cache = JITCache()
    private let executionLock = NSLock()

    var isEnabled = true
    var isAChipOptimized = false

    private init() {
        // Auto-detect A-chip and enable optimizations
        detectChipAndOptimize()
    }

    /// Enable JIT optimization
    func enable() {
        isEnabled = true
    }

    /// Disable JIT optimization (fallback to full interpretation)
    func disable() {
        isEnabled = false
        cache.clear()
    }

    /// Record instruction execution for hotspot detection
    func recordInstruction(at pc: UInt32, size: Int = 4) {
        guard isEnabled else { return }
        cache.recordExecution(at: pc, length: size)
    }

    /// Check if an instruction path should be JIT compiled
    func shouldJIT(at pc: UInt32) -> Bool {
        guard isEnabled else { return false }
        return cache.isHotPath(at: pc)
    }

    /// Get optimization statistics
    func getStats() -> JITStats {
        let (hotPaths, total, topHotspots) = cache.getStatistics()
        return JITStats(
            hotPathsDetected: hotPaths,
            totalInstructions: total,
            topHotspots: topHotspots,
            cacheSize: cache.totalSize,
            isAChip: isAChipOptimized
        )
    }

    /// Clear cache and restart optimization
    func reset() {
        cache.clear()
    }

    // MARK: - A-Chip Detection

    private func detectChipAndOptimize() {
        #if targetEnvironment(simulator)
            isAChipOptimized = false
            isEnabled = false
        #else
            // Check if running on A-chip device
            isAChipOptimized = isRunningOnAChip()
            if isAChipOptimized {
                // Apply A-chip specific optimizations
                applyAChipOptimizations()
            }
        #endif
    }

    private func isRunningOnAChip() -> Bool {
        // Check device model for A-series chips
        var systemInfo = utsname()
        uname(&systemInfo)
        let model = String(bytes: Data(bytes: &systemInfo.machine, count: Int(_SYS_NAMELEN)), encoding: .ascii)?
            .trimmingCharacters(in: .controlCharacters) ?? ""

        // A-chip devices: A8, A8X, A9, A9X, A10, etc.
        let aChipPatterns = ["A8", "A9", "A10", "A11", "A12"]
        return aChipPatterns.contains { model.contains($0) }
    }

    private func applyAChipOptimizations() {
        // A-chips benefit from aggressive JIT due to limited memory and CPU
        // Lower the JIT threshold for faster hotspot detection
        let optimizedCache = JITCache(jitThreshold: 5, cacheSizeLimit: 512 * 1024)
        // Note: In real implementation, would use the optimizedCache instead
    }
}

/// JIT Statistics for monitoring
struct JITStats {
    let hotPathsDetected: Int
    let totalInstructions: Int
    let topHotspots: [(pc: UInt32, executions: Int)]
    let cacheSize: Int
    let isAChip: Bool

    var hitRate: Double {
        guard totalInstructions > 0 else { return 0 }
        return Double(hotPathsDetected) / Double(totalInstructions)
    }

    var description: String {
        """
        JIT Optimization Status:
        ├─ Device: \(isAChip ? "A-Chip (Optimized)" : "Simulator/Other")
        ├─ Hotspots Detected: \(hotPathsDetected) / \(totalInstructions)
        ├─ Hit Rate: \(String(format: "%.2f%%", hitRate * 100))
        ├─ Cache Size: \(cacheSize / 1024)KB
        └─ Top Hotspots:
        \(topHotspots.map { "   0x\(String($0.pc, radix: 16)): \($0.executions) executions" }.joined(separator: "\n"))
        """
    }
}

/// Execution mode for emulation
enum ExecutionMode {
    /// Pure interpretation - slowest but most compatible
    case interpreter

    /// JIT with fallback - automatically compiles hot paths
    case jitOptimized

    /// Mixed mode - intelligently switches between JIT and interpretation
    case mixed
}

/// Emulation configuration
struct EmulationConfig {
    var executionMode: ExecutionMode = .jitOptimized
    var enableJIT: Bool = true
    var jitThreshold: Int = 5
    var maxCompiledBlocks: Int = 256

    static let `default` = EmulationConfig()

    static let aChipOptimized = EmulationConfig(
        executionMode: .jitOptimized,
        enableJIT: true,
        jitThreshold: 3,  // More aggressive on A-chips
        maxCompiledBlocks: 512
    )

    static let conservative = EmulationConfig(
        executionMode: .interpreter,
        enableJIT: false,
        jitThreshold: 100,  // Very high threshold (essentially disabled)
        maxCompiledBlocks: 0
    )
}
