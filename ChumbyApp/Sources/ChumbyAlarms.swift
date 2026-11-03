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
    var body: some View {
        if case .landed(let at) = model.marks[mark], Date().timeIntervalSince(at) < 1.2 {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
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

// One alarm row, the same for your own alarms and the calendar's: the time large, what it is under it, any word about it
// under that, and the switch alone on the right.
struct AlarmRow<Notes: View>: View {
    let clock: (String, String)
    var day: String?
    let detail: String
    let on: Bool
    var mark: String?
    let tap: () -> Void
    let toggle: Binding<Bool>
    @ViewBuilder var notes: () -> Notes
    var body: some View {
        HStack(spacing: 12) {
            Button(action: tap) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(clock.0).font(.custom("Trebuchet MS", size: 44)).monospacedDigit()
                        Text(clock.1).font(.custom("Trebuchet MS", size: 20))
                        if let day { Text(day).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 6) }
                    }
                    .opacity(on ? 1 : 0.5)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).opacity(on ? 1 : 0.7)
                    notes()
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
    @Namespace private var buttons
    // The last ring seen, so the card keeps its words and buttons while it fades out after Stop.
    @State private var last: Sys.Ringing?
    var ring: Sys.Ringing? { model.sys.ringing ?? last }
    var name: String { ring.map { r in [r.name.hasPrefix(Alarm.calendarPrefix) ? String(r.name.dropFirst(Alarm.calendarPrefix.count)) : r.name, r.sound].filter { !$0.isEmpty }.joined(separator: " · ") } ?? "" }
    var body: some View {
        content
            .onAppear { last = model.sys.ringing }
            .onChange(of: model.sys.ringing) { _, r in if let r { last = r } }
    }
    @ViewBuilder var content: some View {
        if let r = ring, model.unreachable {
            // An old reading: what it was doing when last heard from, and no buttons that can't reach it.
            VStack(spacing: 3) {
                Text("Was \(r.snoozed ? "snoozing" : "ringing")\(model.seenAt.map { " at " + seenText($0) } ?? "")").font(.custom("Trebuchet MS", size: 22).weight(.bold))
                Text([name, "can’t reach the Chumby"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.custom("Trebuchet MS", size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(16).frame(maxWidth: .infinity)
        } else if let r = ring {
            VStack(spacing: 14) {
                VStack(spacing: 3) {
                    // One title that crossfades from Ringing to Snoozed, in the same spring as the buttons.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(r.snoozed ? model.snoozeEnds.map { "Snoozed until \($0.formatted(date: .omitted, time: .shortened))" } ?? "Snoozed" : "Ringing")
                            .contentTransition(.opacity)
                    }
                    .font(.custom("Trebuchet MS", size: 24).weight(.bold))
                    Text(name).font(.custom("Trebuchet MS", size: 16)).foregroundStyle(.secondary).lineLimit(1)
                }
                // Snooze folds away into the side Stop grows from, so Stop widens in place rather than jumping.
                HStack(spacing: 14) {
                    if !r.snoozed {
                        Button { model.ringSnooze() } label: { Label("Snooze", systemImage: "water.waves").frame(maxWidth: .infinity, minHeight: 56) }
                            .buttonStyle(.glass)
                            .transition(.scale(scale: 0.4, anchor: .trailing).combined(with: .opacity))
                    }
                    Button { model.ringOff() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 56) }
                        .buttonStyle(.glassProminent).tint(ChumbyPalette.orange)
                        .matchedGeometryEffect(id: "stop", in: buttons)
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
    // Stopped: the card fades and settles back a little while what's under it slides up in the same spring.
    static var ringCard: AnyTransition { .opacity.combined(with: .scale(scale: 0.95, anchor: .top)) }
}

// MARK: - Naps
// Four lengths. The one running becomes its own countdown, draining like water, with × to call it off.
struct NapChips: View {
    @EnvironmentObject var model: ChumbyModel
    @AppStorage("napLength") private var napLength = 0
    @State private var sending: Int?
    var body: some View {
        let due = model.napDue
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach([10, 20, 30, 60], id: \.self) { m in
                    if let due, m == napLength { countdown(due, total: m) } else {
                        Button {
                            napLength = m; sending = m
                            Task { await model.nap(m); sending = nil }
                        } label: {
                            Group { if sending == m { ProgressView() } else { Text("\(m) min") } }.frame(maxWidth: .infinity, minHeight: 34)
                        }
                        .buttonStyle(.bordered).disabled(sending != nil)
                    }
                }
            }
            // A nap set somewhere else, of a length these don't have.
            if let due, ![10, 20, 30, 60].contains(napLength) || napLength == 0 {
                HStack {
                    Text("Nap until \(due.formatted(date: .omitted, time: .shortened))")
                    Spacer()
                    Button("Cancel") { Task { await model.cancelNap() } }.buttonStyle(.borderless)
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
            HStack(spacing: 4) {
                Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText(countsDown: true)).animation(.snappy, value: Int(left))
                Button { Task { await model.cancelNap() } } label: { Image(systemName: "xmark").font(.footnote.weight(.bold)) }
                    .buttonStyle(.borderless).accessibilityLabel("Cancel nap")
            }
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(alignment: .bottom) {
                GeometryReader { g in
                    Capsule().fill(ChumbyPalette.hex(0x79bbff).opacity(0.45))
                        .frame(height: g.size.height * k).frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(Capsule())
            }
            .overlay(Capsule().stroke(.tint.opacity(0.6), lineWidth: 1))
            .accessibilityLabel("Nap, \(Int(left) / 60) minutes left")
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
    private static func file(_ k: String) -> URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chumby-art-" + String(k.hashValue & 0x7fffffff)) }
    private var links: [String: String] { get { UserDefaults.standard.dictionary(forKey: "songLinks") as? [String: String] ?? [:] } set { UserDefaults.standard.set(newValue, forKey: "songLinks") } }
    static func key(_ s: Song) -> String { s.artist + " – " + s.title }
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
            guard let u = c.url, let d = try? await URLSession.shared.data(from: u).0, let t = (try? JSONDecoder().decode(R.self, from: d))?.results.first else { return }
            if let link = t.trackViewUrl { links[k] = link }
            var f = Found(image: nil, link: t.trackViewUrl.flatMap(URL.init(string:)), tint: nil)
            if let a = t.artworkUrl100.map({ $0.replacingOccurrences(of: "100x100", with: "300x300") }), let au = URL(string: a), let img = try? await URLSession.shared.data(from: au).0 {
                try? img.write(to: Self.file(k), options: .atomic)
                f.image = PlatformImage(data: img); f.tint = Self.tint(img)
            }
            found[k] = f
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
    @ObservedObject private var art = SongArt.shared
    @Environment(\.openURL) private var openURL
    // For each time an alarm went off, the first song Pandora played in the 45 minutes after it.
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
        let list = Self.wakings(model.songs, model.state.alarms)
        if !list.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(list, id: \.song.id) { w in tile(w.song) }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            } header: { Text("Woke up to") }
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
                    if let i = f?.image { Image(platform: i).resizable().scaledToFill() }
                    else {
                        // No cover found: the octopus on the Chumby's own blue, never a grey box.
                        ChumbyPalette.hex(0x2c5bae)
                        OctopusMark(color: .white.opacity(0.9), eyes: ChumbyPalette.hex(0x2c5bae)).padding(26)
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
struct AlarmsTab: View {
    @EnvironmentObject var model: ChumbyModel
    @ObservedObject private var wake = CalendarWake.shared
    @Environment(\.paneLayout) private var wide
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
    struct DayTarget: Identifiable { let id: String }
    static let actions = [("night", "on", "Night mode: clock"), ("night", "dim", "Night mode: dim"), ("night", "dark", "Night mode: dark"), ("night", "off", "Night mode off"), ("screen", "bright", "Screen bright"), ("screen", "dim", "Screen dim"), ("screen", "off", "Screen off")]

    var dismissed: Set<String> { Set(dismissedRaw.split(separator: "\n").map(String.init)) }
    var missed: [ChumbyState.Missed] { model.state.missed.filter { Date().timeIntervalSince1970 - $0.at < 86400 && !dismissed.contains($0.id) }.suffix(3).reversed().map { $0 } }
    var mine: [Alarm] { model.state.alarms.filter { !$0.isPlaceholder && $0.name != "Catch-up" && !$0.isCalendar && $0.name != "Nap" }.sorted { $0.localMinutes < $1.localMinutes } }
    var volumeText: String {
        let f = model.state.fade
        let fade = f < 0 ? "" : f == 0 ? ", no fade" : ", fades in over " + (f < 60 ? "\(f) s" : "\(f / 60) min")
        return "Rings at \(model.state.volume)%" + fade
    }
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
    func openDay(_ k: String) { if wide { show(.day(k)) } else { day = DayTarget(id: k) } }
    func openSettings() { if wide { show(.settings) } else { model.alarmsPage = true } }
    var plus: some View {
        Button { edit(nil) } label: { Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).frame(width: 30, height: 30) }
            .buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Add alarm")
    }

    // For the build's film: a row to bring on screen, so the nap's chip and countdown are filmed, not run below the fold.
    @State private var scrollTo: String?
    var body: some View {
        ScrollViewReader { proxy in
            page.onChange(of: scrollTo) { _, id in if let id { withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(id, anchor: .center) } } }
        }
    }
    var page: some View {
        TwoPane(rightTitle: rightTitle, rightTrailing: paneShown == .settings ? AnyView(Button("Done") { show(.schedule) }.fontWeight(.semibold).foregroundStyle(.tint)) : nil) {
            // + lives in the side bar's column when there is one (RootView puts it there); only with the bars across is it here.
            PageTitle("Alarms") { if model.railWidth < 44 { plus } }
            ReachRow()
            if model.sys.ringing != nil { Section { RingingCard() } }
            Section { glance }
            if !missed.isEmpty {
                Section {
                    ForEach(missed) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            RowNote(icon: "alarm.waves.left.and.right.fill", text: m.rang ? "Rang late" : "Missed")
                            Text([Date(timeIntervalSince1970: m.at).formatted(.dateTime.weekday(.abbreviated).hour().minute()), m.name.hasPrefix(Alarm.calendarPrefix) ? String(m.name.dropFirst(Alarm.calendarPrefix.count)) : m.name].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .swipeActions { Button("Dismiss") { dismissedRaw = (dismissed.union([m.id])).joined(separator: "\n") }.tint(.gray) }
                    }
                } footer: { Text("The Chumby was frozen or off when these came due. Swipe to dismiss.") }
            }
            yours
            calendar
        } right: {
            switch paneShown {
            case .schedule:
                Section("Quick nap") { NapChips().id("nap") }
                WokeUpTo()
                schedule
            case .settings: CalendarSettingsSections()
            case .editor(let a): AlarmEditor(original: a, close: { show(.schedule) }).id(a?.key ?? "new")
            case .day(let k): CalendarDaySheet(key: k, close: { show(.schedule) }).id(k)
            case .template: AlarmEditor(calendarTemplate: true, close: { show(paneBack) })
            }
        }
        .seaList()
        .environment(\.openTemplate, wide ? { paneBack = pane; show(.template) } : nil)
        .navigationDestination(isPresented: $model.alarmsPage) { CalendarWakeSettings() }
        .sheet(item: $editing) { t in AlarmEditor(original: t.alarm).environmentObject(model) }
        .sheet(item: $day) { d in CalendarDaySheet(key: d.id).environmentObject(model) }
        .refreshable { await model.loadState() }
        .onChange(of: model.addAlarm) { _, _ in edit(nil) }
        .onChange(of: wide) { _, _ in pane = .schedule }
        .onAppear {
            wake.refreshPlan()
            Task { await model.loadSongs() }
            guard !posed else { return }
            posed = true
            switch ChumbyModel.pose {
            case "calsettings": openSettings()
            case "template": if wide { show(.template) } else { openSettings() }
            case "calday": if let k = wake.plan.first?.key { openDay(k) }
            case "editor": edit(mine.first ?? Alarm())
            case "editornew": edit(nil)
            case "failure":
                Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if let a = mine.first { model.change(.toggle(a, !a.isOn)) }
                }
            case "alarmsdemo":
                // For the build's film: Settings in and out, then down to Quick nap, where a 10-minute nap is started,
                // counts down for a while and is called off, all on screen.
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000); openSettings()
                    try? await Task.sleep(nanoseconds: 2_500_000_000); if wide { show(.schedule) } else { model.alarmsPage = false }
                    try? await Task.sleep(nanoseconds: 1_200_000_000); scrollTo = "nap"
                    try? await Task.sleep(nanoseconds: 1_200_000_000); await model.nap(10)
                    try? await Task.sleep(nanoseconds: 4_500_000_000); await model.cancelNap()
                }
            default: break
            }
        }
    }

    // What rings next, first, so it never has to be worked out from the list.
    @ViewBuilder var glance: some View {
        if !model.stateKnown {
            HStack(spacing: 10) { ProgressView(); Text("Reaching the Chumby…").foregroundStyle(.secondary) }.padding(.vertical, 6)
        } else if let n = model.nextRing() {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next alarm").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    let c = clockParts(n.at)
                    Text(c.0).font(.custom("Trebuchet MS", size: 52).weight(.bold)).monospacedDigit().contentTransition(.numericText())
                    Text(c.1).font(.custom("Trebuchet MS", size: 22).weight(.bold)).contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Text(n.at, style: .relative).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).monospacedDigit().contentTransition(.numericText())
                }
                Text("\(dayWord(n.at)) · \(alarmLabel(n.alarm).capitalizedFirst)").foregroundStyle(.secondary).lineLimit(1).contentTransition(.numericText())
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

    var yours: some View {
        Section {
            if model.stateKnown && mine.isEmpty {
                Text("No alarms yet. Tap + to add one.").foregroundStyle(.secondary)
            }
            ForEach(mine, id: \.key) { a in
                AlarmRow(clock: (a.clock, a.meridiem), detail: [a.name, a.whenText, a.soundText].filter { !$0.isEmpty }.joined(separator: " · "), on: a.isOn, mark: a.key,
                         tap: { edit(a) },
                         toggle: Binding(get: { a.isOn }, set: { model.change(.toggle(a, $0)) })) {
                    MarkNote(mark: a.key)
                }
            }
            if model.stateKnown {
                Button { model.tab = 3 } label: {
                    HStack(spacing: 8) { Image(systemName: "speaker.wave.2.fill").font(.footnote); Text(volumeText) }
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityHint("Opens Sounds")
            }
        } header: { Text("Your alarms") } footer: {
            if model.state.pending { Text("The Chumby is putting your last change in place.") }
        }
    }

    // The calendar's alarms in the same rows as your own, checked against what the Chumby really holds.
    var calendar: some View {
        Section {
            if wake.rules.enabled && wake.allowed {
                if wake.plan.isEmpty { Text("Nothing coming up that needs waking for.").foregroundStyle(.secondary) }
                ForEach(wake.plan) { item in
                    // Only against a recent reading, and never in the build's sample, which has no Chumby behind it.
                    let status = model.stateConfirmed && !CalendarWake.sample ? wake.onDevice(item, in: model.deviceState) : .set
                    AlarmRow(clock: clockParts(item.wake), day: item.wake.formatted(.dateTime.weekday(.abbreviated)),
                             detail: "\(item.title) at \(item.start.formatted(date: .omitted, time: .shortened)), \(leadText(item.lead)) before",
                             on: !item.skipped, tap: { openDay(item.key) },
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
                        Text(a.whenText).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 6)
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
            if wake.rules.enabled && wake.allowed {
                // One way in for all of it: wake-up times, how the alarms ring, words and calendars.
                if wide {
                    Button { show(pane == .settings ? .schedule : .settings) } label: {
                        HStack { Text("Settings"); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(pane == .settings ? AnyView(Color.accentColor.opacity(0.18)) : AnyView(GlassRow()))
                } else {
                    // Pushed through the model, so the rail knows to swap + for Back.
                    Button { model.alarmsPage = true } label: {
                        HStack { Text("Settings"); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("From your calendar")
        } footer: {
            if let n = wake.note { Text(n) }
            else if wake.rules.enabled, let s = wake.lastSync { Text("Set on the Chumby, so they ring with your phone off. Updated \(s.formatted(.relative(presentation: .named))). Tap one to change that day.") }
            else if !wake.rules.enabled { Text("Wakes you before the first thing each day.") }
        }
    }

    var schedule: some View {
        Section {
            ForEach($model.state.schedule) { $e in
                HStack {
                    DatePicker("Time", selection: Binding(get: { Self.date(e.time) }, set: { e.time = Self.hhmm($0); model.saveScheduleSoon() }), displayedComponents: .hourAndMinute).labelsHidden()
                    Picker("Action", selection: Binding(get: { e.cmd + ":" + e.val }, set: { v in
                        let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
                        e.cmd = parts[0]; e.val = parts.count > 1 ? parts[1] : ""
                        Task { await model.saveSchedule() }
                    })) {
                        ForEach(Self.actions, id: \.2) { Text($0.2).tag($0.0 + ":" + $0.1) }
                        ForEach(model.state.channelNames, id: \.self) { Text("Channel: " + $0).tag("channel:" + $0) }
                    }.labelsHidden()
                }
            }
            .onDelete { model.state.schedule.remove(atOffsets: $0); model.state.reindex(); Task { await model.saveSchedule() } }
            Button("Add a time") { model.state.schedule.append(ScheduleItem()); model.state.reindex(); Task { await model.saveSchedule() } }.foregroundStyle(.tint)
            if let f = model.failed("schedule") { FailNote(text: f) }
        } header: { Text("Daily schedule") } footer: { Text("Runs every day at these times, even with your phone away.") }
    }
    static func date(_ s: String) -> Date {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 22, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
    static func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
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

    var stations: [NamedID] {
        var out = model.state.pandora
        for a in model.state.alarms where a.arg == "pandora" && !a.param.isEmpty {
            let p = a.param.components(separatedBy: "##")
            if !out.contains(where: { $0.id == p[0] }) { out.append(NamedID(id: p[0], name: p.count > 1 ? p[1] : a.param_description)) }
        }
        return out
    }
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
    var switchesOff: [String] {
        guard loaded, let change else { return [] }
        var sending = model.deviceState
        change.apply(&sending)
        return ChumbyState.switchedOff(saved: model.deviceState.alarms, sending: sending.alarms).map { alarmLabel(sending.alarms[$0]) }
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
                    Picker("Then", selection: $after) { ForEach(afterOptions, id: \.0) { Text($0.1).tag($0.0) } }
                    Toggle("Backup beep", isOn: Binding(get: { alarm.backup == "1" }, set: { alarm.backup = $0 ? "1" : "0" }))
                    if alarm.backup == "1" {
                        Picker("Backup after", selection: $alarm.backupDelay) { ForEach(["1", "2", "5", "10", "15", "30"], id: \.self) { Text("\($0) min").tag($0) } }
                    }
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
        Task {
            let why = await model.save(c)
            saving = false
            if let why { problem = why } else { finish() }
        }
    }
}
