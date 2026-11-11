import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// "Send a file" on the Control tab, with the Mac's own controls: photos or files, several at once, each with its progress,
// a tick, or the reason and Try again; then the recent sends, each with Show in Finder on the Mac.

// The app's sends, kept above the tabs so unfolding or leaving Control doesn't lose them.
@MainActor
final class AppSends: ObservableObject {
    static let shared = AppSends()
    let queue = SendQueue(base: { URL(string: SavedAddress.value).flatMap { $0.host == nil ? nil : $0 } })
    @Published var recent: [SentFile] = []
    @Published var recentFailed = false
    private var misses = MissClock()
    #if canImport(UIKit)
    private var background: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var watching: Any?
    private init() {
        // A sent file joins the recent list once its tick has been seen; its row then leaves the sends in flight.
        queue.onSent = { [weak self] job in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                await self?.loadRecent()
                withAnimation(Motion.quick) { self?.queue.remove(job) }
            }
        }
        // Time to finish a send if he leaves the app mid-way.
        watching = queue.$busy.removeDuplicates().sink { [weak self] busy in
            #if canImport(UIKit)
            guard let self else { return }
            if busy, self.background == .invalid {
                self.background = UIApplication.shared.beginBackgroundTask(withName: "Send to Mac") { [weak self] in self?.endBackground() }
            } else if !busy { self.endBackground() }
            #endif
        }
    }
    #if canImport(UIKit)
    private func endBackground() { if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid } }
    #endif

    func loadRecent() async {
        guard let base = queue.base() else { return }
        do { recent = try await MacFiles.recent(base); misses.hit(); recentFailed = false }
        catch is CancellationError {}
        catch { if misses.miss() { recentFailed = true } }
    }

    // Photos, in the order picked: each one's original file (as it is in the library, not converted) under its own name.
    func add(photos items: [PhotosPickerItem]) {
        for item in items {
            let job = SendJob(name: "Photo")
            queue.add(job)
            Task {
                do {
                    guard let picked = try await item.loadTransferable(type: PickedFile.self) else { queue.fail(job, "That photo couldn’t be read."); return }
                    queue.ready(job, file: picked.url, name: picked.url.lastPathComponent)
                } catch {
                    queue.fail(job, "That photo couldn’t be read from the library.")
                }
            }
        }
    }
    func add(files urls: [URL]) {
        for u in urls {
            let job = SendJob(name: u.lastPathComponent)
            queue.add(job)
            Task.detached(priority: .userInitiated) {
                do {
                    let kept = try MacFiles.keep(u)
                    await MainActor.run { self.queue.ready(job, file: kept, name: kept.lastPathComponent) }
                } catch {
                    await MainActor.run { self.queue.fail(job, "That file couldn’t be opened.") }
                }
            }
        }
    }

    // The build's shot of sends in flight: one going, one sent, one that failed with its reason. Never on the phone.
    func pose() {
        guard queue.jobs.isEmpty else { return }
        let a = SendJob(name: "IMG_4127.HEIC"); a.size = 3_400_000; a.state = .sending(0.46)
        let b = SendJob(name: "Lease renewal.pdf"); b.size = 820_000; b.state = .done("Lease renewal 2.pdf")
        let tmp = MacFiles.holding("Trip.mov"); FileManager.default.createFile(atPath: tmp.path, contents: Data(count: 16))
        let c = SendJob(name: "Trip.mov", file: tmp); c.size = 48_000_000; c.state = .failed("Can’t reach the Mac. Is Tailscale on?")
        for j in [b, a, c] { queue.add(j) }
    }
}

// A photo or video from the library, copied to a file this app owns, under the name the library gives it.
struct PickedFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { PickedFile(url: try MacFiles.keep($0.file, named: name($0.file, .movie))) }
        FileRepresentation(importedContentType: .image) { PickedFile(url: try MacFiles.keep($0.file, named: name($0.file, .image))) }
        FileRepresentation(importedContentType: .item) { PickedFile(url: try MacFiles.keep($0.file, named: name($0.file, .data))) }
    }
    // The library's own file name when it has one; a dated one otherwise ("Photo 2026-11-10 at 14.03.07.heic").
    static func name(_ u: URL, _ kind: UTType) -> String {
        let n = u.lastPathComponent, ext = u.pathExtension
        if !n.isEmpty, !n.contains("="), n.count < 80, !UUID.looksLike(u.deletingPathExtension().lastPathComponent) { return n }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return (kind == .movie ? "Video " : "Photo ") + f.string(from: Date()) + (ext.isEmpty ? "" : "." + ext)
    }
}
extension UUID { static func looksLike(_ s: String) -> Bool { UUID(uuidString: s) != nil } }

// The Control tab's section: the two ways in, the files on their way, then what's already on the Mac.
struct SendSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var sends = AppSends.shared
    @ObservedObject private var queue = AppSends.shared.queue
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var showAll = false
    @State private var shown: String?
    @State private var revealFail: [String: String] = [:]
    let route: String

    var body: some View {
        Section {
            if route == "public link" {
                Label("Sending works over Tailscale only. Connect through Tailscale in Settings to send.", systemImage: "lock.shield").font(.footnote).foregroundStyle(.secondary)
            }
            PhotosPicker(selection: $picked, selectionBehavior: .ordered, matching: nil, preferredItemEncoding: .current, photoLibrary: .shared()) {
                Label("Send photos and videos", systemImage: "photo.on.rectangle")
            }
            .disabled(route == "public link")
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                sends.add(photos: items); picked = []
            }
            Button { importing = true } label: { Label("Send files", systemImage: "folder") }
                .disabled(route == "public link")
                .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                    if case .success(let urls) = r, !urls.isEmpty { sends.add(files: urls) }
                }
            ForEach(queue.jobs) { job in
                SendJobRow(job: job, retry: { queue.retry(job) }, tint: macBlue, remove: { withAnimation(Motion.quick) { queue.remove(job) } })
                    .transition(.opacity)
            }
        } header: { Text("Send to Mac") } footer: {
            Text("Files land in Downloads › From iPhone on the Mac. In other apps, Share › Send to Mac Pro does the same.")
        }
        .task {
            if model.pose == "send" { sends.pose() }
            while !Task.isCancelled {
                if !model.screenOpen { await sends.loadRecent() }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        if !sends.recent.isEmpty || sends.recentFailed {
            Section {
                if sends.recentFailed && sends.recent.isEmpty {
                    Label(Phrase.macAway, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                }
                ForEach(showAll ? sends.recent : Array(sends.recent.prefix(4))) { f in recentRow(f) }
                if sends.recent.count > 4 {
                    Button(showAll ? "Show fewer" : "Show all \(sends.recent.count)") { withAnimation(Motion.quick) { showAll.toggle() } }
                }
            } header: { Text("Sent recently") }
        }
    }

    func recentRow(_ f: SentFile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: f.dir == true ? "folder" : MacFiles.symbol(f.name)).foregroundStyle(.secondary).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.name).lineLimit(1).truncationMode(.middle)
                    Text("\(MacFiles.bytes(f.size)) · \(Format.ago(ms: f.at))").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { reveal(f) } label: {
                    if shown == f.name { Label("Shown", systemImage: "checkmark").labelStyle(.titleAndIcon) } else { Text("Show in Finder") }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityHint("Opens a Finder window on the Mac with this file selected")
            }
            if let e = revealFail[f.name] { FailText(e) }
        }
    }
    func reveal(_ f: SentFile) {
        guard let base = sends.queue.base() else { return }
        revealFail[f.name] = nil
        Task {
            do {
                try await MacFiles.reveal(f.name, on: base)
                withAnimation(Motion.quick) { shown = f.name }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if shown == f.name { withAnimation(Motion.quick) { shown = nil } }
            } catch {
                withAnimation(Motion.quick) { revealFail[f.name] = MacFiles.unreachable(error) ? Phrase.macAway : error.localizedDescription }
            }
        }
    }
}

// The Control tab's ways to the Mac's health and its restart, apart from the everyday buttons.
struct MacPowerSections: View {
    @EnvironmentObject private var noticeState: NoticeStore  // redrawn when the Mac's reachability changes (not through the model)
    @EnvironmentObject var model: AppModel
    @ObservedObject private var watch = RestartWatch.shared
    @State private var summary: MacReport?
    @State private var misses = MissClock()
    // The row's summary is only ever what the Mac last said: a read that fails for 8 s takes it away (it kept its last
    // green "All running" for as long as the Mac was gone), and none is shown while the app itself can't reach the Mac.
    @discardableResult func read() async -> Bool {
        do { summary = try await model.api.macHealth(); HealthSummary.shared.set(summary); misses.hit(); return true }
        catch is CancellationError { return true }
        catch { if misses.miss() { summary = nil; HealthSummary.shared.set(nil) }; return false }
    }
    var body: some View {
        Section {
            Button { model.macPage = .health } label: {
                HStack {
                    Label(watch.active ? "Getting everything up" : "Everything on the Mac", systemImage: "checklist").lineLimit(1)
                    Spacer()
                    // None while a restart is under way: "Getting everything up · All running" said two things at once.
                    if let s = summary, model.problem == nil, !watch.active {
                        let bad = s.parts.filter(\.bad).count
                        HStack(spacing: 6) {
                            Circle().fill(bad == 0 ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(bad == 0 ? "All running" : "\(bad) need\(bad == 1 ? "s" : "") a look").lineLimit(1)
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            // Plain, so the summary reads grey and the name white, as a Settings row does; the row is still the button.
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .id("power")
        } header: { Text("Health") } footer: {
            Text("Tailscale, the bridge, sessions, the TV link, the Letterboxd relay, the Chumby and OCLP, each with its state.")
        }
        .task {
            if let p = MacHealthView.posed(model.pose == "send" ? "healthbad" : "health") , !model.pose.isEmpty { summary = p.report; return }
            while !Task.isCancelled {
                let ok = model.screenOpen ? true : await read()
                // Sooner after a miss, so 8 s of them are noticed in about 8.
                try? await Task.sleep(nanoseconds: ok ? 30_000_000_000 : 4_000_000_000)
            }
        }
        // Back from its page: the summary says what that page last saw.
        .onReceive(model.nav.$macPage.dropFirst()) { p in if p == nil { Task { await read() } } }
        Section {
            Button(role: .destructive) { model.macPage = .restart } label: {
                HStack { Text("Restart the Mac…"); Spacer(); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
            }
        } header: { Text("Power") } footer: { Text("Checks first that it will come back by itself.") }
    }
}
