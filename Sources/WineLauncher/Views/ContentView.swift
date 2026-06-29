import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: GameStore
    @State private var selectedGameID: UUID? = nil
    @State private var showAddGame = false
    @State private var searchText = ""
    @State private var addSoftwareBottlePath: String? = nil   // pre-selected bottle when adding software
    @State private var expandedBottles: Set<String> = []      // which bottles are opened in the sidebar

    private func bottleExpanded(_ path: String) -> Binding<Bool> {
        Binding(
            get: { expandedBottles.contains(path) },
            set: { isOn in
                if isOn { expandedBottles.insert(path) } else { expandedBottles.remove(path) }
            }
        )
    }

    var filteredGames: [Game] {
        if searchText.isEmpty { return store.games }
        return store.games.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // Games grouped by their Wine bottle (prefix) — the sidebar shows one
    // section per bottle rather than a flat list of games.
    var bottleGroups: [(bottle: String, path: String, games: [Game])] {
        let grouped = Dictionary(grouping: filteredGames, by: { $0.resolvedPrefixPath })
        return grouped.map { (path, games) in
            (bottle: Self.bottleName(for: path), path: path,
             games: games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
        .sorted { $0.bottle.localizedCaseInsensitiveCompare($1.bottle) == .orderedAscending }
    }

    // A friendly name for a bottle: the prefix folder, or its parent when the
    // prefix is just called "wineprefix".
    static func bottleName(for prefixPath: String) -> String {
        let url = URL(fileURLWithPath: prefixPath)
        let last = url.lastPathComponent
        if last.lowercased() == "wineprefix" || last.lowercased() == "pfx" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return last
    }

    private func promptNewBottle() {
        let alert = NSAlert()
        alert.messageText = "Nouvelle bouteille"
        alert.informativeText = "Donne un nom à la bouteille (un prefix Wine isolé pour tes logiciels)."
        alert.addButton(withTitle: "Créer")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Ma bouteille"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { store.addBottle(name: name) }
        }
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
        .onChange(of: showAddGame) { _, show in
            if show {
                AddGameWindowController.shared.open(store: store, preselectBottle: addSoftwareBottlePath) {
                    selectedGameID = store.games.last?.id
                    showAddGame = false
                    addSoftwareBottlePath = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newBottle)) { _ in
            promptNewBottle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .addSoftware)) { _ in
            addSoftwareBottlePath = nil
            showAddGame = true
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "gamecontroller.fill").foregroundStyle(Color.accentColor)
                Text("Elvius Gaming").font(.headline)
                Spacer()
                Button { selectedGameID = nil } label: {
                    Image(systemName: "square.grid.2x2.fill").font(.title3)
                        .foregroundStyle(selectedGameID == nil ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Galerie / Bibliothèque")
                Menu {
                    Button("Nouvelle bouteille…", systemImage: "shippingbox") { promptNewBottle() }
                        .keyboardShortcut("n", modifiers: .command)
                    Button("Ajouter un logiciel…", systemImage: "plus.app") {
                        addSoftwareBottlePath = nil; showAddGame = true
                    }.keyboardShortcut("n", modifiers: [.command, .shift])
                    Divider()
                    Button("Scanner l'ordinateur", systemImage: "magnifyingglass") {
                        let n = store.scanComputer()
                        let a = NSAlert()
                        a.messageText = n > 0 ? "\(n) jeu(x) trouvé(s)" : "Aucun nouveau jeu trouvé"
                        a.runModal()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("Ajouter")
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

            // Bottle list
            if store.allBottles.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("Crée ta première bouteille")
                        .foregroundStyle(.secondary).font(.callout)
                    Button("Nouvelle bouteille") { promptNewBottle() }.buttonStyle(.borderedProminent)
                }
                Spacer()
            } else {
                List(selection: $selectedGameID) {
                    ForEach(store.allBottles) { bottle in
                        let bottleGames = store.games(in: bottle).filter {
                            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                        }
                        Section(isExpanded: bottleExpanded(bottle.prefixPath)) {
                            ForEach(bottleGames) { game in
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
                            if bottleGames.isEmpty {
                                Text("Aucun logiciel — clic-droit pour en ajouter")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        } header: {
                            HStack {
                                Label("\(bottle.name)  ·  \(bottleGames.count)", systemImage: "shippingbox.fill")
                                Spacer()
                                Button { addSoftwareBottlePath = bottle.prefixPath; showAddGame = true } label: {
                                    Image(systemName: "plus")
                                }.buttonStyle(.plain).help("Ajouter un logiciel à cette bouteille")
                            }
                            .font(.caption)
                            .contextMenu {
                                Button("Ajouter un logiciel…") { addSoftwareBottlePath = bottle.prefixPath; showAddGame = true }
                                Button("Ouvrir le disque C:") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: bottle.prefixPath + "/drive_c"))
                                }
                                Button("Ouvrir le dossier de la bouteille") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: bottle.prefixPath))
                                }
                                if store.bottles.contains(where: { $0.id == bottle.id }) {
                                    Divider()
                                    Button("Supprimer la bouteille", role: .destructive) {
                                        store.deleteBottle(id: bottle.id)
                                    }
                                }
                            }
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

    // Library gallery shown when no game is selected: stats header + cover grid.
    private var emptyState: some View {
        let totalGames = store.games.count
        let playedThisMonth = store.games.filter { $0.playedThisMonth }.count
        let totalHours = store.games.reduce(0.0) { $0 + $1.totalPlaytime } / 3600.0
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 18)]

        return ScrollView {
            VStack(spacing: 24) {
                // Header stats
                HStack(spacing: 16) {
                    statCard(value: "\(totalGames)", label: "Jeux au total", icon: "square.stack.fill", color: .blue)
                    statCard(value: "\(playedThisMonth)", label: "Joués ce mois-ci", icon: "calendar", color: .green)
                    statCard(value: String(format: "%.1f h", totalHours), label: "Heures jouées", icon: "clock.fill", color: .orange)
                }
                .padding(.top, 24)

                if store.games.isEmpty {
                    Button("Ajouter un jeu") { showAddGame = true }.buttonStyle(.borderedProminent).padding(.top, 40)
                } else {
                    // Cover grid
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(store.games) { game in
                            coverTile(game)
                                .onTapGesture { selectedGameID = game.id }
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func coverTile(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if !game.coverImagePath.isEmpty, let img = NSImage(contentsOfFile: game.coverImagePath) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        LinearGradient(colors: [Color.accentColor.opacity(0.5), Color.purple.opacity(0.4)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .overlay(Image(systemName: "gamecontroller.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.85)))
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipped()
                // Running indicator
                if store.runningGameID == game.id {
                    Text("En cours").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.green, in: Capsule()).foregroundStyle(.white).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))

            Text(game.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: game.os.symbol).font(.system(size: 8))
                Text(game.totalPlaytime > 0 ? game.playtimeFormatted : "Jamais joué")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text(value).font(.system(.title, design: .rounded).bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 130, height: 110)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
