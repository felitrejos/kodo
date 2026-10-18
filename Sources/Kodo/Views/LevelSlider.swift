import SwiftUI

/// A slim volume track in the spirit of Control Center: a soft capsule that fills as you drag.
struct LevelSlider: View {
    let title: String
    let value: Double
    var isDimmed = false
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knob = Design.sliderHeight - 6
            let fill = max(knob, width * value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 6)
                Capsule()
                    // Neutral, like Control Center: color is saved for what's switched on.
                    .fill(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary.opacity(0.75)))
                    .frame(width: fill, height: 6)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: fill - knob)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        onChange(min(max(drag.location.x / width, 0), 1))
                    }
            )
        }
        .frame(height: Design.sliderHeight)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: 0...1) {
                Text(title)
            }
        }
    }
}
