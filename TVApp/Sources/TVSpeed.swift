import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

// Everything that makes a flick quicker than the TV would be on its own: streams asked for before they're needed, the
// TV made ready while the card is still in the hand, and the start followed as it happens rather than polled for.

// Stream lists, kept for ten minutes. A card's press asks for its list, so by the time the flick screen opens it's
// usually here. Only answers with streams in them are kept, and only one question is ever in flight for a title.
@MainActor
final class StreamCache {
    static let shared = StreamCache()
    private struct Entry { let at: Date; let task: Task<[StremioStream]?, Never> }
    private var entries: [String: Entry] = [:]
    private static let fresh: TimeInterval = 600
    static func key(_ type: String, _ imdb: String, _ video: String) -> String { "\(type)/\(imdb)/\(video)" }
    func streams(type: String, imdb: String, video: String, again: Bool = false) async -> [StremioStream]? {
        let k = Self.key(type, imdb, video)
        if !again, let e = entries[k], Date().timeIntervalSince(e.at) < Self.fresh {
            if let s = await e.task.value, !s.isEmpty { return s }
        }
        let term = video.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? video
        let address = TVBridge.url("/api/tv/streams?type=\(type)&id=\(imdb)&video=\(term)")
        let task = Task<[StremioStream]?, Never> {
            struct Answer: Decodable { let streams: [StremioStream] }
            guard let d = await TVBridge.data(address, timeout: 25) else { return nil }
            return (try? JSONDecoder().decode(Answer.self, from: d))?.streams
        }
        entries[k] = Entry(at: Date(), task: task)
        let s = await task.value
        // Nothing found is worth asking again for next time.
        if s?.isEmpty != false, entries[k]?.task == task { entries[k] = nil }
        return s
    }
    // An episode row under a finger ("tt…:s:e"): its list asked for now, so the tap that follows finds it on its way
    // (an episode's list not asked for ahead took 0.5–1.3 s after the tap, 07:17–07:24Z on 11-11).
    func prefetch(episode video: String) {
        guard let imdb = video.split(separator: ":").first.map(String.init), imdb.hasPrefix("tt"), video.contains(":") else { return }
        let k = Self.key("series", imdb, video)
        if let e = entries[k], Date().timeIntervalSince(e.at) < Self.fresh { return }
        Task { _ = await streams(type: "series", imdb: imdb, video: video) }
    }
    // A list that turned out stale: the next look asks afresh.
    func forget(type: String, imdb: String, video: String) { entries[Self.key(type, imdb, video)] = nil }
    // Pressed on a card: a film, or an episode already named, has a list worth fetching now. A series still to have
    // its episode picked doesn't.
    // When a card was last pressed, for timing press → first stream row on the phone.
    static var pressedAt: Date?
    func prefetch(_ item: MediaItem) {
        Self.pressedAt = Date()
        guard let ref = item.stremioRef, ref.type == "movie" || ref.video != nil else { return }
        // And its link resolved on the TV now (a details page opened, a card pressed, a search's first results): a pick
        // whose link wasn't resolved ahead took 7.5 to 13 s to play, one that was, 3 to 4.5 s (real TV, 2026-11-10).
        Warm.ask(type: ref.type, imdb: ref.imdb, video: ref.video)
        let k = Self.key(ref.type, ref.imdb, ref.video ?? ref.imdb)
        if let e = entries[k], Date().timeIntervalSince(e.at) < Self.fresh { return }
        Task { _ = await streams(type: ref.type, imdb: ref.imdb, video: ref.video ?? ref.imdb) }
    }
}

// A title's link resolved on the TV ahead of a pick, wherever one can begin. Nothing else happens there: the TV isn't
// woken and nothing opens. The Mac does one at a time and never while something plays; here, the same title isn't
// asked for again within ten minutes.
enum Warm {
    @MainActor private static var asked: [String: Date] = [:]
    @MainActor static func ask(type: String, imdb: String, video: String?) {
        guard type == "movie" || video != nil else { return }
        let key = "\(type)/\(imdb)/\(video ?? imdb)"
        if let at = asked[key], Date().timeIntervalSince(at) < 600 { return }
        if asked.count > 60 { asked.removeAll() }
        asked[key] = Date()
        var body: [String: Any] = ["type": type, "imdb": imdb]
        if let video { body["video"] = video }
        Task { _ = try? await TVBridge.post("warm", body, timeout: 15) }
    }
}

// The TV made ready for a stream while the card is still in the hand: woken if it's asleep, and Stremio cleared if it
// has no player open. Harmless if he puts the card down, and the Mac skips both in the start itself if this ran lately.
// With what's coming (type, imdb, video, and the stream's token once it's chosen), the Mac can also warm that stream's
// link on the TV ahead of the throw (§2.5a C6). The same ask isn't repeated within 20 s; a new one (a token now known) is.
enum Prepare {
    @MainActor private static var last = (key: "", at: Date.distantPast)
    @MainActor static func arm(_ body: [String: Any] = [:]) {
        let key = body.keys.sorted().map { "\($0)=\(body[$0] ?? "")" }.joined(separator: "&")
        guard key != last.key || Date().timeIntervalSince(last.at) > 20 else { return }
        last = (key, Date())
        Task { _ = try? await TVBridge.post("prepare", body, timeout: 20) }
    }
}

// How long each part of a flick took, on this phone's clock, for the Mac's log (its `timing` route), so real flicks can be
// timed from the bridge: touch, release, request, impact, remote, the phases, playing, answer. One flick at a time, held
// here rather than in the flick screen, which closes long before the TV plays. Sent once, when both the answer and the
// landing on the Remote are in (or 25 s on, whatever there is). Never in the way: a failure is dropped.
@MainActor
final class FlickClock {
    static private(set) var current = FlickClock()
    private var events: [(String, Double)] = []
    private var answered = false, landed = false, sent = false
    private static var touchAt: Double?
    static func now() -> Double { Date().timeIntervalSince1970 * 1000 }
    // The card picked up: kept for the throw that may follow.
    static func touched() { touchAt = now() }
    // The release: a new flick, starting with its touch if there was one.
    static func begin() {
        current.flush()
        let c = FlickClock()
        if let t = touchAt { c.events.append(("touch", t)) }
        touchAt = nil
        c.mark("release")
        current = c
        Task { [weak c] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            c?.flush()
        }
    }
    func mark(_ name: String) { events.append((name, Self.now())) }
    // The answer, or the failure: sent once the Remote's landing is in too (it may come either side).
    func finished(onStage: Bool = false) { answered = true; if landed || onStage { flush() } }
    func remoteLanded() { mark("remote"); landed = true; if answered { flush() } }
    func flush() {
        guard !sent, !events.isEmpty else { return }
        sent = true
        let body: [String: Any] = ["events": events.map { ["name": $0.0, "at": $0.1] }]
        Task { _ = try? await TVBridge.post("timing", body, timeout: 10) }
    }
}

// The streams the Mac tried under the last send that failed (the pick and its fallbacks).
// Only those whose player came up and never played (or errored); one that never got a player isn't among them and stays
// his to pick. Nil when the Mac didn't say (an older one).
@MainActor enum TriedStreams { static var last: [String]? }
extension TVBridge {
    // The start of a stream, followed as the Mac reports it: a line as the TV wakes, as Stremio opens, as its player
    // comes up and as the film plays, then the answer. A Mac from before this answers once, at the end, in the old way,
    // and that's taken as it always was. Each line goes to `phase` as it comes; `opened` says which kind of answer it is.
    static func playStream(_ body: [String: Any], timeout: TimeInterval = 60,
                           opened: @escaping @MainActor (Bool) -> Void,
                           phase: @escaping @MainActor (String) -> Void) async throws -> Data {
        guard let u = url("/api/tv/play-stream"), let base = URL(string: address) else { throw URLError(.badURL) }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: r)
        let http = resp as? HTTPURLResponse
        let streamed = http?.statusCode == 200 && (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("ndjson")
        await opened(streamed)
        if !streamed {
            // The old way: one answer, its meaning in the status.
            var d = Data()
            for try await b in bytes { d.append(b) }
            return try answer(d, code: http?.statusCode)
        }
        for try await line in bytes.lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let d = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let p = j["phase"] as? String { await phase(p); continue }
            if j["ok"] as? Bool == true { return d }
            if j["error"] != nil || j["failed"] != nil {
                // Every stream the Mac tried, kept for the flick to set apart; and a start called off (his own Home, another
                // app, a newer send) is not a failure.
                if j["failed"] as? String == "start" { await MainActor.run { TriedStreams.last = j["tried"] as? [String] }; throw DidNotStart() }
                if j["error"] as? String == "Stopped" { throw CancellationError() }
                if j["retry"] as? Bool == true { throw Slow() }
                if j["failed"] as? String == "gone" || j["gone"] as? Bool == true { throw Gone() }
                throw TVIntentError.noAnswer
            }
        }
        // Cut off before the answer.
        throw TVIntentError.noAnswer
    }
    // What a whole answer means, as `post` reads it.
    private static func answer(_ d: Data, code: Int?) throws -> Data {
        if code == 409 {
            let retry = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["retry"] as? Bool == true
            throw retry ? Slow() as Error : Gone()
        }
        if code == 422, (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["failed"] as? String == "start" { throw DidNotStart() }
        guard code == 200 else { throw TVIntentError.noAnswer }
        return d
    }
}

// For the build's poses only: every frame that takes longer than 34 ms, with when it was, sent to the stand-in Mac, which
// writes them to a log the build keeps. Stalls come out as numbers rather than being read off a film (r21).
#if os(iOS)
@MainActor
final class HitchLog: NSObject {
    static let shared = HitchLog()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var hitches: [[String: Any]] = []
    private var flushing: Task<Void, Never>?
    func start() {
        guard link == nil, UserDefaults.standard.string(forKey: "pose") != nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    // A check a pose makes that failed, sent with the hitches so the build can say so loudly.
    func assertFailed(_ note: String) {
        guard UserDefaults.standard.string(forKey: "pose") != nil else { return }
        print("ASSERT \(note)")
        Task { _ = try? await TVBridge.post("hitch", ["hitches": [["ms": 0, "at": Date().timeIntervalSince1970 * 1000, "note": note]]], timeout: 5) }
    }
    // What he just did (a tab changed, a page pushed or popped), written between the slow frames with its own time, so the
    // log says which move each stall belongs to. Only in the build's films run with -swipeLog YES; never on the phone.
    func note(_ text: String) {
        guard link != nil, SwipeLog.on else { return }
        hitches.append(["ms": 0, "at": Date().timeIntervalSince1970 * 1000, "mark": text])
        SwipeLog.note(text)
        flushSoon()
    }
    private func flushSoon() {
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self else { return }
            let batch = self.hitches; self.hitches = []; self.flushing = nil
            if !batch.isEmpty { _ = try? await TVBridge.post("hitch", ["hitches": batch], timeout: 5) }
        }
    }
    @objc private func tick(_ l: CADisplayLink) {
        defer { last = l.timestamp }
        guard last > 0 else { return }
        let gap = (l.timestamp - last) * 1000
        guard gap > 34 else { return }
        hitches.append(["ms": Int(gap), "at": Date().timeIntervalSince1970 * 1000])
        print("HITCH \(Int(gap)) ms")
        flushSoon()
    }
}
#endif
