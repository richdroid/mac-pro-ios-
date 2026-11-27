import SwiftUI
import WidgetKit
// Widgets at real sizes for the cloud build's screenshots. Never shipped.
func card<C: View>(_ w: CGFloat, _ h: CGFloat, @ViewBuilder _ c: () -> C) -> some View {
    c().padding(16).frame(width: w, height: h)
        // What the widget's container draws on a real Home Screen.
        .background(GraphiteWall())
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
}
// The Mac Pro widgets' own background, as Graphite gives it.
struct GraphiteWall: View {
    var body: some View {
        ZStack { LinearGradient(colors: [Color(white: 0.17), Color(white: 0.05)], startPoint: .top, endPoint: .bottom); RadialGradient(colors: [Color(red: 0.55, green: 0.62, blue: 0.74).opacity(0.28), .clear], center: .center, startRadius: 10, endRadius: 170) }
    }
}
@main struct GalleryApp: App {
    var e: MacEntry { MacEntry(date: Date(), state: .sample) }
    var sheets: Bool { UserDefaults.standard.bool(forKey: "sheets") }
    var body: some Scene { WindowGroup {
        if sheets { MacSheets() } else {
        ScrollView { VStack(spacing: 12) {
            card(338, 158) { StatusView(forced: .systemMedium, entry: e) }
            HStack(spacing: 12) { card(158, 158) { StatusView(forced: .systemSmall, entry: e) }; card(158, 158) { TempView(forced: .systemSmall, entry: e) } }
            card(338, 158) { TempView(forced: .systemMedium, entry: e) }
            HStack(spacing: 12) { card(158, 158) { ClaudeView(entry: e) } }
        }.padding(10) }.background(Color(white: 0.8))
        }
    } }
}

// Real-shaped readings, as the Mac's bridge sends them (the shape of ci/mock-status.json): every sensor the Mac Pro has.
enum MacSample {
    static let temps: [(String, Double)] = [("CPU", 54), ("GPU A", 44), ("GPU B", 45), ("Memory", 42), ("Chipset", 52), ("Drive", 38), ("Power supply", 51), ("Intake air", 27)]
    static let hot: [(String, Double)] = [("CPU", 93), ("GPU A", 71), ("GPU B", 68), ("Memory", 58), ("Chipset", 66), ("Drive", 44), ("Power supply", 62), ("Intake air", 31)]
    static func status(cpu: Int = 14, memUsed: Double = 13.7e9, diskFree: Double = 210e9, five: Double? = 6, week: Double? = 47, temps: [(String, Double)] = temps, uptime: Double = 187200, alert: String? = nil) -> WidgetStatus {
        var plan: [String: Any] = [:]
        if let five { plan["fiveHour"] = five; plan["fiveHourResets"] = Date().addingTimeInterval(2 * 3600).timeIntervalSince1970 * 1000 }
        if let week { plan["sevenDay"] = week; plan["sevenDayResets"] = Date().addingTimeInterval(3 * 86400).timeIntervalSince1970 * 1000 }
        let soon = Date().addingTimeInterval(5 * 86400).timeIntervalSince1970 * 1000
        let j: [String: Any] = [
            "macos": "26.7.2", "uptime": uptime, "alerts": alert.map { [["title": $0, "level": "warning"]] } ?? [],
            "cpu": ["total": cpu], "mem": ["used": memUsed, "total": 34.4e9], "disk": ["free": diskFree, "total": 500e9],
            "usage": ["plan": plan], "claude": ["remoteControl": true],
            "temps": temps.map { ["name": $0.0, "c": $0.1] },
            "iosApps": ["reachable": true, "apps": [
                ["name": "Mac Pro", "expires": 0, "state": "testflight", "own": true, "icon": "/ios/icon/MacPro.ipa", "build": "291"],
                ["name": "Chumby", "expires": 0, "state": "testflight", "own": true, "icon": "/ios/icon/Chumby.ipa", "build": "291"],
                ["name": "TV", "expires": 0, "state": "testflight", "own": true, "icon": "/ios/icon/TV.ipa", "build": "291"],
                ["name": "SideStore", "expires": soon, "state": "installed", "own": false, "icon": "/ios/icon/SideStore.ipa"],
            ]],
        ]
        return try! JSONDecoder().decode(WidgetStatus.self, from: JSONSerialization.data(withJSONObject: j))
    }
    // Each state a widget can be in, by name.
    static var states: [(String, MacEntry)] {
        let now = Date()
        return [
            ("Live", MacEntry(date: now, state: .ok(status()))),
            ("Busy and hot", MacEntry(date: now, state: .ok(status(cpu: 91, memUsed: 30.9e9, diskFree: 40e9, five: 72, week: 88, temps: hot, alert: "CPU is hot")))),
            ("A blip: last reading 6 min ago", MacEntry(date: now, state: .ok(status()), readAt: now.addingTimeInterval(-6 * 60))),
            ("Not heard for 2 h: last reading", MacEntry(date: now, state: .ok(status()), readAt: now.addingTimeInterval(-2 * 3600))),
            ("Mac not answering, nothing kept", MacEntry(date: now, state: .unreachable)),
            ("Hot, not heard since yesterday", MacEntry(date: now, state: .ok(status(cpu: 91, memUsed: 30.9e9, temps: hot)), readAt: now.addingTimeInterval(-20 * 3600))),
            ("Answer it can't read", MacEntry(date: now, state: .unreadable)),
            ("No address", MacEntry(date: now, state: .noAddress)),
        ]
    }
}

struct MacSheets: View {
    @State private var names: [String] = []
    @State private var icons: [String: Data] = [:]
    var withIcons: MacEntry { var e = MacSample.states[0].1; e.icons = icons; return e }
    func home(_ look: Look) -> some View {
        Sheet("Mac Pro widgets · \(look.title)", colors: look.wallpaper) {
            ForEach(MacSample.states, id: \.0) { name, e in
                SheetRow("Mac Pro Status · \(name)") {
                    HomeCell(look, Fam.small, bg: GraphiteWall()) { StatusView(forced: .systemSmall, entry: e).foregroundStyle(.white) }
                    HomeCell(look, Fam.medium, bg: GraphiteWall()) { StatusView(forced: .systemMedium, entry: e).foregroundStyle(.white) }
                }
            }
            ForEach(MacSample.states.prefix(5), id: \.0) { name, e in
                SheetRow("Temperatures · \(name)") {
                    HomeCell(look, Fam.small, bg: GraphiteWall()) { TempView(forced: .systemSmall, entry: e).foregroundStyle(.white) }
                    HomeCell(look, Fam.medium, bg: GraphiteWall()) { TempView(forced: .systemMedium, entry: e).foregroundStyle(.white) }
                }
            }
            SheetRow("Claude Usage · live, busy, week only, not answering") {
                let s = MacSample.states
                ForEach(Array([s[0].1, s[1].1, MacEntry(date: Date(), state: .ok(MacSample.status(five: nil))), s[4].1].enumerated()), id: \.offset) { _, e in
                    HomeCell(look, Fam.small, bg: GraphiteWall()) { ClaudeView(entry: e).foregroundStyle(.white) }
                }
            }
            SheetRow("Apps on this iPhone · live, not answering") {
                HomeCell(look, Fam.medium, bg: GraphiteWall()) { AppsView(entry: withIcons).foregroundStyle(.white) }
                HomeCell(look, Fam.medium, bg: GraphiteWall()) { AppsView(entry: MacSample.states[4].1).foregroundStyle(.white) }
            }
        }
    }
    func large(_ look: Look) -> some View {
        Sheet("Mac Pro Temperatures (large) · \(look.title)", colors: look.wallpaper) {
            SheetRow("Live · Busy and hot") {
                HomeCell(look, Fam.large, bg: GraphiteWall()) { TempView(forced: .systemLarge, entry: MacSample.states[0].1).foregroundStyle(.white) }
                HomeCell(look, Fam.large, bg: GraphiteWall()) { TempView(forced: .systemLarge, entry: MacSample.states[1].1).foregroundStyle(.white) }
            }
            SheetRow("Not heard for 2 h · Mac not answering, nothing kept") {
                HomeCell(look, Fam.large, bg: GraphiteWall()) { TempView(forced: .systemLarge, entry: MacSample.states[3].1).foregroundStyle(.white) }
                HomeCell(look, Fam.large, bg: GraphiteWall()) { TempView(forced: .systemLarge, entry: MacSample.states[4].1).foregroundStyle(.white) }
            }
        }
    }
    var lock: some View {
        Sheet("Mac Pro · Lock Screen (vibrant)", colors: [Color(red: 0.2, green: 0.3, blue: 0.45), Color(red: 0.55, green: 0.35, blue: 0.4), Color(red: 0.85, green: 0.6, blue: 0.4)]) {
            ForEach(MacSample.states, id: \.0) { name, e in
                SheetRow(name) {
                    LockCell(Fam.circular) { StatusView(forced: .accessoryCircular, entry: e) }
                    LockCell(Fam.rectangular) { StatusView(forced: .accessoryRectangular, entry: e) }
                    LockCell(Fam.circular) { TempView(forced: .accessoryCircular, entry: e) }
                    LockCell(Fam.inline) { TempView(forced: .accessoryInline, entry: e) }
                }
            }
        }
    }
    var standby: some View {
        Sheet("Mac Pro · StandBy (day, night)", colors: [.black, .black]) {
            ForEach(MacSample.states.prefix(3), id: \.0) { name, e in
                SheetRow(name) {
                    StandByCell { StatusView(forced: .systemSmall, entry: e).foregroundStyle(.white) }
                    StandByCell(night: true) { TempView(forced: .systemSmall, entry: e).foregroundStyle(.white) }
                }
            }
        }
    }
    var controls: some View {
        Sheet("Mac Pro · Control Center (drawn stand-ins: each control\u{2019}s own name and glyph, not a system capture)", colors: [Color(red: 0.12, green: 0.14, blue: 0.2), Color(red: 0.2, green: 0.16, blue: 0.24)]) {
            SheetRow("Controls") { ControlTile(title: "Mac Screen", symbol: "desktopcomputer"); ControlTile(title: "Mac Display Off", symbol: "display") }
        }
    }
    var body: some View {
        SheetsDone(names: names).task {
            // The apps' icons from the build's stand-in Mac.
            icons = await MacProvider.icons(MacSample.status(), URL(string: "http://127.0.0.1:9011"))
            print("sheets: icons \(icons.keys.sorted())")
            for look in Look.allCases {
                writeSheet("mac-home-\(look.rawValue)", home(look)); names.append("mac-home-\(look.rawValue)")
                writeSheet("mac-large-\(look.rawValue)", large(look)); names.append("mac-large-\(look.rawValue)")
            }
            writeSheet("mac-lock", scale: 3, lock); names.append("mac-lock")
            writeSheet("mac-standby", standby); names.append("mac-standby")
            writeSheet("mac-controls", controls); names.append("mac-controls")
            print("sheets done")
        }
    }
}
