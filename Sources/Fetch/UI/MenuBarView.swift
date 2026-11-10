import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fetch")
                .font(.system(size: 13, weight: .semibold))
            Text(model.menuStatus)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .preview = model.phase {
                Button("Download") { model.download() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button("Open Fetch") {
                openWindow(id: "main")
                NSApp.activate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }
}
