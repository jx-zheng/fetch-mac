import AppKit
import Combine
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
    @StateObject private var model: AppModel
    @StateObject private var menuBar: MenuBarInsertion

    init() {
        let model = AppModel.shared
        _model = StateObject(wrappedValue: model)
        _menuBar = StateObject(wrappedValue: MenuBarInsertion(model: model))
    }

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

    /// MenuBarExtra writes `isInserted` on every scene update. Writing the same
    /// value through `@Published` still publishes, which rebuilds the scene and
    /// writes the binding again. That loop was the launch CPU peg.
    private var menuBarBinding: Binding<Bool> {
        Binding(
            get: { menuBar.inserted },
            set: { newValue in
                guard menuBar.inserted != newValue else { return }
                menuBar.apply(newValue)
                if model.showMenuBar != newValue {
                    model.showMenuBar = newValue
                }
            }
        )
    }
}

/// Menu-bar visibility that does not publish when MenuBarExtra echoes the current value.
private final class MenuBarInsertion: ObservableObject {
    @Published private(set) var inserted: Bool
    private var observation: AnyCancellable?

    init(model: AppModel) {
        inserted = model.showMenuBar
        observation = model.$showMenuBar
            .removeDuplicates()
            .sink { [weak self] value in
                self?.apply(value)
            }
    }

    func apply(_ value: Bool) {
        guard inserted != value else { return }
        inserted = value
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
