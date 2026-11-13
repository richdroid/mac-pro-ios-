import SwiftUI

// The box itself, the way the Mac Pro app shows the Mac: its picture, then what it's up to.
struct DeviceInfo: Decodable {
    struct History: Decodable { let cpu: [Double], mem: [Double], rx: [Double], tx: [Double] }
    let model: String, android: String, resolution: String, wifi: String, ip: String
    let uptime: Double, memUsed: Double, memTotal: Double, diskUsed: Double, diskTotal: Double, tempC: Double, rxRate: Double, txRate: Double
    let cpu: Int
    let hist: History
}
private func bytes(_ b: Double) -> String { b >= 1e9 ? String(format: "%.1f GB", b / 1e9) : String(format: "%.0f MB", b / 1e6) }
private func rate(_ b: Double) -> String { b >= 1e6 ? String(format: "%.1f MB/s", b / 1e6) : String(format: "%.0f KB/s", b / 1e3) }
private func span(_ s: Double) -> String {
    let u = Int(s), d = u / 86400, h = u / 3600 % 24, m = u / 60 % 60
    return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
private struct Spark: View {
    let values: [Double]
    var top: Double?
    var body: some View {
        GeometryReader { g in
            let peak = max(top ?? (values.max() ?? 1), 0.001), step = g.size.width / CGFloat(max(values.count - 1, 1))
            let point = { (i: Int) in CGPoint(x: CGFloat(i) * step, y: g.size.height * (1 - CGFloat(values[i] / peak))) }
            // Too few points to be a line yet: a faint resting baseline in its place, rather than two points read as a trend.
            if values.count < 8 {
                Path { p in p.move(to: CGPoint(x: 0, y: g.size.height - 1)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height - 1)) }
                    .stroke(.white.opacity(0.14), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2, 5]))
            } else {
            // Stood on the tile's foot: the line with its area filled down to the foot, so a low reading (CPU) and a high
            // one (memory) read as levels on one floor, never as two lines floating at different heights (gate 276).
            let line = Path { p in
                guard values.count > 1 else { return }
                p.move(to: point(0))
                for i in 1..<values.count { p.addLine(to: point(i)) }
            }
            let area = line.foot(g.size)
            area.fill(LinearGradient(colors: [TVLook.accent.opacity(0.28), TVLook.accent.opacity(0.04)], startPoint: .top, endPoint: .bottom))
            line.stroke(TVLook.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 38)
    }
}
private extension Path {
    // The line closed down to the foot of a box this size, for the area under it.
    func foot(_ size: CGSize) -> Path {
        var p = self
        p.addLine(to: CGPoint(x: size.width, y: size.height)); p.addLine(to: CGPoint(x: 0, y: size.height)); p.closeSubpath()
        return p
    }
}
private struct Tile: View {
    let title: String, value: String, detail: String
    let spark: [Double]
    var top: Double?
    // A box just woken answers 0% and 0 KB/s before it has measured anything: a dash, breathing, until a second reading.
    var settled: Bool { spark.count >= 2 }
    @State private var breathe = false
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(settled ? value : "—").font(.system(size: 26, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).contentTransition(.numericText())
                .opacity(settled ? 1 : breathe ? 0.75 : 0.35)
                .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { breathe = true } }
            if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            // Each tile's spark on its foot, whatever the lines above it hold, so sibling tiles' sparks share one line.
            Spacer(minLength: 8)
            Spark(values: spark, top: top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .tvCard(16)
    }
}
// The box's numbers, kept for the app's life, so coming back to Status shows the last ones at once while new ones come.
@MainActor
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()
    @Published var info: DeviceInfo?
    @Published var failed = false
    // Since when no answer has come, by any asking. "Can't reach" only after about 25 s of that, as everywhere in the app:
    // a blip leaves no trace, and the last reading stays at full strength meanwhile (Richard's rulings, 11-11). A request
    // cut short because he left the tab is no answer either way: it flashed "Can't reach it" over greyed tiles for a
    // frame on coming back to Status (gate HOLD of 8446178).
    // The clock starts afresh with each visit, and after a quiet spell with no miss: one miss long ago and one now are two
    // blips, not 25 s of failure (gate of 87d77ca).
    var failingSince: Date?, lastMiss: Date?, lastAnswer: Date?
    func answered() { failingSince = nil; lastMiss = nil; lastAnswer = Date(); if failed { failed = false } }
    func arrived() { failingSince = nil; lastMiss = nil }
    func missed() {
        let now = Date()
        if failingSince == nil || now.timeIntervalSince(lastMiss ?? now) > 30 { failingSince = now }
        lastMiss = now
        if !failed, now.timeIntervalSince(failingSince!) >= TVModel.unreachableAfter { failed = true }
    }
}
struct DeviceTab: View {
    @Environment(TVModel.self) var model
    @Environment(\.paneLayout) private var panes
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var store = DeviceStore.shared
    var info: DeviceInfo? { store.info }
    // Out of touch: the Mac (said once, by the banner at the top, and dimmed with it), or only the box's own readings
    // while the Mac still answers. While the Mac's own reading is failing too, the box's wait for the banner, so the page
    // dims once, as the banner arrives (gate of 87d77ca: the pill said it again, and the tiles greyed, 2 s later).
    // A box failure counted from before the Mac came back is the outage's, and is never said as the TV's: it read "Can't
    // reach the TV" for a quarter second as the Mac returned (gate of f6d2272).
    var failed: Bool { !model.reachable || model.status?.online == false || (store.failed && !model.retrying && (store.failingSince.map { $0 > model.reachedAt } ?? false)) }
    @State private var tidying = false
    @State private var tidyNote: String?
    @State private var breathe = false
    // Closes the heavy apps left idle in the background, which is what fills the box's 2 GB until things stutter.
    func tidy() {
        model.tick(); tidying = true; tidyNote = nil
        Task {
            struct Answer: Decodable { let stopped: [String]; let availableMB: Int }
            if let d = try? await TVBridge.post("tidy", timeout: 40), let a = try? JSONDecoder().decode(Answer.self, from: d) {
                let free = a.availableMB >= 1024 ? String(format: "%.1f GB", Double(a.availableMB) / 1024) : "\(a.availableMB) MB"
                withAnimation(.snappy) { tidyNote = a.stopped.isEmpty ? "Nothing idle to close. \(free) available." : "Closed \(a.stopped.joined(separator: ", ")). \(free) available." }
            } else { withAnimation(.snappy) { tidyNote = "The TV didn’t answer." } }
            tidying = false
        }
    }
    // The same words as the Remote's, from the same reading: the television off over HDMI-CEC is "Asleep" there, so it
    // is here (it said "Awake" beside the Remote's "Asleep", gate of 8446178).
    var screenWords: String {
        guard let s = model.status else { return "Awake" }
        if s.screen == "asleep" { return "Asleep" }
        if let a = s.away { return a.line }
        if s.screen == "screensaver" { return "Screensaver" }
        return "Awake"
    }
    var hero: some View {
        VStack(spacing: 4) {
            // Fades in when it comes, rather than appearing in a frame.
            // Asked again once the box first answers: a picture asked for while the Mac was away stayed missing for good,
            // only its glow showing (gate of 87d77ca).
            Cover(url: TVBridge.url("/api/tv/device-image"), key: "device-image-\(info != nil)") { Color.clear }
                .frame(height: panes ? 260 : 170)
                .background(RadialGradient(colors: [.white.opacity(0.16), .clear], center: .center, startRadius: 4, endRadius: 110).frame(width: 240, height: 240))
                .accessibilityLabel("The TV box and its remote")
            // Until the box answers, the shape of its name rather than a made-up one, so nothing changes name as it loads.
            Text(info?.model ?? "onn. 4K Streaming Box").font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 6)
                .redacted(reason: info == nil ? .placeholder : [])
            Text(info.map { "Android \($0.android) · up \(span($0.uptime))" } ?? "Android 14 · up 1d 1h").font(.subheadline).foregroundStyle(.secondary)
                .redacted(reason: info == nil ? .placeholder : [])
            HStack(spacing: 6) {
                Circle().fill(failed ? TVLook.away : Color.green).frame(width: 9, height: 9)
                // The banner says the Mac is out of reach; the pill never says it again, only how old the readings are.
                if failed, !model.reachable || model.status?.online == false, let at = store.lastAnswer {
                    Text("Last seen \(Text(at, style: .time))")
                } else {
                    Text(!failed ? screenWords : model.reachable ? "Can’t reach the TV" : "No reading yet")
                }
            }
            .font(.footnote.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 5).tvCard(14).padding(.top, 6)
            // The dot's colour eases between green and orange, as the tiles do, rather than switching in a frame.
            .settledAnimation(.easeOut(duration: 0.3), value: failed)
        }
        .frame(maxWidth: .infinity)
    }
    // The tiles before the first answer: their shapes, breathing, so the page doesn't jump when the numbers come.
    // Stacks rather than a Grid, which sizes each column to a shape's tiny ideal width, so these fill the row as the
    // real tiles do.
    var waitingTiles: some View {
        VStack(spacing: 12) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 12) {
                    ForEach(0..<2, id: \.self) { _ in RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.08)).frame(maxWidth: .infinity).frame(height: 128) }
                }
            }
        }
        // Breathing by a plain repeating animation: a phase animator lays its content out at its natural size, and a
        // shape's natural width is next to nothing.
        .frame(maxWidth: .infinity)
        .opacity(breathe ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: breathe)
        .onAppear { breathe = true }
        .accessibilityHidden(true)
    }
    @ViewBuilder func tiles(_ i: DeviceInfo) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Tile(title: "CPU", value: "\(i.cpu)%", detail: "4 cores", spark: i.hist.cpu, top: 100)
                Tile(title: "Memory", value: bytes(i.memUsed), detail: "of \(bytes(i.memTotal))", spark: i.hist.mem, top: 100)
            }
            GridRow {
                Tile(title: "Download", value: rate(i.rxRate), detail: "", spark: i.hist.rx)
                // No subtitle on either: the box's IP address was plumbing, and the home network isn't news (gate 276).
                Tile(title: "Upload", value: rate(i.txRate), detail: "", spark: i.hist.tx)
            }
        }
        // Out of touch, the last numbers stay but step back, so they aren't read as live.
        .opacity(failed ? 0.4 : 1)
        .saturation(failed ? 0 : 1)
        .settledAnimation(.easeOut(duration: 0.3), value: failed)
    }
    @ViewBuilder func details(_ i: DeviceInfo) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Storage"); Spacer(); Text("\(bytes(i.diskUsed)) of \(bytes(i.diskTotal))").foregroundStyle(.secondary) }
                ProgressView(value: i.diskUsed, total: max(i.diskTotal, 1)).tint(i.diskUsed / max(i.diskTotal, 1) > 0.9 ? .red : TVLook.accent)
            }
            .padding(14)
            Divider()
            HStack { Text("Temperature"); Spacer(); Text("\(Int((i.tempC * 9 / 5 + 32).rounded()))°F").foregroundStyle(.secondary).monospacedDigit() }.padding(14)
            Divider()
            HStack { Text("Resolution"); Spacer(); Text(i.resolution.replacingOccurrences(of: "x", with: " × ")).foregroundStyle(.secondary) }.padding(14)
            Divider()
            // The television behind the box, as HDMI-CEC tells it: a row and its rule, or nothing while that isn't known.
            TelevisionRow(status: model.status)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: tidy) {
                    HStack(spacing: 8) {
                        if tidying { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        Text(tidying ? "Freeing up memory…" : "Free up memory")
                        Spacer()
                    }
                    .font(.body.weight(.medium)).foregroundStyle(TVLook.accent).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(tidying)
                Text(tidyNote ?? "Closes idle apps. Never what’s playing.")
                    .font(.footnote).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            .padding(14)
        }
        // The television's row comes and goes with the whole card easing, so the rows under it never move at a stroke.
        .settledAnimation(.easeOut(duration: 0.25), value: TelevisionRow.value(model.status?.cec))
        .tvCard()
        // Stepped back with the tiles, so the whole page reads as last seen, not half of it.
        .opacity(failed ? 0.4 : 1)
        .saturation(failed ? 0 : 1)
        .settledAnimation(.easeOut(duration: 0.3), value: failed)
    }
    // Asked for only while this tab is on screen, every 2 s (and so retried every 2 s while it fails). Leaving the tab, or
    // a push over it, cancels the task: whatever that cut short says nothing about the TV, and is dropped.
    func poll() async {
        guard phase == .active else { return }
        store.arrived()
        while !Task.isCancelled {
            let d = await TVBridge.data(TVBridge.url("/api/tv/device"), timeout: 8)
            if Task.isCancelled { return }
            if let d, let i = try? JSONDecoder().decode(DeviceInfo.self, from: d) {
                // The first answer just appears; only later changes ease, so the name never crossfades over a placeholder.
                if store.info == nil { store.info = i } else { withAnimation(.easeOut(duration: 0.25)) { store.info = i } }
                store.answered()
            } else { store.missed() }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
    // The scroll views are the body itself, with nothing wrapped round them, so the bar sees them and folds the title
    // away as the page scrolls, as on Apps and Watch.
    var body: some View {
        if panes {
            FoldSplit {
                // A scrolling page like the other side, so the two sides sit under the bar the same way.
                ScrollView {
                    hero.padding(20).containerRelativeFrame(.vertical, alignment: .center)
                }
                .backToTop(posed: false)
            } right: {
                ScrollView {
                    VStack(spacing: 18) { if let info { tiles(info); details(info) } else if !failed { waitingTiles } }.padding(20)
                        // The tiles fade in over their waiting shapes (the first answer is set with no animation, so the
                        // name over them doesn't crossfade; the shapes here are theirs to replace).
                        .settledAnimation(.easeOut(duration: 0.25), value: info == nil)
                        .task(id: phase) { await poll() }
                }
                .backToTop()
                .onChange(of: model.reachable) { _, back in if back { store.arrived(); if store.failed { store.failed = false } } }
            }
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    // As open: the tiles fade in over their shapes; the name above stays out of the fade.
                    Group { if let info { tiles(info); details(info) } else if !failed { waitingTiles } }
                        .settledAnimation(.easeOut(duration: 0.25), value: info == nil)
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                .task(id: phase) { await poll() }
            }
            .backToTop()
            .onChange(of: model.reachable) { _, back in if back { store.arrived(); if store.failed { store.failed = false } } }
        }
    }
}
