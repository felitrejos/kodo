import SwiftUI

struct DeviceRow: View {
    let model: KodoModel
    let output: AudioDevice

    @State private var isHovering = false
    @State private var showsInspector = false

    var body: some View {
        let isActive = model.isActive(output)
        let volume = model.volume(for: output)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                DeviceChip(title: chipTitle, symbol: output.symbolName, isActive: isActive, action: choose)
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.name)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isCuttingOut ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .opacity(model.isHidden(output) ? 0.5 : 1)
                Spacer(minLength: 4)
                Button("Details for \(output.name)", systemImage: "info.circle", action: showInspector)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering || showsInspector ? 1 : 0)
                    .popover(isPresented: $showsInspector, arrowEdge: .trailing) {
                        DeviceInspector(model: model, output: output)
                    }
            }
            // Under the name, like Control Center's sliders, so names never get squeezed.
            if isActive, let volume {
                CapsuleSlider(
                    title: output.name,
                    value: Double(volume),
                    isMuted: model.isMuted(output),
                    showsGlyph: true,
                    onToggleMute: toggleMute,
                    onChange: setVolume)
                    .padding(.leading, Design.chipSize + 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(.rect)
        .onHover(perform: setHovering)
        .contextMenu {
            Button("Details…", systemImage: "info.circle", action: showInspector)
            Button(model.isHidden(output) ? "Show in Kodo" : "Hide from Kodo", systemImage: model.isHidden(output) ? "eye" : "eye.slash", action: toggleHidden)
        }
        .animation(Design.animation, value: isActive)
    }

    private var chipTitle: String {
        if model.isSyncOn {
            return model.isSelected(output) ? "Remove \(output.name) from Sync" : "Add \(output.name) to Sync"
        }
        return "Play through \(output.name)"
    }

    /// Only while it's playing in the group, where the dropouts were heard.
    private var isCuttingOut: Bool {
        model.isSyncOn && model.isSelected(output) && model.isCuttingOut(output)
    }

    private var detail: String {
        if model.isHidden(output) {
            return "Hidden"
        }
        if isCuttingOut {
            return "\(output.kindDescription) · cutting out"
        }
        if model.isSyncOn, model.isSelected(output), let delay = model.delay(for: output), delay >= 0.0005 {
            return "\(output.kindDescription) · waits \((delay * 1000).formatted(.number.precision(.fractionLength(0)))) ms"
        }
        if model.isSyncOn, model.activeOutputs.count > 1, model.leadSpeaker == output {
            return "\(output.kindDescription) · leads"
        }
        return output.kindDescription
    }

    private func choose() {
        withAnimation(Design.animation) {
            model.choose(output)
        }
    }

    private func setVolume(_ volume: Double) {
        model.setVolume(Float(volume), for: output)
    }

    private func toggleMute() {
        model.toggleMute(output)
    }

    private func showInspector() {
        showsInspector = true
    }

    private func setHovering(_ hovering: Bool) {
        isHovering = hovering
    }

    private func toggleHidden() {
        withAnimation(Design.animation) {
            model.setHidden(!model.isHidden(output), for: output)
        }
    }
}
