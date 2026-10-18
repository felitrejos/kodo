import SwiftUI

/// Shared measurements and timings, so every part of the menu feels like one piece.
enum Design {
    static let menuWidth: CGFloat = 360
    static let edgePadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 4
    static let rowHeight: CGFloat = 40
    static let iconSize: CGFloat = 26
    static let toggleSize: CGFloat = 26
    static let nameWidth: CGFloat = 142
    static let sliderHeight: CGFloat = 20
    static let cornerRadius: CGFloat = 8
    static let animation = Animation.snappy(duration: 0.22)
}
