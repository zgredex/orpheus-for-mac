import SwiftUI

/// Shared layout tokens for the native UI. Colors stay on system semantics.
enum DS {
    /// 4-pt spacing scale.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Radius {
        static let control: CGFloat = 7
        static let thumb: CGFloat = 6
        static let hero: CGFloat = 10
    }

    enum Artwork {
        static let queue: CGFloat = 28
        static let row: CGFloat = 44
        static let result: CGFloat = 48
        static let hero: CGFloat = 148
    }

    /// Window and split-pane geometry is tuned around the effective workspace
    /// of a 13-inch MacBook while retaining a useful compact resize range.
    enum Window {
        static let minimumWidth: CGFloat = 860
        static let minimumHeight: CGFloat = 600
        static let defaultWidth: CGFloat = 1_180
        static let defaultHeight: CGFloat = 760
    }

    enum Pane {
        static let queueMinimumWidth: CGFloat = 236
        static let queueIdealWidth: CGFloat = 268
        static let queueMaximumWidth: CGFloat = 300
        static let workspaceMinimumWidth: CGFloat = 560
    }

    enum Sheet {
        static let settingsWidth: CGFloat = 620
        static let settingsHeight: CGFloat = 700
        static let diagnosticsMinimumWidth: CGFloat = 860
        static let diagnosticsIdealWidth: CGFloat = 1_060
        static let diagnosticsMinimumHeight: CGFloat = 600
        static let diagnosticsIdealHeight: CGFloat = 700
    }

    enum Bar {
        static let inputHeight: CGFloat = 34
        static let paneHeaderHeight: CGFloat = 40
    }

    enum Preview {
        static let headerDetailsMinimumWidth: CGFloat = 220
        static let headerDetailsIdealWidth: CGFloat = 300
        static let headerDetailsMaximumWidth: CGFloat = 360
        static let headerAccessoryMinimumWidth: CGFloat = 320
        /// Bounds the accessory's natural size while `ViewThatFits` evaluates
        /// the horizontal header. Without this, long editorial text reports its
        /// full unwrapped width and incorrectly forces the compact layout.
        static let headerAccessoryIdealWidth: CGFloat = 480
        static let editorialReaderWidth: CGFloat = 540
        static let editorialReaderHeight: CGFloat = 360
    }

    /// Activity is a supporting pane, not a second primary workspace. It grows
    /// for up to three useful rows; additional history remains scrollable.
    enum ActivityPane {
        static let minimumHeight: CGFloat = 88
        static let emptyContentHeight: CGFloat = 62
        static let rowHeight: CGFloat = 104
        static let compactRowHeight: CGFloat = 116
        static let accessibilityRowHeight: CGFloat = 132
        static let maximumVisibleRows = 2

        static func preferredHeight(
            activityCount: Int,
            compact: Bool = false,
            accessibility: Bool = false
        ) -> CGFloat {
            let contentHeight: CGFloat
            if activityCount <= 0 {
                contentHeight = emptyContentHeight
            } else {
                let visibleRows = min(activityCount, maximumVisibleRows)
                let resolvedRowHeight = accessibility
                    ? accessibilityRowHeight
                    : (compact ? compactRowHeight : rowHeight)
                contentHeight = resolvedRowHeight * CGFloat(visibleRows)
            }
            return Bar.paneHeaderHeight + 1 + contentHeight
        }
    }

    /// Stable trailing columns shared by dense, full-width rows.
    enum Column {
        static let categoryPicker: CGFloat = 440
        static let librarySectionPicker: CGFloat = 560
        static let searchStatus: CGFloat = 118
        static let searchQuality: CGFloat = 128
        static let rowAction: CGFloat = 30
        static let activityQuality: CGFloat = 120
        static let activityTransfer: CGFloat = 104
        static let activityActions: CGFloat = 148
        static let libraryIntegrity: CGFloat = 112
        static let commandPathMaximum: CGFloat = 360
    }

    enum Row {
        static let searchMinimumHeight: CGFloat = 56
        static let searchRegularMinimumWidth: CGFloat = 650
        static let trackRegularMinimumWidth: CGFloat = 620
        static let queueHeaderRegularMinimumWidth: CGFloat = 300
        static let activityRegularMinimumWidth: CGFloat = 760
        static let activityPrimaryMinimumWidth: CGFloat = 220
        static let libraryRegularMinimumWidth: CGFloat = 680
    }
}

extension Font {
    /// Title/subtitle pair used by queue, search, and activity rows.
    static let rowTitle: Font = .callout.weight(.medium)
    static let rowSubtitle: Font = .caption
}
