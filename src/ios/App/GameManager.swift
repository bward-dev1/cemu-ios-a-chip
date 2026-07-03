import Combine
import Foundation
import SwiftUI

struct GameMetadata: Codable, Identifiable {
    let id: String
    let title: String
    let romPath: String
    let coverPath: String?
    let region: String
    let releaseDate: String
    let genre: String
    var isFavorite: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, title, romPath, coverPath, region, releaseDate, genre
    }
}

enum ROMImportError: Error {
    case unsupportedFileType(String)
}

@MainActor
class GameManager: ObservableObject {
    @Published var games: [GameMetadata] = []
    @Published var favorites: [GameMetadata] = []
    @Published var isLoading = false
    @Published var currentGame: GameMetadata?
    @Published var emulationState: EmulationState = .idle
    @Published var lastImportError: String?

    /// Mirrors `emulationEngine.frameRate`. The engine's own `@Published`
    /// property doesn't propagate to views observing `GameManager` (SwiftUI
    /// only watches `objectWillChange` on the object it's handed, not nested
    /// ObservableObjects), so without this the on-screen FPS counter would
    /// render once and never update again.
    @Published var frameRate: Int = 0

    private let romsDirectory = "Roms"
    private let gameListFile = "games.json"
    private var emulationEngine: OptimizedEmulationEngine?
    private var frameRateCancellable: AnyCancellable?

    init() {
        let engine = OptimizedEmulationEngine()
        emulationEngine = engine
        frameRateCancellable = engine.$frameRate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.frameRate = rate
            }
        Task {
            await loadGames()
        }
    }

    func loadGames() async {
        isLoading = true
        defer { isLoading = false }

        let fileManager = FileManager.default
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let romsPath = documentsPath.appendingPathComponent(romsDirectory)

        try? fileManager.createDirectory(at: romsPath, withIntermediateDirectories: true)

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: romsPath,
                includingPropertiesForKeys: nil
            )

            var discoveredGames: [GameMetadata] = []

            for item in contents {
                let pathExtension = item.pathExtension.lowercased()
                guard ["wua", "wud", "iso", "rpx"].contains(pathExtension) else { continue }

                let gameID = item.deletingPathExtension().lastPathComponent

                let gameMetadata = GameMetadata(
                    id: gameID,
                    title: gameID,
                    romPath: item.path,
                    coverPath: findCover(for: gameID, in: romsPath),
                    region: "Unknown",
                    releaseDate: "Unknown",
                    genre: "Game"
                )

                discoveredGames.append(gameMetadata)
            }

            self.games = discoveredGames.sorted { $0.title < $1.title }
            self.favorites = self.games.filter { $0.isFavorite }
        } catch {
            print("Error scanning Roms directory: \(error)")
        }
    }

    /// Copies picked ROM files (already app-local temp copies, since the
    /// picker is opened with `asCopy: true`) into Documents/Roms/, then
    /// rescans so they show up immediately.
    func importROMs(from urls: [URL]) async {
        let fileManager = FileManager.default
        guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let romsPath = documentsPath.appendingPathComponent(romsDirectory)
        try? fileManager.createDirectory(at: romsPath, withIntermediateDirectories: true)

        var firstError: String?

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ["wua", "wud", "iso", "rpx"].contains(ext) else {
                if firstError == nil {
                    firstError = "\(url.lastPathComponent) isn't a supported ROM type (.wua, .wud, .rpx, .iso)"
                }
                continue
            }

            let destination = romsPath.appendingPathComponent(url.lastPathComponent)
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: url, to: destination)
            } catch {
                if firstError == nil {
                    firstError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }

        lastImportError = firstError
        await loadGames()
    }

    private func findCover(for gameID: String, in directory: URL) -> String? {
        let fileManager = FileManager.default

        for ext in ["jpg", "jpeg", "png"] {
            let coverPath = directory.appendingPathComponent("\(gameID)_cover.\(ext)")
            if fileManager.fileExists(atPath: coverPath.path) {
                return coverPath.path
            }
        }

        return nil
    }

    func toggleFavorite(_ game: GameMetadata) {
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].isFavorite.toggle()

            if games[index].isFavorite {
                favorites.append(games[index])
            } else {
                favorites.removeAll { $0.id == game.id }
            }
        }
    }

    func launchGame(_ game: GameMetadata) {
        currentGame = game
        emulationState = .loading

        guard let engine = emulationEngine else {
            emulationState = .error
            return
        }

        engine.loadROM(game.romPath)
        engine.startEmulation()
        emulationState = .running
    }

    func stopEmulation() {
        emulationEngine?.stopEmulation()
        emulationState = .idle
        currentGame = nil
    }

    func getEmulationEngine() -> OptimizedEmulationEngine? {
        return emulationEngine
    }

    /// Optional JIT compilation status (loops compiled, whether it's enabled).
    var jitStats: JITStats? {
        emulationEngine?.jitStats
    }

    func setJITEnabled(_ enabled: Bool) {
        emulationEngine?.setJITEnabled(enabled)
    }

    func getFrameTexture() -> MTLTexture? {
        return emulationEngine?.getFrameTexture()
    }

    func getFrameRate() -> Int {
        return frameRate
    }
}

enum EmulationState {
    case idle
    case loading
    case running
    case paused
    case error
}
