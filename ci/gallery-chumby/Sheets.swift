import SwiftUI
import WidgetKit

// The Chumby widgets in every family, look and state, as PNG sheets ("-sheets YES").
enum ChumbySample {
    static var base: ChumbyEntry { ChumbyProvider.sample }
    static var skipped: ChumbyEntry {
        var s = base
        s.skipped = SkippedAlarm(name: "Work", at: (s.nextAt ?? Date()).timeIntervalSince1970, when: "weekday")
        s.nextAt = s.nextAt.map { Calendar.current.date(byAdding: .day, value: 1, to: $0) ?? $0 }
        return s
    }
    static var moved: ChumbyEntry {
        var s = base
        var a = Alarm(); a.name = "Work" + JustOnce.suffix; a.when = "once"
        let at = (s.nextAt ?? Date()).addingTimeInterval(45 * 60)
        a.time = String(Int(at.timeIntervalSince1970 / 60))
        s.nextAlarm = a; s.nextAt = at
        s.moved = JustOnceNow(alarm: a, at: at, original: base.nextAlarm, usual: base.nextAt, pinned: true, skip: nil)
        s.skipped = SkippedAlarm(name: "Work", at: (base.nextAt ?? Date()).timeIntervalSince1970, when: "weekday")
        return s
    }
    static var night: ChumbyEntry { var s = base; s.sys.night = 1; return s }
    static var playing: ChumbyEntry { var s = base; s.playing = true; return s }
    static var noAlarm: ChumbyEntry { var s = base; s.nextAlarm = nil; s.nextAt = nil; return s }
    // The Chumby not heard from: the alarms still known (they're rules), a last-seen time.
    static var away: ChumbyEntry { var s = base; s.reachable = false; s.lastSeen = Date().addingTimeInterval(-25 * 60); return s }
    static var never: ChumbyEntry { ChumbyEntry(date: Date()) }
    static var afternoon: ChumbyEntry {
        var s = base
        var a = Alarm(); a.time = "880"; a.name = "Calendar: Dentist appointment at the clinic downtown"
        s.nextAlarm = a
        s.nextAt = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 14, minute: 40), matchingPolicy: .nextTime)
        return s
    }
    static var nightSkipped: ChumbyEntry { var s = skipped; s.sys.night = 1; return s }
    static let states: [(String, ChumbyEntry)] = [("Next alarm", base), ("Skipped", skipped), ("Just this once", moved), ("Night mode", night),
                                                  ("Music playing", playing), ("No alarm set", noAlarm), ("Not answering (alarms known)", away), ("Never reached", never),
                                                  ("A PM calendar alarm, long name", afternoon), ("Night and skipped", nightSkipped)]
}

struct ChumbySheets: View {
    @State private var names: [String] = []
    func sea<C: View>(_ c: C) -> some View { c.environment(\.colorScheme, .dark).foregroundStyle(ChumbyPalette.ink(true)) }
    func home(_ look: Look) -> some View {
        Sheet("Chumby widgets · \(look.title)", colors: look.wallpaper) {
            ForEach(ChumbySample.states, id: \.0) { name, e in
                SheetRow(name) {
                    HomeCell(look, Fam.small, bg: SeaFor()) { sea(AlarmBody(family: .systemSmall, entry: e)) }
                    HomeCell(look, Fam.medium, bg: SeaFor()) { sea(RemoteBody(entry: e)) }
                }
            }
        }
    }
    func status(_ look: Look) -> some View {
        Sheet("Chumby Status and Octopus · \(look.title)", colors: look.wallpaper) {
            ForEach([ChumbySample.states[0], ChumbySample.states[5], ChumbySample.states[6], ChumbySample.states[7]], id: \.0) { name, e in
                SheetRow(name) {
                    HomeCell(look, Fam.small, bg: SeaFor()) { sea(ChumbyStatusBody(family: .systemSmall, entry: e)) }
                    HomeCell(look, Fam.medium, bg: SeaFor()) { sea(ChumbyStatusBody(family: .systemMedium, entry: e)) }
                    HomeCell(look, Fam.small, bg: SeaFor()) { sea(BuddyBody(entry: e)) }
                }
            }
        }
    }
    var lock: some View {
        Sheet("Chumby · Lock Screen (vibrant)", colors: [Color(red: 0.2, green: 0.3, blue: 0.45), Color(red: 0.55, green: 0.35, blue: 0.4), Color(red: 0.85, green: 0.6, blue: 0.4)]) {
            ForEach(ChumbySample.states, id: \.0) { name, e in
                SheetRow(name) {
                    LockCell(Fam.circular) { AlarmBody(family: .accessoryCircular, entry: e) }
                    LockCell(Fam.rectangular) { AlarmBody(family: .accessoryRectangular, entry: e) }
                    LockCell(Fam.inline) { AlarmBody(family: .accessoryInline, entry: e) }
                }
            }
        }
    }
    var standby: some View {
        Sheet("Chumby · StandBy (day, night)", colors: [.black, .black]) {
            ForEach([ChumbySample.states[0], ChumbySample.states[1], ChumbySample.states[6]], id: \.0) { name, e in
                SheetRow(name) {
                    StandByCell { sea(AlarmBody(family: .systemSmall, entry: e)) }
                    StandByCell(night: true) { sea(AlarmBody(family: .systemSmall, entry: e)) }
                    StandByCell { sea(BuddyBody(entry: e)) }
                }
            }
        }
    }
    var controls: some View {
        Sheet("Chumby · Control Center (drawn stand-ins: each control\u{2019}s own name and glyph, not a system capture) (off, on)", colors: [Color(red: 0.12, green: 0.14, blue: 0.2), Color(red: 0.2, green: 0.16, blue: 0.24)]) {
            SheetRow("Skip: next alarm, skipped, just this once") {
                ControlTile(title: "Skip 6:45 AM", symbol: "forward.end.fill"); ControlTile(title: "Skipped 6:45 AM", symbol: "moon.zzz.fill", on: true); ControlTile(title: "Just this once 7:30 AM", symbol: "clock.arrow.circlepath", on: true)
            }
            SheetRow("Night mode: day, night") { ControlTile(title: "Day", symbol: "sun.max.fill"); ControlTile(title: "Night", symbol: "moon.fill", on: true) }
            SheetRow("Buttons") {
                ControlTile(title: "Next Widget", symbol: "forward.fill"); ControlTile(title: "20-Minute Nap", symbol: "zzz")
                ControlTile(title: "Stop Alarm", symbol: "alarm.waves.left.and.right.fill"); ControlTile(title: "Chumby", symbol: "hand.tap.fill")
            }
        }
    }
    var body: some View {
        SheetsDone(names: names).task {
            for look in Look.allCases {
                writeSheet("chumby-home-\(look.rawValue)", home(look)); names.append("chumby-home-\(look.rawValue)")
                writeSheet("chumby-status-\(look.rawValue)", status(look)); names.append("chumby-status-\(look.rawValue)")
            }
            writeSheet("chumby-lock", scale: 3, lock); names.append("chumby-lock")
            writeSheet("chumby-standby", standby); names.append("chumby-standby")
            writeSheet("chumby-controls", controls); names.append("chumby-controls")
            print("sheets done")
        }
    }
}
