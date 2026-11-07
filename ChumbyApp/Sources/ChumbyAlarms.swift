import SwiftUI
import CoreImage
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Small pieces every tab uses
// A failure, at the control it belongs to.
struct FailNote: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(.medium)).foregroundStyle(ChumbyPalette.warn(scheme == .dark))
        .accessibilityElement(children: .combine)
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
                Text([name(s.ring), "can’t reach the Chumby"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.custom("Trebuchet MS", size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
// Four lengths. The one running becomes its own countdown, filled with the accent and draining like water, with × to
// call it off. A nap set elsewhere shows in the chip that holds it, so there's never a row to come and go under the chips.
struct NapChips: View {
    @EnvironmentObject var model: ChumbyModel
    @AppStorage("napLength") private var napLength = 0
    @State private var sending: Int?
    static let lengths = [10, 20, 30, 60]
    // The chip tapped, while the time left still fits it; otherwise the shortest one the time left fits in.
    func chip(for due: Date) -> Int {
        let left = due.timeIntervalSinceNow / 60
        if Self.lengths.contains(napLength), left <= Double(napLength) + 1 { return napLength }
        return Self.lengths.first { Double($0) >= left } ?? 60
    }
    var body: some View {
        let due = model.napDue
        let running = due.map(chip(for:))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(Self.lengths, id: \.self) { m in
                    if let due, m == running { countdown(due, total: m) } else {
                        Button {
                            napLength = m; sending = m
                            Task { await model.nap(m); sending = nil }
                        } label: {
                            // While a nap runs its chip says "min", so the others say just the number and all four stay equal.
                            Group { if sending == m { ProgressView() } else { Text(running == nil ? "\(m) min" : "\(m)").lineLimit(1).minimumScaleFactor(0.8) } }.frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.bordered).disabled(sending != nil)
                        .accessibilityLabel("\(m) minute nap")
                    }
                }
            }
            if let f = model.failed("nap") { FailNote(text: f) }
        }
        // The chip turning into its countdown and back, never a swap in one frame.
        .animation(.snappy, value: due)
    }
    func countdown(_ due: Date, total: Int) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(due.timeIntervalSince(ctx.date), 0)
            let k = min(left / Double(total * 60), 1)
            // Whole minutes left, rounded up, so it never reads as a time of day beside the clock. Never more than the nap
            // chosen: the Chumby rings on a whole minute, so a 10-minute nap can be up to 10:59 away, and must still say 10.
            let minutes = min(max(Int((left / 60).rounded(.up)), 1), total)
            HStack(spacing: 3) {
                // "left" is what the falling tide already says; with it the chip clipped to "11 min l…" beside the ×.
                Text("\(minutes) min").monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText(countsDown: true)).animation(.snappy, value: minutes)
                Button { Task { await model.cancelNap() } } label: { Image(systemName: "xmark").font(.caption2.weight(.heavy)) }
                    .buttonStyle(.borderless).foregroundStyle(.white).accessibilityLabel("Cancel nap")
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            // The same breathing room inside as the chips beside it.
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            // The accent, with the time left as a lighter tide that falls as the nap runs down.
            .background {
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.tint)
                    GeometryReader { g in
                        Rectangle().fill(.white.opacity(0.22))
                            .frame(height: g.size.height * k).frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .clipShape(Capsule())
            }
            .accessibilityLabel("Nap, \(minutes) minutes left")
        }
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
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(list, id: \.song.id) { w in tile(w.song).transition(.opacity.combined(with: .scale(scale: 0.92))) }
                    }
                    .padding(.vertical, 4)
                    .animation(.snappy, value: list.map(\.song.id))
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            } header: { SectionHead(icon: "sunrise.fill", text: "Woke up to", color: ChumbyPalette.sub(scheme == .dark)) }
        }
    }
    func tile(_ s: Song) -> some View {
        let f = art.found[SongArt.key(s)]
        return Button {
            var c = URLComponents(string: "https://music.apple.com/search")!
            c.queryItems = [.init(name: "term", value: s.artist + " " + s.title)]
            if let u = f?.link ?? c.url { openURL(u) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    if let i = f?.image { Image(platform: i).resizable().scaledToFill().transition(.opacity) }
                    else if f != nil {
                        // Looked for and none found: the octopus on the Chumby's own blue, never a grey box.
                        ZStack {
                            ChumbyPalette.hex(0x2c5bae)
                            OctopusMark(color: .white.opacity(0.9), eyes: ChumbyPalette.hex(0x2c5bae)).padding(26)
                        }
                        .transition(.opacity)
                    } else {
                        // Still on its way (rare, as covers are fetched at launch and kept): a plain tile, no stand-in art.
                        GlassRow().transition(.opacity)
                    }
                }
                .frame(width: 112, height: 112).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(s.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Text(Date(timeIntervalSince1970: s.t).formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(width: 112, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onAppear { art.look(s) }
        .accessibilityLabel("\(s.title) by \(s.artist). Opens in Apple Music.")
    }
}

// MARK: - Alarms
// Everything left of a view's trailing edge, reaching far past its other three.
struct TrailingEdge: Shape {
    func path(in r: CGRect) -> Path { Path(CGRect(x: r.minX - 4000, y: r.minY - 4000, width: r.width + 4000, height: r.height + 8000)) }
}

struct AlarmsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @ObservedObject private var wake = CalendarWake.shared
    @Environment(\.paneLayout) private var wide
    @Environment(\.colorScheme) private var scheme
    @State private var editing: EditTarget?
    @State private var day: DayTarget?
    // Open, the right pane holds whatever would otherwise be a sheet, so nothing sits across the fold.
    enum Pane: Equatable { case schedule, settings, editor(Alarm?), day(String), template }
    @State private var pane: Pane = .schedule
    @State private var paneBack: Pane = .schedule
    @State private var removing: String?
    @State private var posed = false
    @AppStorage("missedDismissed") private var dismissedRaw = ""
    struct EditTarget: Identifiable { let alarm: Alarm?; var id: String { alarm?.key ?? "new" } }
    // Each editor grows out of the row that opened it and shrinks back into it, the iOS zoom, rather than a sheet rising
    // from the foot with no tie to what was tapped (Richard, 2026-11-07: "the animation to edit like the calendar alarm
    // sucks").
    @Namespace private var editNS
    struct DayTarget: Identifiable { let id: String }

    var dismissed: Set<String> { Set(dismissedRaw.split(separator: "\n").map(String.init)) }
    var missed: [ChumbyState.Missed] { model.state.missed.filter { Date().timeIntervalSince1970 - $0.at < 86400 && !dismissed.contains($0.id) }.suffix(3).reversed().map { $0 } }
    var mine: [Alarm] { model.state.alarms.filter { !$0.isPlaceholder && $0.name != "Catch-up" && !$0.isCalendar && $0.name != "Nap" }.sorted { $0.localMinutes < $1.localMinutes } }
    var paneShown: Pane { wide ? pane : .schedule }
    // Pages that bring their own title row (editor, day) have none from here.
    var rightTitle: String? {
        switch paneShown {
        case .schedule: return " "
        case .settings: return "Calendar settings"
        default: return nil
        }
    }
    func show(_ p: Pane) { withAnimation(.snappy) { pane = p } }
    func edit(_ a: Alarm?) { if wide { show(.editor(a)) } else { editing = EditTarget(alarm: a) } }
    // With the side column, a day is a page in the content column like Calendar settings, so no sheet's corner sits under
    // the rail's clock. With the bars across it's a sheet the height of what's in it.
    func openDay(_ k: String) {
        if wide { show(.day(k)) } else if rail {
            dayPage = k
            model.alarmsPageTitle = wake.plan.first { $0.key == k }.map { $0.wake.formatted(.dateTime.weekday(.wide)) } ?? "That day"
            model.alarmsPage = true
        } else { day = DayTarget(id: k) }
    }
    func openSettings() { if wide { show(.settings) } else { dayPage = nil; model.alarmsPageTitle = "Calendar settings"; model.alarmsPage = true } }
    @State private var dayPage: String?

    // For the build's film: a row to bring on screen, so the nap's chip and countdown are filmed, not run below the fold.
    @State private var scrollTo: String?
    // With the Duo's side column, Calendar settings (or a calendar day) is a page swapped in inside this tab, never a push: a push
    // carried the rail off with the page. The list fades under it, kept as it was, so coming back finds it where it was left.
    var rail: Bool { model.railWidth >= 44 }
    var body: some View {
        let swapped = rail && model.alarmsPage
        ZStack {
            // Never clipped or masked, so it stays drawn whole while it fades.
            ScrollViewReader { proxy in
                page.onChange(of: scrollTo) { _, id in if let id { withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) } } }
            }
            // Gone in the slide's first third going out, so the incoming page's rows never pass over its words; coming home
            // it starts back once the leaving page is a little way off, and is nearly whole as that page clears.
            .opacity(swapped ? 0 : 1)
            .animation(swapped ? .easeOut(duration: Self.slide / 3) : .easeOut(duration: Self.slide * 0.6).delay(Self.slide * 0.15), value: swapped)
            .allowsHitTesting(!swapped).accessibilityHidden(swapped)
            // Only the incoming page is cut, at the rail's edge, by a frame that stays put while the page moves inside it,
            // so the pages still run under the top and bottom bars. It brings no sea of its own: the tab's stays as it is.
            ZStack {
                if swapped {
                    Group {
                        if let k = dayPage {
                            List { CalendarDaySheet(key: k, close: { model.alarmsPage = false }, done: false).listRowBackground(GlassRow()) }
                                .seaList()
                        } else {
                            CalendarWakeSettings(ownSea: false)
                        }
                    }
                        // A swipe in from the left edge goes back, as it would from a pushed page.
                        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { g in
                            if g.startLocation.x < 40 && g.translation.width > 80 && abs(g.translation.height) < g.translation.width { model.alarmsPage = false }
                        })
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(TrailingEdge())
            .animation(.snappy(duration: Self.slide), value: swapped)
        }
    }
    static let slide = 0.35
    // Folded, top to bottom as he uses it: what rings next (with Skip), then the calendar's alarms, then his own, then a
    // nap. Open, the calendar's sit under the hero on the left and his own and the nap on the right, so both panes carry
    // weight. The two kinds never look alike: the calendar's have a coral page-of-a-calendar tile and say which event and
    // how long before it; his own have a blue alarm tile and say when they repeat (Richard, 2026-11-05: "theres little to
    // no distinction between daily alarms and calendar alarms its just super unintuitive"). Night times moved to Tinker,
    // and "Woke up to" to Sounds.
    var page: some View {
        TwoPane(rightTitle: rightTitle, rightTrailing: paneShown == .settings ? AnyView(Button("Done") { show(.schedule) }.fontWeight(.semibold).foregroundStyle(.tint)) : nil) {
            // Add alarm is never a loose circle: by the rail it's RootView's foot bar; with the tabs across the foot, the same bar
            // sits centred just above them (below).
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
                } footer: { Text("The Chumby was frozen or off when these came due.") }
            }
            calendar
        } right: {
            switch paneShown {
            case .schedule:
                yours
                Section { NapChips().id("nap") } header: { SectionHead(icon: "zzz", text: "Nap", color: ChumbyPalette.sub(scheme == .dark)) }
            case .settings: CalendarSettingsSections()
            case .editor(let a): AlarmEditor(original: a, close: { show(.schedule) }).id(a?.key ?? "new")
            case .day(let k): CalendarDaySheet(key: k, close: { show(.schedule) }).id(k)
            case .template: AlarmEditor(calendarTemplate: true, close: { show(paneBack) })
            }
        }
        .seaList()
        // A nap set or called off moves anything it touches (the next alarm, the chip) in one spring, never in one frame.
        .animation(.snappy, value: model.napDue)
        .environment(\.openTemplate, wide ? { paneBack = pane; show(.template) } : nil)
        // Pushed only with the bars across, where the system's own Back is used.
        .navigationDestination(isPresented: Binding(get: { model.alarmsPage && !rail }, set: { model.alarmsPage = $0 })) { CalendarWakeSettings().zoomed(from: "calendar", in: editNS) }
        .sheet(item: $editing) { t in AlarmEditor(original: t.alarm).environmentObject(model).zoomed(from: t.id, in: editNS) }
        .sheet(item: $day) { d in CalendarDaySheet(key: d.id).environmentObject(model).zoomed(from: d.id, in: editNS) }
        .refreshable { await model.loadState() }
        .onChange(of: model.addAlarm) { _, _ in edit(nil) }
        .onChange(of: wide) { _, _ in pane = .schedule }
        .onAppear {
            wake.refreshPlan()
            guard !posed else { return }
            posed = true
            switch ChumbyModel.pose {
            case "calsettings": openSettings()
            case "template": if wide { show(.template) } else { openSettings() }
            case "calday": if let k = wake.plan.first?.key { openDay(k) }
            case "editor": edit(mine.first ?? Alarm())
            case "editornew": edit(nil)
            // His own alarms and the nap brought on screen, folded, for their shot.
            case "alarmsmine": Task { try? await Task.sleep(nanoseconds: 1_500_000_000); scrollTo = "nap" }
            case "failure":
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if let a = mine.first { model.change(.toggle(a, !a.isOn)) }
                }
            case "alarmsdemo":
                // For the build's film: Settings in and out, then down to the nap, where a 10-minute nap is started,
                // counts down for a while and is called off, all on screen.
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000); openSettings()
                    try? await Task.sleep(nanoseconds: 2_500_000_000); if wide { show(.schedule) } else { model.alarmsPage = false }
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
        if !model.stateKnown {
            HStack(spacing: 10) { ProgressView(); Text("Reaching the Chumby…").foregroundStyle(.secondary) }.padding(.vertical, 6)
        } else if let n = model.nextRing() {
            let fromCalendar = n.alarm.isCalendar
            let skippedNow = model.state.skipped.map { $0.date > Date() } == true
            VStack(alignment: .leading, spacing: 3) {
                // A skip shows here too, with its Undo, so the time below never looks as if the skipped one vanished.
                if let s = model.state.skipped, s.date > Date() {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(clockParts(s.date).0 + " " + clockParts(s.date).1).font(.custom("Trebuchet MS", size: 17).weight(.bold)).strikethrough().foregroundStyle(.secondary)
                        Text("Skipped").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Undo") { Task { await model.unskip() } }.font(.subheadline.weight(.semibold)).foregroundStyle(.tint).buttonStyle(.borderless)
                    }
                    .padding(.bottom, 4)
                }
                // What kind it is, in that kind's colour, the same glyph as its row below.
                SectionHead(icon: fromCalendar ? "calendar" : "alarm.fill",
                            text: (skippedNow ? "Then" : "Next alarm") + " · " + { let k = kindWord(n.alarm); return k.prefix(1).uppercased() + k.dropFirst() }(),
                            color: fromCalendar ? ChumbyPalette.cal(scheme == .dark) : ChumbyPalette.acc(scheme == .dark))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    let c = clockParts(n.at)
                    Text(c.0).font(.custom("Trebuchet MS", size: 52).weight(.bold)).monospacedDigit().contentTransition(.numericText())
                    Text(c.1).font(.custom("Trebuchet MS", size: 22).weight(.bold)).contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Text(n.at, style: .relative).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).monospacedDigit().contentTransition(.numericText())
                }
                HStack(alignment: .center, spacing: 10) {
                    Text("\(dayWord(n.at)) · \(alarmLabel(n.alarm).capitalizedFirst)").foregroundStyle(.secondary).lineLimit(1).contentTransition(.numericText())
                    Spacer(minLength: 8)
                    // The one thing he'd reach for here: let it pass. Only on a Chumby that can skip, and not twice.
                    if model.state.skipKnown && !skippedNow && model.sys.ringing == nil {
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
                if let f = model.failed("skip") { FailNote(text: f) }
            }
            .padding(.vertical, 2)
            // A nap starting or called off rolls the time over rather than swapping it.
            .animation(.snappy, value: n.at)
        } else {
            HStack(spacing: 10) {
                OctopusMark(color: ChumbyPalette.hex(0x2c5bae).opacity(0.7), blink: 0.08).frame(width: 34)
                Text("No alarm set. Sleep in.").foregroundStyle(.secondary)
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
            if model.stateKnown && mine.isEmpty {
                Text("None of your own yet.").foregroundStyle(.secondary)
            }
            ForEach(mine, id: \.key) { a in
                AlarmRow(clock: (a.clock, a.meridiem), title: a.name.isEmpty ? "Alarm" : a.name,
                         detail: [a.whenUnlessNamed, a.soundText].filter { !$0.isEmpty }.joined(separator: " · "), on: a.isOn, mark: a.key,
                         tile: AnyView(AlarmTile(calendarDay: nil, on: a.isOn)),
                         tap: { edit(a) },
                         toggle: Binding(get: { a.isOn }, set: { model.change(.toggle(a, $0)) })) {
                    MarkNote(mark: a.key)
                }
                .zoomSource(a.key, in: editNS)
            }
            // The end of the card: one row, tapped anywhere, as Channels' Add widgets. Nothing floats over the page, so
            // nothing can cover the Nap chips under it (Richard's Alarms shot, 2026-11-05).
            Button { edit(nil) } label: {
                Label("Add alarm", systemImage: "plus.circle.fill").font(.body.weight(.semibold))
                    .foregroundStyle(ChumbyPalette.acc(scheme == .dark))
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add an alarm")
            .zoomSource("new", in: editNS)
        } header: { SectionHead(icon: "alarm", text: "My alarms", color: ChumbyPalette.acc(scheme == .dark)) } footer: {
            if model.state.pending { Text("The Chumby is putting your last change in place.") }
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
                    AlarmRow(clock: clockParts(item.wake), title: item.title,
                             detail: "\(item.start.formatted(date: .omitted, time: .shortened)) · \(leadText(item.lead)) before",
                             on: !item.skipped,
                             tile: AnyView(AlarmTile(calendarDay: item.wake, on: !item.skipped)),
                             oneLine: true,
                             tap: { openDay(item.key) },
                             toggle: Binding(get: { !item.skipped }, set: { _ in model.tick(); wake.toggleSkip(item) })) {
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
                Button { Task { await wake.enable() } } label: { Label("Wake me from my calendar", systemImage: "calendar.badge.clock") }
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
            if let n = wake.note { Text(n) }
            else if !wake.rules.enabled { Text("Wakes you before the first thing each day.") }
        }
    }
}
// A section's heading with its kind's glyph and colour, so the two kinds of alarm can be told apart at a glance.
struct SectionHead: View {
    let icon: String, text: String, color: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.subheadline.weight(.semibold))
            Text(text).font(.custom("Trebuchet MS", size: 16).weight(.bold))
        }
        .foregroundStyle(color).textCase(nil)
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

// MARK: - The alarm editor
struct AlarmEditor: View {
    @EnvironmentObject var model: ChumbyModel
    @Environment(\.dismiss) private var dismiss
    // The alarm as it was when opened, or nil for a new one. Saved by what it is, never by its place in the list.
    var original: Alarm?
    // The settings every calendar alarm shares: how it sounds and what it does, never when it rings or what it's called,
    // which the calendar decides.
    var calendarTemplate = false
    // Set when it's shown in the open Duo's right pane rather than as a sheet: how to go back.
    var close: (() -> Void)?
    init(original: Alarm? = nil, calendarTemplate: Bool = false, close: (() -> Void)? = nil) { self.original = original; self.calendarTemplate = calendarTemplate; self.close = close }
    var title: String { calendarTemplate ? "How they ring" : original != nil ? "Edit alarm" : "Add alarm" }
    @State private var alarm = Alarm()
    @State private var time = Date()
    @State private var date = Date()
    @State private var repeatMode = "daily"
    @State private var day = 1
    @State private var kind = "beep"
    @State private var tone = "Beep"
    @State private var streamIndex = 0
    @State private var pandoraID = ""
    @State private var after = ""
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var problem: String?
    @State private var loaded = false

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
        if !calendarTemplate {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            if repeatMode == "once" { a.when = "once"; a.time = String(Int((onceAt.timeIntervalSince1970 / 60).rounded())) }
            else { a.when = repeatMode == "day" ? Alarm.dayKeys[day] : repeatMode; a.time = String((c.hour ?? 7) * 60 + (c.minute ?? 0)) }
            a.name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            a.enabled = "1"
        }
        switch kind {
        case "beep": a.type = "beep"; a.arg = tone; a.param = ""; a.param_description = tone
        case "none": a.type = "none"; a.arg = ""; a.param = ""; a.param_description = "None"
        case "stream":
            guard model.state.streams.indices.contains(streamIndex) else { return .failure(.message("Add a radio stream on the Sounds tab first.")) }
            let s = model.state.streams[streamIndex]
            func esc(_ v: String) -> String { v.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
            a.type = "audio"; a.arg = "directurl"; a.param_description = s.name.isEmpty ? s.url : s.name
            a.param = "<stream url=\"\(esc(s.url))\" id=\"\(esc(s.id))\" mimetype=\"\(esc(s.mimetype))\" name=\"\(esc(s.name.isEmpty ? s.url : s.name))\" />"
        case "pandora":
            guard !pandoraID.isEmpty else { return .failure(.message("Pick a Pandora station first.")) }
            let name = stations.first { $0.id == pandoraID }?.name ?? "Pandora"
            a.type = "audio"; a.arg = "pandora"; a.param = pandoraID + "##" + name; a.param_description = name
        default: break
        }
        if kind == "none" { a.duration = "0" }
        let parts = after.components(separatedBy: "|")
        a.action = parts.first ?? ""; a.action_param = parts.count > 1 ? parts[1] : ""
        return .success(a)
    }
    var change: AlarmChange? {
        guard !calendarTemplate, case .success(let a) = draft else { return nil }
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
            // In the right pane: its own title row with Cancel and Save, then the same sections, clear of the fold.
            Group {
                PageTitle(title) {
                    HStack(spacing: 16) {
                        Button("Cancel") { stopTest(); close() }.disabled(saving)
                        if saving { ProgressView() } else { Button("Save") { save() }.fontWeight(.semibold) }
                    }
                    .foregroundStyle(.tint)
                }
                .onAppear { if !loaded { load(); loaded = true }; model.editingAlarm = true }
                .onDisappear { model.editingAlarm = false }
                sections
            }
        } else {
            NavigationStack {
                Form { sections.listRowBackground(GlassRow()) }
                .seaList().background { SeaBackground().ignoresSafeArea() }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Text(title).font(.custom("Trebuchet MS", size: 18).weight(.bold)) }
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stopTest(); dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else { Button("Save") { save() }.fontWeight(.semibold) }
                    }
                }
                .interactiveDismissDisabled(saving)
                .onAppear { if !loaded { load(); loaded = true }; model.editingAlarm = true }
                .onDisappear { model.editingAlarm = false }
            }
        }
    }
    func finish() { stopTest(); if let close { close() } else { dismiss() } }

    var sections: some View {
            Group {
                // Above everything, beside Save: why it couldn't save, or what saving will do that isn't obvious.
                if saving || problem != nil || !switchesOff.isEmpty || (original.map { !$0.isOn } ?? false) && !calendarTemplate {
                    Section {
                        if saving { HStack(spacing: 10) { ProgressView(); Text("Reaching the Chumby…").foregroundStyle(.secondary) } }
                        if let problem { FailNote(text: problem) }
                        let off = switchesOff
                        if !off.isEmpty { RowNote(icon: "alarm", text: "Saving turns off \(Self.list(off)).") }
                        if !calendarTemplate, let o = original, !o.isOn { RowNote(icon: "alarm.fill", text: "Saving turns this alarm on.", color: .secondary) }
                    }
                }
                if !calendarTemplate {
                Section { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity) }
                Section {
                    Picker("Repeat", selection: $repeatMode) {
                        Text("Once").tag("once"); Text("Daily").tag("daily"); Text("Weekdays").tag("weekday"); Text("Weekends").tag("weekend"); Text("One day").tag("day")
                    }
                    if repeatMode == "day" {
                        Picker("Day", selection: $day) { ForEach(0..<7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0]).tag($0) } }
                    }
                    if repeatMode == "once" {
                        DatePicker("Date", selection: $date, displayedComponents: .date)
                        Text("Rings \(onceAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))").font(.subheadline).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Label")
                        TextField("Optional", text: $alarm.name).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                    }
                }
                }
                Section("Sound") {
                    Picker("Plays", selection: $kind) {
                        Text("Tone").tag("beep"); Text("Radio").tag("stream"); Text("Pandora").tag("pandora"); Text("Silent").tag("none")
                        if kind == "keep" { Text("Current").tag("keep") }
                    }
                    if kind == "beep" {
                        Picker("Tone", selection: $tone) { ForEach(model.state.tones, id: \.self) { Text($0).tag($0) } }
                        Button {
                            Task { do { try await model.api?.post("test", extra: "&tone=" + ChumbyAPI.enc(tone)) } catch { model.fail("test", "Couldn’t play it. \(AlarmWriter.explain(error))") } }
                        } label: { Label("Play on the Chumby", systemImage: "play.fill") }
                        .foregroundStyle(.tint)
                        if let f = model.failed("test") { FailNote(text: f) }
                    }
                    if kind == "stream" {
                        if model.state.streams.isEmpty { Text("Add a radio stream on the Sounds tab first.").foregroundStyle(.secondary) }
                        else { Picker("Station", selection: $streamIndex) { ForEach(model.state.streams.indices, id: \.self) { i in Text(model.state.streams[i].name.isEmpty ? model.state.streams[i].url : model.state.streams[i].name).tag(i) } } }
                    }
                    if kind == "pandora" {
                        if stations.isEmpty { Text("No Pandora stations on the Chumby yet.").foregroundStyle(.secondary) }
                        else { Picker("Station", selection: $pandoraID) { ForEach(stations) { Text($0.name).tag($0.id) } } }
                    }
                    if kind == "keep" { LabeledContent("Plays", value: alarm.soundText) }
                    if kind != "none" {
                        Picker("Plays for", selection: $alarm.duration) {
                            ForEach([("1", "1 minute"), ("5", "5 minutes"), ("10", "10 minutes"), ("15", "15 minutes"), ("30", "30 minutes"), ("60", "1 hour"), ("120", "2 hours"), ("-1", "Until stopped")], id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                    Picker("Snooze", selection: $alarm.snooze) {
                        ForEach(["1", "3", "5", "9", "10", "15", "20", "30", "60"], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    Toggle("Stop on its own", isOn: Binding(get: { alarm.auto_dismiss == "1" }, set: { alarm.auto_dismiss = $0 ? "1" : "0" }))
                }
                Section {
                    // No Backup beep switch: the Chumby saves every alarm with backup 0 whatever it's sent (do_save, since
                    // 11-05: the stock beeper killed the alarm panel), so turning it on here came back off after Save.
                    Picker("Then", selection: $after) { ForEach(afterOptions, id: \.0) { Text($0.1).tag($0.0) } }
                } header: { Text("Afterwards") } footer: { if calendarTemplate { Text("Applies to every alarm your calendar sets, now and later.") } }
                if let original, !calendarTemplate { Section {
                    // The question hangs off the button that asked it, so it points at what was tapped.
                    Button("Delete alarm", role: .destructive) { confirmDelete = true }.foregroundStyle(.red).disabled(saving)
                        .confirmationDialog("Delete this alarm?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete alarm", role: .destructive) { run(.delete(original)) }
                        }
                } }
            }
    }
    func stopTest() { Task { try? await model.api?.post("test", extra: "&stop=1") } }

    func load() {
        if calendarTemplate {
            // The saved set if there is one, else how the first calendar alarm rings now.
            if let t = model.state.calTpl ?? CalendarWake.shared.storedSettings ?? model.state.alarms.first(where: { $0.isCalendar }) { alarm = t }
        } else if let original { alarm = original }
        // The build's shot of a new alarm being set for a new time, so "Saving turns off …" can be seen.
        if original == nil && !calendarTemplate && ChumbyModel.pose == "editornew" { alarm.time = "330"; alarm.when = "weekday" }
        let m = alarm.localMinutes
        time = Calendar.current.date(bySettingHour: m / 60 % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
        if let d = Alarm.dayKeys.firstIndex(of: alarm.when) { day = d; repeatMode = "day" } else { repeatMode = alarm.when }
        if alarm.when == "once" { date = Date(timeIntervalSince1970: (Double(alarm.time) ?? 0) * 60) }
        kind = alarm.type == "beep" ? "beep" : alarm.type == "none" ? "none" : alarm.arg == "directurl" ? "stream" : alarm.arg == "pandora" ? "pandora" : "keep"
        tone = model.state.tones.contains(alarm.arg) ? alarm.arg : (model.state.tones.first ?? "Beep")
        if kind == "stream", let k = model.state.streams.firstIndex(where: { (!$0.id.isEmpty && alarm.param.contains($0.id)) || alarm.param.contains($0.url.replacingOccurrences(of: "&", with: "&amp;")) }) { streamIndex = k }
        pandoraID = kind == "pandora" ? (alarm.param.components(separatedBy: "##").first ?? "") : (stations.first?.id ?? "")
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
