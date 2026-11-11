import AppKit
import FetchCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, downloads, engine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .downloads: return "Downloads"
        case .engine: return "Engine"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .downloads: return "arrow.down"
        case .engine: return "terminal"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: SettingsTab = .general
    @State private var barHeight: CGFloat = 28
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { item in
                    tabButton(item)
                }
            }
            .background(LayoutMarker(name: "settingsTabRow"))
            .padding(.top, 8)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 0.5) }
            Group {
                switch tab {
                case .general: general
                case .downloads: downloads
                case .engine: engine
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .frame(width: 500)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            ZStack {
                (scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.95, green: 0.95, blue: 0.96))
                WindowBackground()
                (scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.62))
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            settingsTitleChrome
                .frame(height: barHeight)
                .frame(maxWidth: .infinity)
                .ignoresSafeArea(edges: .top)
        }
        .background {
            TitleBarInsetReader { inset in
                if abs(inset - barHeight) > 0.5 { barHeight = inset }
            }
        }
    }

    /// The pane title sits on the traffic-light row, same as the main window.
    private var settingsTitleChrome: some View {
        ZStack {
            titleFill.allowsHitTesting(false)
            LayoutMarker(name: "settingsTitleBar")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            WindowDragRegion()
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .allowsHitTesting(false)
                .background(LayoutMarker(name: "settingsPaneTitle"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var titleFill: Color {
        scheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.95, green: 0.95, blue: 0.96)
    }

    private func tabButton(_ item: SettingsTab) -> some View {
        Button {
            tab = item
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14))
                    .background(LayoutMarker(name: "settings-tab-\(item.rawValue)-icon"))
                Text(item.title)
                    .font(.system(size: 11))
                    .background(LayoutMarker(name: "settings-tab-\(item.rawValue)-label"))
            }
            .foregroundStyle(tab == item ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minWidth: 88, minHeight: 48)
            .contentShape(Rectangle())
            .background { LayoutMarker(name: "settings-tab-\(item.rawValue)") }
            .background(tab == item ? Theme.chip : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(item.title)
        .accessibilityIdentifier("settings-tab-\(item.rawValue)")
        .accessibilityAddTraits(tab == item ? .isSelected : [])
    }

    private var videoQuality: Binding<Quality> {
        Binding(
            get: { Quality.videoDefault(stored: model.defaultQuality.rawValue) },
            set: { model.defaultQuality = $0 }
        )
    }

    private var audioQuality: Binding<Quality> {
        Binding(
            get: { Quality.audioDefault(stored: model.defaultAudioQuality.rawValue, legacyVideoKey: nil) },
            set: { model.defaultAudioQuality = $0 }
        )
    }

    private var general: some View {
        VStack(spacing: 0) {
            row("Save to") {
                Button(action: model.chooseFolder) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Theme.secondary)
                        Text(model.saveName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.secondary)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(width: 180, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .background(Theme.field.opacity(0.8), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Save to \(model.saveName)")
            }
            row("Default format") {
                Picker("Default format", selection: $model.container) {
                    ForEach(ContainerFormat.allCases) { format in
                        Text(format.menuTitle).tag(format)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            row("Watch the clipboard", subtitle: "Offer to fetch when you copy a video link") {
                Toggle("Watch the clipboard", isOn: $model.watchClipboard)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            row("Show in menu bar") {
                Toggle("Show in menu bar", isOn: $model.showMenuBar)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            row("Download engine", subtitle: model.engineSummary, last: true) {
                Button(action: model.checkEngineNow) {
                    Text(model.engineBusy ? "Checking…" : "Check now")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .background(Theme.field.opacity(0.8), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(model.engineBusy)
            }
        }
        .background(LayoutMarker(name: "settings-pane-general"))
    }

    private var downloads: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Files are saved with the video’s title. Characters that don’t belong in a file name are removed, and Fetch won’t write outside the folder you pick.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            HStack {
                Text("Video quality")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                Spacer()
                Picker("Video quality", selection: videoQuality) {
                    ForEach(Quality.choices(for: .mp4H264, sourceHeights: [])) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            HStack {
                Text("Audio quality")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                Spacer()
                Picker("Audio quality", selection: audioQuality) {
                    ForEach(Quality.choices(for: .mp3, sourceHeights: [])) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Max size")
                        .font(.system(size: 13))
                    Text("Re-encode when the best file is larger than this")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Toggle("Max size", isOn: $model.maxSizeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Button(action: model.revealSaveFolder) {
                Text("Show the save folder in Finder")
                    .font(.system(size: 13))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LayoutMarker(name: "settings-pane-downloads"))
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("yt-dlp, ffmpeg, and Deno live in Application Support so the engine can update itself. Fetch checks the published SHA-256 before it runs a new build.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            versionLine("yt-dlp", model.ytDlpVersion)
            versionLine("Deno", model.denoVersion)
            versionLine("ffmpeg", model.ffmpegVersion)
            Text(model.engineStatus)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                Button("Update stable") { model.updateEngine(channel: "stable") }
                Button("Update nightly") { model.updateEngine(channel: "nightly") }
            }
            .disabled(model.engineBusy)
            Text("Nightly is only for when a site changes and the stable engine can’t read it yet.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LayoutMarker(name: "settings-pane-engine"))
    }

    private func versionLine(_ name: String, _ version: String) -> some View {
        HStack {
            Text(name)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
            Spacer()
            Text(version)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.secondary)
        }
    }

    private func row<Control: View>(_ title: String, subtitle: String? = nil, last: Bool = false, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(Theme.separator).frame(height: 0.5) }
        }
    }
}
