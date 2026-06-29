import SwiftUI

struct AddGameView: View {
    @EnvironmentObject var store: GameStore
    @State private var exePath = ""
    var onDismiss: (() -> Void)? = nil
    var preselectBottlePath: String? = nil   // when adding software into a specific bottle

    private func dismiss() { AddGameWindowController.shared.window?.close() }
    @State private var bottleMode: BottleMode = .new
    @State private var existingBottleID: UUID? = nil

    enum BottleMode { case new, existing }

    // Bottles that already exist (games with a ready prefix)
    private var existingBottles: [Game] {
        store.games.filter { !$0.resolvedPrefixPath.isEmpty && $0.setupStatus == .ready }
    }

    private var selectedBottle: Game? {
        guard let id = existingBottleID else { return existingBottles.first }
        return existingBottles.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add a Game").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                VStack(spacing: 24) {

                    // Steam shortcut
                    Button { downloadSteam() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle.fill").font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Set up Steam for Windows").font(.subheadline.bold())
                                Text("Downloads Steam installer + installs all prerequisites automatically")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)

                    HStack { Divider(); Text("or add a game directly").font(.caption).foregroundStyle(.tertiary); Divider() }

                    // Drop zone
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                exePath.isEmpty ? Color.accentColor.opacity(0.4) : Color.green,
                                style: StrokeStyle(lineWidth: 2, dash: [8])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(exePath.isEmpty
                                          ? Color.accentColor.opacity(0.05)
                                          : Color.green.opacity(0.08))
                            )

                        if exePath.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 40)).foregroundStyle(Color.accentColor)
                                Text("Drop the game .exe here").font(.title3.bold())
                                Text("or").foregroundStyle(.secondary)
                                Button("Browse for .exe") { pickExe() }.buttonStyle(.borderedProminent)
                            }
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 36)).foregroundStyle(.green)
                                Text(URL(fileURLWithPath: exePath).lastPathComponent).font(.headline)
                                Text(exePath).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .lineLimit(2).multilineTextAlignment(.center)
                                Button("Change") { pickExe() }.font(.caption).buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(height: 180)
                    .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
                        guard let provider = providers.first else { return false }
                        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                            guard let data = item as? Data,
                                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                            DispatchQueue.main.async { exePath = url.path }
                        }
                        return true
                    }

                    // Bottle picker — shown once exe is selected
                    if !exePath.isEmpty {

                        // Bottle section
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Wine Bottle (shared environment)", systemImage: "archivebox").font(.subheadline.bold())
                                Text("Exes in the same bottle share one Windows C:\\ drive and can interact with each other (e.g. a game running inside Steam).")
                                    .font(.caption).foregroundStyle(.secondary)

                                Divider()

                                Picker("", selection: $bottleMode) {
                                    Text("Create new bottle").tag(BottleMode.new)
                                    Text("Use existing bottle").tag(BottleMode.existing)
                                        .disabled(existingBottles.isEmpty)
                                }
                                .pickerStyle(.segmented)

                                if bottleMode == .existing {
                                    if existingBottles.isEmpty {
                                        Text("No ready bottles yet — add and set up a game first.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Picker("Bottle", selection: Binding(
                                            get: { existingBottleID ?? existingBottles.first?.id },
                                            set: { existingBottleID = $0 }
                                        )) {
                                            ForEach(existingBottles) { game in
                                                HStack {
                                                    Text(game.name)
                                                    Text("— \(game.resolvedPrefixPath)")
                                                        .foregroundStyle(.secondary).font(.caption)
                                                }
                                                .tag(Optional(game.id))
                                            }
                                        }
                                        .pickerStyle(.menu)

                                        if let bottle = selectedBottle {
                                            HStack(spacing: 6) {
                                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                                                Text("Will share \(bottle.name)'s prefix at \(bottle.resolvedPrefixPath)")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(4)
                        }

                        // Detection summary
                        let detection = DetectionService.detect(exePath: exePath)
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Auto-detected", systemImage: "sparkles").font(.subheadline.bold())
                            Divider()
                            detectionRow("Architecture", detection.arch.uppercased())
                            detectionRow("DirectX", detection.directX.uppercased())
                            if let ac = detection.antiCheat {
                                detectionRow("Anti-cheat", ac, warning: true)
                            }
                            detectionRow("DXVK", detection.needsDXVK ? "Will install" : "Not needed", accent: detection.needsDXVK)
                            detectionRow("VKD3D", detection.needsVKD3D ? "Will install" : "Not needed", accent: detection.needsVKD3D)
                        }
                        .padding(14)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add & Setup") {
                    // A pre-selected bottle (from the bottle's "+") wins; otherwise
                    // use the picker's choice.
                    let sharedPrefix = preselectBottlePath
                        ?? (bottleMode == .existing ? selectedBottle?.resolvedPrefixPath : nil)
                    store.addAndSetup(exePath: exePath, sharedPrefix: sharedPrefix)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(exePath.isEmpty)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .frame(width: 500, height: exePath.isEmpty ? 460 : 760)
        .animation(.easeInOut(duration: 0.2), value: exePath)
        .animation(.easeInOut(duration: 0.15), value: bottleMode)
    }

    @ViewBuilder
    private func detectionRow(_ label: String, _ value: String, warning: Bool = false, accent: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
            Text(value)
                .bold(accent || warning)
                .foregroundStyle(warning ? .orange : accent ? Color.accentColor : .primary)
        }
        .font(.subheadline)
    }

    private func downloadSteam() {
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/SteamSetup.exe")
        if FileManager.default.fileExists(atPath: dest.path) {
            exePath = dest.path
        } else {
            NSWorkspace.shared.open(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!)
            exePath = dest.path
        }
    }

    private func pickExe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Select the Windows .exe for this game"
        if panel.runModal() == .OK, let url = panel.url {
            exePath = url.path
        }
    }
}
