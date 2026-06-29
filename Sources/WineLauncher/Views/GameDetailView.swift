import SwiftUI

struct GameDetailView: View {
    @EnvironmentObject var store: GameStore
    let gameID: UUID
    @State private var showLog = false
    @State private var isEditingName = false
    @State private var editName = ""

    private var game: Game? { store.games.first { $0.id == gameID } }
    private var isRunning: Bool { store.runningGameID == gameID }
    private var progress: SetupProgress? { store.setupProgress[gameID] }

    var body: some View {
        if let game {
            ScrollView {
                VStack(spacing: 0) {
                    header(game)
                    Divider()
                    body(game).padding(24)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear { store.loadAchievements(for: game) }
            }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ game: Game) -> some View {
        HStack(spacing: 20) {
            // Cover
            ZStack {
                if !game.coverImagePath.isEmpty, let img = NSImage(contentsOfFile: game.coverImagePath) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.2)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 36)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 90, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.1)))
            .shadow(radius: 6)

            VStack(alignment: .leading, spacing: 6) {
                // Editable name
                if isEditingName {
                    HStack {
                        TextField("", text: $editName)
                            .font(.title2.bold()).textFieldStyle(.roundedBorder)
                            .onSubmit { store.rename(id: game.id, to: editName); isEditingName = false }
                        Button("✓") { store.rename(id: game.id, to: editName); isEditingName = false }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(game.name).font(.title2.bold())
                        Button { editName = game.name; isEditingName = true } label: {
                            Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                        }.buttonStyle(.plain)
                    }
                }

                // Status badge
                statusBadge(game)

                HStack(spacing: 10) {
                    Label(game.lastPlayedFormatted, systemImage: "clock.arrow.circlepath")
                    if game.totalPlaytime > 0 {
                        Label(game.playtimeFormatted, systemImage: "hourglass")
                    }
                    Label(game.os.rawValue, systemImage: game.os.symbol)
                }
                .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            // Big play button
            VStack(spacing: 4) {
                Button {
                    if isRunning { store.stopRunning() }
                    else { store.launch(game: game) }
                } label: {
                    Image(systemName: isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(
                            game.setupStatus != .ready ? .gray :
                            isRunning ? .orange : Color.accentColor
                        )
                        .symbolEffect(.pulse, isActive: isRunning)
                }
                .buttonStyle(.plain)
                .disabled(game.setupStatus != .ready && !isRunning)
                .help(game.setupStatus != .ready ? "Game not ready yet" : isRunning ? "Force stop" : "Launch game")

                Text(isRunning ? "Running" : game.setupStatus == .ready ? "Play" : game.setupStatus.rawValue)
                    .font(.caption.bold())
                    .foregroundStyle(isRunning ? .orange : game.setupStatus == .ready ? Color.accentColor : .secondary)

                // Per-bottle actions
                HStack(spacing: 6) {
                    Button {
                        store.openCDrive(for: game)
                    } label: {
                        Label("Disque C:", systemImage: "externaldrive").labelStyle(.iconOnly)
                    }
                    .help("Ouvrir le disque C: de la bouteille")

                    Button {
                        promptCustomCommand(for: game)
                    } label: {
                        Label("Commande", systemImage: "terminal").labelStyle(.iconOnly)
                    }
                    .help("Lancer une commande dans la bouteille")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(24)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func achievementsSection(_ game: Game) -> some View {
        let list = store.achievements[game.id] ?? []
        if !list.isEmpty {
            let unlocked = list.filter { $0.unlocked }.count
            let total = list.count
            let cols = [GridItem(.adaptive(minimum: 54, maximum: 54), spacing: 8)]
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Succès", systemImage: "trophy.fill").font(.headline)
                        Spacer()
                        Text("\(unlocked) / \(total)").font(.subheadline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
                    }
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.1))
                            Capsule().fill(Color.yellow)
                                .frame(width: geo.size.width * (total > 0 ? CGFloat(unlocked) / CGFloat(total) : 0))
                        }
                    }.frame(height: 6)
                    // Icon grid (locked ones greyed)
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(list) { ach in
                            AsyncImage(url: URL(string: ach.iconURL)) { img in
                                img.resizable().scaledToFit()
                            } placeholder: {
                                Color.primary.opacity(0.08)
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .saturation(ach.unlocked ? 1 : 0)
                            .opacity(ach.unlocked ? 1 : 0.35)
                            .help("\(ach.name)\(ach.unlocked ? " ✓" : "")\n\(ach.desc)")
                        }
                    }
                }.padding(4)
            }
        }
    }

    // Finalize an installer: find the installed exe, re-point, trash the setup.
    private func finalizeInstall(_ game: Game) {
        let candidates = store.finalizeInstall(gameID: game.id)
        if candidates.count <= 1 { return }   // auto-picked (or none found)

        // Multiple candidates — let the user choose the real game exe.
        let alert = NSAlert()
        alert.messageText = "Quel est le jeu installé ?"
        alert.informativeText = "Plusieurs exécutables trouvés. Choisis le bon — le setup ira à la corbeille."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        for c in candidates { popup.addItem(withTitle: (c as NSString).lastPathComponent); popup.lastItem?.toolTip = c }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Choisir")
        alert.addButton(withTitle: "Annuler")
        if alert.runModal() == .alertFirstButtonReturn {
            let chosen = candidates[popup.indexOfSelectedItem]
            store.repoint(gameID: game.id, toExe: chosen, trashOldInstaller: game.exePath)
        }
    }

    // Ask for a command line and run it inside the game's bottle.
    private func promptCustomCommand(for game: Game) {
        let alert = NSAlert()
        alert.messageText = "Commande dans la bouteille « \(ContentView.bottleName(for: game.resolvedPrefixPath)) »"
        alert.informativeText = "Exemples : winecfg · regedit · explorer · un autre .exe"
        alert.addButton(withTitle: "Lancer")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "winecfg"
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            let cmd = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !cmd.isEmpty { store.runCustomCommand(for: game, command: cmd) }
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func body(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 20) {

            // Achievements
            achievementsSection(game)

            // Installer banner
            if store.isInstaller(game.exePath) {
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox.and.arrow.backward").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Installeur détecté").font(.subheadline.bold())
                            Text("Lance l'installeur (bouton Play), puis Finalise : je pointe vers le jeu installé et j'envoie le setup à la corbeille.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Finaliser") { finalizeInstall(game) }
                            .buttonStyle(.borderedProminent)
                    }.padding(4)
                }
            }

            // Detection results
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Auto-detected Configuration", systemImage: "sparkles").font(.headline)
                    Divider()
                    HStack(spacing: 24) {
                        infoChip("Architecture", game.detection.arch.uppercased(), icon: "cpu")
                        infoChip("DirectX", game.detection.directX.uppercased(), icon: "display")
                        if let ac = game.detection.antiCheat {
                            infoChip("Anti-cheat", ac, icon: "lock.shield", color: .orange)
                        }
                        infoChip("DXVK", game.detection.needsDXVK ? "Active" : "—",
                                 icon: "bolt", color: game.detection.needsDXVK ? Color.accentColor : .secondary)
                        infoChip("VKD3D", game.detection.needsVKD3D ? "Active" : "—",
                                 icon: "bolt.fill", color: game.detection.needsVKD3D ? Color.accentColor : .secondary)
                    }
                    if !game.detection.notes.isEmpty {
                        Divider()
                        ForEach(game.detection.notes, id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(4)
            }

            // Paths
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Paths", systemImage: "folder").font(.headline)
                    Divider()
                    pathRow("Executable", game.exePath)
                    pathRow("Wine Prefix", game.resolvedPrefixPath)
                }
                .padding(4)
            }

            // Progress bar (visible during setup)
            if let p = progress, game.setupStatus == .installing {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Installing prerequisites…", systemImage: "arrow.down.circle")
                                .font(.headline)
                            Spacer()
                            Text(p.etaString)
                                .font(.caption).foregroundStyle(.secondary)
                            Button {
                                store.cancelSetup(id: game.id)
                            } label: {
                                Image(systemName: "stop.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel setup")
                        }
                        ProgressView(value: p.fraction)
                            .progressViewStyle(.linear)
                            .tint(Color.accentColor)
                        HStack {
                            Text("[\(p.current)/\(p.total)] \(p.currentPackage)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(p.fraction * 100))%")
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(4)
                }
            }

            // Setup log / error
            if !game.setupError.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(
                                game.setupStatus == .error ? "Setup Error" : "Setup Log",
                                systemImage: game.setupStatus == .error ? "exclamationmark.triangle" : "terminal"
                            )
                            .font(.headline)
                            .foregroundStyle(game.setupStatus == .error ? .red : .primary)
                            Spacer()
                            if game.setupStatus == .error {
                                Button("Retry Setup") { store.reRunSetup(id: game.id) }
                                    .buttonStyle(.borderedProminent).tint(.orange)
                            }
                        }
                        Divider()
                        ScrollView {
                            Text(game.setupError)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(4)
                }
            }

            // Optional extras (only shown when game is ready)
            if game.setupStatus == .ready {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Optional Extras", systemImage: "plus.circle").font(.headline)
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(".NET Framework 4.8").font(.subheadline.bold())
                                Text("Required by some Unity games, EA App, Ubisoft Connect. Takes ~5 min.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Install") {
                                store.installExtra(gameID: game.id, verb: "dotnet48")
                            }
                            .buttonStyle(.bordered)
                            .disabled(game.setupStatus == .installing)
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Media Foundation (mf)").font(.subheadline.bold())
                                Text("Required for in-game video cutscenes.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Install") {
                                store.installExtra(gameID: game.id, verb: "mf")
                            }
                            .buttonStyle(.bordered)
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("vcrun2013 + vcrun2010").font(.subheadline.bold())
                                Text("Older VC++ runtimes for legacy games (pre-2015).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Install") {
                                store.installExtra(gameID: game.id, verb: "vcrun2013 vcrun2010")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(4)
                }
            }

            // Launch log — always visible when there's content
            if !store.launchLog.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(isRunning ? "Launch Log (live)" : "Last Launch Log", systemImage: "terminal")
                                .font(.headline)
                            if isRunning {
                                ProgressView().controlSize(.mini).padding(.leading, 4)
                            }
                            Spacer()
                            if isRunning {
                                Button("Force Stop") { store.stopRunning() }
                                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
                            }
                        }
                        Divider()
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(store.launchLog)
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("bottom")
                            }
                            .frame(maxHeight: 220)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onChange(of: store.launchLog) { _, _ in
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .padding(4)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusBadge(_ game: Game) -> some View {
        HStack(spacing: 5) {
            switch game.setupStatus {
            case .notSetup:
                Image(systemName: "circle").foregroundStyle(.secondary)
                Text(game.setupStatus.rawValue)
            case .installing:
                ProgressView().controlSize(.mini)
                Text("Setting up…")
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready to play")
            case .error:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text("Setup failed")
            }
        }
        .font(.caption.bold())
        .foregroundStyle(game.setupStatus == .ready ? .green :
                         game.setupStatus == .error ? .red : .secondary)
    }

    @ViewBuilder
    private func infoChip(_ label: String, _ value: String, icon: String, color: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(value).font(.caption.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(minWidth: 60)
    }

    @ViewBuilder
    private func pathRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            Text(value.isEmpty ? "—" : value)
                .font(.caption.monospaced())
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
        }
    }
}
