import Foundation

/// A single save slot's metadata - small and fast to list without touching
/// the (much larger, compressed) state payload itself.
struct SaveStateMetadata: Codable, Identifiable {
    let id: String
    let gameID: String
    let slot: Int
    let createdAt: Date
    let label: String
}

/// The actual captured state for one slot: CPU registers plus a compressed
/// full-memory snapshot. Stored as a single JSON file per slot - Data fields
/// base64-encode under JSONEncoder, which costs ~33% size overhead versus a
/// hand-rolled binary container, but the memory blob is already
/// lzfse-compressed down to a small size (a 256MB buffer that's almost
/// entirely zeros compresses extremely well), so that overhead is on top of
/// an already-small number. Not worth a custom binary format for it.
private struct SaveStatePayload: Codable {
    let cpuState: CPUState
    let compressedMemory: Data
    let uncompressedMemorySize: Int
}

enum SaveStateError: Error {
    case notRunning
    case captureFailed
    case sizeMismatch
    case compressionFailed
    case io(Error)
}

/// Manages save states on disk: Documents/SaveStates/<gameID>/<slot>.meta.json
/// (fast-listable metadata) + <slot>.state (the compressed payload).
@MainActor
final class SaveStateManager {
    static let slotsPerGame = 3

    private let fileManager = FileManager.default

    private func gameDirectory(for gameID: String) -> URL? {
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsPath.appendingPathComponent("SaveStates").appendingPathComponent(gameID)
    }

    private func metadataURL(gameID: String, slot: Int) -> URL? {
        gameDirectory(for: gameID)?.appendingPathComponent("slot_\(slot).meta.json")
    }

    private func payloadURL(gameID: String, slot: Int) -> URL? {
        gameDirectory(for: gameID)?.appendingPathComponent("slot_\(slot).state")
    }

    /// Metadata for every slot that currently has a save, sorted by slot number.
    func listSaveStates(for gameID: String) -> [SaveStateMetadata] {
        (1...Self.slotsPerGame).compactMap { slot -> SaveStateMetadata? in
            guard let url = metadataURL(gameID: gameID, slot: slot),
                  let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? JSONDecoder().decode(SaveStateMetadata.self, from: data)
        }
    }

    /// Captures the engine's current state (thread-safe - see
    /// OptimizedEmulationEngine.captureState) and writes it to `slot`,
    /// overwriting whatever was there before.
    func save(
        gameID: String,
        slot: Int,
        label: String,
        engine: OptimizedEmulationEngine,
        completion: @escaping (Result<Void, SaveStateError>) -> Void
    ) {
        let handleCapture: (CPUState?, Data?) -> Void = { [weak self] cpuState, memoryData in
            guard let self else { return }
            guard let cpuState, let memoryData else {
                completion(.failure(.notRunning))
                return
            }

            guard let compressed = self.compress(memoryData) else {
                completion(.failure(.compressionFailed))
                return
            }

            let payload = SaveStatePayload(
                cpuState: cpuState,
                compressedMemory: compressed,
                uncompressedMemorySize: memoryData.count
            )
            let metadata = SaveStateMetadata(
                id: "\(gameID)-\(slot)",
                gameID: gameID,
                slot: slot,
                createdAt: Date(),
                label: label
            )

            do {
                guard let dir = self.gameDirectory(for: gameID),
                      let metaURL = self.metadataURL(gameID: gameID, slot: slot),
                      let payloadURL = self.payloadURL(gameID: gameID, slot: slot) else {
                    completion(.failure(.io(NSError(domain: "SaveStateManager", code: -1))))
                    return
                }

                try self.fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                try JSONEncoder().encode(payload).write(to: payloadURL, options: .atomic)
                try JSONEncoder().encode(metadata).write(to: metaURL, options: .atomic)

                completion(.success(()))
            } catch {
                completion(.failure(.io(error)))
            }
        }

        engine.captureState(completion: handleCapture)
    }

    private func compress(_ data: Data) -> Data? {
        let algorithm: NSData.CompressionAlgorithm = .lzfse
        let source = data as NSData
        return try? source.compressed(using: algorithm) as Data
    }

    private func decompress(_ data: Data) -> Data? {
        let algorithm: NSData.CompressionAlgorithm = .lzfse
        let source = data as NSData
        return try? source.decompressed(using: algorithm) as Data
    }

    /// Loads `slot` and restores it into `engine` (thread-safe - see
    /// OptimizedEmulationEngine.restoreState).
    func load(
        gameID: String,
        slot: Int,
        engine: OptimizedEmulationEngine,
        completion: @escaping (Result<Void, SaveStateError>) -> Void
    ) {
        guard let payloadURL = payloadURL(gameID: gameID, slot: slot) else {
            completion(.failure(.io(NSError(domain: "SaveStateManager", code: -1))))
            return
        }

        let payload: SaveStatePayload
        do {
            let data = try Data(contentsOf: payloadURL)
            payload = try JSONDecoder().decode(SaveStatePayload.self, from: data)
        } catch {
            completion(.failure(.io(error)))
            return
        }

        guard let decompressed = decompress(payload.compressedMemory),
              decompressed.count == payload.uncompressedMemorySize else {
            completion(.failure(.sizeMismatch))
            return
        }

        engine.restoreState(cpuState: payload.cpuState, memoryData: decompressed) { success in
            completion(success ? .success(()) : .failure(.sizeMismatch))
        }
    }

    func deleteSaveState(gameID: String, slot: Int) {
        if let metaURL = metadataURL(gameID: gameID, slot: slot) {
            try? fileManager.removeItem(at: metaURL)
        }
        if let payloadURL = payloadURL(gameID: gameID, slot: slot) {
            try? fileManager.removeItem(at: payloadURL)
        }
    }

    /// Removes every save state for a game - called when its ROM is deleted,
    /// so orphaned states don't accumulate on disk forever.
    func deleteAllSaveStates(for gameID: String) {
        guard let dir = gameDirectory(for: gameID) else { return }
        try? fileManager.removeItem(at: dir)
    }
}
