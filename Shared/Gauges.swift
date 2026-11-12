import SwiftUI
import WidgetKit

// Dials made of ticks, after the vent slots around the Mac Pro's base. Cheap to redraw, and they hold up on clear Home Screens.
enum Heat {
    static func f(_ c: Double) -> Int { Int((c * 9 / 5 + 32).rounded()) }
    // In whichever unit is chosen in Settings, Fahrenheit unless Celsius is.
    static func shown(_ c: Double) -> Int { MacPrefs.celsius ? Int(c.rounded()) : f(c) }
    static func level(_ c: Double) -> Double { min(max((c - 20) / 80, 0), 1) }
    static func color(_ c: Double) -> Color { c >= 90 ? .red : c >= 75 ? .orange : c >= 60 ? .yellow : .white }
    // Silver when cool, warming only near the top of the dial.
    static func tick(_ t: Double) -> Color {
        t > 0.875 ? Color(red: 1, green: 0.27, blue: 0.23) : t > 0.69 ? Color(red: 1, green: 0.6, blue: 0.04) : t > 0.5 ? Color(red: 1, green: 0.84, blue: 0.04) : Color(white: 0.93)
    }
}
// The app's colour, chosen in Settings; blue unless another is.
var macBlue: Color { MacPrefs.accent.color }
enum MacAccent: String, CaseIterable, Identifiable {
    case blue, teal, purple, pink, orange, green, graphite
    var id: String { rawValue }
    var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.04, green: 0.52, blue: 1)
        case .teal: return Color(red: 0.19, green: 0.78, blue: 0.82)
        case .purple: return Color(red: 0.62, green: 0.42, blue: 1)
        case .pink: return Color(red: 1, green: 0.3, blue: 0.55)
        case .orange: return Color(red: 1, green: 0.58, blue: 0.1)
        case .green: return Color(red: 0.2, green: 0.8, blue: 0.4)
        case .graphite: return Color(white: 0.72)
        }
    }
}
// Every choice in Settings, read where it's used.
enum MacPrefs {
    static var d: UserDefaults { .standard }
    static var accent: MacAccent { MacAccent(rawValue: d.string(forKey: "accent") ?? "") ?? .blue }
    static var celsius: Bool { d.bool(forKey: "celsius") }
    static var haptics: Bool { d.object(forKey: "haptics") as? Bool ?? true }
    // Two fingers on the Mac's screen move the page with them, as on a Mac trackpad; off reverses it.
    static var naturalScroll: Bool { d.object(forKey: "naturalScroll") as? Bool ?? true }
    static var liveEvery: Double { let v = d.double(forKey: "liveEvery"); return v > 0 ? v : 1 }
    static var fullEvery: Double { let v = d.double(forKey: "fullEvery"); return v > 0 ? v : 10 }
    // What the API may cost in a month, in dollars, for the Usage tab's dial.
    static var apiBudget: Double { let v = d.double(forKey: "apiBudget"); return v > 0 ? v : 200 }

    // The widgets follow the colour and temperature unit through an App Group the app and its widgets share. Until the
    // build is signed with that group there's no shared container: nothing is shared, and the widgets stay blue and °F.
    static let groupID = "group.local.macpro.MacPro"
    static var shared: UserDefaults? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) == nil ? nil : UserDefaults(suiteName: groupID)
    }
    static func shareWithWidgets() {
        let address = d.string(forKey: "address") ?? ""
        guard let g = shared, g.string(forKey: "accent") != accent.rawValue || g.object(forKey: "celsius") as? Bool != celsius || g.string(forKey: "address") != address else { return }
        g.set(accent.rawValue, forKey: "accent"); g.set(celsius, forKey: "celsius"); g.set(address, forKey: "address")
        WidgetCenter.shared.reloadAllTimelines()
    }
    // Read by the widgets: the app's choices when shared, else nil, and the widget keeps its own look.
    static var widgetAccent: MacAccent? { shared?.string(forKey: "accent").flatMap(MacAccent.init(rawValue:)) }
    static var widgetCelsius: Bool { shared?.bool(forKey: "celsius") ?? false }
}

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
    // The ticks by colour: unlit, lit in the tint, or lit by heat in bands.
    private func groups(lit: Int) -> [(color: Color, indices: [Int])] {
        var order: [String] = [], byKey: [String: (Color, [Int])] = [:]
        for i in 0..<ticks {
            let t = Double(i) / Double(ticks - 1)
            let (key, color): (String, Color) = i > lit ? ("off", Color.primary.opacity(0.16)) : heat ? ("h\(t > 0.875 ? 3 : t > 0.69 ? 2 : t > 0.5 ? 1 : 0)", Heat.tick(t)) : ("on", tint)
            if byKey[key] == nil { order.append(key); byKey[key] = (color, []) }
            byKey[key]!.1.append(i)
        }
        return order.map { (byKey[$0]!.0, byKey[$0]!.1) }
    }
    var body: some View {
        ZStack {
            // Drawn as shapes, one per colour of tick, not a Canvas: a Canvas's drawing went blank for the frames before a
            // turn (the system's snapshot for the rotation) and stayed blank while the main thread was busy (designer,
            // resize regate on 32dd2bd: "a chart keeps its last drawing until the next is ready").
            let lit = Int((min(max(value, 0), 1) * Double(ticks - 1)).rounded())
            ForEach(Array(groups(lit: lit).enumerated()), id: \.offset) { _, g in
                Ticks(indices: g.indices, ticks: ticks, length: length, sweep: sweep)
                    .stroke(g.color, style: StrokeStyle(lineWidth: width, lineCap: .round))
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
    // Shapes, not a Canvas, for the same reason as the dials' ticks: never a blank chart for a frame.
    var body: some View {
        if values.count > 1 {
            let hi = max(top ?? values.max() ?? 1, 0.0001)
            ZStack {
                SparkPath(values: values, hi: hi, closed: true).fill(color.opacity(0.18))
                SparkPath(values: values, hi: hi, closed: false).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
struct SparkPath: Shape {
    let values: [Double]
    let hi: Double
    let closed: Bool
    func path(in rect: CGRect) -> Path {
        var line = Path()
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let p = CGPoint(x: rect.minX + CGFloat(i) * step, y: rect.minY + rect.height * (1 - CGFloat(min(v / hi, 1))) * 0.92 + 1.5)
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        if closed { line.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); line.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); line.closeSubpath() }
        return line
    }
}
// Some of a dial's ticks, as one path: the ones at `indices` of `ticks` around a `sweep`-degree arc.
struct Ticks: Shape {
    let indices: [Int]
    let ticks: Int
    let length: CGFloat
    let sweep: Double
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2 - 1, c = CGPoint(x: rect.midX, y: rect.midY)
        let start = 90 + (360 - sweep) / 2
        var p = Path()
        for i in indices {
            let a = (start + Double(i) / Double(ticks - 1) * sweep) * .pi / 180
            p.move(to: CGPoint(x: c.x + cos(a) * (r - length), y: c.y + sin(a) * (r - length)))
            p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
        }
        return p
    }
}
