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

    enum Bar {
        static let inputHeight: CGFloat = 34
        static let paneHeaderHeight: CGFloat = 40
    }

    enum Preview {
        static let headerDetailsMinimumWidth: CGFloat = 220
        static let headerDetailsIdealWidth: CGFloat = 300
        static let headerDetailsMaximumWidth: CGFloat = 360
        static let headerAccessoryMinimumWidth: CGFloat = 320
        static let editorialReaderWidth: CGFloat = 540
        static let editorialReaderHeight: CGFloat = 360
    }

    /// Activity is a supporting pane, not a second primary workspace. It grows
    /// for up to three useful rows; additional history remains scrollable.
    enum ActivityPane {
        static let minimumHeight: CGFloat = 88
        static let emptyContentHeight: CGFloat = 62
        static let rowHeight: CGFloat = 74
        static let maximumVisibleRows = 3

        static func preferredHeight(activityCount: Int) -> CGFloat {
            let contentHeight: CGFloat
            if activityCount <= 0 {
                contentHeight = emptyContentHeight
            } else {
                contentHeight = rowHeight * CGFloat(min(activityCount, maximumVisibleRows))
            }
            return Bar.paneHeaderHeight + 1 + contentHeight
        }
    }

    /// Stable trailing columns shared by dense, full-width rows.
    enum Column {
        static let searchStatus: CGFloat = 132
        static let searchQuality: CGFloat = 140
        static let rowAction: CGFloat = 30
        static let activityQuality: CGFloat = 132
        static let activityTransfer: CGFloat = 112
        static let activityActions: CGFloat = 154
    }
}

extension Font {
    /// Title/subtitle pair used by queue, search, and activity rows.
    static let rowTitle: Font = .callout.weight(.medium)
    static let rowSubtitle: Font = .caption
}
