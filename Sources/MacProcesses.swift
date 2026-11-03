import SwiftUI

// What's using the Mac, heaviest first. The Mac decides what may be quit; locked rows say why not.
struct MacProcess: Decodable, Identifiable, Hashable {
    let pid: Int, start: String, name: String, cpu: Double, mem: Double
    let locked: String?
    var id: Int { pid }
}
struct ProcessReport: Decodable { let cpu: [MacProcess]; let mem: [MacProcess] }

enum ProcessSort: String, Identifiable, Hashable, CaseIterable {
    case cpu, memory
    var id: String { rawValue }
    var title: String { self == .cpu ? "CPU" : "Memory" }
    init?(metric: HistoryMetric) {
        if metric == .cpu { self = .cpu } else if metric == .memory { self = .memory } else { return nil }
    }
}

struct ProcessesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.paneLayout) private var panes
    struct Pending: Identifiable { let process: MacProcess; let force: Bool; var id: String { "\(process.pid)\(force)" } }
    @State private var sort: ProcessSort
    @State private var report: ProcessReport?
    @State private var failed = false
    @State private var pending: Pending?
    @State private var working: Int?
    @State private var note: String?
    init(first: ProcessSort) { _sort = State(initialValue: first) }

    func rows(_ by: ProcessSort) -> [MacProcess] { by == .cpu ? report?.cpu ?? [] : report?.mem ?? [] }

    // Names stay in full colour, since they're the answer to what's using the Mac; a lock says which can't be quit.
    func face(_ p: MacProcess, by: ProcessSort) -> some View {
        let cpu = String(format: "%.0f%%", p.cpu), mem = Format.memory(p.mem)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).lineLimit(1)
                Text(p.locked ?? (by == .cpu ? mem : "\(cpu) CPU")).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if working == p.pid { ProgressView() }
            else if p.locked != nil { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Can’t be quit from here") }
            Text(by == .cpu ? cpu : mem).font(.body.weight(.medium)).monospacedDigit()
        }
        .contentShape(Rectangle())
    }
    @ViewBuilder func row(_ p: MacProcess, by: ProcessSort) -> some View {
        if p.locked != nil { face(p, by: by) }
        else {
            Button { pending = Pending(process: p, force: false) } label: { face(p, by: by) }
                .buttonStyle(.plain)
                .disabled(working != nil)
                .accessibilityHint("Asks before quitting")
                // The question hangs off the row that was tapped.
                .confirmationDialog(dialogTitle, isPresented: .init(get: { pending?.process.pid == p.pid }, set: { if !$0 { pending = nil } }), titleVisibility: .visible, presenting: pending) { q in
                    Button(q.force ? "Force Quit" : "Quit", role: .destructive) { Task { await quit(q) } }
                } message: { q in
                    Text(q.force ? "Unsaved work is lost." : "It’s asked to close. Unsaved work may be lost.")
                }
        }
    }

    func list(_ by: ProcessSort, chooser: Bool, notes: Bool) -> some View {
        List {
            if chooser {
                Section {
                    Picker("Sort by", selection: $sort) { ForEach(ProcessSort.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            if notes, let note { Section { FailText(note) } }
            if chooser { Section { rowsBody(by) } } else { Section(by.title) { rowsBody(by) } }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        // The same top edge in both panes when open.
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollsUnder(by == .memory && !chooser ? 1 : 0)
        .refreshable { await load() }
    }
    @ViewBuilder func rowsBody(_ by: ProcessSort) -> some View {
        if report == nil {
            if failed { Label("Can’t reach the Mac", systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
            else { HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) } }
        }
        ForEach(rows(by)) { row($0, by: by) }
    }

    func load() async {
        do { report = try await model.api.processes(); failed = false }
        catch is CancellationError {}
        catch { failed = report == nil }
    }

    func quit(_ p: Pending) async {
        working = p.process.pid; defer { working = nil }
        note = nil
        do {
            // Gone from the list says it quit; only a process that stayed needs a word.
            let gone = try await model.api.quitProcess(p.process, force: p.force)
            if gone { note = nil }
            else if p.force { note = "\(p.process.name) is still running." }
            else { note = nil; pending = Pending(process: p.process, force: true) }
        } catch { note = error.localizedDescription }
        await load()
    }

    var body: some View {
        Group {
            if panes {
                FoldSplit { list(.cpu, chooser: false, notes: true) } right: { list(.memory, chooser: false, notes: false) }
            } else {
                list(sort, chooser: true, notes: true)
            }
        }
        .background(groupedBackground.ignoresSafeArea())
        .topEdge()
        .navigationTitle("Processes")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                // The list stays put while a dialog is asking about one of its rows.
                if pending == nil && working == nil { await load() }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    var dialogTitle: String {
        guard let pending else { return "" }
        return pending.force ? "\(pending.process.name) didn’t quit. Force it?" : "Quit \(pending.process.name)?"
    }
}

// On the CPU and Memory history screens.
struct ProcessesLink: View {
    @EnvironmentObject var model: AppModel
    let sort: ProcessSort
    var body: some View {
        Button { model.processes = sort } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(macBlue)
                Text("Processes")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(cardFill, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }
}

// One Claude Code session on the Mac: what it's doing, and, for the ones this Mac keeps, its screen a tap away.
struct SessionRow: View {
    let session: Status.Session
    let working: Bool
    let restart: () -> Void
    @State private var confirm = false
    var tint: Color {
        if session.stuck == true || session.waiting == true { return .orange }
        switch session.status {
        case "stopped": return .red
        case "idle": return .green
        case "starting": return .secondary
        default: return macBlue
        }
    }
    var state: String {
        if session.waiting == true { return "Waiting for you" }
        let name: String
        switch session.status {
        case "shell": name = "Running a command"
        case "stopped": return "Not running"
        case "starting": return "Starting"
        default: name = sentenceCase(session.status)
        }
        guard let at = session.updated else { return name }
        let line = "\(name) for \(Format.span(Date().timeIntervalSince1970 - at / 1000))"
        return session.stuck == true ? line + " · stuck?" : line
    }
    // Rows the Claude app runs, not this Mac, don't open here, and say so.
    var line: String { session.key == nil ? state + " · in the Claude app" : state }
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).lineLimit(1)
                Text(line).font(.footnote.weight(session.waiting == true ? .semibold : .regular)).foregroundStyle(session.stuck == true || session.waiting == true ? .orange : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if working { ProgressView() }
            else if session.restartable == true, session.status == "stopped" {
                Button("Start", action: restart).buttonStyle(.bordered).controlSize(.small)
            } else if session.restartable == true, session.stuck == true {
                // Only a session that seems stuck has a reason to be restarted.
                Button("Restart") { confirm = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .confirmationDialog("Restart \(session.name)?", isPresented: $confirm, titleVisibility: .visible) {
                        Button("Restart", role: .destructive, action: restart)
                    } message: { Text(session.waiting == true ? "It will come back to the same question. To answer it, tap the session instead." : "It stops what it’s doing, then picks up the same conversation.") }
            }
        }
        .contentShape(Rectangle())
    }
    // Every session this Mac keeps has a page, running or not; a stopped one can be started from there too.
    var canOpen: Bool { session.key != nil }
}
