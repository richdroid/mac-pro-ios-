import SwiftUI

// Which speaker the Mac plays through (it is an AirPlay speaker too), Bluetooth included: a small system sheet from the
// Remote's heading. Richard, 2026-11-24: "like i can choose a bluetooth device on phone in tv app". Hidden while the
// bridge has no /api/mac/audio (404).
struct MacAudio: Decodable, Equatable {
    struct Output: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let kind: String
        var paired: Bool?
        var connected: Bool?
        var current: Bool?
        var symbol: String {
            switch kind {
            case "bluetooth": return "headphones"
            case "builtin": return "macpro.gen3"
            case "hdmi": return "tv"
            default: return "hifispeaker"
            }
        }
    }
    struct AirPlay: Decodable, Equatable { var running: Bool?, playing: Bool?, title: String?, artist: String? }
    var outputs: [Output]
    var airplay: AirPlay?
}

@MainActor @Observable
final class SpeakerStore {
    static let shared = SpeakerStore()
    // nil: not asked yet; false: the bridge has no such endpoint, so the key stays hidden.
    private(set) var available: Bool?
    private(set) var audio: MacAudio?
    private(set) var failed = false
    private(set) var choosing: String?
    private(set) var note: String?
    // When the bridge was last asked. A 404 (an older bridge, or the public link, which only Tailscale may use) or no
    // answer at all is asked again on a later visit, a minute on, rather than hiding the key for the whole launch.
    private var askedAt = Date.distantPast
    func loadIfDue() async {
        if available == true || Date().timeIntervalSince(askedAt) > 60 { await load() }
    }
    // A note from an earlier choice isn't news the next time the sheet opens.
    func clearNote() { note = nil }
    func load() async {
        guard let u = TVBridge.url("/api/mac/audio") else { return }
        askedAt = Date()
        var r = URLRequest(url: u); r.timeoutInterval = 8; r.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let code = (resp as? HTTPURLResponse)?.statusCode else {
            if available == true { failed = true }
            return
        }
        if code == 404 { available = false; return }
        guard code == 200, let a = try? JSONDecoder().decode(MacAudio.self, from: d) else { failed = available == true; return }
        available = true; failed = false
        if a != audio { audio = a }
    }
    func choose(_ o: MacAudio.Output) async {
        // Already the one playing: nothing to ask the Mac.
        if o.current == true { Haptic.fire(.tick); return }
        guard choosing == nil, let u = TVBridge.url("/api/mac/audio/select"), let base = URL(string: TVBridge.address) else { return }
        choosing = o.id; note = nil
        Haptic.fire(.tap)
        // Connecting a Bluetooth pair can take the Mac up to ~27 s (12 s to connect, up to 10 s for it to appear, then the
        // switch), so the phone waits longer than that before calling it a failure.
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 35
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["id": o.id])
        let answer = (try? await URLSession.shared.data(for: r)).flatMap { try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any] }
        let ok = answer?["ok"] as? Bool == true
        note = (answer?["say"] as? String) ?? (ok ? nil : "Couldn’t switch to \(o.name).")
        choosing = nil
        Haptic.fire(ok ? .tick : .thunk)
        await load()
    }
}

// The Remote heading's key; nothing at all while the bridge can't say.
struct SpeakerKey: View {
    @State private var store = SpeakerStore.shared
    @State private var open = false
    var body: some View {
        Group {
            if store.available == true {
                Button { open = true } label: {
                    Image(systemName: "hifispeaker.2").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.white.opacity(0.12), in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speaker")
                .sheet(isPresented: $open) { SpeakerSheet().presentationDetents([.medium, .large]) }
            }
        }
        .task { await store.loadIfDue() }
    }
}

struct SpeakerSheet: View {
    @State private var store = SpeakerStore.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let a = store.audio {
                    Section {
                        ForEach(a.outputs) { o in
                            Button { Task { await store.choose(o) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: o.symbol).frame(width: 28).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(o.name).foregroundStyle(.primary)
                                        if o.kind == "bluetooth", o.connected != true {
                                            Text(store.choosing == o.id ? "Connecting…" : "Not connected").font(.footnote).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if store.choosing == o.id { ProgressView() }
                                    else if o.current == true { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(TVLook.accent) }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(store.choosing != nil)
                            .accessibilityAddTraits(o.current == true ? .isSelected : [])
                        }
                    } footer: {
                        if let n = store.note { Text(n) }
                        else if let p = a.airplay, p.playing == true, let t = p.title, !t.isEmpty { Text("Playing over AirPlay: " + ([t] + [p.artist].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " · ")) }
                    }
                } else if store.failed {
                    ContentUnavailableView { Label("Can’t reach the Mac", systemImage: "wifi.exclamationmark") } actions: {
                        Button("Try Again") { Task { await store.load() } }
                    }
                } else {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Speaker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { await store.load() }
        }
        .task {
            store.clearNote()
            await store.load()
            // A Bluetooth device coming or going shows while the sheet is up.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 4_000_000_000); if store.choosing == nil { await store.load() } }
        }
    }
}
