import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

// Send to Mac Pro, from any app's share sheet (Richard, 2026-11-10: "use tailscale for sending files to mac in mac pro app").
// Whatever is shared becomes files: files, photos and videos as they are; a link a .webloc that opens it on the Mac; text a
// .txt. Each goes straight to the bridge over the tailnet with its progress and a tick, and the card closes by itself
// once everything is there. No setup: the Mac Pro app's own address.

enum ShareAddress {
    // The address the Mac Pro app saved (its Keychain item, readable here when the build's signing shares the team's
    // keychain), else the one baked into this build.
    static var base: URL? {
        for s in [keychain(), Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String] {
            if let s, !s.isEmpty, let u = URL(string: s), u.host != nil { return u }
        }
        return nil
    }
    private static func keychain() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.macpro.address",
                                kSecAttrAccount as String: "address", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// Turns what was shared into files on disk, one job each.
enum ShareItems {
    static func jobs(from items: [NSExtensionItem], into queue: SendQueue) async {
        let providers = items.flatMap { $0.attachments ?? [] }
        let title = items.lazy.compactMap { $0.attributedContentText?.string }.first { !$0.isEmpty }
        var webLinks: [URL] = [], texts: [String] = [], files = 0
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || fileType(p) != nil {
                files += 1
                let job = await MainActor.run { () -> SendJob in let j = SendJob(name: p.suggestedName ?? "File"); queue.add(j); return j }
                do {
                    let kept = try await file(p)
                    await MainActor.run { queue.ready(job, file: kept, name: kept.lastPathComponent) }
                } catch {
                    await MainActor.run { queue.fail(job, "That couldn’t be read from the app it came from.") }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !u.isFileURL {
                webLinks.append(u)
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let t = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                texts.append(t)
            }
        }
        // A link shared with its own text (Safari sends both) is the link alone.
        if !webLinks.isEmpty { texts.removeAll { t in webLinks.contains { t.contains($0.absoluteString) } || t == title } }
        for u in webLinks { await add(webloc(u, title: webLinks.count == 1 ? title : nil), to: queue) }
        for t in texts where !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await add(text(t), to: queue) }
        _ = files
    }
    private static func add(_ made: URL?, to queue: SendQueue) async {
        guard let made else { return }
        await MainActor.run { queue.add(SendJob(name: made.lastPathComponent, file: made)) }
    }
    // The first type a provider has that's a file's contents (a photo, a film, a PDF), not a link or plain text.
    static func fileType(_ p: NSItemProvider) -> String? {
        p.registeredTypeIdentifiers.first { id in
            guard let t = UTType(id) else { return false }
            if t.conforms(to: .url) || t == .plainText || t == .utf8PlainText || t == .text { return false }
            return t.conforms(to: .data) || t.conforms(to: .image) || t.conforms(to: .audiovisualContent)
        }
    }
    private static func file(_ p: NSItemProvider) async throws -> URL {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let u = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL, u.isFileURL {
            return try MacFiles.keep(u)
        }
        guard let type = fileType(p) else { throw SendError.say("Nothing to send.") }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            // The lent file lives only until this returns: copied at once.
            _ = p.loadFileRepresentation(forTypeIdentifier: type) { u, e in
                guard let u else { c.resume(throwing: e ?? SendError.say("Nothing to send.")); return }
                var name = p.suggestedName ?? u.deletingPathExtension().lastPathComponent
                let ext = u.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "") : u.pathExtension
                if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() { name += "." + ext }
                do { c.resume(returning: try MacFiles.keep(u, named: name)) } catch { c.resume(throwing: error) }
            }
        }
    }
    // A link as a .webloc, named by the page's title or its site: double-clicked on the Mac it opens in the browser.
    static func webloc(_ u: URL, title: String?) -> URL? {
        let base = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty || $0.count > 80 ? nil : $0 }
            ?? (u.host?.replacingOccurrences(of: "www.", with: "") ?? "Link")
        let dest = MacFiles.holding(MacFiles.clean(base) + ".webloc")
        guard let d = try? PropertyListSerialization.data(fromPropertyList: ["URL": u.absoluteString], format: .xml, options: 0),
              (try? d.write(to: dest)) != nil else { return nil }
        return dest
    }
    // Text as a .txt, named by its first few words.
    static func text(_ t: String) -> URL? {
        let first = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
        var words = first.split(separator: " ").prefix(6).joined(separator: " ")
        if words.count > 48 { words = String(words.prefix(48)) }
        let dest = MacFiles.holding(MacFiles.clean(words.isEmpty ? "Text" : words) + ".txt")
        guard (try? Data(t.utf8).write(to: dest)) != nil else { return nil }
        return dest
    }
}

// The card in the share sheet: each file with its progress and tick; "Sent to your Mac" and it closes by itself; a failure
// keeps it open with the reason and Try again.
@MainActor
final class ShareModel: ObservableObject {
    let queue = SendQueue(base: { ShareAddress.base })
    // Everything shared has been looked at (and the jobs made), so an empty list means there was nothing to send.
    @Published var started = false
}

struct ShareSendView: View {
    @ObservedObject var model: ShareModel
    @ObservedObject var queue: SendQueue
    let close: () -> Void
    init(model: ShareModel, close: @escaping () -> Void) { self.model = model; queue = model.queue; self.close = close }
    var started: Bool { model.started }
    @State private var closing = false
    let blue = Color(red: 0.04, green: 0.52, blue: 1)
    var allSent: Bool { started && !queue.jobs.isEmpty && queue.jobs.allSatisfy(\.finished) }
    var anyFailed: Bool { queue.jobs.contains { $0.failed } }

    var body: some View {
        NavigationStack {
            List {
                if ShareAddress.base == nil {
                    Section { Text("Open the Mac Pro app once so this knows where your Mac is.").foregroundStyle(.secondary) }
                } else if queue.jobs.isEmpty {
                    Section { HStack(spacing: 12) { ProgressView(); Text(started ? "Nothing here can be sent." : "Getting it ready…").foregroundStyle(.secondary) } }
                } else {
                    Section {
                        ForEach(queue.jobs) { SendJobRow(job: $0, retry: { [queue, job = $0] in queue.retry(job) }, tint: blue) }
                    } footer: {
                        if allSent { Label("Sent to your Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.body.weight(.semibold)).padding(.top, 6) }
                        else { Text("To Downloads › From iPhone on the Mac, over Tailscale.") }
                    }
                }
            }
            .navigationTitle("Send to Mac Pro")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(allSent || anyFailed ? "Close" : "Cancel") { queue.cancelAll(); close() }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: allSent)
        }
        .tint(blue)
        .preferredColorScheme(.dark)
        .onChange(of: allSent) { _, done in
            guard done, !closing else { return }
            closing = true
            // Long enough to see the ticks.
            Task { try? await Task.sleep(nanoseconds: 1_300_000_000); close() }
        }
    }
}
