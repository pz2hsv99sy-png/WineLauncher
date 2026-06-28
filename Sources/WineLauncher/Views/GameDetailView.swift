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
            .sheet(isPresented: $showLog) {
                LogView(log: store.launchLog, isRunning: store.runningGameID == game.id) {
                    store.stopRunning()
                }
            }
            .onChange(of: store.runningGameID) { _, id in
                if id == game.id { showLog = true }
            }
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

                Text(game.lastPlayedFormatted).font(.caption).foregroundStyle(.tertiary)
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
            }
        }
        .padding(24)
        .background(.ultraThinMaterial)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 20) {

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

            // Launch log button (if ran before)
            if !store.launchLog.isEmpty {
                Button { showLog = true } label: {
                    Label("View last launch log", systemImage: "doc.text").font(.callout)
                }
                .buttonStyle(.borderless).foregroundStyle(Color.accentColor)
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
