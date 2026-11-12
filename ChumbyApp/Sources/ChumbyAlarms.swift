import SwiftUI
import CoreImage
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Small pieces every tab uses
// A failure, at the control it belongs to.
// `dismiss`: for a note that stays until it's put away (one about tonight's alarm must not clear itself while the phone
// is locked), the ✕ that does it, as on a change that didn't reach the Chumby (MarkNote).
struct FailNote: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(ChumbyPalette.warn(scheme == .dark))
            .accessibilityElement(children: .combine)
            if let dismiss {
                Spacer(minLength: 8)
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill").font(.body).symbolRenderingMode(.palette).foregroundStyle(.white, ChumbyPalette.acc(scheme == .dark))
                        .frame(minWidth: 44, minHeight: 32, alignment: .trailing).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
        }
    }
}
// A change that hasn't reached the Chumby, under the row it belongs to, with a way to send it again.
// The control beside it shows what the Chumby really holds; this says what couldn't be changed, and why.
struct MarkNote: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    let mark: String
    var body: some View {
        if case .failed(let head, let why) = model.marks[mark] {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(ChumbyPalette.warn(scheme == .dark))
                    Text(head).fontWeight(.semibold).foregroundStyle(ChumbyPalette.warn(scheme == .dark))
                    Text("·").foregroundStyle(.secondary)
                    Button("Retry") { model.retry(mark) }.buttonStyle(.borderless).fontWeight(.semibold).foregroundStyle(.tint)
                    Spacer(minLength: 8)
                    // Or let it go: the control beside it already shows what the Chumby holds.
                    Button { model.dismiss(mark) } label: {
                        Image(systemName: "xmark.circle.fill").font(.body).symbolRenderingMode(.palette).foregroundStyle(.white, ChumbyPalette.acc(scheme == .dark))
                            .frame(minWidth: 44, minHeight: 32, alignment: .trailing).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                }
                Text(why).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }
    }
}
// Instead of a message: once the Chumby has the change, a small bubble rises off the control and pops.
struct LandBubble: View {
    @EnvironmentObject var model: ChumbyModel
    let mark: String
    // The bubble is gone (faded out) by 0.9 s; past 1.2 s its clock stops, instead of ticking until the next redraw.
    @State private var done = false
    var body: some View {
        if case .landed(let at) = model.marks[mark], Date().timeIntervalSince(at) < 1.2 {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: done)) { ctx in
                let p = min(ctx.date.timeIntervalSince(at) / 0.9, 1)
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.95), .white.opacity(0.15), ChumbyPalette.hex(0x79bbff).opacity(0.3)], center: UnitPoint(x: 0.32, y: 0.28), startRadius: 0, endRadius: 8))
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
                    .frame(width: 11, height: 11)
                    .scaleEffect(p > 0.85 ? 1 + (p - 0.85) * 4 : 0.6 + p * 0.5)
                    .offset(x: 6 * sin(p * 7), y: -34 * p)
                    .opacity(p > 0.85 ? 1 - (p - 0.85) / 0.15 : 1)
            }
            .allowsHitTesting(false)
            .task(id: at) {
                done = false
                try? await Task.sleep(nanoseconds: UInt64(max(0, 1.2 - Date().timeIntervalSince(at)) * 1e9))
                done = true
            }
        }
    }
}
// Hours and minutes the way the Chumby's own alarm rows show them.
func clockParts(_ d: Date) -> (String, String) {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    let h = c.hour ?? 0, m = c.minute ?? 0
    return (String(format: "%d:%02d", h % 12 == 0 ? 12 : h % 12, m), h < 12 ? "AM" : "PM")
}
func dayWord(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    return d.formatted(.dateTime.weekday(.wide))
}
// What an alarm is called on screen: calendar alarms by their event, an unnamed one by its time.
func alarmLabel(_ a: Alarm) -> String {
    if a.isCalendar { return String(a.name.dropFirst(Alarm.calendarPrefix.count)) }
    return a.name.isEmpty ? "your \(a.clock) \(a.meridiem) alarm" : a.name
}

// One alarm row, the same shape for his own alarms and the calendar's: the kind's tile, the time large, what it is, a line
// about when (or which event), any word about it under that, and the switch alone on the right. Tapped anywhere but the
// switch, it opens.
struct AlarmRow<Notes: View>: View {
    let clock: (String, String)
    let title: String
    let detail: String
    let on: Bool
    var mark: String?
    var tile: AnyView?
    // One line, shrinking a touch before it would wrap: "6:00 PM · 2 h 40 min before" never breaks mid-phrase.
    var oneLine = false
    let tap: () -> Void
    let toggle: Binding<Bool>
    @ViewBuilder var notes: () -> Notes
    var body: some View {
        HStack(spacing: 12) {
            Button(action: tap) {
                HStack(alignment: .top, spacing: 12) {
                    if let tile { tile.padding(.top, 6) }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(clock.0).font(.custom("Trebuchet MS", size: 40)).monospacedDigit()
                            Text(clock.1).font(.custom("Trebuchet MS", size: 18))
                        }
                        .opacity(on ? 1 : 0.5)
                        Text(title).font(.body.weight(.semibold)).lineLimit(1).opacity(on ? 1 : 0.6)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(oneLine ? 1 : 2).minimumScaleFactor(oneLine ? 0.85 : 1).opacity(on ? 1 : 0.7)
                        notes()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("On", isOn: toggle).labelsHidden()
                .overlay(alignment: .top) { if let mark { LandBubble(mark: mark) } }
        }
    }
}
// A glyph and a line under an alarm, lined up with the text above it so the row's divider stays straight.
struct RowNote: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String, text: String
    var color: Color?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: icon).font(.footnote)
            Text(text).font(.subheadline)
        }
        .foregroundStyle(color ?? ChumbyPalette.warn(scheme == .dark))
    }
}

// MARK: - Ringing
// While an alarm rings or snoozes: its name, and Snooze and Stop large enough to hit half asleep.
struct RingingCard: View {
    @EnvironmentObject var model: ChumbyModel
    // Everything the card says, taken while the alarm is still there. Once Stop is tapped the card draws only this, so
    // its words never change while it fades.
    struct Shown: Equatable { var ring: Sys.Ringing; var until: Date?; var away: Bool; var seen: Date? }
    @State private var frozen: Shown?
    // Room for the wave and "Snooze" in the card's type, with the capsule's ends.
    @ScaledMetric(relativeTo: .title3) private var snoozeMin: CGFloat = 136
    var live: Shown? { model.sys.ringing.map { Shown(ring: $0, until: model.snoozeEnds, away: model.unreachable, seen: model.seenAt) } }
    var shown: Shown? { live ?? frozen }
    var body: some View {
        content
            .onAppear { frozen = live }
            .onChange(of: live) { _, s in if let s { frozen = s } }
    }
    func name(_ r: Sys.Ringing) -> String {
        [r.name.hasPrefix(Alarm.calendarPrefix) ? String(r.name.dropFirst(Alarm.calendarPrefix.count)) : r.name, r.sound].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    @ViewBuilder var content: some View {
        if let s = shown, s.away {
            // An old reading: what it was doing when last heard from, and no buttons that can't reach it.
            VStack(spacing: 3) {
                Text("Was \(s.ring.snoozed ? "snoozing" : "ringing")\(s.seen.map { " at " + seenText($0) } ?? "")").font(.custom("Trebuchet MS", size: 22).weight(.bold))
                Text([name(s.ring), "the Chumby isn’t answering"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.custom("Trebuchet MS", size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(16).frame(maxWidth: .infinity)
        } else if let s = shown {
            let snoozed = s.ring.snoozed
            VStack(spacing: 14) {
                VStack(spacing: 3) {
                    // Ringing hands over to Snoozed one at a time: the old title is gone before the new one fades in.
                    ZStack {
                        Text(snoozed ? s.until.map { "Snoozed until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Snoozed" : "Ringing")
                            .id(snoozed)
                            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.12)), removal: .opacity.animation(.easeOut(duration: 0.1))))
                    }
                    .font(.custom("Trebuchet MS", size: 24).weight(.bold))
                    Text(name(s.ring)).font(.custom("Trebuchet MS", size: 16)).foregroundStyle(.secondary).lineLimit(1)
                }
                // Snooze narrows to nothing while Stop widens into the room it leaves. Its glass is its own capsule, sized by
                // the frame, so the glass narrows with it rather than vanishing; the word fades out before the frame reaches
                // it. Never narrower than "Snooze" until it goes.
                HStack(spacing: 0) {
                    Button { model.ringSnooze() } label: {
                        Label("Snooze", systemImage: "water.waves").labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
                            .opacity(snoozed ? 0 : 1)
                            .animation(.easeOut(duration: 0.07), value: snoozed)
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 56)
                            .clipped()
                            .contentShape(Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                            // The glass goes with the word, so it never narrows as an empty blob.
                            .opacity(snoozed ? 0 : 1)
                            .animation(.easeOut(duration: 0.1), value: snoozed)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: snoozed ? 0 : snoozeMin, maxWidth: snoozed ? 0 : .infinity)
                    .padding(.trailing, snoozed ? 0 : 14)
                    .allowsHitTesting(!snoozed).accessibilityHidden(snoozed)
                    Button { model.ringOff() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 56) }
                        .buttonStyle(.glassProminent).tint(ChumbyPalette.orange)
                }
                .font(.custom("Trebuchet MS", size: 20).weight(.bold))
                if let f = model.failed("ring") { FailNote(text: f) }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }
}

extension AnyTransition {
    // Stopped: the card is gone by opacity alone within 0.12 s, before the controls under it start up (ChumbyModel.stopSpring).
    static var ringCard: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)), removal: .opacity.animation(.easeOut(duration: ChumbyModel.stopFade)))
    }
}

// MARK: - Naps
// A nap is a real alarm he can set and then change (Richard, 2026-11-09: "i should be able to set a nap alarm and edit it
// based on like whatever"). With none set: four lengths, one tap each, and a row for another time or sound, which opens
// the nap's editor. Set, it's an alarm row like his own: when it rings, what it plays, how long is left (the tide in its
// tile), tapped to change, switched off to call it off. It stays the one "Nap" alarm on the Chumby, so the Chumby's helper
// rule still holds: it never turns his other alarms off and is never pinned.
struct NapSection: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    @AppStorage("napLength") private var napLength = 0
    @AppStorage("napSetAt") private var napSetAt = 0.0
    @State private var sending: Int?
    static let lengths = [10, 20, 30, 60]
    // Which rows the list holds, and whether they're drawn, while a nap is set or called off (AlarmsTab.napMoves); `due`
    // is the nap's time, kept while its row fades out.
    let row: Bool
    let faded: Bool
    let due: Date?
    // Opens the nap's editor: for the nap set, or a new one.
    let edit: (Alarm?) -> Void
    var body: some View {
        Group {
            if row, let due {
                napRow(due).opacity(faded ? 0 : 1)
            } else {
                chips.opacity(faded ? 0 : 1)
                Button { edit(nil) } label: {
                    Label("Another time or sound", systemImage: "slider.horizontal.3").font(.body.weight(.semibold))
                        .foregroundStyle(ChumbyPalette.acc(scheme == .dark))
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set a nap with another time or sound")
                .opacity(faded ? 0 : 1)
            }
            if let f = model.failed("nap") { FailNote(text: f) }
        }
    }
    var chips: some View {
        HStack(spacing: 8) {
            ForEach(Self.lengths, id: \.self) { m in
                Button {
                    napLength = m; sending = m
                    Task { await model.nap(m); sending = nil }
                } label: {
                    Group { if sending == m { ProgressView() } else { Text("\(m) min").lineLimit(1).minimumScaleFactor(0.8) } }.frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered).disabled(sending != nil)
                .accessibilityLabel("\(m) minute nap")
            }
        }
    }
    // The nap set, as an alarm: the Nap alarm's own sound and length, or the Chumby's own nap (cmd nap), which has none
    // and nothing to change. The time left is said in whole minutes and moves once a minute, so the row never flickers.
    func napRow(_ due: Date) -> some View {
        let nap = model.napAlarm
        let own = nap == nil
        return TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let left = max(due.timeIntervalSince(ctx.date), 0)
            let minutes = max(Int((left / 60).rounded(.up)), 1)
            // Its whole length, from when this phone set it; set elsewhere, an hour stands in, so the tide still falls.
            let set = Date(timeIntervalSince1970: napSetAt)
            let total = set < due && due.timeIntervalSince(set) < 12 * 3600 ? due.timeIntervalSince(set) : 3600
            AlarmRow(clock: clockParts(due), title: "Nap",
                     detail: [left < 60 ? "Rings any moment" : "Rings in \(minutes) min", own ? "set on the Chumby" : nap?.soundText ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                     on: true, mark: "nap",
                     tile: AnyView(NapTile(left: min(left / total, 1))),
                     tap: { if let nap { edit(nap) } },
                     toggle: Binding(get: { true }, set: { on in if !on { Task { await model.cancelNap() } } })) { EmptyView() }
        }
        .accessibilityHint(own ? "" : "Opens the nap to change it")
    }
}
// The nap's heading: "Nap" stands still, and ", wake me in" fades away with the chips as a nap is set and back in with
// them when it's called off (it swapped whole in one frame). Timed to NapSection's three moves.
struct NapHead: View {
    let set: Bool
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "zzz").font(.subheadline.weight(.semibold))
            HStack(spacing: 0) {
                Text("Nap")
                Text(", wake me in").opacity(set ? 0 : 1)
                    .animation(set ? .easeOut(duration: AlarmsTab.napFade) : .easeIn(duration: 0.16).delay(AlarmsTab.napFade + AlarmsTab.napSettle), value: set)
            }
            .font(.custom("Trebuchet MS", size: 16).weight(.bold))
        }
        .foregroundStyle(color).textCase(nil)
        .accessibilityElement(children: .ignore).accessibilityLabel(set ? "Nap" : "Nap, wake me in")
    }
}
// The nap's tile: zzz on the Chumby's blue, with the time left as a lighter tide that falls as the nap runs down.
struct NapTile: View {
    let left: Double
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let c = ChumbyPalette.sub(scheme == .dark)
        ZStack(alignment: .bottom) {
            c.opacity(0.18)
            GeometryReader { g in
                Rectangle().fill(c.opacity(0.28)).frame(height: g.size.height * left).frame(maxHeight: .infinity, alignment: .bottom)
            }
            Image(systemName: "zzz").font(.system(size: 20, weight: .semibold)).foregroundStyle(c)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 44, height: 48)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .animation(.smooth(duration: 0.6), value: left)
        .accessibilityHidden(true)
    }
}

// MARK: - What woke me
// Songs Pandora played just after an alarm, each with its cover and a way to it in Apple Music.
@MainActor
final class SongArt: ObservableObject {
    static let shared = SongArt()
    struct Found { var image: PlatformImage?; var link: URL?; var tint: Color? }
    @Published var found: [String: Found] = [:]
    private var asked = Set<String>()
    // Named by a hash that's the same every launch (Swift's own hashValue changes each time, so nothing kept was ever found).
    private static func file(_ k: String) -> URL {
        var h: UInt64 = 0xcbf29ce484222325
        for b in k.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chumby-art-" + String(h, radix: 16))
    }
    private var links: [String: String] { get { UserDefaults.standard.dictionary(forKey: "songLinks") as? [String: String] ?? [:] } set { UserDefaults.standard.set(newValue, forKey: "songLinks") } }
    static func key(_ s: Song) -> String { s.artist + " – " + s.title }
    // At launch and on opening Alarms, so the covers are in hand before the row ever scrolls into view.
    func prefetch(_ songs: [Song], _ alarms: [Alarm], _ rings: [Ring] = []) {
        for w in WokeUpTo.wakings(songs, alarms, rings) { look(w.song) }
    }
    func look(_ s: Song) {
        let k = Self.key(s)
        guard !asked.contains(k) else { return }
        asked.insert(k)
        // Kept from before: shown at once, never fetched again.
        if let d = try? Data(contentsOf: Self.file(k)), let i = PlatformImage(data: d) {
            found[k] = Found(image: i, link: links[k].flatMap(URL.init(string:)), tint: Self.tint(d)); return
        }
        Task {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [.init(name: "term", value: s.artist + " " + s.title), .init(name: "entity", value: "song"), .init(name: "limit", value: "1")]
            struct R: Decodable { struct T: Decodable { let artworkUrl100: String?; let trackViewUrl: String? }; let results: [T] }
            // Not reached: asked again next time rather than settling on no cover, but shown meanwhile with the octopus tile,
            // so a song never waits off the strip for a lookup that can't happen.
            guard let u = c.url, let d = try? await URLSession.shared.data(from: u).0, let r = try? JSONDecoder().decode(R.self, from: d) else {
                asked.remove(k)
                if found[k] == nil { withAnimation(.easeOut(duration: 0.2)) { found[k] = Found(image: nil, link: nil, tint: nil) } }
                return
            }
            var f = Found(image: nil, link: nil, tint: nil)
            if let t = r.results.first {
                if let link = t.trackViewUrl { links[k] = link }
                f.link = t.trackViewUrl.flatMap(URL.init(string:))
                if let a = t.artworkUrl100.map({ $0.replacingOccurrences(of: "100x100", with: "300x300") }), let au = URL(string: a), let img = try? await URLSession.shared.data(from: au).0 {
                    try? img.write(to: Self.file(k), options: .atomic)
                    f.image = PlatformImage(data: img); f.tint = Self.tint(img)
                }
            }
            // Arriving late, the cover crossfades in rather than cutting.
            withAnimation(.easeOut(duration: 0.2)) { found[k] = f }
        }
    }
    // The cover's average colour, for the tile behind it.
    static func tint(_ d: Data) -> Color? {
        guard let i = CIImage(data: d), let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: i, kCIInputExtentKey: CIVector(cgRect: i.extent)]), let o = f.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(o, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
    }
}
struct WokeUpTo: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var art = SongArt.shared
    @Environment(\.openURL) private var openURL
    @State private var width: CGFloat = 0
    // For each time an alarm went off, the first song Pandora played in the 45 minutes after it.
    // From the Chumby's own log of rings when it has one: each ring's first song within 45 minutes, named as the alarm was.
    // A once-only calendar alarm leaves the alarm list once it fires, so pairing with the list found nothing for it (Richard,
    // 2026-11-06: "woke up to doesnt work"). The list is the fallback for a Chumby too old to log rings.
    static func wakings(_ songs: [Song], _ alarms: [Alarm], _ rings: [Ring]) -> [(song: Song, alarm: String)] {
        guard !rings.isEmpty else { return wakings(songs, alarms) }
        let byTime = songs.sorted(by: { $0.t < $1.t })
        var out: [(song: Song, alarm: String)] = []
        for r in rings.sorted(by: { $0.t > $1.t }) {
            guard let s = byTime.first(where: { $0.t >= r.t && $0.t - r.t < 45 * 60 }), !out.contains(where: { $0.song == s }) else { continue }
            let name = r.name.hasPrefix(Alarm.calendarPrefix) ? String(r.name.dropFirst(Alarm.calendarPrefix.count)) : r.name
            out.append((s, name.isEmpty ? "your alarm" : name))
            if out.count == 8 { break }
        }
        return out
    }
    static func wakings(_ songs: [Song], _ alarms: [Alarm]) -> [(song: Song, alarm: String)] {
        let cal = Calendar.current
        var out: [(song: Song, alarm: String, fire: Date)] = []
        for s in songs.sorted(by: { $0.t < $1.t }) {
            let t = Date(timeIntervalSince1970: s.t)
            var hit: (Date, String)?
            for a in alarms where !a.isPlaceholder && a.type == "audio" {
                var fires: [Date] = []
                if a.when == "once" { if let m = Double(a.time) { fires = [Date(timeIntervalSince1970: m * 60)] } }
                else if let m = Int(a.time) {
                    for back in 0...1 {
                        guard let day = cal.date(byAdding: .day, value: -back, to: t), let f = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) else { continue }
                        let w = cal.component(.weekday, from: f) - 1
                        if a.when == "daily" || (a.when == "weekday" && w > 0 && w < 6) || (a.when == "weekend" && (w == 0 || w == 6)) || a.when == Alarm.dayKeys[w] { fires.append(f) }
                    }
                }
                for f in fires where t >= f && t.timeIntervalSince(f) < 45 * 60 { hit = (f, alarmLabel(a)) }
            }
            guard let h = hit, !out.contains(where: { abs($0.fire.timeIntervalSince(h.0)) < 60 }) else { continue }
            out.append((s, h.1, h.0))
        }
        return out.reversed().prefix(8).map { ($0.song, $0.alarm) }
    }
    var body: some View {
        let all = Self.wakings(model.songs, model.state.alarms, model.rings)
        // A song joins the strip only once its cover has been looked up, so a new one arrives with its art, never as a
        // blank tile, and slides the others along in one spring rather than a frame.
        let list = all.filter { art.found[SongArt.key($0.song)] != nil }
        if !list.isEmpty {
            // The covers fill the card when they all fit (open portrait had three small ones and 40% of the card bare), and
            // scroll at their smallest when they don't, sliding out under the card's own edge on both sides alike.
            let n = CGFloat(list.count)
            let avail = width - 2 * Self.inset
            let fits = width > 0 && n * Self.smallest + (n - 1) * Self.gap <= avail
            let side = fits ? min(Self.largest, ((avail - (n - 1) * Self.gap) / n).rounded(.down)) : Self.smallest
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Self.gap) {
                        ForEach(list, id: \.song.id) { w in tile(w.song, side: side).transition(.opacity.combined(with: .scale(scale: 0.92))) }
                    }
                    .padding(.vertical, 14)
                    .animation(.snappy, value: list.map(\.song.id))
                }
                .contentMargins(.horizontal, Self.inset, for: .scrollContent)
                .scrollDisabled(fits)
                .clipShape(RoundedRectangle(cornerRadius: SoloCard.radius, style: .continuous))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .listRowInsets(EdgeInsets())
            } header: { SectionHead(icon: "sunrise.fill", text: "Woke up to") }
        }
    }
    static let gap: CGFloat = 10, inset: CGFloat = 14, smallest: CGFloat = 100, largest: CGFloat = 200
    func tile(_ s: Song, side: CGFloat) -> some View {
        let f = art.found[SongArt.key(s)]
        return Button {
            var c = URLComponents(string: "https://music.apple.com/search")!
            c.queryItems = [.init(name: "term", value: s.artist + " " + s.title)]
            if let u = f?.link ?? c.url { openURL(u) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    if let i = f?.image { Image(platform: i).resizable().scaledToFill().transition(.opacity) }
                    else if f != nil {
                        // Looked for and none found: the octopus on the Chumby's own blue, never a grey box.
                        ZStack {
                            ChumbyPalette.hex(0x2c5bae)
                            OctopusMark(color: .white.opacity(0.9), eyes: ChumbyPalette.hex(0x2c5bae)).padding(side * 0.23)
                        }
                        .transition(.opacity)
                    } else {
                        // Still on its way (rare, as covers are fetched at launch and kept): a plain tile, no stand-in art.
                        GlassRow().transition(.opacity)
                    }
                }
                .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.bottom, 3)
                // Top-aligned, the artist straight under the title: a one-line title no longer leaves a gap that a
                // two-line one doesn't, so every caption starts the same distance under its cover (designer, 11-11).
                Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Text(s.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(Date(timeIntervalSince1970: s.t).formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onAppear { art.look(s) }
        .accessibilityLabel("\(s.title) by \(s.artist). Opens in Apple Music.")
    }
}

// MARK: - Alarms
struct AlarmsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @ObservedObject private var wake = CalendarWake.shared
    @State private var turningOn = false
    @Environment(\.paneLayout) private var wide
    @Environment(\.colorScheme) private var scheme
    @State private var editing: EditTarget?
    // Open, the right pane holds whatever would otherwise be a sheet, so nothing sits across the fold.
    enum Pane: Equatable { case schedule, settings, editor(Alarm?), napEditor(Alarm?), day(String), template }
    @State private var pane: Pane = .schedule
    @State private var paneBack: Pane = .schedule
    @State private var removing: String?
    @State private var posed = false
    @AppStorage("missedDismissed") private var dismissedRaw = ""
    struct EditTarget: Identifiable { let alarm: Alarm?; var nap = false; var id: String { (nap ? "nap-" : "") + (alarm?.key ?? "new") } }
    // Each editor grows out of the row that opened it and shrinks back into it, the iOS zoom, rather than a sheet rising
    // from the foot with no tie to what was tapped (Richard, 2026-11-07: "the animation to edit like the calendar alarm
    // sucks").
    @Namespace private var editNS

    var dismissed: Set<String> { Set(dismissedRaw.split(separator: "\n").map(String.init)) }
    var missed: [ChumbyState.Missed] { model.state.missed.filter { Date().timeIntervalSince1970 - $0.at < 86400 && !dismissed.contains($0.id) }.suffix(3).reversed().map { $0 } }
    // A "just this once" standing in for one of these is told on that alarm's row, never listed as an alarm of its own.
    var folded: String? { model.state.justOnce().flatMap { $0.original != nil ? $0.alarm.key : nil } }
    // A one-off whose time is long gone can never ring again and is cleared at the next save; until then it isn't listed
    // as an alarm that's "off" (11-10: yesterday's one-off and its "just this once" sat in his list as two dead rows).
    var mine: [Alarm] { model.state.alarms.filter { !$0.isPlaceholder && $0.name != "Catch-up" && !$0.isCalendar && $0.name != "Nap" && $0.key != folded && !ChumbyState.isExpired($0, chumby: model.state.chumbyNow) }.sorted { $0.localMinutes < $1.localMinutes } }
    var paneShown: Pane { wide ? pane : .schedule }
    // Pages that bring their own list and title row (editor, day), shown in the right pane in place of its list.
    // An editor opened in the pane stays the same view through a turn: drawn over the whole page upright (TwoPane), and
    // back in its pane open flat, with what's typed and where it was. Never a cover made for it by the turn.
    var rightPage: AnyView? {
        switch pane {
        case .editor(let a): return AnyView(AlarmEditor(original: a, close: { show(.schedule) }).id(a?.key ?? "new"))
        case .napEditor(let a): return AnyView(AlarmEditor(original: a, nap: true, close: { show(.schedule) }).id("nap-" + (a?.key ?? "new")))
        case .day(let k): return wide ? AnyView(CalendarDaySheet(key: k, close: { show(.schedule) }).id(k)) : nil
        case .template: return AnyView(AlarmEditor(calendarTemplate: true, close: { closeTemplate() }))
        default: return nil
        }
    }
    // Pages that bring their own title row (editor, day) have none from here.
    var rightTitle: String? {
        switch paneShown {
        case .schedule: return " "
        case .settings: return "Calendar settings"
        default: return nil
        }
    }
    // The right pane changing pages: the page there fades out, the next takes its place while nothing is drawn, and fades
    // in. Changed inside one animation, the list traded the two pages' rows through each other.
    @State private var paneFaded = false
    @State private var paneSwap: Task<Void, Never>?
    func show(_ p: Pane) {
        paneSwap?.cancel(); paneSwap = nil
        guard p != pane else { if paneFaded { withAnimation(.easeOut(duration: 0.2)) { paneFaded = false } }; return }
        paneSwap = Task { @MainActor in
            // Out in 0.1 s and straight back in over 0.18 s: the pane is never seen empty (gate B3: 0.3–0.4 s blank).
            withAnimation(.easeIn(duration: 0.1)) { paneFaded = true }
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            pane = p
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { paneFaded = false }
            paneSwap = nil
        }
    }
    // The template's editor closed: back to where it was opened from (Calendar settings, pushed when upright).
    func closeTemplate() {
        if wide || paneBack != .settings { show(wide ? paneBack : .schedule); return }
        show(.schedule); dayPage = nil; model.alarmsPage = true
    }
    func edit(_ a: Alarm?) { if wide { show(.editor(a)) } else { editing = EditTarget(alarm: a) } }
    // The nap's editor: the nap set, or a new one.
    func editNap(_ a: Alarm?) { if wide { show(.napEditor(a)) } else { editing = EditTarget(alarm: a, nap: true) } }
    // Folded, and open in portrait, a day is a page pushed over Alarms like Calendar settings; open in landscape it fills
    // the right pane.
    func openDay(_ k: String) { if wide { show(.day(k)) } else { dayPage = k; model.alarmsPage = true } }
    func openSettings() { if wide { show(.settings) } else { dayPage = nil; model.alarmsPage = true } }
    @State private var dayPage: String?

    // For the build's film: a row to bring on screen, so the nap's chip and countdown are filmed, not run below the fold.
    @State private var scrollTo: String?
    // Calendar settings or a day over Alarms is a real push, with the system's own Back and its edge swipe, laid out by
    // iOS the Duo's way (the top of the side strip folded and open in landscape, the top bar open in portrait): Apple's
    // HIG for iPhone Duo, "Vertical controls"; Richard, 2026-11-08: "the back button is retarded and not iphone duo
    // standard". It slides as the system's pages do, whole: the zoom (11-07) resized the page as it went, so its rows
    // re-laid themselves out under the finger (Richard, 2026-11-09: "when u swipe a page off screen the elements
    // compact as u do so … make sure that doesnt occur anywhere"). The zoom stays on the sheets, which aren't swiped off.
    var body: some View {
        ScrollViewReader { proxy in
            page.onChange(of: scrollTo) { _, id in if let id { withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }
    // Folded, top to bottom as he uses it: what rings next (with Skip), then his own alarms, then the calendar's, then a
    // nap. Open, his own sit under the hero on the left and the calendar's and the nap on the right, always: My alarms
    // first and Calendar under it in every posture (Richard, 2026-11-10). The two kinds never look alike: the calendar's
    // have a coral page-of-a-calendar tile and say which event and how long before it; his own have a blue alarm tile
    // and say when they repeat (Richard, 2026-11-05: "theres little to no distinction between daily alarms and calendar
    // alarms its just super unintuitive"). Night times moved to Tinker, and "Woke up to" to Sounds.
    var page: some View {
        TwoPane(rightTitle: rightTitle, rightTrailing: paneShown == .settings ? AnyView(Button("Done") { show(.schedule) }.fontWeight(.semibold).foregroundStyle(.tint)) : nil, rightShown: !paneFaded, rightPage: rightPage) {
            // Add alarm is never a loose circle: it's the last row of My alarms (below).
            PageTitle("Alarms")
            ReachRow()
            if model.sys.ringing != nil { Section { RingingCard() } }
            Section { glance }
            if !missed.isEmpty {
                Section {
                    ForEach(missed) { m in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                RowNote(icon: "alarm.waves.left.and.right.fill", text: m.rang ? "Rang late" : "Missed")
                                Text([Date(timeIntervalSince1970: m.at).formatted(.dateTime.weekday(.abbreviated).hour().minute()), m.name.hasPrefix(Alarm.calendarPrefix) ? String(m.name.dropFirst(Alarm.calendarPrefix.count)) : m.name].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            // Put away with the mark beside it, never a swipe that slides the row off its card.
                            RowRemove(label: "Dismiss", icon: "xmark.circle.fill") { withAnimation(.snappy) { dismissedRaw = (dismissed.union([m.id])).joined(separator: "\n") } }
                        }
                    }
                } footer: { SectionFoot("The Chumby was frozen or off when these came due.") }
            }
            yours
        } right: {
            switch paneShown {
            case .schedule:
                // The nap keeps one place, under the calendar's, open or folded, whatever the calendar's doing: it used to
                // cross panes whenever the calendar had nothing listed, so it was never in one place.
                calendar
                nap
            case .settings: CalendarSettingsSections()
            default: EmptyView()
            }
        }
        .seaList()
        // A nap set or called off moves anything it touches (the next alarm, the chip) in one spring, never in one frame.
        .animation(.snappy, value: model.napDue)
        .onChange(of: model.napDue) { _, _ in napMoves() }
        // Back on this tab with the rows behind the Chumby (a change that came while it was away): put right at once.
        .onAppear { if napSwap == nil, napRowShown != (model.napDue != nil) { napRows = model.napDue != nil; napFaded = false } }
        .environment(\.openTemplate, wide ? { paneBack = pane; show(.template) } : nil)
        // Pushed and put away by a turn without the slide (onChange(of: wide), in a still transaction): sliding, the page
        // showed the navigation's blank page behind it, and over the split as it went (gate B3).
        .navigationDestination(isPresented: $model.alarmsPage) {
            Group { if let k = dayPage { CalendarDayPage(key: k) } else { CalendarWakeSettings() } }
        }
        // Edge to edge (fillCover), with the zoom from its row.
        .fillCover(item: $editing) { t in AlarmEditor(original: t.alarm, nap: t.nap).environmentObject(model).zoomed(from: t.id, in: editNS) }
        // Pulled down, the calendar is read again too, so "Pull down to try again" under Calendar is true.
        .refreshable { await model.loadState(); if wake.rules.enabled, wake.note != nil { await wake.sync() } }
        .onChange(of: model.addAlarm) { _, _ in edit(nil) }
        // The hinge or a turn mid-page keeps the page (Richard, 2026-11-08: "reactivity to diff modes and folding scenarios
        // across everything"): opened flat, what was pushed over the one list (Calendar settings, a day) moves to the
        // right pane, and an editor opened there goes back to a sheet when the phone is folded or turned upright; a
        // sheet already up stays a sheet. Never a page lost to a fold.
        .onChange(of: wide) { _, w in
            paneSwap?.cancel(); paneSwap = nil; paneFaded = false
            var still = Transaction(); still.disablesAnimations = true
            // An editor opened in the pane (or the template's) is left where it is: the same view, over the whole page upright
            // and back in its pane open flat (the lead's ruling, 11-11). One opened folded stays a cover.
            switch pane { case .editor, .napEditor, .template: return; default: break }
            if w {
                if model.alarmsPage { withTransaction(still) { pane = dayPage.map { .day($0) } ?? .settings; model.alarmsPage = false } }
                else { pane = .schedule }
            } else {
                withTransaction(still) {
                    switch pane {
                    case .settings: dayPage = nil; model.alarmsPage = true
                    case .day(let k): dayPage = k; model.alarmsPage = true
                    default: break
                    }
                    pane = .schedule
                }
            }
        }
        .onAppear {
            wake.refreshPlan()
            guard !posed else { return }
            posed = true
            switch ChumbyModel.pose {
            case "calsettings": openSettings()
            case "template": if wide { show(.template) } else { openSettings() }
            case "calday": if let k = wake.plan.first?.key { openDay(k) }
            // A day with its own settings: a set time 25 minutes earlier than usual and a label of its own.
            case "caldayedit":
                if let w = wake.plan.first {
                    wake.rules.dayEdits[w.key] = DayEdit(wakeAt: w.wake.addingTimeInterval(-25 * 60).timeIntervalSince1970, label: "Early start")
                    openDay(w.key)
                }
            // A day with its own sound: the mock's radio station and a 15-minute snooze, the other days on the shared set.
            case "caldayown":
                // Once the mock's list (with its radio station) has come in.
                Task {
                    for _ in 0..<30 where model.state.streams.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000) }
                    guard let w = wake.plan.first else { return }
                    var own = Alarm(); own.snooze = "15"
                    var radio = SoundChoice(); radio.kind = "stream"
                    _ = radio.apply(to: &own, state: model.state, stations: model.pandoraStations)
                    wake.rules.dayEdits[w.key] = DayEdit(own: own)
                    openDay(w.key)
                }
            // A calendar day moved for that day alone by "just this once": its own time, 25 minutes later than usual.
            case "calonce": if let w = wake.plan.first { wake.rules.dayEdits[w.key] = DayEdit(wakeAt: w.wake.addingTimeInterval(25 * 60).timeIntervalSince1970) }
            case "editor", "editordraft": edit(mine.first ?? Alarm())
            case "editornew": edit(nil)
            // His own alarms and the nap brought on screen, folded, for their shot.
            case "alarmsmine", "napset": Task { try? await Task.sleep(nanoseconds: 1_500_000_000); scrollTo = "nap" }
            // The nap set (the mock's nap scene) opened in its editor.
            case "napeditor":
                Task {
                    for _ in 0..<30 where model.napAlarm == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                    editNap(model.napAlarm)
                }
            case "failure":
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if let a = mine.first { model.change(.toggle(a, !a.isOn)) }
                }
            // Opens the alarm's editor, then its "just this once" sheet and the warning that Set would replace the skip
            // already set (the mock's skipped scene), for the shot.
            case "reskip": if let a = mine.first { edit(a) }
            case "alarmsdemo":
                // For the build's film: Settings in and out, then a calendar day and an alarm's editor each in and out (the
                // zoom from their rows), then down to the nap, where a 10-minute nap is started, counts down for a while
                // and is called off, all on screen.
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000); openSettings()
                    try? await Task.sleep(nanoseconds: 2_500_000_000); if wide { show(.schedule) } else { model.alarmsPage = false }
                    try? await Task.sleep(nanoseconds: 1_200_000_000); if let k = wake.plan.first?.key { openDay(k) }
                    try? await Task.sleep(nanoseconds: 2_500_000_000); if wide { show(.schedule) } else { model.alarmsPage = false }
                    try? await Task.sleep(nanoseconds: 1_200_000_000); if let a = mine.first { edit(a) }
                    try? await Task.sleep(nanoseconds: 2_500_000_000); if wide { show(.schedule) } else { editing = nil }
                    try? await Task.sleep(nanoseconds: 1_200_000_000); scrollTo = "nap"
                    try? await Task.sleep(nanoseconds: 1_200_000_000); UserDefaults.standard.set(10, forKey: "napLength"); await model.nap(10)
                    try? await Task.sleep(nanoseconds: 4_500_000_000); await model.cancelNap()
                }
            default: break
            }
        }
    }

    // What rings next, first, so it never has to be worked out from the list: what kind it is, the time, when, and Skip.
    @State private var skipping = false
    @ViewBuilder var glance: some View {
        if !model.stateKnown && model.unreachable {
            // Out of reach, no spinner promising an answer that can't come: the Offline row above says why.
            Text("What rings next shows once the Chumby answers.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
        } else if !model.stateKnown {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reaching the Chumby…").foregroundStyle(.secondary)
                    Text("What rings next shows once it answers.").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } else if let n = model.nextRing() {
            // A "just this once" standing behind the Chumby's skip is that alarm moved for one ring, never a skip: the
            // moved time leads, the usual one is said in words, and "Back to 6:45 AM" takes it back (Richard,
            // 2026-11-08: "i dont like that it shows as a skip").
            let moved = model.state.justOnce().flatMap { $0.pinned && $0.alarm.key == n.alarm.key ? $0 : nil }
            let shownAlarm = moved?.original ?? n.alarm
            let fromCalendar = shownAlarm.isCalendar
            let skippedNow = model.state.skipped.map { $0.date > Date() } == true
            VStack(alignment: .leading, spacing: 3) {
                // A plain skip shows here too, with its Undo, so the time below never looks as if the skipped one vanished.
                if moved == nil, let s = model.state.skipped, s.date > Date() {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(clockParts(s.date).0 + " " + clockParts(s.date).1).font(.custom("Trebuchet MS", size: 17).weight(.bold)).strikethrough().foregroundStyle(.secondary)
                        Text("Skipped").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Undo") { Task { await model.unskip() } }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.tint).buttonStyle(.borderless)
                    }
                    .padding(.bottom, 4)
                }
                // What kind it is, in that kind's colour, the same glyph as its row below.
                SectionHead(icon: fromCalendar ? "calendar" : "alarm.fill",
                            text: (skippedNow && moved == nil ? "Then" : "Next alarm") + " · " + { let k = kindWord(shownAlarm); return k.prefix(1).uppercased() + k.dropFirst() }(),
                            color: fromCalendar ? ChumbyPalette.cal(scheme == .dark) : ChumbyPalette.acc(scheme == .dark))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    let c = clockParts(n.at)
                    Text(c.0).font(.custom("Trebuchet MS", size: 52).weight(.bold)).monospacedDigit().contentTransition(.numericText())
                    Text(c.1).font(.custom("Trebuchet MS", size: 22).weight(.bold)).contentTransition(.numericText())
                    Spacer(minLength: 0)
                }
                // Moved for one ring, the day line says so in few words and "Back to 6:45 AM" has a row of its own:
                // beside the line, folded, both were cut short (build 218: "Back to 6:45…", "just this once (usual…").
                if let moved, moved.usual != nil {
                    Text("\(dayWord(n.at)) · \(alarmLabel(shownAlarm).capitalizedFirst) · just this once" + (moved.usual.map { " · usually \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        .foregroundStyle(.secondary).lineLimit(2).contentTransition(.numericText())
                }
                HStack(alignment: .center, spacing: 10) {
                    // How long until it rings sits under the time, with the day: at the time's right, the card's top
                    // corner, the status bar's clock and Wi-Fi covered it once the page scrolled (gate dd1a, 276).
                    VStack(alignment: .leading, spacing: 2) {
                        if moved == nil {
                            Text("\(dayWord(n.at)) · \(alarmLabel(shownAlarm).capitalizedFirst)")
                                .foregroundStyle(.secondary).lineLimit(1).contentTransition(.numericText())
                        }
                        Text(n.at, style: .relative).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).monospacedDigit().contentTransition(.numericText())
                    }
                    Spacer(minLength: 8)
                    if let moved, let u = moved.usual {
                        // Back to the usual: the skip taken back and the one-off removed, in that order (undoJustOnce).
                        Button {
                            skipping = true
                            Task { if let why = await model.undoJustOnce() { model.fail("skip", why) }; skipping = false }
                        } label: {
                            Group { if skipping { ProgressView() } else { Text("Back to \(u.formatted(date: .omitted, time: .shortened))") } }
                                .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize().frame(minHeight: 30).padding(.horizontal, 4)
                        }
                        .buttonStyle(.glass).disabled(skipping || model.unreachable)
                        .accessibilityLabel("Back to the usual \(u.formatted(date: .omitted, time: .shortened)) alarm")
                    } else if n.alarm.name == "Nap", model.sys.ringing == nil {
                        // A nap isn't skipped, it's called off: the same as the nap row's switch and its editor (Richard,
                        // 2026-11-10: a nap's card says "Cancel nap").
                        Button {
                            skipping = true
                            Task { await model.cancelNap(); skipping = false }
                        } label: {
                            Group { if skipping { ProgressView() } else { Label("Cancel nap", systemImage: "xmark") } }
                                .font(.subheadline.weight(.semibold)).frame(minWidth: 64, minHeight: 30)
                        }
                        .buttonStyle(.glass).disabled(skipping || model.unreachable)
                        .accessibilityLabel("Cancel the nap")
                    } else if model.state.skipKnown && !skippedNow && model.sys.ringing == nil {
                        // The one thing he'd reach for here: let it pass. Only on a Chumby that can skip, and not twice.
                        Button {
                            skipping = true
                            Task { await model.skipNext(); skipping = false }
                        } label: {
                            Group { if skipping { ProgressView() } else { Label("Skip", systemImage: "forward.end.fill") } }
                                .font(.subheadline.weight(.semibold)).frame(minWidth: 64, minHeight: 30)
                        }
                        .buttonStyle(.glass).disabled(skipping || model.unreachable)
                        .accessibilityLabel("Skip the \(clockParts(n.at).0) \(clockParts(n.at).1) alarm")
                    }
                }
                if let f = model.failed("skip") { FailNote(text: f, dismiss: model.dismissal("skip")) }
                // No "just this once" door here: Home's card and the alarm's own editor have it (Richard, 2026-11-10).
            }
            .padding(.vertical, 2)
            // A nap starting or called off rolls the time over rather than swapping it.
            .animation(.snappy, value: n.at)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    OctopusMark(color: ChumbyPalette.hex(0x2c5bae).opacity(0.7), blink: 0.08).frame(width: 34)
                    Text("No alarm set. Sleep in.").foregroundStyle(.secondary)
                }
                // With the calendar's wake-ups switched off and nothing else set, his usual alarm is one tap away, named,
                // so "nothing set" is never where switching the calendar off quietly leaves him (2026-11-10). Switching
                // on an alarm already in the list is not a new alarm, so nothing else is touched.
                if !wake.rules.enabled, !model.unreachable, let a = model.deviceState.usualAlarm(rings: model.rings) {
                    Button { model.change(.toggle(a, true)) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Turn on \(a.spoken)", systemImage: "alarm.fill").font(.body.weight(.semibold))
                                .foregroundStyle(ChumbyPalette.acc(scheme == .dark))
                            Text("\(a.clock) \(a.meridiem) · \(a.whenText) · \(a.soundText)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Switches that alarm on")
                    MarkNote(mark: a.key)
                }
            }
        }
    }

    // What kind of alarm it is, in a few words, for the hero's heading.
    func kindWord(_ a: Alarm) -> String {
        if a.isCalendar { return "from your calendar" }
        if a.name == "Nap" { return "nap" }
        if a.name == "Catch-up" { return "catch-up" }
        switch a.when {
        case "once": return "one-off"
        case "daily": return "every day"
        case "weekday": return "weekdays"
        case "weekend": return "weekends"
        default: return a.whenText
        }
    }
    // His own alarms: blue alarm tiles, each saying when it repeats and what it plays.
    var yours: some View {
        Section {
            ForEach(mine, id: \.key) { a in
                AlarmRow(clock: (a.clock, a.meridiem), title: a.name.isEmpty ? "Alarm" : a.name,
                         detail: [a.whenUnlessNamed, a.soundText].filter { !$0.isEmpty }.joined(separator: " · "), on: a.isOn, mark: a.key,
                         tile: AnyView(AlarmTile(calendarDay: nil, on: a.isOn)),
                         tap: { edit(a) },
                         toggle: Binding(get: { a.isOn }, set: { on in
                             // Switching off a "just this once" puts the usual time back, never leaving both quiet.
                             if !on, JustOnce.isOne(a), let j = model.state.justOnce(), j.alarm.key == a.key, j.canUndo {
                                 Task { if let why = await model.undoJustOnce() { model.fail("skip", why) } }
                             } else { model.change(.toggle(a, on)) }
                         })) {
                    if JustOnce.isOne(a), let j = model.state.justOnce(), j.alarm.key == a.key {
                        if let r = j.replaces { RowNote(icon: "clock.arrow.circlepath", text: "In place of the \(r.date.formatted(date: .omitted, time: .shortened)), just this once", color: .secondary) }
                        else if j.orphan, let u = j.usual { RowNote(icon: "exclamationmark.circle.fill", text: "The usual \(u.formatted(date: .omitted, time: .shortened)) isn’t skipped, so both ring") }
                    }
                    // Its one ring moved or changed, said here on the alarm it belongs to (the one-off isn't listed).
                    if let j = model.state.justOnce(), j.original?.key == a.key {
                        if j.pinned { RowNote(icon: "clock.arrow.circlepath", text: "Just this once: \(dayWord(j.at).lowercased()) at \(j.at.formatted(date: .omitted, time: .shortened)), \(j.alarm.soundText)", color: .secondary) }
                        else if j.orphan, let u = j.usual { RowNote(icon: "exclamationmark.circle.fill", text: "Both will ring: \(u.formatted(date: .omitted, time: .shortened)) and the one-off at \(j.at.formatted(date: .omitted, time: .shortened))") }
                    }
                    MarkNote(mark: a.key)
                }
                .zoomSource(a.key, in: editNS)
            }
            // The end of the card: one row, tapped anywhere, as Channels' Add widgets. Nothing floats over the page, so
            // nothing can cover the Nap chips under it (Richard's Alarms shot, 2026-11-05).
            Button { edit(nil) } label: {
                // With none of his own, the row says so on its second line: one card row, never a lone capsule.
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Add alarm").font(.body.weight(.semibold))
                        if model.stateKnown && mine.isEmpty {
                            Text("None of your own yet").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } icon: { Image(systemName: "plus.circle.fill").font(.body.weight(.semibold)) }
                    .foregroundStyle(ChumbyPalette.acc(scheme == .dark))
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add an alarm")
            .zoomSource("new", in: editNS)
        } header: { SectionHead(icon: "alarm", text: "My alarms", color: ChumbyPalette.acc(scheme == .dark)) } footer: {
            if model.state.pending { SectionFoot("The Chumby is putting your last change in place.") }
        }
    }

    // A nap set or called off is three moves, one after the other, never two sets of rows drawn over each other (the
    // list's own row change crossfaded the chips and the nap's row for about a tenth of a second): what's there fades
    // out, the rows change places while nothing is drawn in them, and what's new fades in. `napRows` is which rows the
    // list holds; until the first change it's as the Chumby said when the tab was first drawn (`napFirst`), so the rows
    // only ever change inside the three moves; its `due` keeps the row's time while the row fades out.
    final class NapFirst { var row: Bool?; var due: Date? }
    @State private var napFirst = NapFirst()
    @State private var napRows: Bool?
    @State private var napFaded = false
    @State private var napSwap: Task<Void, Never>?
    static let napFade = 0.12, napSettle = 0.22
    var napRowShown: Bool {
        if napFirst.row == nil { napFirst.row = model.napDue != nil }
        return napRows ?? napFirst.row ?? false
    }
    var napDueShown: Date? {
        if let d = model.napDue { napFirst.due = d }
        return model.napDue ?? napFirst.due
    }
    func napMoves() {
        guard (model.napDue != nil) != napRowShown || napSwap != nil else { return }
        napSwap?.cancel()
        napSwap = Task { @MainActor in
            withAnimation(.easeOut(duration: Self.napFade)) { napFaded = true }
            try? await Task.sleep(nanoseconds: UInt64(Self.napFade * 1e9))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: Self.napSettle)) { napRows = model.napDue != nil }
            try? await Task.sleep(nanoseconds: UInt64(Self.napSettle * 1e9))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.16)) { napFaded = false }
            napSwap = nil
        }
    }
    // The heading says what a chip does, so "20 min" reads as a nap that rings in 20 minutes, not a setting; with a nap
    // set, the row says the rest.
    var nap: some View {
        Section { NapSection(row: napRowShown, faded: napFaded, due: napDueShown, edit: editNap).id("nap").zoomSource("nap-" + (model.napAlarm?.key ?? "new"), in: editNS) } header: {
            NapHead(set: model.napDue != nil, color: ChumbyPalette.sub(scheme == .dark))
        }
    }
    // The rule first, said plainly, and changed only as a rule; then the alarms it has set, checked against what the
    // Chumby really holds. A row opens that day, which is also changed only as "how long before".
    var ruleRow: some View {
        Button { if wide { show(pane == .settings ? .schedule : .settings) } else { openSettings() } } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 22, weight: .semibold)).foregroundStyle(ChumbyPalette.cal(scheme == .dark))
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wakes you \(leadText(wake.rules.workLead)) before work")
                    Text("\(leadText(wake.rules.otherLead)) before anything else").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens calendar settings")
        .zoomSource("calendar", in: editNS)
        .listRowBackground(wide && pane == .settings ? AnyView(ChumbyPalette.cal(scheme == .dark).opacity(0.18)) : AnyView(GlassRow()))
    }
    var calendar: some View {
        Section {
            if wake.rules.enabled && wake.allowed {
                ruleRow
                if wake.plan.isEmpty { Text("Nothing coming up that needs waking for.").foregroundStyle(.secondary) }
                ForEach(wake.plan) { item in
                    // Only against a recent reading, and never in the build's sample, which has no Chumby behind it.
                    let status = model.stateConfirmed && !CalendarWake.sample ? wake.onDevice(item, in: model.deviceState) : .set
                    AlarmRow(clock: clockParts(item.wake), title: item.shown,
                             detail: "\(item.start.formatted(date: .omitted, time: .shortened)) · \(item.exact ? "set for this day" : leadText(item.lead) + " before")",
                             on: !item.skipped,
                             tile: AnyView(AlarmTile(calendarDay: item.wake, on: !item.skipped)),
                             oneLine: true,
                             tap: { openDay(item.key) },
                             toggle: Binding(get: { !item.skipped }, set: { _ in model.tick(); wake.toggleSkip(item) })) {
                        // What that day does differently, said where the day is.
                        if let j = model.state.justOnce(for: item) {
                            RowNote(icon: "clock.arrow.circlepath", text: "\(j.alarm.soundText) · \(j.at.formatted(date: .omitted, time: .shortened)) (just this once)", color: ChumbyPalette.cal(scheme == .dark))
                        } else if let o = item.own {
                            RowNote(icon: "pencil", text: "\(o.soundText) · \(item.wake.formatted(date: .omitted, time: .shortened)) (just this day)", color: ChumbyPalette.cal(scheme == .dark))
                        } else if item.custom {
                            RowNote(icon: "pencil", text: item.label != nil && !item.exact && wake.rules.leadOverrides[item.key] == nil ? "Label just for this day" : "Just this day", color: ChumbyPalette.cal(scheme == .dark))
                        }
                        if let short = item.shortNight { RowNote(icon: "moon.zzz", text: "Short night: \(short)") }
                        if !item.skipped, let other = wake.alsoRinging(item, in: model.state) { RowNote(icon: "alarm", text: "Also rings earlier: \(other)") }
                        if status == .missing && !wake.running && !wake.queued {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                RowNote(icon: "exclamationmark.circle.fill", text: "Not on the Chumby yet")
                                Text("·").foregroundStyle(.secondary)
                                Button("Retry") { Task { await wake.sync() } }.buttonStyle(.borderless).font(.subheadline.weight(.semibold))
                            }
                        }
                        if status == .stillOn && !wake.running && !wake.queued { RowNote(icon: "exclamationmark.circle.fill", text: "Still on the Chumby; it’ll ring") }
                    }
                    .zoomSource(item.key, in: editNS)
                }
            } else if wake.rules.enabled {
                Text("Chumby can’t see your calendar, so these can’t follow it.").foregroundStyle(.secondary)
            } else {
                // Off: the same switch as Calendar settings' (one setting, one look), with what it does on its second line
                // (designer, 11-11). Turning it on asks for the calendar and starts the plan, as the "Turn on" row did.
                // The switch holds what he asked for while the calendar's permission is asked and the plan starts, rather
                // than springing back off under the alert; a refusal lets it go, and the note under the card says why.
                Toggle(isOn: Binding(get: { wake.rules.enabled || turningOn }, set: { on in
                    guard on, !turningOn else { return }
                    turningOn = true
                    Task { await wake.enable(); withAnimation(.snappy) { turningOn = false } }
                })) {
                    TwoLine("Wake me from my calendar", CalendarWake.what)
                }
            }
            // Left on the Chumby when the plan stopped wanting them (Calendars turned off, an event gone): they still ring.
            ForEach(model.stateConfirmed && !CalendarWake.sample ? wake.strays(in: model.deviceState) : [], id: \.key) { a in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(a.clock).font(.custom("Trebuchet MS", size: 26)).monospacedDigit()
                        Text(a.meridiem).font(.custom("Trebuchet MS", size: 14))
                        Text(a.whenUnlessNamed).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 6)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        RowNote(icon: "exclamationmark.circle.fill", text: "Old calendar alarm: \(alarmLabel(a))")
                        Text("·").foregroundStyle(.secondary)
                        Button(removing == a.key ? "Removing…" : "Remove") {
                            removing = a.key
                            Task { if let why = await model.save(.delete(a)) { model.fail("stray", why) }; removing = nil }
                        }.buttonStyle(.borderless).font(.subheadline.weight(.semibold)).disabled(removing != nil)
                    }
                }
            }
            if let f = model.failed("stray") { FailNote(text: f) }
            if wake.denied { OpenSettingsButton() }
        } header: {
            SectionHead(icon: "calendar", text: "Calendar", color: ChumbyPalette.cal(scheme == .dark))
        } footer: {
            // Only what's wrong or waiting, and what turning it on does. No reassurance (Richard, 2026-11-05: "i dont need
            // this message abt it ringing when my phone isnt on esp not twice").
            if let n = wake.note { SectionFoot(n) }
        }
    }
}
// Every section's heading, in every tab and sheet: a glyph and the words in the quiet sub colour. Colour only where it
// marks an alarm's kind (My alarms in the accent blue, Calendar in coral), so the two kinds can be told apart at a glance.
// The sheets' plain "When" and "Sound" were a third style (designer, 11-11).
struct SectionHead: View {
    let icon: String, text: String
    var color: Color?
    @Environment(\.colorScheme) private var scheme
    init(icon: String, text: String, color: Color? = nil) { self.icon = icon; self.text = text; self.color = color }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.subheadline.weight(.semibold))
            Text(text).font(.custom("Trebuchet MS", size: 16).weight(.bold))
        }
        .foregroundStyle(color ?? ChumbyPalette.sub(scheme == .dark)).textCase(nil)
    }
}
// The tile at the head of an alarm row. A calendar alarm's is a little page of a calendar in coral (its weekday over its
// date); his own is the alarm glyph on blue. Dimmed with the row when it's off.
struct AlarmTile: View {
    let calendarDay: Date?
    let on: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let d = calendarDay {
                let c = ChumbyPalette.cal(scheme == .dark)
                VStack(spacing: 0) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 16).background(c)
                    Text(d.formatted(.dateTime.day())).font(.custom("Trebuchet MS", size: 22).weight(.bold)).monospacedDigit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(c.opacity(0.2))
                }
            } else {
                Image(systemName: "alarm.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(ChumbyPalette.acc(scheme == .dark))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(ChumbyPalette.acc(scheme == .dark).opacity(0.18))
            }
        }
        .frame(width: 44, height: 48)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .opacity(on ? 1 : 0.5)
        .accessibilityHidden(true)
    }
}
extension ChumbyModel {
    // His Pandora stations: the list the Chumby found, and any an alarm already plays.
    var pandoraStations: [NamedID] {
        var out = state.pandora
        for a in state.alarms where a.arg == "pandora" && !a.param.isEmpty {
            let p = a.param.components(separatedBy: "##")
            if !out.contains(where: { $0.id == p[0] }) { out.append(NamedID(id: p[0], name: p.count > 1 ? p[1] : a.param_description)) }
        }
        return out
    }
}
// What an alarm plays, as one tag for a picker ("beep:Chime", "stream:<key>", "pandora:<id>", "none"), and set from one.
// The same rules as the editor's Sound section. "" for something set on the Chumby that the phone can't name.
extension Alarm {
    func soundTag(streams: [Stream]) -> String {
        if type == "none" { return "none" }
        if type == "beep" { return "beep:" + (arg.isEmpty ? "Beep" : arg) }
        if arg == "directurl", let s = streams.first(where: { (!$0.id.isEmpty && param.contains($0.id)) || param.contains($0.url.replacingOccurrences(of: "&", with: "&amp;")) }) { return "stream:" + s.key }
        if arg == "pandora" { return "pandora:" + (param.components(separatedBy: "##").first ?? "") }
        return ""
    }
    mutating func setSound(_ tag: String, streams: [Stream], stations: [NamedID]) {
        let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.first ?? "", value = parts.count > 1 ? parts[1] : ""
        func esc(_ v: String) -> String { v.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
        switch kind {
        case "beep": type = "beep"; arg = value; param = ""; param_description = value
        case "none": type = "none"; arg = ""; param = ""; param_description = "None"; duration = "0"
        case "stream":
            guard let s = streams.first(where: { $0.key == value }) else { return }
            type = "audio"; arg = "directurl"; param_description = s.name.isEmpty ? s.url : s.name
            param = "<stream url=\"\(esc(s.url))\" id=\"\(esc(s.id))\" mimetype=\"\(esc(s.mimetype))\" name=\"\(esc(s.name.isEmpty ? s.url : s.name))\" />"
        case "pandora":
            let name = stations.first { $0.id == value }?.name ?? "Pandora"
            type = "audio"; arg = "pandora"; param = value + "##" + name; param_description = name
        default: return
        }
        // Back from Silent, it plays for the editor's usual half hour rather than not at all.
        if kind != "none" && duration == "0" { duration = "30" }
    }
}
extension String { var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() } }

// MARK: - Sound
// What an alarm plays, as the editor's pickers hold it, and how it's written into an alarm the way the Chumby reads it.
// Shared by the alarm editor, the calendar alarms' settings and "just this once", so all three offer the same choices.
struct SoundChoice: Equatable {
    var kind = "beep", tone = "Beep", streamIndex = 0, pandoraID = ""
    init() {}
    init(_ a: Alarm, state: ChumbyState, stations: [NamedID]) {
        kind = a.type == "beep" ? "beep" : a.type == "none" ? "none" : a.arg == "directurl" ? "stream" : a.arg == "pandora" ? "pandora" : "keep"
        tone = state.tones.contains(a.arg) ? a.arg : (state.tones.first ?? "Beep")
        if kind == "stream", let k = state.streams.firstIndex(where: { (!$0.id.isEmpty && a.param.contains($0.id)) || a.param.contains($0.url.replacingOccurrences(of: "&", with: "&amp;")) }) { streamIndex = k }
        pandoraID = kind == "pandora" ? (a.param.components(separatedBy: "##").first ?? "") : (stations.first?.id ?? "")
    }
    // Writes the sound into `a`, or says why it can't. "keep" leaves the alarm's own sound as it is.
    func apply(to a: inout Alarm, state: ChumbyState, stations: [NamedID]) -> ChumbyError? {
        switch kind {
        case "beep": a.type = "beep"; a.arg = tone; a.param = ""; a.param_description = tone
        case "none": a.type = "none"; a.arg = ""; a.param = ""; a.param_description = "None"
        case "stream":
            guard state.streams.indices.contains(streamIndex) else { return .message("Add a radio stream on the Sounds tab first.") }
            let s = state.streams[streamIndex]
            func esc(_ v: String) -> String { v.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
            a.type = "audio"; a.arg = "directurl"; a.param_description = s.name.isEmpty ? s.url : s.name
            a.param = "<stream url=\"\(esc(s.url))\" id=\"\(esc(s.id))\" mimetype=\"\(esc(s.mimetype))\" name=\"\(esc(s.name.isEmpty ? s.url : s.name))\" />"
        case "pandora":
            guard !pandoraID.isEmpty else { return .message("Pick a Pandora station first.") }
            let name = stations.first { $0.id == pandoraID }?.name ?? "Pandora"
            a.type = "audio"; a.arg = "pandora"; a.param = pandoraID + "##" + name; a.param_description = name
        default: break
        }
        if kind == "none" { a.duration = "0" } else if a.duration == "0" { a.duration = "30" }
        // The control panel never rings a tone marked to end by itself (Alarm.ringAlarm: "cannot autoDismiss Beep-type
        // alarm!", and nothing plays), so a tone is always written as waiting to be stopped. Music keeps what was chosen.
        if kind == "beep" { a.auto_dismiss = "0" }
        return nil
    }
    // Whether the sound is music (a stream or Pandora), the only kind the Chumby can end by itself.
    var isMusic: Bool { kind == "stream" || kind == "pandora" }
}
// The editor's sound rows: what it plays (with a try on the Chumby for a tone), for how long, and the snooze. `alarm`
// holds the length and snooze; `choice` the sound.
// "Plays for" is one control (Richard, 2026-11-10: "Plays for 30 minutes" beside "Stop on its own: off" read as a
// contradiction). What the Chumby's control panel does, read from Alarm.ringAlarm and stepAlarmSoundContinuous: the sound
// plays for `duration` minutes (-1: until stopped) and then goes quiet, and the alarm screen (Snooze, Stop) stays up until
// he stops it; with auto_dismiss, music plays that long and the alarm then ends by itself, with no screen and no
// snooze, and its "after" action is skipped. So the lengths are the choices, "Until I stop it" is -1, and for music
// only, a second group of lengths "ends by itself" sets auto_dismiss. The same fields and values as before for the same
// choices.
struct SoundRows: View {
    @EnvironmentObject var model: ChumbyModel
    @Binding var choice: SoundChoice
    @Binding var alarm: Alarm
    // Laid under the last row, for a sheet that measures where its rows end (a calendar day's).
    var tail: AnyView? = nil
    // Silent has no length row. While the menu closes on a pick to or from Silent, whether it was silent is held, and the
    // row comes or goes once the menu has gone (MenuClose), in one fade: the only pick that adds or removes a row.
    @State private var wasSilent: Bool?
    var kind: String { choice.kind }
    var stations: [NamedID] { model.pandoraStations }
    // One menu for the sound, in sections (Tones, Radio, Pandora, Silent), as the Sounds tab has it: a pick fills this one
    // row, and no row comes or goes under the menu as it closes (Richard, 11-12: "the animation for the sound selection
    // window … is gross": Plays, then Tone or Station, swapped rows 0.35 s after the menu went, printed over each other).
    var tag: Binding<String> {
        Binding(get: {
            switch choice.kind {
            case "beep": return "beep:" + choice.tone
            case "stream": return "stream:\(choice.streamIndex)"
            case "pandora": return "pandora:" + choice.pandoraID
            case "none": return "none"
            default: return "keep"
            }
        }, set: { t in
            var c = choice
            if t.hasPrefix("beep:") { c.kind = "beep"; c.tone = String(t.dropFirst(5)) }
            else if t.hasPrefix("stream:") { c.kind = "stream"; c.streamIndex = Int(t.dropFirst(7)) ?? 0 }
            else if t.hasPrefix("pandora:") { c.kind = "pandora"; c.pandoraID = String(t.dropFirst(8)) }
            else if t == "none" { c.kind = "none" }
            else { return }
            guard c != choice else { return }
            let silent = choice.kind == "none"
            choice = c
            if silent != (c.kind == "none") {
                wasSilent = silent
                MenuClose.then { wasSilent = nil }
            }
        })
    }
    var body: some View {
        HStack(spacing: 10) {
            Picker("Plays", selection: tag) {
                Section("Tones") { ForEach(model.state.tones, id: \.self) { Text($0).tag("beep:" + $0) } }
                if !model.state.streams.isEmpty {
                    Section("Radio") { ForEach(model.state.streams.indices, id: \.self) { i in Text(model.state.streams[i].name.isEmpty ? model.state.streams[i].url : model.state.streams[i].name).tag("stream:\(i)") } }
                }
                if !stations.isEmpty { Section("Pandora") { ForEach(stations) { Text($0.name).tag("pandora:" + $0.id) } } }
                Text("Silent").tag("none")
                if kind == "keep" { Text(alarm.soundText).tag("keep") }
            }
            // A tone is tried on the Chumby from its own row, so trying one never adds or removes a row. Its place is kept
            // for every sound, so the menu's value (the menu's anchor) never moves as it closes.
            Button {
                Task { do { try await model.api?.post("test", extra: "&tone=" + ChumbyAPI.enc(choice.tone)) } catch { model.fail("test", "Couldn’t play it. \(AlarmWriter.explain(error))") } }
            } label: { Image(systemName: "play.circle.fill").font(.title2).symbolRenderingMode(.hierarchical) }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .accessibilityLabel("Play on the Chumby")
            .opacity(kind == "beep" ? 1 : 0)
            .disabled(kind != "beep")
        }
        // Where the row is, for the build's films (their taps open its menu by this when words can't be read).
        .pageLog("soundrow")
        if let f = model.failed("test") { FailNote(text: f) }
        if kind == "stream" && model.state.streams.isEmpty { Text("Add a radio stream on the Sounds tab first.").foregroundStyle(.secondary) }
        if kind == "pandora" && stations.isEmpty { Text("No Pandora stations on the Chumby yet.").foregroundStyle(.secondary) }
        if !(wasSilent ?? (kind == "none")) {
            let music = choice.isMusic || kind == "keep"
            Picker("Plays for", selection: playsFor) {
                ForEach(SoundRows.lengths(including: alarm.duration), id: \.0) { Text($0.1).tag($0.0) }
                Text("Until I stop it").tag("-1")
                // Only music can end by itself; the Chumby never rings a tone marked that way.
                if music {
                    Section {
                        ForEach(SoundRows.lengths(including: alarm.duration).filter { $0.0 != "1" }, id: \.0) { Text("\($0.1), ends by itself").tag("auto:" + $0.0) }
                    }
                }
            }
        }
        Picker("Snooze", selection: $alarm.snooze) {
            ForEach(SoundRows.snoozes(including: alarm.snooze), id: \.self) { Text("\($0) min").tag($0) }
        }
        .background { tail }
    }
    // The one choice over the alarm's length and whether it ends by itself: "30" plays 30 minutes and waits to be
    // stopped; "auto:30" plays 30 minutes and ends; "-1" plays until stopped.
    var playsFor: Binding<String> {
        Binding(get: {
            let d = alarm.duration
            return alarm.auto_dismiss == "1" && d != "-1" && (choice.isMusic || kind == "keep") ? "auto:" + d : d
        }, set: { v in
            if v.hasPrefix("auto:") { alarm.duration = String(v.dropFirst(5)); alarm.auto_dismiss = "1" }
            else { alarm.duration = v; alarm.auto_dismiss = "0" }
        })
    }
    // The usual lengths, and the alarm's own if it's another (set on the Chumby), so the picker never shows nothing.
    static func lengths(including d: String) -> [(String, String)] {
        let usual = [("1", "1 minute"), ("5", "5 minutes"), ("10", "10 minutes"), ("15", "15 minutes"), ("30", "30 minutes"), ("60", "1 hour"), ("120", "2 hours")]
        guard let m = Int(d), m > 0, !usual.contains(where: { $0.0 == d }) else { return usual }
        return (usual + [(d, m % 60 == 0 ? "\(m / 60) hours" : "\(m) minutes")]).sorted { (Int($0.0) ?? 0) < (Int($1.0) ?? 0) }
    }
    static func snoozes(including s: String) -> [String] {
        let usual = ["1", "3", "5", "9", "10", "15", "20", "30", "60"]
        return usual.contains(s) || Int(s) == nil ? usual : (usual + [s]).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }
}

// MARK: - The alarm editor
// An editor's unsaved draft, kept for the moment a turn moves the editor between the right pane and its cover (Richard's
// 11-08 rule, as the lead ruled 11-11: he never loses what he typed). Taken only within a few seconds of being left.
// Written on every change, outside the view, and cleared only by Save, Cancel or the editor finishing: the twin that
// appears after a turn reads it whatever order the two views come and go in (gate B: written on disappear, it arrived
// a turn late and the label he'd typed was lost on the way back).
struct EditorDraft: Equatable { var alarm: Alarm; var time: Date; var date: Date; var repeatMode: String; var day: Int; var sound: SoundChoice; var after: String }
@MainActor enum EditorDrafts {
    static var byKey: [String: EditorDraft] = [:]
}
struct AlarmEditor: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    // The alarm as it was when opened, or nil for a new one. Saved by what it is, never by its place in the list.
    var original: Alarm?
    // The settings every calendar alarm shares: how it sounds and what it does, never when it rings or what it's called,
    // which the calendar decides.
    var calendarTemplate = false
    // The nap: a one-off named "Nap", so the Chumby treats it as its nap (never counted by newest_wins, never pinned). Its
    // name stays "Nap" for that reason, so there's no label; it has no repeat; its time is also set as a length from now.
    var nap = false
    // Set when it's shown in the open Duo's right pane rather than as a sheet: how to go back.
    var close: (() -> Void)?
    init(original: Alarm? = nil, calendarTemplate: Bool = false, nap: Bool = false, close: (() -> Void)? = nil) { self.original = original; self.calendarTemplate = calendarTemplate; self.nap = nap; self.close = close }
    var title: String { nap ? "Nap" : calendarTemplate ? "How they ring" : original != nil ? "Edit alarm" : "Add alarm" }
    @AppStorage("napLength") private var napLength = 0
    static let napLengths = [10, 20, 30, 45, 60, 90]
    @State private var alarm = Alarm()
    @State private var time = Date()
    @State private var date = Date()
    @State private var repeatMode = "daily"
    @State private var repeatClosing: String?     // Repeat's old value while its menu closes (MenuClose)
    @State private var day = 1
    @State private var sound = SoundChoice()
    @State private var after = ""
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var problem: String?
    @State private var loaded = false
    @State private var justOnce = false
    @State private var ended = false
    @State private var drafting = false

    var stations: [NamedID] { model.pandoraStations }
    var afterOptions: [(String, String)] {
        var o = [("", "Return to what was on screen"), ("nightmode|on", "Night mode on"), ("nightmode|off", "Night mode off"), ("bright|bright", "Screen bright"), ("bright|dim", "Screen dim"), ("bright|off", "Screen off")]
        for c in model.state.channels { o.append(("profile|" + c.id, "Switch channel to “\(c.name)”")) }
        let cur = alarm.action.isEmpty ? "" : alarm.action + "|" + alarm.action_param
        if !cur.isEmpty && !o.contains(where: { $0.0 == cur }) { o.append((cur, alarm.action == "profile" ? "Switch channel (set on the Chumby)" : cur)) }
        return o
    }
    // A one-off goes to the next time it can still ring, as the Clock app does, so a time already past means tomorrow.
    var onceAt: Date {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        var when = Calendar.current.date(bySettingHour: c.hour ?? 7, minute: c.minute ?? 0, second: 0, of: date) ?? date
        while when <= Date() { when = Calendar.current.date(byAdding: .day, value: 1, to: when) ?? when.addingTimeInterval(86400) }
        return when
    }
    // What Save would send, or why it can't.
    var draft: Result<Alarm, ChumbyError> {
        var a = alarm
        if nap {
            a.name = "Nap"; a.when = "once"; a.enabled = "1"
            a.time = String(Int((onceAt.timeIntervalSince1970 / 60).rounded()))
        } else if !calendarTemplate {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            if repeatMode == "once" { a.when = "once"; a.time = String(Int((onceAt.timeIntervalSince1970 / 60).rounded())) }
            else { a.when = repeatMode == "day" ? Alarm.dayKeys[day] : repeatMode; a.time = String((c.hour ?? 7) * 60 + (c.minute ?? 0)) }
            a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            a.enabled = "1"
        }
        if let why = sound.apply(to: &a, state: model.state, stations: stations) { return .failure(why) }
        let parts = after.components(separatedBy: "|")
        a.action = parts.first ?? ""; a.action_param = parts.count > 1 ? parts[1] : ""
        return .success(a)
    }
    var change: AlarmChange? {
        guard !calendarTemplate, case .success(let a) = draft else { return nil }
        if nap { return .setNap(a) }
        return original.map { .replace($0, a) } ?? .add(a)
    }
    // Rick's rule, worked out before Save: a new alarm, or one whose time or label changes, switches the others off.
    var switchesOff: [String] { switchedOffAlarms.map { alarmLabel($0) } }
    private var switchedOffAlarms: [Alarm] {
        guard loaded, let change else { return [] }
        var sending = model.deviceState
        change.apply(&sending)
        return ChumbyState.switchedOff(saved: model.deviceState.alarms, sending: sending.alarms).map { sending.alarms[$0] }
    }
    static func list(_ names: [String]) -> String {
        names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    var body: some View {
        if let close {
            // In the right pane: its own list, its title row with Cancel and Save, then the same sections, clear of the
            // fold. The title row stays pinned once the page is scrolled, so Save is always in reach.
            let buttons = HStack(spacing: 16) {
                Button("Cancel") { ended = true; EditorDrafts.byKey[placeKey] = nil; stopTest(); close() }.disabled(saving)
                if saving { ProgressView() } else { Button("Save") { save() }.fontWeight(.semibold) }
            }
            .foregroundStyle(.tint)
            List {
                PageTitle(title, pins: true) { buttons }
                sections.listRowBackground(GlassRow())
            }
            .pinsTitle { PageTitle(title) { buttons } }
            .keepsPlace(placeKey)
            .staysAtTop()
            // On the list, never on a row: a lazy row scrolled off would end the edit (held readings landing) or present
            // nothing. (Build 204's "presents from none" was a sheet bound from many rows of the pane's shared list.)
            .onAppear { if !loaded { begin(); loaded = true }; model.editingAlarm = true; posedJustOnce() }
            .onDisappear { model.editingAlarm = false }
            .onChange(of: typed) { _, _ in keepDraft() }
            .fillCover(isPresented: $justOnce) { justOnceSheet }
        } else {
            // Presented edge to edge (fillCover, from Alarms and the calendar's sound row), with Cancel and Save as the
            // system's items, each with a glyph, so on the Duo they take the side bar, Cancel at the top where Back goes
            // and Save under it, and the form has the whole width (Richard, 2026-11-10: "not edge to edge … utilize
            // sidebar"). As words alone iOS kept them in a row across the top: it sets no title-only item vertically.
            NavigationStack {
                Form { sections.listRowBackground(GlassRow()) }
                .keepsPlace(placeKey)
                .seaList().background { SeaBackground().ignoresSafeArea() }
                // The system's own title (its face set once in ChumbyApp.dressBars), never a text item in the bar (ruling 11-09).
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { ended = true; EditorDrafts.byKey[placeKey] = nil; stopTest(); dismiss() } label: { Label("Cancel", systemImage: "xmark") }.disabled(saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else { Button { save() } label: { Label("Save", systemImage: "checkmark") }.fontWeight(.semibold) }
                    }
                }
                .interactiveDismissDisabled(saving)
                .onAppear { if !loaded { begin(); loaded = true }; model.editingAlarm = true; posedJustOnce() }
                .onDisappear { model.editingAlarm = false }
                .onChange(of: typed) { _, _ in keepDraft() }
                .fillCover(isPresented: $justOnce) { justOnceSheet }
            }
        }
    }
    // "Just this once" for this alarm's next ring, presented by the editor itself (the row that opens it sits far down a
    // lazy form, so a sheet of the row's own isn't there until it's been scrolled to).
    @ViewBuilder var justOnceSheet: some View {
        if let original, case .ok(_, let due, _) = model.justOnceOffer(for: original) { JustOnceSheet(original: original, due: due).environmentObject(model) }
    }
    // For the shot: the sheet, and in it Set with the Chumby's one skip already on another alarm.
    // For the build's turn film (-pose editordraft): an unsaved label typed once, 3 s in, which must survive the turn.
    static var drafted = false
    func posedJustOnce() {
        if ChumbyModel.pose == "editordraft", !Self.drafted, original != nil {
            Self.drafted = true
            Task { try? await Task.sleep(nanoseconds: 3_000_000_000); alarm.name = "Kept through the turn" }
        }
        guard ChumbyModel.pose == "reskip", original != nil else { return }
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); justOnce = true }
    }
    func finish() { ended = true; EditorDrafts.byKey[placeKey] = nil;  stopTest(); if let close { close() } else { dismiss() } }
    // The same editor in the pane and in its cover: what's typed, and where it's scrolled, carry across a turn.
    var placeKey: String { "page:editor:" + (calendarTemplate ? "template" : original?.key ?? (nap ? "nap" : "new")) }
    // Opened: a draft left by its twin a moment ago (the turn that moved it between pane and cover), or the alarm as it is.
    func begin() {
        // Its twin's draft only while a turn is moving it between pane and cover; opened afresh, the alarm as it is.
        if PagePlace.turning, let d = EditorDrafts.byKey[placeKey] {
            alarm = d.alarm; time = d.time; date = d.date; repeatMode = d.repeatMode; day = d.day; sound = d.sound; after = d.after
            SwipeLog.note("draft taken \(placeKey)")
        } else { EditorDrafts.byKey[placeKey] = nil; load() }
        drafting = true
    }
    var typed: EditorDraft { EditorDraft(alarm: alarm, time: time, date: date, repeatMode: repeatMode, day: day, sound: sound, after: after) }
    func keepDraft() {
        guard drafting, !ended else { return }
        EditorDrafts.byKey[placeKey] = typed
    }

    var sections: some View {
            Group {
                // Above everything, beside Save: why it couldn't save, or what saving will do that isn't obvious.
                if saving || problem != nil || !switchesOff.isEmpty || (original.map { !$0.isOn } ?? false) && !calendarTemplate {
                    Section {
                        if saving { HStack(spacing: 10) { ProgressView(); Text("Reaching the Chumby…").foregroundStyle(.secondary) } }
                        if let problem { FailNote(text: problem) }
                        let off = switchesOff
                        if !off.isEmpty { RowNote(icon: "alarm", text: "Saving turns off \(Self.list(off)).") }
                        if !calendarTemplate && !nap, let o = original, !o.isOn { RowNote(icon: "alarm.fill", text: "Saving turns this alarm on.", color: .secondary) }
                    }
                }
                if nap {
                    // When it rings, as a time or as a length from now; the two always agree.
                    Section {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                        HStack(spacing: 8) {
                            ForEach(Self.napLengths, id: \.self) { m in
                                Button { withAnimation(.snappy) { setNapLength(m) } } label: {
                                    Text("\(m)").lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 34)
                                }
                                .buttonStyle(.bordered).tint(napMinutes == m ? ChumbyPalette.acc(scheme == .dark) : nil)
                                .accessibilityLabel("In \(m) minutes")
                            }
                        }
                        .listRowSeparator(.hidden)
                        Text(napIn).font(.subheadline).foregroundStyle(.secondary).contentTransition(.numericText())
                    } header: { SectionHead(icon: "timer", text: "Wake me in") } footer: { if nap && original == nil { SectionFoot("Rings once, as your other alarms do, and never turns them off.") } }
                }
                if !calendarTemplate && !nap {
                Section { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity).placeMark("ed-time") }
                Section {
                    Picker("Repeat", selection: $repeatMode.afterMenu($repeatClosing)) {
                        Text("Once").tag("once"); Text("Daily").tag("daily"); Text("Weekdays").tag("weekday"); Text("Weekends").tag("weekend"); Text("One day").tag("day")
                    }
                    .placeMark("ed-repeat")
                    // The Day and Date rows come and go once Repeat's menu has closed, not under it.
                    let repeatShown = repeatClosing ?? repeatMode
                    if repeatShown == "day" {
                        Picker("Day", selection: $day) { ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) } }
                    }
                    if repeatShown == "once" {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                        Text("Rings \(onceAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))").font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Label")
                        TextField("Optional", text: $alarm.name).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    }
                }
                }
                Section { SoundRows(choice: $sound, alarm: $alarm) } header: { SectionHead(icon: "music.note", text: "Sound") }
                Section {
                    // No Backup beep switch: the Chumby saves every alarm with backup 0 whatever it's sent (do_save, since
                    // 11-05: the stock beeper killed the alarm panel), so turning it on here came back off after Save.
                    // What it's for, said in the row: alone, "Then" was a one-row capsule (designer, 11-11).
                    // The value stays at the right whatever the width (the system's row stacked it under a long label).
                    MenuRow(title: "Then", note: "What the screen does once it stops ringing.", selection: $after) {
                        ForEach(afterOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .placeMark("ed-after")
                } header: { SectionHead(icon: "arrow.turn.down.right", text: "Afterwards") }
                // One of his repeating alarms: later or another sound for its next ring only (the Chumby's skip is pinned by name,
                // so it needn't be the next alarm to ring).
                if let original, !calendarTemplate, original.when != "once", original.isOn,
                   let j = model.state.justOnce(), j.original?.key == original.key, j.pinned, let u = j.usual {
                    Section {
                        RowNote(icon: "clock.arrow.circlepath", text: "Rings \(dayWord(j.at).lowercased()) at \(j.at.formatted(date: .omitted, time: .shortened)) with \(j.alarm.soundText), then as usual.", color: .secondary)
                        Button("Back to \(u.formatted(date: .omitted, time: .shortened))") {
                            saving = true; problem = nil
                            Task { let why = await model.undoJustOnce(); saving = false; if let why { problem = why } else { finish() } }
                        }.foregroundStyle(.tint).disabled(saving)
                    } header: { SectionHead(icon: "clock.arrow.circlepath", text: "Just this once") }
                } else if let original, !calendarTemplate, original.when != "once", original.isOn {
                    switch model.justOnceOffer(for: original) {
                    case .hidden: EmptyView()
                    case .note(let why): Section { Text(why).font(.subheadline).foregroundStyle(.secondary) } header: { SectionHead(icon: "clock.arrow.circlepath", text: "Just this once") }
                    case .ok(_, let due, let warning):
                        Section {
                            Button { justOnce = true } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Later or another sound, just this once").foregroundStyle(.tint)
                                    Text("\(dayWord(due)) at \(due.formatted(date: .omitted, time: .shortened)) only. It repeats as usual after.").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            if let warning { RowNote(icon: "exclamationmark.circle.fill", text: warning) }
                        } header: { SectionHead(icon: "clock.arrow.circlepath", text: "Just this once") }
                    }
                }
                // A "just this once" goes back to the usual time rather than just going: deleting it alone would leave the
                // usual one skipped, and neither would ring.
                if let original, !calendarTemplate, JustOnce.isOne(original), let j = model.state.justOnce(), j.alarm.key == original.key, j.canUndo { Section {
                    Button("Back to the usual time") {
                        saving = true; problem = nil
                        Task { let why = await model.undoJustOnce(); saving = false; if let why { problem = why } else { finish() } }
                    }.foregroundStyle(.tint).disabled(saving)
                    // The section's only row (the pinned case with its note is the section above), so a solo card.
                    .soloCard(note: "The usual alarm rings again and this one goes.")
                } }
                else if nap, original != nil { Section {
                    // Calling the nap off, from its editor too; it goes without asking, since it was one tap to set.
                    Button("Cancel nap", role: .destructive) { run(.cancelNap) }.foregroundStyle(.red).disabled(saving)
                } }
                else if let original, !calendarTemplate { Section {
                    // The question hangs off the button that asked it, so it points at what was tapped.
                    Button("Delete alarm", role: .destructive) { confirmDelete = true }.foregroundStyle(.red).disabled(saving)
                        .confirmationDialog("Delete this alarm?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete alarm", role: .destructive) { run(.delete(original)) }
                        }
                } }
            }
    }
    func stopTest() { Task { try? await model.api?.post("test", extra: "&stop=1") } }
    // The nap's length from now, in whole minutes (rounded up: the Chumby rings on the minute), and the time to match it.
    var napMinutes: Int { max(Int((onceAt.timeIntervalSinceNow / 60).rounded(.up)), 1) }
    var napIn: String {
        let m = napMinutes
        return m >= 60 ? "In \(m / 60) h\(m % 60 > 0 ? " \(m % 60) min" : "")" : "In \(m) min"
    }
    func setNapLength(_ m: Int) {
        napLength = m
        time = Date().addingTimeInterval(Double(m) * 60)
        date = time
    }

    func load() {
        if nap {
            if let original { alarm = original } else {
                // A new nap: the last length chosen, a short ring, the Chumby's first tone (as the chips make one).
                alarm = Alarm(); alarm.name = "Nap"; alarm.when = "once"; alarm.duration = "5"
                let tone = model.state.tones.first ?? "Beep"
                alarm.type = "beep"; alarm.arg = tone; alarm.param_description = tone
                alarm.time = String(Int((Date().timeIntervalSince1970 / 60).rounded(.up)) + (NapSection.lengths.contains(napLength) ? napLength : 20))
            }
            time = Date(timeIntervalSince1970: (Double(alarm.time) ?? 0) * 60); date = time
            repeatMode = "once"
            sound = SoundChoice(alarm, state: model.state, stations: stations)
            after = alarm.action.isEmpty ? "" : alarm.action + "|" + alarm.action_param
            return
        }
        if calendarTemplate {
            // The saved set if there is one, else how the first calendar alarm rings now.
            if let t = model.state.calTpl ?? CalendarWake.shared.storedSettings ?? model.state.alarms.first(where: { $0.isCalendar && !$0.isOwn }) { alarm = t }
        } else if let original { alarm = original }
        // The build's shot of a new alarm being set for a new time, so "Saving turns off …" can be seen.
        if original == nil && !calendarTemplate && ChumbyModel.pose == "editornew" { alarm.time = "330"; alarm.when = "weekday" }
        let m = alarm.localMinutes
        time = Calendar.current.date(bySettingHour: m / 60 % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
        if let d = Alarm.dayKeys.firstIndex(of: alarm.when) { day = d; repeatMode = "day" } else { repeatMode = alarm.when }
        if alarm.when == "once" { date = Date(timeIntervalSince1970: (Double(alarm.time) ?? 0) * 60) }
        sound = SoundChoice(alarm, state: model.state, stations: stations)
        after = alarm.action.isEmpty ? "" : alarm.action + "|" + alarm.action_param
    }

    // The sheet stays until the Chumby has it; if it can't, it says why here and keeps everything as it was typed.
    func save() {
        switch draft {
        case .failure(let e): problem = e.errorDescription
        case .success(let a):
            if calendarTemplate {
                saving = true; problem = nil
                Task {
                    let why = await model.saveCalendarTemplate(a)
                    saving = false
                    if let why { problem = why } else { finish() }
                }
            } else if let change { run(change) }
        }
    }
    func run(_ c: AlarmChange) {
        saving = true; problem = nil
        // What the note above Save said this turns off: shown before Save, so saving is the user's own say-so for those.
        var shownOff = Set(switchedOffAlarms.map(\.key))
        if case .delete = c { shownOff = [] }
        Task {
            let why = await model.save(c, alsoOff: shownOff)
            saving = false
            if let why { problem = why } else { finish() }
        }
    }
}

// The iOS zoom between a row and what it opens: the row is the source, the sheet or page grows out of it.
extension View {
    @ViewBuilder func zoomSource(_ id: String, in ns: Namespace.ID) -> some View {
        #if os(iOS)
        matchedTransitionSource(id: id, in: ns)
        #else
        self
        #endif
    }
    @ViewBuilder func zoomed(from id: String, in ns: Namespace.ID) -> some View {
        #if os(iOS)
        navigationTransition(.zoom(sourceID: id, in: ns))
        #else
        self
        #endif
    }
}
