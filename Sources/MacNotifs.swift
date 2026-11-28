import SwiftUI

// The Mac's notifications from the phone (Richard, 2026-11-28: "give me the ability to dismiss notifs from the mac pro
// app"). The banners and alerts macOS leaves on the Mac's screen ("App Background Activity", "Some iCloud Data Isn't
// Syncing", a Calendar shift) stack over the Console; Status says how many there are, and this page lists them, each
// swiped away or all dismissed at once. The bridge (notifs.js) closes each with its own Close (Clear All for a stack),
// as a swipe on the Mac would; a notification's buttons (Allow, Turn Off, Open …) are never pressed.

struct MacNotif: Decodable, Equatable, Identifiable, Hashable {
    let id: String
    var app: String?
    var title: String?
    var subtitle: String?
    var body: String?
    var stack: Bool?
    // Its first line: the title, else the first words it has.
    var heading: String { [title, subtitle, body].compactMap { $0 }.first { !$0.isEmpty } ?? "Notification" }
    // What follows the title, when there's more.
    var detail: String? {
        let rest = [subtitle, body].compactMap { $0 }.filter { !$0.isEmpty && $0 != heading }
        return rest.isEmpty ? nil : rest.joined(separator: " · ")
    }
}
struct MacNotifsFeed: Decodable, Equatable {
    var ok: Bool
    var notifications: [MacNotif]
    var say: String?
}

// Status's row, only while there are some: how many, and the page with them.
struct MacNotifsRow: View {
    @EnvironmentObject var model: AppModel
    let count: Int
    var body: some View {
        if count > 0 {
            Section {
                Button { model.macPage = .notifications } label: {
                    HStack {
                        Text("On the Mac’s screen").foregroundStyle(Color.primary)
                        Spacer()
                        Text(count == 1 ? "1 notification" : "\(count) notifications").foregroundStyle(.secondary).monospacedDigit()
                        RowChevron()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("mac-notifs")
                .place("mac-notifs")
            }
        }
    }
}

struct MacNotifRow: View {
    let n: MacNotif
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: n.stack == true ? "square.stack" : AppsTab.symbol(n.app ?? ""))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                if let app = n.app, !app.isEmpty { Text(app).font(.footnote).foregroundStyle(.secondary) }
                Text(n.heading).foregroundStyle(Color.primary)
                // The whole of it: cut at two lines, folded lost the end of a sentence with no way to read it (gate on macpro-1128).
                if let d = n.detail { Text(d).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct MacNotifsView: View {
    let model: AppModel
    @StateObject private var feed = FeedReader<MacNotifsFeed>("/api/mac/notifications")
    // Dismissed here: out of the list at once, back with a reason if the Mac couldn't close it.
    @State private var gone: Set<String> = []
    @State private var clearing = false
    @State private var failure: String?
    @Environment(\.paneLayout) private var panes
    static let how = "Each closes as it would on the Mac. Its buttons, like Allow or Turn Off, are never pressed."
    var shown: [MacNotif] { (feed.value?.notifications ?? []).filter { !gone.contains($0.id) } }
    var body: some View {
        ConsolePage(title: "Notifications", place: "macnotifs", away: feed.away, lastRead: feed.lastRead) {
            if let f = feed.value {
                if !f.ok {
                    Section { Text(f.say ?? "The Mac’s notifications couldn’t be read.").foregroundStyle(.secondary) }
                } else if shown.isEmpty {
                    Section {
                        ContentUnavailableView("No Notifications", systemImage: "bell.slash", description: Text("Nothing is left on the Mac’s screen."))
                    }
                } else {
                    Section {
                        ForEach(shown) { n in
                            MacNotifRow(n: n)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) { dismiss(n) } label: { Label(n.stack == true ? "Clear" : "Dismiss", systemImage: "xmark") }
                                }
                                .place(n.id)
                                // Where the first row is, for the build's swipe films (-findBack YES only).
                                .findSpot(n.id == shown.first?.id ? "notif0" : "")
                        }
                    } header: {
                        Text("On the Mac’s screen")
                    } footer: {
                        if !panes { Text(Self.how) }
                    }
                }
                if let failure { Section { FailText(failure) } }
            } else if !feed.away {
                Section { HStack { ProgressView(); Text("Reading the Mac’s screen…").foregroundStyle(.secondary) } }
            }
        } right: {
            // Open flat, the right pane holds what the list's footer says and Dismiss All beside the list; it was left
            // empty, half the screen black (gate on macpro-1128).
            if let f = feed.value, f.ok {
                if shown.isEmpty {
                    Section { Text(Self.how).foregroundStyle(.secondary) } header: { Text("Dismissing from the phone") }
                } else {
                    Section {
                        Button(role: .destructive) { dismissAll() } label: {
                            Label(shown.count == 1 ? "Dismiss the notification" : "Dismiss all \(shown.count)", systemImage: "xmark.circle")
                        }
                        .disabled(clearing || feed.away)
                    } header: { Text("Dismissing from the phone") } footer: { Text(Self.how) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Dismiss All") { dismissAll() }
                    .disabled(clearing || shown.isEmpty || feed.away || feed.value?.ok != true)
            }
        }
        .taskInFront {
            switch MacConsole.pose {
            case "notifsempty": feed.set(MacNotifsFeed(ok: true, notifications: [])); return
            default: await feed.loop(model, every: 8)
            }
        }
    }
    func dismiss(_ n: MacNotif) {
        withAnimation(Motion.quick) { _ = gone.insert(n.id); failure = nil }
        Task {
            let r = await post("/api/mac/notifications/dismiss", ["id": n.id])
            if !r.done { withAnimation(Motion.quick) { _ = gone.remove(n.id); failure = r.error ?? r.say ?? "That one didn’t close." } }
            await settle()
        }
    }
    func dismissAll() {
        let ids = Set(shown.map(\.id))
        clearing = true
        withAnimation(Motion.quick) { gone.formUnion(ids); failure = nil }
        Task {
            let r = await post("/api/mac/notifications/dismiss-all", [:])
            if !r.done { withAnimation(Motion.quick) { gone.subtract(ids); failure = r.error ?? r.say ?? "They didn’t close." } }
            await settle()
            clearing = false
        }
    }
    func post(_ path: String, _ body: [String: Any]) async -> MacActionResult {
        do { return try await model.api.macDo(path, body, timeout: 40) }
        catch { return MacActionResult(ok: false, error: MacFiles.unreachable(error) ? "The Mac didn’t answer, so it’s not known whether that closed. This page checks again by itself." : error.localizedDescription) }
    }
    // What the Mac shows now takes over from what was taken out here; Status's count follows with its next reading.
    func settle() async {
        await feed.read(model.api)
        let now = Set((feed.value?.notifications ?? []).map(\.id))
        gone = gone.intersection(now)
        await model.refresh()
    }
}
