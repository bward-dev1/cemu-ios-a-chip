import Foundation

/// Efficient cache for compiled/interpreted instruction blocks
final class JITCache {
    private struct CacheEntry {
        let startPC: UInt32
        let length: Int
        var executions: Int
        let createdAt: Date
        var lastAccessedAt: Date
    }

    private var cache: [UInt32: CacheEntry] = [:]
    private let cacheLock = NSLock()
    private let maxCacheSize = 1024 * 1024  // 1MB max

    var totalSize = 0

    // Configuration
    let jitThreshold: Int
    let cacheSizeLimit: Int

    init(jitThreshold: Int = 10, cacheSizeLimit: Int = 1024 * 1024) {
        self.jitThreshold = jitThreshold
        self.cacheSizeLimit = cacheSizeLimit
    }

    /// Record instruction execution
    func recordExecution(at pc: UInt32, length: Int = 4) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if var entry = cache[pc] {
            entry.executions += 1
            entry.lastAccessedAt = Date()
            cache[pc] = entry
        } else {
            cache[pc] = CacheEntry(
                startPC: pc,
                length: length,
                executions: 1,
                createdAt: Date(),
                lastAccessedAt: Date()
            )
        }
    }

    /// Check if instruction is hot (should be JIT compiled)
    func isHotPath(at pc: UInt32) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        return (cache[pc]?.executions ?? 0) >= jitThreshold
    }

    /// Get cache statistics
    func getStatistics() -> (hotPaths: Int, totalRecorded: Int, topHotspots: [(pc: UInt32, executions: Int)]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        let hotPaths = cache.values.filter { $0.executions >= jitThreshold }.count
        let topHotspots = cache.sorted { $0.value.executions > $1.value.executions }
            .prefix(5)
            .map { ($0.key, $0.value.executions) }

        return (hotPaths, cache.count, Array(topHotspots))
    }

    /// Clear cache
    func clear() {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        cache.removeAll(keepingCapacity: true)
        totalSize = 0
    }

    /// Evict least-recently-used entries if cache exceeds limit
    func evictIfNeeded() {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard totalSize > cacheSizeLimit else { return }

        // Sort by last accessed time and remove oldest
        let sorted = cache.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        let toRemove = sorted.count / 4  // Remove 25% of entries

        for i in 0..<toRemove {
            let pc = sorted[i].key
            cache.removeValue(forKey: pc)
        }
    }
}

/// A-chip specific optimization profile
struct AChipProfile {
    // A-chip performance characteristics
    static let isAChip = true
    static let coreCount = 2  // Dual-core A9/A8X
    static let l1CacheSize = 32 * 1024
    static let l2CacheSize = 512 * 1024

    // JIT optimization for A-chips
    static let jitThreshold = 8  // Lower threshold for A-chips (faster compilation)
    static let aggressiveInlining = true
    static let enableSpeculation = true
    static let enablePrefetching = true

    // Memory settings
    static let maxCompiledBlocks = 512
    static let blockCacheSize = 512 * 1024  // 512KB

    static func optimizeForCurrentDevice() {
        // Detect device and apply appropriate settings
        #if targetEnvironment(simulator)
            // Simulator: use conservative settings
            let jit = JITCompiler(enabled: false)
        #else
            // Real device: use aggressive JIT
            WiiUCPU.enableJIT()
        #endif
    }
}
