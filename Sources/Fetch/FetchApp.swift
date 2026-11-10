import AppKit
import SwiftUI

@main
enum FetchEntry {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--screenshots"), arguments.indices.contains(index + 1) {
            ScreenshotHarness.run(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            return
        }
        if arguments.contains("--launch-sample") || arguments.contains("--idle-benchmark") {
            AppFlags.launchSample = true
            AppFlags.skipEngineUpdate = true
        }
        if arguments.contains("--cli") {
            let group = DispatchGroup()
            group.enter()
            Task.detached {
                await CLI.run()
                group.leave()
            }
            group.wait()
            return
        }
        FetchApp.main()
    }
}

struct FetchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Fetch", id: "main") {
            MainContainer(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands { FetchCommands() }

        Window("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Fetch", systemImage: "arrow.down.circle", isInserted: menuBarBinding) {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarBinding: Binding<Bool> {
        $model.showMenuBar
    }
}

struct MainContainer: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainView(
            urlText: $model.urlText,
            container: $model.container,
            quality: $model.quality,
            maxSizeEnabled: $model.maxSizeEnabled,
            maxSizeText: $model.maxSizeText,
            phase: model.phase,
            clipboardOffer: model.clipboardOffer,
            saveName: model.saveName,
            dropActive: model.dropActive,
            actions: MainActions(
                submit: model.submit,
                clear: model.clear,
                download: model.download,
                cancel: model.cancelDownload,
                settings: { openWindow(id: "settings") },
                chooseFolder: model.chooseFolder,
                primary: model.primaryAction,
                secondary: model.secondaryAction,
                reveal: model.revealCompleted,
                openFile: model.openCompleted,
                drop: model.handleDrop,
                acceptOffer: model.acceptClipboardOffer,
                dismissOffer: model.dismissClipboardOffer
            )
        )
        .onChange(of: model.urlText) { _, _ in model.noteTyping() }
        .onAppear { model.start() }
    }
}

struct FetchCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.showMenuBar
    }
}
