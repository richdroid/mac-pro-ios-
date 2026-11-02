import SwiftUI

// A kept session's own screen, to answer whatever it's waiting on from here: keys for its menus, and a box to tell it something.
struct SessionTerminal: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: Status.Session
    @State private var text = ""
    @State private var running = true
    @State private var loaded = false
    @State private var message = ""
    @State private var note: String?
    @State private var sends = 0
    static let keys: [(String, String)] = [("esc", "Esc"), ("enter", "Enter"), ("up", "↑"), ("down", "↓"), ("left", "←"), ("right", "→"),
                                           ("1", "1"), ("2", "2"), ("3", "3"), ("tab", "Tab"), ("shift-tab", "⇧Tab"), ("ctrl-c", "Ctrl-C")]
    var key: String { session.key ?? session.name }
    func show(_ t: API.Term) {
        running = t.running ?? true
        if let s = t.text, s != text { text = s }
        loaded = true
    }
    func load() async {
        do { show(try await model.api.termScreen(key)); if note == "Can’t reach the Mac" { note = nil } }
        catch { if !loaded { note = "Can’t reach the Mac" } }
    }
    func send(_ body: [String: Any]) {
        sends += 1
        Task {
            do { show(try await model.api.termSend(key, body)) }
            catch { withAnimation { note = error.localizedDescription } }
        }
    }
    var screen: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear.frame(height: 1).id("end")
            }
            .defaultScrollAnchor(.bottom)
            .background(Color(white: 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)) }
            .overlay {
                if !loaded { ProgressView() }
                else if !running { ContentUnavailableView("Not running", systemImage: "moon.zzz", description: Text("The Mac starts it again within two minutes.")) }
            }
            .onChange(of: text) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }
    var keyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.keys, id: \.0) { k, label in
                    Button(label) { send(["key": k]) }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(k == "ctrl-c" ? .red : nil)
                        .accessibilityLabel(k == "up" ? "Up" : k == "down" ? "Down" : k == "left" ? "Left" : k == "right" ? "Right" : label)
                }
            }
        }
    }
    var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the session", text: $message, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Button {
                let m = message; message = ""
                send(["text": m])
                withAnimation { note = "Sent" }
            } label: {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 40, height: 40)
                    .background(macBlue, in: Circle()).foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
            .accessibilityLabel("Send")
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                screen
                keyRow
                composer
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
            .navigationTitle(session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay(alignment: .top) {
                if let note {
                    Text(note).font(.footnote.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: Capsule()).padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: note) { try? await Task.sleep(nanoseconds: 1_600_000_000); withAnimation { self.note = nil } }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.impact(weight: .light), trigger: sends)
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
}
