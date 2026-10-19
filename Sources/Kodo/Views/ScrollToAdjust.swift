import AppKit
import SwiftUI

/// Lets the scroll wheel or a two-finger swipe nudge a slider while the pointer is over it,
/// like the system volume. Moving up is louder, whichever way scrolling is set to go.
struct ScrollToAdjust: ViewModifier {
    let adjust: (Double) -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onHover(perform: hover)
            .onDisappear(perform: stopListening)
    }

    private func hover(_ hovering: Bool) {
        if hovering {
            startListening()
        } else {
            stopListening()
        }
    }

    private func startListening() {
        stopListening()
        let adjust = adjust
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let direction: Double = event.isDirectionInvertedFromDevice ? -1 : 1
            // Trackpads report fine-grained points; wheels report whole lines.
            let step = event.hasPreciseScrollingDeltas ? 1 / 300.0 : 1 / 25.0
            let delta = Double(event.scrollingDeltaY) * direction * step
            guard delta != 0 else {
                return event
            }
            MainActor.assumeIsolated {
                adjust(delta)
            }
            // Swallow it, so the menu doesn't scroll while you're changing the volume.
            return nil
        }
    }

    private func stopListening() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

extension View {
    func scrollToAdjust(_ adjust: @escaping (Double) -> Void) -> some View {
        modifier(ScrollToAdjust(adjust: adjust))
    }
}
