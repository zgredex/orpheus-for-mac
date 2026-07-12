import SwiftUI

/// One presentation mapping shared by every status glyph in the app.
struct StatusStyle: Equatable {
    var systemImage: String
    var tint: Color
    var isSpinner = false
}

extension NativeQueueStatus {
    /// `nil` for `.ready` — idle items show no glyph.
    var style: StatusStyle? {
        switch self {
        case .ready: nil
        case .loading: StatusStyle(systemImage: "progress.indicator", tint: .accentColor, isSpinner: true)
        case .downloading: StatusStyle(systemImage: "arrow.down.circle.fill", tint: .accentColor)
        case .completed: StatusStyle(systemImage: "checkmark.circle.fill", tint: .green)
        case .failed: StatusStyle(systemImage: "exclamationmark.circle.fill", tint: .red)
        case .cancelled: StatusStyle(systemImage: "xmark.circle", tint: .secondary)
        }
    }
}

extension NativeActivityStatus {
    var style: StatusStyle {
        switch self {
        case .queued: StatusStyle(systemImage: "clock", tint: .secondary)
        // One steady spinner for every active phase: statuses flap between
        // downloading/tagging/validating on each track, and swapping glyph
        // styles per flap makes the row flicker.
        case .resolving, .downloading, .tagging, .validating:
            StatusStyle(systemImage: "progress.indicator", tint: .accentColor, isSpinner: true)
        case .completed: StatusStyle(systemImage: "checkmark.circle.fill", tint: .green)
        case .failed: StatusStyle(systemImage: "exclamationmark.circle.fill", tint: .red)
        case .cancelled: StatusStyle(systemImage: "xmark.circle", tint: .secondary)
        }
    }
}

struct StatusGlyph: View {
    let style: StatusStyle

    var body: some View {
        if style.isSpinner {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: style.systemImage).foregroundStyle(style.tint)
        }
    }
}
