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
        if let index = arguments.firstIndex(of: "--menu-shots"),
           arguments.indices.contains(index + 2) {
            AppFlags.skipEngineUpdate = true
            let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            let media = arguments[index + 2]
            DispatchQueue.main.async {
                Task { @MainActor in
                    await MenuShots.run(directory: directory, media: media)
                }
            }
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.run()
            return
        }
        if let index = arguments.firstIndex(of: "--titlebar-check"), arguments.indices.contains(index + 1) {
            AppFlags.titlebarCheckURL = arguments[index + 1]
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
    @StateObject private var model: AppModel
    @State private var menuBarInserted: Bool

    init() {
        let model = AppModel.shared
        _model = StateObject(wrappedValue: model)
        _menuBarInserted = State(initialValue: model.showMenuBar)
    }

    var body: some Scene {
        Window("Fetch", id: "main") {
            MainContainer(model: model)
                .onChange(of: model.showMenuBar) { _, newValue in
                    if menuBarInserted != newValue { menuBarInserted = newValue }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands { FetchCommands() }

        Window("Settings", id: "settings") {
            SettingsView(model: model)
                .onChange(of: model.showMenuBar) { _, newValue in
                    if menuBarInserted != newValue { menuBarInserted = newValue }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Fetch", systemImage: "arrow.down.circle", isInserted: menuBarBinding) {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    /// MenuBarExtra writes `isInserted` on every scene update. Writing that
    /// echo into `showMenuBar` published again, rebuilt the scene, and wrote
    /// the binding again. That loop pegged a core and grew RSS. `@State`
    /// ignores an unchanged Bool, and the setter refuses to publish the model.
    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { menuBarInserted },
            set: { newValue in
                guard menuBarInserted != newValue else { return }
                menuBarInserted = newValue
                if model.showMenuBar != newValue {
                    model.showMenuBar = newValue
                }
            }
        )
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
            sourceHeights: model.sourceHeights,
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
        if let path = AppFlags.titlebarCheckURL {
            TitlebarCheck.run(saving: URL(fileURLWithPath: path))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.showMenuBar
    }
}
