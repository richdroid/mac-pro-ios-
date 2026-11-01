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
            Path { p in
                guard values.count > 1 else { return }
                p.move(to: point(0))
                for i in 1..<values.count { p.addLine(to: point(i)) }
            }
            .stroke(TVLook.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 38)
    }
}
private struct Tile: View {
    let title: String, value: String, detail: String
    let spark: [Double]
    var top: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7).contentTransition(.numericText())
            Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Spark(values: spark, top: top).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .tvCard(16)
    }
}
struct DeviceTab: View {
    @EnvironmentObject var model: TVModel
    @Environment(\.paneLayout) private var panes
    @Environment(\.scenePhase) private var phase
    @State private var info: DeviceInfo?
    @State private var failed = false
    var hero: some View {
        VStack(spacing: 4) {
            Art(url: TVBridge.url("/api/tv/device-image")) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(height: panes ? 260 : 170)
                .background(RadialGradient(colors: [.white.opacity(0.16), .clear], center: .center, startRadius: 4, endRadius: 110).frame(width: 240, height: 240))
                .accessibilityLabel("The TV box and its remote")
            Text(info?.model ?? "Google TV").font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 6)
            if let i = info { Text("Android \(i.android) · up \(span(i.uptime))").font(.subheadline).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                Circle().fill(failed ? Color.orange : Color.green).frame(width: 9, height: 9)
                Text(failed ? "Can’t reach it" : model.status?.screen == "asleep" ? "Asleep" : "Awake")
            }
            .font(.footnote.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 5).tvCard(14).padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
    @ViewBuilder func tiles(_ i: DeviceInfo) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Tile(title: "CPU", value: "\(i.cpu)%", detail: "4 cores", spark: i.hist.cpu, top: 100)
                Tile(title: "Memory", value: bytes(i.memUsed), detail: "of \(bytes(i.memTotal))", spark: i.hist.mem, top: 100)
            }
            GridRow {
                Tile(title: "Download", value: rate(i.rxRate), detail: i.wifi.isEmpty ? "Wi-Fi" : i.wifi, spark: i.hist.rx)
                Tile(title: "Upload", value: rate(i.txRate), detail: i.ip, spark: i.hist.tx)
            }
        }
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
            HStack { Text("Resolution"); Spacer(); Text(i.resolution).foregroundStyle(.secondary) }.padding(14)
        }
        .tvCard()
    }
    var body: some View {
        Group {
            if panes {
                FoldSplit {
                    hero.padding(20).frame(maxHeight: .infinity)
                } right: {
                    ScrollView { if let info { VStack(spacing: 18) { tiles(info); details(info) }.padding(20) } }
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        hero
                        if let info { tiles(info); details(info) }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
        }
        .task(id: phase) {
            // Asked for only while this tab is on screen.
            guard phase == .active else { return }
            while !Task.isCancelled {
                if let d = await TVBridge.data(TVBridge.url("/api/tv/device"), timeout: 8), let i = try? JSONDecoder().decode(DeviceInfo.self, from: d) {
                    withAnimation(.easeOut(duration: 0.25)) { info = i }
                    failed = false
                } else { failed = true }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
