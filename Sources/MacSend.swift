import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Send to Mac (Richard, 2026-11-10: "use tailscale for sending files to mac in mac pro app"). Files go to the bridge over
// the tailnet only (the public door refuses them) and land in ~/Downloads/From iPhone under their own names. Built into
// the app and into its share extension (MacProShare), so both send the same way: streamed from a file on disk, never the
// whole file in memory, with real progress, a done tick, and a reason with Try again when it fails.

// One file in ~/Downloads/From iPhone, as /api/files/recent lists it (newest first).
struct SentFile: Decodable, Identifiable, Hashable {
    let name: String
    let size: Double
    let at: Double
    var dir: Bool? = false
    var id: String { name }
}

enum MacFiles {
    static func origin(_ base: URL) -> String { "\(base.scheme ?? "https")://\(base.host ?? "")\(base.port.map { ":\($0)" } ?? "")" }
    private static func post(_ base: URL, _ path: String) -> URLRequest? {
        guard let u = URL(string: path, relativeTo: base) else { return nil }
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        // The bridge refuses posts from other sites: say which site this is, as the app's other posts do.
        r.setValue(origin(base), forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash")
        return r
    }
    static func query(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&+=#?")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
    // What the Mac's refusal says, in his words.
    static func reason(_ code: Int, _ data: Data) -> String {
        let said = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch code {
        case 404 where said?.contains("Tailscale") == true: return "The Mac takes files over Tailscale only. Turn Tailscale on and try again."
        case 404: return "This Mac doesn’t take files yet. Its Mac dashboard needs updating."
        case 413: return "That file is too big for the Mac to take."
        case 401, 403: return "The Mac didn’t accept this iPhone. Open the Mac Pro app and sign in."
        default: return said.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? "The Mac couldn’t save it (error \(code))."
        }
    }
    // A failure that's the Mac being out of reach, worth asking again for a few seconds (Tailscale wakes after the app).
    static func unreachable(_ e: Error) -> Bool {
        guard let u = e as? URLError else { return false }
        return [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut, .networkConnectionLost,
                .secureConnectionFailed, .internationalRoamingOff, .dataNotAllowed].contains(u.code)
    }

    // Streams one file to the Mac and returns the name it was saved as ("name 2.ext" when the name was taken).
    static func send(_ file: URL, as name: String, size: Int64, to base: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        guard var r = post(base, "/api/files/send?name=\(query(name))") else { throw SendError.say("The Mac’s address isn’t right.") }
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.setValue(String(size), forHTTPHeaderField: "Content-Length")
        // Without a word for a minute, it has stalled; a big file keeps going as long as bytes move.
        r.timeoutInterval = 60
        let watch = UploadWatch(progress)
        let (data, resp) = try await URLSession.shared.upload(for: r, fromFile: file, delegate: watch)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SendError.say(reason(code, data)) }
        struct Answer: Decodable { let name: String? }
        return (try? JSONDecoder().decode(Answer.self, from: data).name) ?? name
    }
    static func recent(_ base: URL) async throws -> [SentFile] {
        struct Answer: Decodable { let files: [SentFile] }
        guard let u = URL(string: "/api/files/recent", relativeTo: base) else { throw SendError.say("The Mac’s address isn’t right.") }
        var r = URLRequest(url: u); r.timeoutInterval = 10; r.cachePolicy = .reloadIgnoringLocalCacheData
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SendError.say(reason(code, d)) }
        return try JSONDecoder().decode(Answer.self, from: d).files
    }
    // Shows the file selected in a Finder window on the Mac.
    static func reveal(_ name: String, on base: URL) async throws {
        guard var r = post(base, "/api/files/reveal?name=\(query(name))") else { throw SendError.say("The Mac’s address isn’t right.") }
        r.timeoutInterval = 10
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw SendError.say(code == 404 ? "It’s not in From iPhone any more." : reason(code, d)) }
    }

    // A file's size, read from disk.
    static func size(_ u: URL) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
    // A private folder of its own for each copy, so two files with one name never meet.
    static func holding(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("send", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(clean(name))
    }
    // A name the Mac can save: no folders in it, never empty.
    static func clean(_ name: String) -> String {
        let n = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty || n.hasPrefix(".") ? "File" + n : n
    }
    // Copies a file the system lends for a moment (a picked file, a shared photo) into the folder this side owns.
    static func keep(_ lent: URL, named: String? = nil) throws -> URL {
        let dest = holding(named ?? lent.lastPathComponent)
        let scoped = lent.startAccessingSecurityScopedResource()
        defer { if scoped { lent.stopAccessingSecurityScopedResource() } }
        var failure: Error?
        var coordinated: NSError?
        NSFileCoordinator().coordinate(readingItemAt: lent, options: .withoutChanges, error: &coordinated) { u in
            do { try FileManager.default.copyItem(at: u, to: dest) } catch { failure = error }
        }
        if let e = failure ?? coordinated { throw e }
        return dest
    }

    static func symbol(_ name: String) -> String {
        let t = UTType(filenameExtension: (name as NSString).pathExtension)
        if t?.conforms(to: .movie) == true { return "film" }
        if t?.conforms(to: .image) == true { return "photo" }
        if t?.conforms(to: .pdf) == true { return "doc.richtext" }
        if t?.conforms(to: .internetShortcut) == true || (name as NSString).pathExtension.lowercased() == "webloc" { return "link" }
        if t?.conforms(to: .plainText) == true { return "doc.plaintext" }
        if t?.conforms(to: .archive) == true { return "doc.zipper" }
        if t?.conforms(to: .audio) == true { return "waveform" }
        return "doc"
    }
    static func bytes(_ b: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }
}

enum SendError: LocalizedError {
    case say(String)
    var errorDescription: String? { if case .say(let s) = self { return s }; return nil }
}

// Hands the upload's progress on as it goes.
final class UploadWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void
    init(_ p: @escaping @Sendable (Double) -> Void) { progress = p }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// One file on its way to the Mac: being made ready (a photo coming from iCloud), waiting its turn, sending, sent or failed.
@MainActor
final class SendJob: ObservableObject, Identifiable {
    enum State: Equatable { case preparing, waiting, sending(Double), done(String), failed(String) }
    let id = UUID()
    @Published var name: String
    @Published var state: State
    @Published var size: Int64 = 0
    var file: URL?
    init(name: String, file: URL? = nil) {
        self.name = name; self.file = file
        state = file == nil ? .preparing : .waiting
        if let file { size = MacFiles.size(file) }
    }
    var finished: Bool { if case .done = state { return true }; return false }
    var failed: Bool { if case .failed = state { return true }; return false }
    var busy: Bool { switch state { case .preparing, .waiting, .sending: return true; default: return false } }
    // What the row says under the name.
    var line: String {
        switch state {
        case .preparing: return "Getting it ready…"
        case .waiting: return size > 0 ? "Waiting · \(MacFiles.bytes(Double(size)))" : "Waiting"
        case .sending(let p): return "\(Int((p * 100).rounded(.down))) % of \(MacFiles.bytes(Double(size)))"
        case .done(let saved): return saved == name ? "Sent · \(MacFiles.bytes(Double(size)))" : "Sent as “\(saved)”"
        case .failed(let why): return why
        }
    }
}

// The files on their way, one at a time in the order chosen.
@MainActor
final class SendQueue: ObservableObject {
    @Published private(set) var jobs: [SendJob] = []
    // True while anything is on its way, so the app can ask for time to finish in the background.
    @Published private(set) var busy = false
    let base: () -> URL?
    var onSent: ((SendJob) -> Void)?
    private var pumping = false
    init(base: @escaping () -> URL?) { self.base = base }

    func add(_ job: SendJob) { jobs.append(job); job.objectWillChange.send(); pump() }
    // A job made ready (its copy is on disk): it takes its turn.
    func ready(_ job: SendJob, file: URL, name: String) {
        job.file = file; job.name = name; job.size = MacFiles.size(file); job.state = .waiting
        pump()
    }
    func fail(_ job: SendJob, _ why: String) { job.state = .failed(why) }
    func retry(_ job: SendJob) { guard job.failed, job.file != nil else { return }; job.state = .waiting; pump() }
    func remove(_ job: SendJob) {
        let wasSending: Bool = { if case .sending = job.state { return true }; return false }()
        jobs.removeAll { $0.id == job.id }
        if wasSending { current?.cancel(); current = nil; pumping = false }
        if let f = job.file { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        job.file = nil
        busy = jobs.contains { $0.busy }
        pump()
    }
    func cancelAll() {
        current?.cancel()
        for j in jobs { if let f = j.file { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) } }
        jobs = []; busy = false
    }
    private var current: Task<Void, Never>?

    private func pump() {
        busy = jobs.contains { $0.busy }
        guard !pumping else { return }
        pumping = true
        current = Task { [weak self] in
            while let self, !Task.isCancelled, let job = self.jobs.first(where: { $0.state == .waiting }) {
                await self.send(job)
            }
            guard !Task.isCancelled else { return }
            self?.pumping = false
            self?.busy = self?.jobs.contains { $0.busy } ?? false
        }
    }

    private func send(_ job: SendJob) async {
        guard let file = job.file else { job.state = .failed("The file wasn’t ready."); return }
        guard let base = base() else { job.state = .failed("This iPhone doesn’t know the Mac’s address yet. Open the Mac Pro app once."); return }
        job.state = .sending(0)
        // Out of reach is only said after ~10 s of asking: Tailscale often wakes a moment after the phone does.
        var firstMiss: Date?
        while !Task.isCancelled {
            do {
                let saved = try await MacFiles.send(file, as: job.name, size: job.size, to: base) { p in
                    Task { @MainActor in if case .sending = job.state { job.state = .sending(min(p, 0.99)) } }
                }
                job.state = .done(saved)
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                job.file = nil
                onSent?(job)
                return
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                if MacFiles.unreachable(error) {
                    let now = Date()
                    if firstMiss == nil { firstMiss = now }
                    if now.timeIntervalSince(firstMiss!) < 10 {
                        job.state = .sending(0)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    job.state = .failed("Can’t reach the Mac. Is Tailscale on?")
                } else {
                    job.state = .failed(error.localizedDescription)
                }
                return
            }
        }
    }
}

// A file's row while it's on its way: what it is, how far it has got, a tick when it's there, the reason and Try again
// when it isn't. Used by the app and by the share sheet's card.
struct SendJobRow: View {
    @ObservedObject var job: SendJob
    let retry: () -> Void
    var tint: Color = .accentColor
    // Stops a send, or clears one that failed; nil where there's nowhere for it to go.
    var remove: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: MacFiles.symbol(job.name)).font(.body).foregroundStyle(.secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                if case .sending(let p) = job.state {
                    ProgressView(value: p).tint(tint)
                        .animation(.linear(duration: 0.2), value: p)
                }
                Text(job.line).font(.footnote).foregroundStyle(job.failed ? Color.red : Color.secondary)
                    .monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch job.state {
            case .done: Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green).transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Sent")
            case .failed: if job.file != nil { Button("Try again", action: retry).buttonStyle(.bordered).controlSize(.small) }
            case .preparing: ProgressView().controlSize(.small)
            default: EmptyView()
            }
            if let remove, !job.finished {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical).foregroundStyle(.primary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(job.failed ? "Remove" : "Stop sending")
            }
        }
        // The divider under a row starts at its name, as under every other row in the card.
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] + 38 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: job.state)
        .padding(.vertical, 2)
    }
}
