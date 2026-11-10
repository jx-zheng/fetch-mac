import AppKit
import FetchCore
import SwiftUI

struct MainActions {
    var submit: () -> Void = {}
    var clear: () -> Void = {}
    var download: () -> Void = {}
    var cancel: () -> Void = {}
    var settings: () -> Void = {}
    var chooseFolder: () -> Void = {}
    var primary: () -> Void = {}
    var secondary: () -> Void = {}
    var reveal: () -> Void = {}
    var openFile: () -> Void = {}
    var drop: ([NSItemProvider]) -> Bool = { _ in false }
}

struct MainView: View {
    @Binding var urlText: String
    @Binding var container: ContainerFormat
    @Binding var quality: Quality
    @Binding var maxSizeEnabled: Bool
    @Binding var maxSizeText: String
    var phase: ScreenPhase
    var saveName: String
    var dropActive: Bool
    var actions: MainActions
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            VStack(spacing: 0) {
                linkField
                content
                    .padding(.top, 14)
                controls
                    .padding(.top, 14)
                footer
                    .padding(.top, 18)
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 20)
        }
        .frame(width: 540)
        .fixedSize(horizontal: true, vertical: true)
        .background(background)
        .onDrop(of: [.url, .plainText, .fileURL], isTargeted: nil) { providers in
            actions.drop(providers)
        }
    }

    private var background: some View {
        ZStack {
            WindowBackground()
            (scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.62))
        }
    }

    private var titleBar: some View {
        ZStack {
            Text("Fetch")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
            HStack {
                Spacer()
                Button(action: actions.settings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.trailing, 12)
        }
        .frame(height: 46)
    }

    private var linkField: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
            TextField("Paste a video link", text: $urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .disabled(isBusy)
                .onSubmit(actions.submit)
                .accessibilityIdentifier("linkField")
            if urlText.isEmpty {
                Text("⌘V")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if !isBusy {
                Button(action: actions.clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 20, height: 20)
                        .background(Theme.chip, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear link")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focused ? Theme.accent : Color.primary.opacity(scheme == .dark ? 0.12 : 0.1), lineWidth: focused ? 1 : 0.5)
        )
        .shadow(color: focused ? Theme.accent.opacity(0.18) : .clear, radius: 0, y: 0)
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.35) : .clear, lineWidth: 3.5)
                .padding(-2)
        )
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .empty:
            dropZone
        case .resolving(let message):
            resolvingCard(message)
        case .preview(let preview):
            previewCard(preview)
        case .downloading(let preview, let progress):
            progressCard(preview, progress)
        case .completed(let completed):
            completedCard(completed)
        case .failed(let problem):
            errorCard(problem)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.square")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Theme.tertiary)
            Text(dropActive ? "Drop to fetch" : "or drop a link here")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 120)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(dropActive ? Theme.accent : Theme.separator)
        )
        .accessibilityLabel("Drop a video link")
    }

    private func resolvingCard(_ message: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func previewCard(_ preview: PreviewContent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            thumb(preview)
            VStack(alignment: .leading, spacing: 0) {
                Text(preview.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                sourceLine(preview)
                    .padding(.top, 4)
                Spacer(minLength: 8)
                badgeRow(preview.badges)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: preview.portrait ? 136 : 108, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func progressCard(_ preview: PreviewContent, _ progress: ProgressContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                thumb(preview, wide: !preview.portrait)
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    sourceLine(preview)
                    Spacer(minLength: 6)
                    Text(progress.headline)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            progressBar(progress.fraction)
                .padding(.top, 10)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent")
            HStack {
                Text(progress.stage)
                Spacer()
                Text(progress.trailing)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.secondary)
            .monospacedDigit()
            .padding(.top, 7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func completedCard(_ completed: CompletedContent) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                thumb(PreviewContent(title: "", site: "", author: nil, resolution: nil, duration: "", thumbnail: nil, portrait: false, badges: []), wide: true)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Theme.ok, in: Circle())
                        .accessibilityHidden(true)
                    Text("Downloaded")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Text(completed.filename)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .padding(.top, 6)
                Text(completed.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 1)
                HStack(spacing: 8) {
                    smallButton("Show in Finder", action: actions.reveal)
                    smallButton("Open", action: actions.openFile)
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func errorCard(_ problem: PresentedProblem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("!")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.danger, in: Circle())
                .accessibilityLabel("Error")
            VStack(alignment: .leading, spacing: 0) {
                Text(problem.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(problem.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                HStack(spacing: 8) {
                    if let title = problem.primaryTitle {
                        smallButton(title, prominent: true, action: actions.primary)
                    }
                    if let title = problem.secondaryTitle {
                        smallButton(title, action: actions.secondary)
                    }
                }
                .padding(.top, problem.primaryTitle == nil && problem.secondaryTitle == nil ? 0 : 12)
                if !problem.detail.isEmpty {
                    Text("Details: \(problem.detail)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(2)
                        .padding(.top, 10)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func thumb(_ preview: PreviewContent, wide: Bool = false) -> some View {
        let portrait = preview.portrait && !wide
        let size = portrait ? CGSize(width: 76, height: 112) : CGSize(width: 150, height: 84)
        return ZStack(alignment: .bottomTrailing) {
            if let image = preview.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                sunset
            }
            if !preview.duration.isEmpty {
                Text(preview.duration)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(5)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var sunset: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 1, green: 0.70, blue: 0.42),
                    Color(red: 1, green: 0.48, blue: 0.48),
                    Color(red: 0.48, green: 0.36, blue: 1),
                    Color(red: 0.17, green: 0.16, blue: 0.42),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Circle()
                .fill(Color(red: 1, green: 0.91, blue: 0.69))
                .frame(width: 26, height: 26)
                .shadow(color: Color(red: 1, green: 0.86, blue: 0.59).opacity(0.7), radius: 12)
                .offset(y: -18)
        }
    }

    private func sourceLine(_ preview: PreviewContent) -> some View {
        HStack(spacing: 6) {
            siteMark(preview.site)
            Text(preview.site)
            if let author = preview.author {
                dot
                Text(author)
            }
            if let resolution = preview.resolution {
                dot
                Text(resolution)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
    }

    private func siteMark(_ site: String) -> some View {
        let symbol: String
        switch site {
        case "YouTube": symbol = "play.fill"
        case "TikTok": symbol = "music.note"
        default: symbol = "link"
        }
        return Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(site == "YouTube" ? Color.white : (scheme == .dark ? Color.black : Color.white))
            .frame(width: 16, height: 16)
            .background(site == "YouTube" ? Color(red: 1, green: 0, blue: 0.2) : (scheme == .dark ? Color.white : Color.black), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var dot: some View {
        Circle().fill(Theme.tertiary).frame(width: 3, height: 3)
    }

    private func badgeRow(_ badges: [PreviewBadge]) -> some View {
        HStack(spacing: 6) {
            ForEach(badges) { badge in
                HStack(spacing: 4) {
                    if badge.good {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(badge.text)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(badge.good ? Theme.ok : Theme.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(badge.good ? Theme.ok.opacity(0.12) : Theme.field.opacity(0.9), in: Capsule())
                .overlay(Capsule().strokeBorder(badge.good ? .clear : Color.primary.opacity(0.08), lineWidth: 0.5))
            }
        }
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.chip)
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.24, green: 0.61, blue: 1), Color(red: 0.04, green: 0.45, blue: 0.94)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 5)
    }

    private var controls: some View {
        HStack(alignment: .bottom, spacing: 10) {
            labeled("Format") {
                Picker("Format", selection: $container) {
                    ForEach(ContainerFormat.allCases) { format in
                        Text(format.menuTitle).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!controlsEnabled)
                .accessibilityIdentifier("formatPicker")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            labeled("Quality") {
                Picker("Quality", selection: $quality) {
                    ForEach(Quality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(!controlsEnabled)
                .accessibilityIdentifier("qualityPicker")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            labeled("Max size") {
                HStack(spacing: 8) {
                    Toggle("Max size", isOn: $maxSizeEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(!controlsEnabled)
                        .accessibilityIdentifier("maxSizeToggle")
                    HStack {
                        TextField("None", text: $maxSizeText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 36)
                            .disabled(!maxSizeEnabled || !controlsEnabled)
                        Text("MB")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .frame(width: 88)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                }
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            content()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Button(action: actions.chooseFolder) {
                HStack(spacing: 4) {
                    Text("Saves to")
                        .foregroundStyle(Theme.secondary)
                    Text(saveName)
                        .foregroundStyle(Theme.text)
                        .fontWeight(.medium)
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save location, \(saveName)")
            Spacer()
            if case .downloading = phase {
                secondaryButton("Cancel", systemImage: nil, action: actions.cancel)
                    .accessibilityIdentifier("cancelButton")
            } else {
                downloadButton
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 0.5)
        }
    }

    private var downloadButton: some View {
        Button(action: actions.download) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text("Download")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(canDownload ? Color.white : Theme.tertiary)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(
                Group {
                    if canDownload {
                        LinearGradient(
                            colors: [Color(red: 0.17, green: 0.55, blue: 1), Color(red: 0.04, green: 0.45, blue: 0.94)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        Theme.chip
                    }
                },
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canDownload)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityIdentifier("downloadButton")
    }

    private func secondaryButton(_ title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(Theme.field.opacity(0.8), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(prominent ? Color.white : Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    Group {
                        if prominent {
                            LinearGradient(colors: [Color(red: 0.17, green: 0.55, blue: 1), Color(red: 0.04, green: 0.45, blue: 0.94)], startPoint: .top, endPoint: .bottom)
                        } else {
                            Theme.field.opacity(0.85)
                        }
                    },
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(prominent ? .clear : Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var canDownload: Bool {
        if case .preview = phase { return true }
        return false
    }

    private var controlsEnabled: Bool {
        switch phase {
        case .downloading, .resolving: return false
        default: return true
        }
    }

    private var isBusy: Bool {
        if case .downloading = phase { return true }
        if case .resolving = phase { return true }
        return false
    }
}
