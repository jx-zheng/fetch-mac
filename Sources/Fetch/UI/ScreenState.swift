import AppKit
import FetchCore

struct PreviewBadge: Equatable, Identifiable {
    var id: String
    var text: String
    var good: Bool
}

struct PreviewContent: Equatable {
    var title: String
    var site: String
    var author: String?
    var resolution: String?
    var duration: String
    var thumbnail: NSImage?
    var portrait: Bool
    var badges: [PreviewBadge]
}

struct ProgressContent: Equatable {
    var fraction: Double
    var headline: String
    var stage: String
    var trailing: String
}

struct CompletedContent: Equatable {
    var filename: String
    var detail: String
    var fileURL: URL?
}

struct PresentedProblem: Equatable {
    enum Action: Equatable {
        case safari
        case retry
        case update
    }

    var title: String
    var message: String
    var detail: String
    var primaryTitle: String?
    var primary: Action?
    var secondaryTitle: String?
    var secondary: Action?
}

enum ScreenPhase: Equatable {
    case empty
    case resolving(String)
    case preview(PreviewContent)
    case downloading(PreviewContent, ProgressContent)
    case completed(CompletedContent)
    case failed(PresentedProblem)
}

enum ProblemCopy {
    static func present(_ mapped: MappedError, site: String, link: String) -> PresentedProblem {
        let noun = link.contains("/reel/") ? "reel" : "video"
        let detail = mapped.detail.isEmpty ? "" : mapped.detail
        switch mapped.kind {
        case .signIn:
            return PresentedProblem(
                title: "\(site) needs you signed in",
                message: "This \(noun) isn't public to logged-out visitors. Fetch can borrow your Safari sign-in for this one download, read-only.",
                detail: detail.isEmpty ? "login required" : detail,
                primaryTitle: "Use Safari sign-in",
                primary: .safari,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        case .private:
            return PresentedProblem(
                title: "This video is private",
                message: "The owner hasn't shared it publicly. If you can watch it in Safari, Fetch can try that sign-in.",
                detail: detail,
                primaryTitle: "Use Safari sign-in",
                primary: .safari,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        case .ageRestricted, .botCheck:
            return PresentedProblem(
                title: mapped.kind == .botCheck ? "YouTube wants to check it's you" : "This video is age-restricted",
                message: "The site won't hand it over without a sign-in. Fetch can use your Safari sign-in for this one download, read-only.",
                detail: detail,
                primaryTitle: "Use Safari sign-in",
                primary: .safari,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        case .region:
            return PresentedProblem(
                title: "This video isn't available in your region",
                message: "The site is blocking this location. A different network sometimes fixes it.",
                detail: detail,
                primaryTitle: nil,
                primary: nil,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        case .engineOutdated:
            return PresentedProblem(
                title: "The download engine needs an update",
                message: "The site changed and this engine couldn't read the page. Fetch can update it and try again.",
                detail: detail,
                primaryTitle: "Update and retry",
                primary: .update,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        case .unsupported:
            return PresentedProblem(
                title: "That link doesn't look like a video Fetch can save",
                message: "Paste a link to a single video. Playlists and ordinary web pages aren't saved.",
                detail: detail,
                primaryTitle: nil,
                primary: nil,
                secondaryTitle: nil,
                secondary: nil
            )
        case .network:
            return PresentedProblem(
                title: "Couldn't reach the site",
                message: "Check your connection and try again.",
                detail: detail,
                primaryTitle: nil,
                primary: nil,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        case .noFormats:
            return PresentedProblem(
                title: "No video file was offered",
                message: "The page loaded, but it didn't include a format Fetch can save.",
                detail: detail,
                primaryTitle: nil,
                primary: nil,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        case .tooLarge:
            return PresentedProblem(
                title: "Couldn't fit it under the size you set",
                message: "Fetch re-encoded it smaller and it was still over the limit. Raise the max size, or turn it off.",
                detail: detail,
                primaryTitle: nil,
                primary: nil,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        case .cancelled:
            return PresentedProblem(title: "Cancelled", message: "", detail: "", primaryTitle: nil, primary: nil, secondaryTitle: nil, secondary: nil)
        case .generic:
            return PresentedProblem(
                title: "Couldn't save that video",
                message: "Something went wrong while reading or saving it.",
                detail: detail,
                primaryTitle: nil,
                primary: nil,
                secondaryTitle: "Try again",
                secondary: .retry
            )
        }
    }
}
