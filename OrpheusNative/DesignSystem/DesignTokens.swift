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
}

extension Font {
    /// Title/subtitle pair used by queue, search, and activity rows.
    static let rowTitle: Font = .callout.weight(.medium)
    static let rowSubtitle: Font = .caption
}
