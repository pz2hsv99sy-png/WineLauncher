import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: GameStore
    @State private var selectedGameID: UUID? = nil
    @State private var showAddGame = false
    @State private var searchText = ""

    var filteredGames: [Game] {
        if searchText.isEmpty { return store.games }
        return store.games.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = selectedGameID {
                GameDetailView(gameID: id)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showAddGame) {
            AddGameView()
                .environmentObject(store)
                .onDisappear {
                    // Select the newest game after adding
                    selectedGameID = store.games.last?.id
                }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gamecontroller.fill").foregroundStyle(Color.accentColor)
                Text("Wine Launcher").font(.headline)
                Spacer()
                Button { showAddGame = true } label: {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Add Game")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search games…", text: $searchText).textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Game list
            if filteredGames.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: store.games.isEmpty ? "plus.square.dashed" : "magnifyingglass")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(store.games.isEmpty ? "Add your first game" : "No results")
                        .foregroundStyle(.secondary).font(.callout)
                    if store.games.isEmpty {
                        Button("Add Game") { showAddGame = true }.buttonStyle(.borderedProminent)
                    }
                }
                Spacer()
            } else {
                List(filteredGames, selection: $selectedGameID) { game in
                    GameRowView(game: game, isRunning: store.runningGameID == game.id)
                        .tag(game.id)
                        .contextMenu {
                            Button("Launch") { store.launch(game: game) }
                                .disabled(game.setupStatus != .ready)
                            Divider()
                            Button("Remove", role: .destructive) {
                                if selectedGameID == game.id { selectedGameID = nil }
                                store.delete(id: game.id)
                            }
                        }
                }
                .listStyle(.sidebar)
            }

            Divider()

            // Footer
            VStack(spacing: 4) {
                HStack {
                    Circle()
                        .fill(store.runningGameID != nil ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(store.runningGameID != nil
                         ? "Running: \(store.games.first { $0.id == store.runningGameID }?.name ?? "")"
                         : "\(store.games.count) game\(store.games.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if store.runningGameID != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2").font(.caption2).foregroundStyle(.secondary)
                        Text("HUD:").font(.caption2).foregroundStyle(.secondary)
                        Picker("", selection: store.hudCornerBinding) {
                            ForEach(HUDCorner.allCases, id: \.self) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .controlSize(.mini)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller").font(.system(size: 64)).foregroundStyle(.tertiary)
            Text("Select a game to play").foregroundStyle(.secondary)
            Button("Add Game") { showAddGame = true }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
