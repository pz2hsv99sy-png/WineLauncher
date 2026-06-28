import SwiftUI

struct LogView: View {
    let log: String
    let isRunning: Bool
    let onStop: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                HStack(spacing: 6) {
                    if isRunning {
                        ProgressView().controlSize(.small)
                        Text("Game running…").font(.subheadline.bold())
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Process exited").font(.subheadline.bold())
                    }
                }
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScroll).font(.caption).toggleStyle(.checkbox)
                if isRunning {
                    Button("Force Stop") { onStop() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(12)
            .background(.ultraThinMaterial)

            Divider()

            // Log output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "Waiting for output…" : log)
                        .font(.caption.monospaced())
                        .foregroundStyle(log.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: log) { _, _ in
                    if autoScroll {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .frame(width: 700, height: 420)
    }
}
