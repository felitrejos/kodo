import AppKit
import SwiftUI

/// A small waveform that moves while an app is making sound.
///
/// The animation runs in an AppKit image view rather than in SwiftUI. The menu bar panel
/// measures and animates its own size on every SwiftUI update, so a SwiftUI animation, even
/// one stepping five times a second, kept the whole panel redrawing at about 20% CPU. An
/// AppKit symbol effect plays on its own layer and never touches SwiftUI.
struct PlayingIndicator: View {
    let isPlaying: Bool
    /// Off while the menu is closed, since the hidden window would keep drawing.
    var animates = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WaveformView(isAnimating: isPlaying && animates && !reduceMotion)
            .fixedSize()
            .opacity(isPlaying ? 1 : 0)
            .accessibilityLabel("Playing")
            .accessibilityHidden(!isPlaying)
    }
}

private struct WaveformView: NSViewRepresentable {
    let isAnimating: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        view.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
        view.contentTintColor = .secondaryLabelColor
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard isAnimating != context.coordinator.isAnimating else {
            return
        }
        context.coordinator.isAnimating = isAnimating
        if isAnimating {
            view.addSymbolEffect(.variableColor.iterative.reversing, options: .repeating)
        } else {
            view.removeAllSymbolEffects()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var isAnimating = false
    }
}
