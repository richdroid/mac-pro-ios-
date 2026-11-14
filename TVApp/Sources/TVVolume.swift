import SwiftUI

// The Remote's volume: − and + beside the pad, a slim level bar under it. It sets the box's own HDMI volume through the
// Mac's "setting" (never the CEC volume keys: the Sony ignores them). What's shown moves at once and is corrected by the
// next status once the Mac has had time to apply it.
@MainActor
final class VolumeModel: ObservableObject {
    static let shared = VolumeModel()
    @Published private(set) var level: Int?
    private var heldAt = Date.distantPast
    private var sending: Task<Void, Never>?
    func shown(_ status: Int?) -> Int? { level ?? status }
    // The TV's own reading wins once nothing of ours is in flight (or after 4 s).
    func sync(_ status: Int?) {
        guard sending == nil, Date().timeIntervalSince(heldAt) > 4 || status == level else { return }
        if level != nil { level = nil }
    }
    func step(_ d: Int, status: Int?, max: Int) {
        guard let base = level ?? status else { return }
        let v = min(max, Swift.max(0, base + d))
        guard v != level else { return }
        level = v; heldAt = Date()
        sending?.cancel()
        sending = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            do { try await TVBridge.post("setting", ["key": "volume", "value": v]) } catch { if !Task.isCancelled { level = nil } }
            if !Task.isCancelled { sending = nil }
        }
    }
}

struct VolumeKey: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var vol = VolumeModel.shared
    let down: Bool, size: CGFloat
    @GestureState private var touching = false
    @State private var held: Task<Void, Never>?
    var step: Int { down ? -1 : 1 }
    func go() { vol.step(step, status: model.status?.volume, max: model.status?.volumeMax ?? 25) }
    func begin() {
        guard held == nil else { return }
        model.tick(); go()
        held = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            while !Task.isCancelled { go(); try? await Task.sleep(nanoseconds: 110_000_000) }
        }
    }
    func end() { held?.cancel(); held = nil }
    var body: some View {
        Image(systemName: down ? "speaker.minus.fill" : "speaker.plus.fill")
            .font(.system(size: size * 0.36, weight: .medium)).frame(width: size, height: size).contentShape(Circle())
            .scaleEffect(touching ? 0.92 : 1).animation(TVLook.press, value: touching)
            .keyGlass()
            .gesture(DragGesture(minimumDistance: 0).updating($touching) { _, s, _ in s = true }.onChanged { _ in begin() }.onEnded { _ in end() })
            .onChange(of: touching) { _, now in if !now { end() } }
            .onDisappear { end() }
            .accessibilityLabel(down ? "Volume down" : "Volume up")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { go() }
    }
}

// The level, as a slim bar the pad's width.
struct VolumeBar: View {
    @Environment(TVModel.self) var model
    @ObservedObject private var vol = VolumeModel.shared
    var body: some View {
        let mx = Double(max(1, model.status?.volumeMax ?? 25)), v = Double(vol.shown(model.status?.volume) ?? 0)
        Capsule().fill(.white.opacity(0.16)).frame(height: 6)
            .overlay(alignment: .leading) { GeometryReader { g in Capsule().fill(.white.opacity(0.85)).frame(width: g.size.width * min(1, v / mx)) } }
            .accessibilityElement().accessibilityLabel("Volume").accessibilityValue("\(Int(v)) of \(Int(mx))")
            .onChange(of: model.status?.volume) { _, s in vol.sync(s) }
    }
}
