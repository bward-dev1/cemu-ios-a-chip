import SwiftUI
import MetalKit

private let lastControllerSkinDefaultsKey = "lastControllerSkinName"

struct ContentView: View {
    @StateObject var gameManager = GameManager()
    @State private var selectedGame: GameMetadata?
    @State private var showingGameBrowser = true
    @State private var showingFavorites = false
    @State private var selectedSkin: WiiUControllerSkin

    init() {
        let savedName = UserDefaults.standard.string(forKey: lastControllerSkinDefaultsKey)
        let restoredSkin = savedName.flatMap { ControllerSkinLibrary.getSkin(by: $0) } ?? WiiUControllerSkin.standard
        _selectedSkin = State(initialValue: restoredSkin)
    }

    var body: some View {
        ZStack {
            if showingGameBrowser {
                GameBrowserView(
                    gameManager: gameManager,
                    selectedGame: $selectedGame,
                    showingGameBrowser: $showingGameBrowser,
                    showingFavorites: $showingFavorites
                )
            } else if gameManager.emulationState == .error {
                LaunchErrorView(
                    message: gameManager.lastLaunchError ?? "This game couldn't be launched.",
                    onBack: {
                        gameManager.stopEmulation()
                        showingGameBrowser = true
                    }
                )
            } else if let game = selectedGame, gameManager.emulationState == .running {
                EmulatorViewOptimized(
                    game: game,
                    gameManager: gameManager,
                    isRunning: $showingGameBrowser,
                    controllerSkin: $selectedSkin
                )
            }
        }
        .ignoresSafeArea()
        .onChange(of: selectedSkin.name) { newName in
            UserDefaults.standard.set(newName, forKey: lastControllerSkinDefaultsKey)
        }
    }
}

struct LaunchErrorView: View {
    let message: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.4))

                Text("Couldn't Launch Game")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                Text(message)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(Color(red: 0.7, green: 0.7, blue: 0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Button(action: onBack) {
                    Text("Back to Library")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(10)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
    }
}

enum GameSortOption: String, CaseIterable {
    case name = "Name"
    case recentlyAdded = "Recently Added"
    case favoritesFirst = "Favorites First"

    var systemImage: String {
        switch self {
        case .name: return "textformat"
        case .recentlyAdded: return "clock"
        case .favoritesFirst: return "heart"
        }
    }
}

struct GameBrowserView: View {
    @ObservedObject var gameManager: GameManager
    @Binding var selectedGame: GameMetadata?
    @Binding var showingGameBrowser: Bool
    @Binding var showingFavorites: Bool
    @State private var searchText = ""
    @State private var showingImporter = false
    @State private var isImporting = false
    @State private var showingSettings = false
    @State private var pendingDelete: GameMetadata?
    @AppStorage("gameSortOption") private var sortOptionRaw: String = GameSortOption.name.rawValue

    private var sortOption: GameSortOption {
        GameSortOption(rawValue: sortOptionRaw) ?? .name
    }

    var filteredGames: [GameMetadata] {
        let gamesToShow = showingFavorites ? gameManager.favorites : gameManager.games
        let searched = searchText.isEmpty
            ? gamesToShow
            : gamesToShow.filter { $0.title.localizedCaseInsensitiveContains(searchText) }

        switch sortOption {
        case .name:
            return searched.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recentlyAdded:
            return searched.sorted { $0.dateAdded > $1.dateAdded }
        case .favoritesFirst:
            return searched.sorted { lhs, rhs in
                if lhs.isFavorite != rhs.isFavorite {
                    return lhs.isFavorite && !rhs.isFavorite
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.15),
                    Color(red: 0.08, green: 0.10, blue: 0.20)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wii U")
                            .font(.system(size: 28, weight: .bold, design: .default))
                            .foregroundColor(.white)

                        Text("Emulator")
                            .font(.system(size: 18, weight: .semibold, design: .default))
                            .foregroundColor(Color(red: 0.4, green: 0.6, blue: 1.0))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 8) {
                            Button(action: { showingImporter = true }) {
                                Group {
                                    if isImporting {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "square.and.arrow.up")
                                    }
                                }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(red: 0.4, green: 0.6, blue: 1.0))
                            }
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                            .disabled(isImporting)
                            .accessibilityLabel("Upload ROM")

                            Button(action: { showingFavorites.toggle() }) {
                                Image(systemName: showingFavorites ? "heart.fill" : "heart")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(showingFavorites ? Color(red: 1.0, green: 0.4, blue: 0.4) : Color(red: 0.6, green: 0.6, blue: 0.6))
                            }
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)

                            Menu {
                                Picker("Sort", selection: $sortOptionRaw) {
                                    ForEach(GameSortOption.allCases, id: \.rawValue) { option in
                                        Label(option.rawValue, systemImage: option.systemImage)
                                            .tag(option.rawValue)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                            }
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                            .accessibilityLabel("Sort games")

                            Button(action: { showingSettings = true }) {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                            }
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                            .accessibilityLabel("Settings")

                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(filteredGames.count)")
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                Text("games")
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                            }
                        }
                    }
                }
                .padding(20)
                .background(Color.white.opacity(0.03))
                .borderBottom(width: 0.5, color: Color.white.opacity(0.1))

                VStack(spacing: 12) {
                    SearchBarPolished(text: $searchText)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    if gameManager.isLoading {
                        LoadingView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filteredGames.isEmpty {
                        EmptyGamesView(showingFavorites: showingFavorites) {
                            showingImporter = true
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 140), spacing: 16)],
                                spacing: 20
                            ) {
                                ForEach(filteredGames) { game in
                                    GameCardOptimized(
                                        game: game,
                                        onTap: {
                                            selectedGame = game
                                            gameManager.launchGame(game)
                                            showingGameBrowser = false
                                        },
                                        onFavoriteTap: {
                                            gameManager.toggleFavorite(game)
                                        },
                                        onDeleteTap: {
                                            pendingDelete = game
                                        }
                                    )
                                }
                            }
                            .padding(16)
                        }
                        .refreshable {
                            await gameManager.loadGames()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingImporter) {
            ROMDocumentPicker { urls in
                isImporting = true
                Task {
                    await gameManager.importROMs(from: urls)
                    isImporting = false
                }
            }
            .ignoresSafeArea()
        }
        .alert(
            "Import Problem",
            isPresented: Binding(
                get: { gameManager.lastImportError != nil },
                set: { if !$0 { gameManager.lastImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(gameManager.lastImportError ?? "")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(gameManager: gameManager)
        }
        .confirmationDialog(
            "Delete \"\(pendingDelete?.title ?? "")\"?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete ROM", role: .destructive) {
                if let game = pendingDelete {
                    Task { await gameManager.deleteROM(game) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This removes the ROM file from your device. This can't be undone.")
        }
    }
}

struct GameCardOptimized: View {
    let game: GameMetadata
    let onTap: () -> Void
    let onFavoriteTap: () -> Void
    let onDeleteTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.1, green: 0.15, blue: 0.3),
                                Color(red: 0.08, green: 0.12, blue: 0.25)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let coverPath = game.coverPath,
                   let uiImage = UIImage(contentsOfFile: coverPath) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .cornerRadius(12)
                        .clipped()
                } else {
                    VStack {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 28))
                            .foregroundColor(Color(red: 0.4, green: 0.6, blue: 1.0))
                    }
                }

                VStack {
                    HStack {
                        Spacer()
                        Button(action: onFavoriteTap) {
                            Image(systemName: game.isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(game.isFavorite ? Color(red: 1.0, green: 0.4, blue: 0.4) : .white)
                                .frame(width: 32, height: 32)
                                .background(Color.black.opacity(0.4))
                                .cornerRadius(8)
                        }
                        .padding(8)
                    }
                    Spacer()
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)

            VStack(alignment: .leading, spacing: 8) {
                Text(game.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .foregroundColor(.white)

                HStack(spacing: 8) {
                    Label(game.region, systemImage: "globe")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                    Spacer()
                }

                Button(action: onTap) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Play")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.3, green: 0.6, blue: 1.0),
                                Color(red: 0.2, green: 0.5, blue: 0.95)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
            }
            .padding(12)
            .background(Color(red: 0.08, green: 0.10, blue: 0.18))
        }
        .background(Color(red: 0.08, green: 0.10, blue: 0.18))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
        .contextMenu {
            Button(action: onFavoriteTap) {
                Label(game.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: game.isFavorite ? "heart.slash" : "heart")
            }
            Button(role: .destructive, action: onDeleteTap) {
                Label("Delete ROM", systemImage: "trash")
            }
        }
    }
}

struct SearchBarPolished: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))

            TextField("Search games...", text: $text)
                .font(.system(size: 15, weight: .regular))
                .textFieldStyle(.plain)
                .foregroundColor(.white)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                }
            }
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

struct LoadingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48, weight: .semibold))
                .foregroundColor(Color(red: 0.4, green: 0.6, blue: 1.0))
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            Text("Loading games...")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

struct EmptyGamesView: View {
    let showingFavorites: Bool
    let onUploadTap: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: showingFavorites ? "heart.slash" : "doc.questionmark")
                .font(.system(size: 56, weight: .regular))
                .foregroundColor(Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.5))

            VStack(spacing: 8) {
                Text(showingFavorites ? "No Favorites Yet" : "No Games Found")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)

                if showingFavorites {
                    Text("Tap the heart on a game to add it here")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                } else {
                    Text("Upload a .wua, .wud, .rpx, or .iso file to get started")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            if !showingFavorites {
                Button(action: onUploadTap) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Upload ROM")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(red: 0.3, green: 0.6, blue: 1.0),
                                Color(red: 0.2, green: 0.5, blue: 0.95)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmulatorViewOptimized: View {
    let game: GameMetadata
    @ObservedObject var gameManager: GameManager
    @Binding var isRunning: Bool
    @Binding var controllerSkin: WiiUControllerSkin
    @State private var showControls = true
    @State private var showSkinSelector = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Button(action: {
                        gameManager.stopEmulation()
                        isRunning = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(height: 40)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                    }

                    VStack(alignment: .center, spacing: 2) {
                        Text(game.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(controllerSkin.name)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundColor(Color(red: 0.4, green: 0.6, blue: 1.0))
                    }
                    .frame(maxWidth: .infinity)

                    HStack(spacing: 8) {
                        Button(action: { showSkinSelector.toggle() }) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(red: 0.4, green: 0.6, blue: 1.0))
                        }
                        .frame(width: 32, height: 40)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)

                        HStack(spacing: 6) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(gameManager.getFrameRate()) FPS")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))

                            if let jit = gameManager.jitStats, jit.isEnabled, jit.compiledLoops > 0 {
                                Divider()
                                    .frame(height: 12)
                                    .background(Color.white.opacity(0.2))

                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(jit.compiledLoops)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            }
                        }
                        .foregroundColor(gameManager.getFrameRate() >= 20 ? Color(red: 0.4, green: 0.9, blue: 0.4) : Color(red: 1.0, green: 0.6, blue: 0.4))
                        .frame(height: 40)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.5))
                .borderBottom(width: 0.5, color: Color.white.opacity(0.1))

                if showSkinSelector {
                    OrganizedControllerSkinSelector(selectedSkin: $controllerSkin)
                        .padding(12)
                        .background(Color.black.opacity(0.7))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                MetalViewIOS(gameManager: gameManager)
                    .ignoresSafeArea()

                if showControls {
                    OptimizedControlPanel(
                        skin: controllerSkin,
                        onDPadInput: { _ in
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                        },
                        onButtonInput: { _ in
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls.toggle()
            }
        }
    }
}

struct BorderBottomModifier: ViewModifier {
    let width: CGFloat
    let color: Color

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            Divider()
                .frame(height: width)
                .background(color)
        }
    }
}

extension View {
    func borderBottom(width: CGFloat, color: Color) -> some View {
        self.modifier(BorderBottomModifier(width: width, color: color))
    }
}

#Preview {
    ContentView()
}
