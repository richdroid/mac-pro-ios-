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

    func row(_ p: MacProcess, by: ProcessSort) -> some View {
        let cpu = String(format: "%.0f%%", p.cpu), mem = Format.memory(p.mem)
        return Button {
            pending = Pending(process: p, force: false)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).lineLimit(1)
                    Text(p.locked ?? (by == .cpu ? mem : "\(cpu) CPU")).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if working == p.pid { ProgressView() }
                else if p.locked != nil { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary) }
                Text(by == .cpu ? cpu : mem).font(.body.weight(.medium)).monospacedDigit().foregroundStyle(p.locked == nil ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(p.locked != nil || working != nil)
        .accessibilityHint(p.locked == nil ? "Asks before quitting" : "Can’t be quit from here")
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
            if notes, let note { Section { Text(note).font(.footnote).foregroundStyle(.secondary) } }
            Section(chooser ? "" : by.title) {
                if report == nil {
                    if failed { Label("Can’t reach the Mac", systemImage: "wifi.exclamationmark").foregroundStyle(.secondary) }
                    else { HStack { ProgressView(); Text("Connecting…").foregroundStyle(.secondary) } }
                }
                ForEach(rows(by)) { row($0, by: by) }
            }
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .refreshable { await load() }
    }

    func load() async {
        do { report = try await model.api.processes(); failed = false }
        catch is CancellationError {}
        catch { failed = report == nil }
    }

    func quit(_ p: Pending) async {
        working = p.process.pid; defer { working = nil }
        do {
            let gone = try await model.api.quitProcess(p.process, force: p.force)
            if gone { note = "\(p.process.name) has quit." }
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
        .navigationTitle("Processes")
        .navigationBarTitleDisplayMode(.inline)
        // Asked from a swipe, which leaves nothing to point at, so it's a plain question in the middle.
        .alert(dialogTitle, isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { p in
            Button(p.force ? "Force Quit" : "Quit", role: .destructive) { Task { await quit(p) } }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(p.force ? "Unsaved work is lost." : "It’s asked to close. Unsaved work may be lost.")
        }
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
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// One Claude Code session on the Mac: what it's doing, and, for the ones this Mac keeps, its screen a tap away.
struct SessionRow: View {
    let session: Status.Session
    let working: Bool
    let restart: () -> Void
    var open: (() -> Void)?
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
        return session.stuck == true ? line + " · may be stuck" : line
    }
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).lineLimit(1)
                Text(state).font(.footnote.weight(session.waiting == true ? .semibold : .regular)).foregroundStyle(session.stuck == true || session.waiting == true ? .orange : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if working { ProgressView() }
            else if session.restartable == true {
                Button(session.status == "stopped" ? "Start" : "Restart") { if session.status == "stopped" { restart() } else { confirm = true } }
                    .buttonStyle(.bordered).controlSize(.small)
                    .confirmationDialog("Restart \(session.name)?", isPresented: $confirm, titleVisibility: .visible) {
                        Button("Restart", role: .destructive, action: restart)
                    } message: { Text(session.waiting == true ? "It will come back to the same question. To answer it, tap the session instead." : "It stops what it’s doing, then picks up the same conversation.") }
            }
            if canOpen { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if canOpen { open?() } }
        .accessibilityAction(named: "Show its screen") { if canOpen { open?() } }
    }
    var canOpen: Bool { open != nil && session.key != nil && session.status != "stopped" }
}
