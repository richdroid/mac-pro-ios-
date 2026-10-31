import SwiftUI

// Light, hand-drawn graphics: cheap enough to redraw every second, and small enough for widgets.
enum Heat {
    static func f(_ c: Double) -> Int { Int((c * 9 / 5 + 32).rounded()) }
    static func level(_ c: Double) -> Double { min(max((c - 20) / 80, 0), 1) }
    static func color(_ c: Double) -> Color { c >= 90 ? .red : c >= 75 ? .orange : c >= 60 ? .yellow : Color(red: 0.3, green: 0.75, blue: 0.95) }
    static let gradient = AngularGradient(colors: [Color(red: 0.3, green: 0.75, blue: 0.95), .green, .yellow, .orange, .red], center: .center, startAngle: .degrees(0), endAngle: .degrees(270))  // before the dial is rotated into place
}

// An open dial, like a car gauge: value 0...1, with whatever goes in the middle.
struct ArcGauge<Center: View, S: ShapeStyle>: View {
    let value: Double
    let style: S
    var width: CGFloat = 7
    let center: Center
    init(_ value: Double, style: S, width: CGFloat = 7, @ViewBuilder center: () -> Center) {
        self.value = value; self.style = style; self.width = width; self.center = center()
    }
    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75).stroke(.primary.opacity(0.13), style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.75 * min(max(value, 0.001), 1)).stroke(style, style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(135))
            center
        }
        .padding(width / 2)
        .aspectRatio(1, contentMode: .fit)
    }
}

// A full circle, for rings nested like Activity.
struct Ring: View {
    let value: Double
    let color: Color
    var width: CGFloat = 8
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: width)
            Circle().trim(from: 0, to: min(max(value, 0.001), 1)).stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .padding(width / 2)
    }
}

struct SparkLine: View {
    let values: [Double]
    var top: Double?
    var color: Color = .accentColor
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let hi = max(top ?? values.max() ?? 1, 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(v / hi, 1))) * 0.94 + 1)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.16)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
    }
}
