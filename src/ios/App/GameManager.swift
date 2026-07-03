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
    @Published var lastLaunchError: String?

    /// Mirrors `emulationEngine.frameRate`. The engine's own `@Published`
    /// property doesn't propagate to views observing `GameManager` (SwiftUI
    /// only watches `objectWillChange` on the object it's handed, not nested
    /// ObservableObjects), so without this the on-screen FPS counter would
    /// render once and never update again.
    @Published var frameRate: Int = 0

    /// Whether the JIT is on. Persisted and pushed into the engine on launch
    /// and on every change.
    @Published var jitEnabled: Bool = true {
        didSet {
            guard jitEnabled != oldValue else { return }
            emulationEngine?.setJITEnabled(jitEnabled)
            UserDefaults.standard.set(jitEnabled, forKey: Self.jitEnabledDefaultsKey)
        }
    }

    private static let jitEnabledDefaultsKey = "jitEnabled"

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

        if UserDefaults.standard.object(forKey: Self.jitEnabledDefaultsKey) != nil {
            jitEnabled = UserDefaults.standard.bool(forKey: Self.jitEnabledDefaultsKey)
        }
        engine.setJITEnabled(jitEnabled)

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

            let favoriteIDs = loadFavoriteIDs(documentsPath: documentsPath)
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
                    genre: "Game",
                    isFavorite: favoriteIDs.contains(gameID)
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

            saveFavoriteIDs()
        }
    }

    /// Removes a ROM (and its cover image, if any) from Documents/Roms/ and
    /// updates in-memory + persisted state to match.
    func deleteROM(_ game: GameMetadata) async {
        let fileManager = FileManager.default
        let romURL = URL(fileURLWithPath: game.romPath)

        try? fileManager.removeItem(at: romURL)
        if let coverPath = game.coverPath {
            try? fileManager.removeItem(at: URL(fileURLWithPath: coverPath))
        }

        if currentGame?.id == game.id {
            stopEmulation()
        }

        games.removeAll { $0.id == game.id }
        favorites.removeAll { $0.id == game.id }
        saveFavoriteIDs()
    }

    private func favoritesFileURL(documentsPath: URL) -> URL {
        documentsPath.appendingPathComponent(gameListFile)
    }

    private func loadFavoriteIDs(documentsPath: URL) -> Set<String> {
        let url = favoritesFileURL(documentsPath: documentsPath)
        guard let data = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: data) else {
            return []
        }
        return ids
    }

    private func saveFavoriteIDs() {
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let ids = Set(games.filter { $0.isFavorite }.map { $0.id })
        guard let data = try? JSONEncoder().encode(ids) else { return }
        try? data.write(to: favoritesFileURL(documentsPath: documentsPath), options: .atomic)
    }

    func launchGame(_ game: GameMetadata) {
        currentGame = game
        emulationState = .loading
        lastLaunchError = nil

        guard let engine = emulationEngine else {
            lastLaunchError = "The emulation engine failed to initialize."
            emulationState = .error
            return
        }

        guard engine.loadROM(game.romPath) else {
            lastLaunchError = "Couldn't read \"\(game.title)\". The file may be missing, moved, or corrupted."
            emulationState = .error
            return
        }

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
        jitEnabled = enabled
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
