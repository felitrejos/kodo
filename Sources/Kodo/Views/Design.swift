import SwiftUI

/// Shared measurements and timings, so every part of the menu feels like one piece.
enum Design {
    static let menuWidth: CGFloat = 340
    static let outerPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 10
    static let cardPadding: CGFloat = 12
    static let cardCornerRadius: CGFloat = 18
    static let rowSpacing: CGFloat = 8
    static let chipSize: CGFloat = 30
    static let appIconSize: CGFloat = 28
    static let sliderHeight: CGFloat = 24
    static let rowSliderWidth: CGFloat = 132
    /// Narrower than a speaker's, so app names get the room they need.
    static let appSliderWidth: CGFloat = 124
    static let animation = Animation.snappy(duration: 0.25)
}
