import SwiftUI

struct GameRowView: View {
    let game: Game
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Cover thumbnail or placeholder
            Group {
                if !game.coverImagePath.isEmpty,
                   let img = NSImage(contentsOfFile: game.coverImagePath) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.06))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if isRunning {
                        Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
                        Text("Running").font(.caption).foregroundStyle(.green)
                    } else if game.setupStatus == .installing {
                        ProgressView().controlSize(.mini)
                        Text("Setting up…").font(.caption).foregroundStyle(.secondary)
                    } else if game.setupStatus == .error {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 8)).foregroundStyle(.red)
                        Text("Setup failed").font(.caption).foregroundStyle(.red)
                    } else if game.setupStatus == .ready {
                        Text(game.lastPlayedFormatted).font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text(game.setupStatus.rawValue).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
