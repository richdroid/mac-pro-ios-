import SwiftUI

// Dials made of ticks, after the vent slots around the Mac Pro's base. Cheap to redraw, and they hold up on clear Home Screens.
enum Heat {
    static func f(_ c: Double) -> Int { Int((c * 9 / 5 + 32).rounded()) }
    static func level(_ c: Double) -> Double { min(max((c - 20) / 80, 0), 1) }
    static func color(_ c: Double) -> Color { c >= 90 ? .red : c >= 75 ? .orange : c >= 60 ? .yellow : .white }
    // Silver when cool, warming only near the top of the dial.
    static func tick(_ t: Double) -> Color {
        t > 0.875 ? Color(red: 1, green: 0.27, blue: 0.23) : t > 0.69 ? Color(red: 1, green: 0.6, blue: 0.04) : t > 0.5 ? Color(red: 1, green: 0.84, blue: 0.04) : Color(white: 0.93)
    }
}
let macBlue = Color(red: 0.04, green: 0.52, blue: 1)

struct ArcGauge<Center: View>: View {
    let value: Double
    var tint: Color = macBlue
    var heat = false
    var ticks = 40
    var length: CGFloat = 8
    var width: CGFloat = 2.6
    var sweep = 270.0
    let center: Center
    init(_ value: Double, tint: Color = macBlue, heat: Bool = false, ticks: Int = 40, length: CGFloat = 8, width: CGFloat = 2.6, sweep: Double = 270, @ViewBuilder center: () -> Center) {
        self.value = value; self.tint = tint; self.heat = heat; self.ticks = ticks; self.length = length; self.width = width; self.sweep = sweep; self.center = center()
    }
    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let r = min(size.width, size.height) / 2 - 1, c = CGPoint(x: size.width / 2, y: size.height / 2)
                let lit = Int((min(max(value, 0), 1) * Double(ticks - 1)).rounded())
                let start = 90 + (360 - sweep) / 2
                for i in 0..<ticks {
                    let t = Double(i) / Double(ticks - 1)
                    let a = (start + t * sweep) * .pi / 180
                    var p = Path()
                    p.move(to: CGPoint(x: c.x + cos(a) * (r - length), y: c.y + sin(a) * (r - length)))
                    p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
                    let color: Color = i > lit ? Color.primary.opacity(0.16) : heat ? Heat.tick(t) : tint
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            }
            center
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct SparkLine: View {
    let values: [Double]
    var top: Double?
    var color: Color = macBlue
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let hi = max(top ?? values.max() ?? 1, 0.0001)
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(v / hi, 1))) * 0.92 + 1.5)
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.18)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
