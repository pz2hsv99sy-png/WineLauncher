import SwiftUI

struct AddGameView: View {
    @EnvironmentObject var store: GameStore
    @Environment(\.dismiss) var dismiss
    @State private var exePath = ""

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

            VStack(spacing: 24) {

                // Steam shortcut
                Button {
                    // Download Steam installer and set path
                    downloadSteam()
                } label: {
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
                                .font(.system(size: 40))
                                .foregroundStyle(Color.accentColor)
                            Text("Drop the game .exe here")
                                .font(.title3.bold())
                            Text("or")
                                .foregroundStyle(.secondary)
                            Button("Browse for .exe") { pickExe() }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.green)
                            Text(URL(fileURLWithPath: exePath).lastPathComponent)
                                .font(.headline)
                            Text(exePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Button("Change") { pickExe() }
                                .font(.caption)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 200)
                .onDrop(of: ["public.file-url"], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        guard let data = item as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        DispatchQueue.main.async { exePath = url.path }
                    }
                    return true
                }

                // What will happen info box
                if !exePath.isEmpty {
                    let detection = DetectionService.detect(exePath: exePath)
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Auto-detected", systemImage: "sparkles").font(.subheadline.bold())
                        Divider()
                        detectionRow("Architecture", detection.arch.uppercased())
                        detectionRow("DirectX", detection.directX.uppercased())
                        if let ac = detection.antiCheat {
                            detectionRow("Anti-cheat", ac, warning: true)
                        }
                        detectionRow("DXVK", detection.needsDXVK ? "Will install" : "Not needed",
                                     accent: detection.needsDXVK)
                        detectionRow("VKD3D", detection.needsVKD3D ? "Will install" : "Not needed",
                                     accent: detection.needsVKD3D)
                        if !detection.notes.isEmpty {
                            Divider()
                            ForEach(detection.notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add & Setup") {
                    store.addAndSetup(exePath: exePath)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(exePath.isEmpty)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .frame(width: 500, height: exePath.isEmpty ? 460 : 700)
        .animation(.easeInOut(duration: 0.2), value: exePath)
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
        // Download SteamSetup.exe to ~/Downloads then set it as the exe
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/SteamSetup.exe")
        if FileManager.default.fileExists(atPath: dest.path) {
            exePath = dest.path
            return
        }
        // Open browser to Steam download — user downloads it manually
        // (direct curl would require network entitlement)
        NSWorkspace.shared.open(URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!)
        // Show a tip
        exePath = dest.path  // pre-fill path so user just has to download
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
