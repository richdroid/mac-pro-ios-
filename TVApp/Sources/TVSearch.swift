import SwiftUI

// PROBE (branch-only): how iOS lays out a search-role tab on the Duo, with the app's own field and with the system's.
struct SearchProbe: View {
    @Environment(TVModel.self) var model
    @State private var text = ""
    @FocusState private var focused: Bool
    static let system = UserDefaults.standard.string(forKey: "searchProbe") == "system"
    var rows: some View {
        ForEach(0..<14, id: \.self) { i in
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.12)).frame(width: 40, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Result \(i + 1) for “\(text)”").font(.body.weight(.semibold)).lineLimit(1)
                    Text("1995 · Film").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 64)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
    var body: some View {
        if Self.system {
            NavigationStack {
                ScrollView { VStack(spacing: 8) { rows }.padding(.horizontal, 20).padding(.vertical, 12) }
                    .scrollDismissesKeyboard(.immediately)
                    .navigationTitle("Search")
                    .background { Ambience() }
            }
            .searchable(text: $text, prompt: "Shows, films, music, apps")
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).padding(.leading, 14)
                    TextField("Shows, films, music, apps", text: $text).focused($focused).autocorrectionDisabled().submitLabel(.search)
                        .hidesTabBar(while: focused, "search")
                }
                .frame(height: 50).glassEffect(.regular, in: Capsule()).padding(.horizontal, 20).padding(.top, 12)
                ScrollView { VStack(spacing: 8) { rows }.padding(.horizontal, 20).padding(.bottom, 12) }
                    .scrollDismissesKeyboard(.immediately)
            }
            .task {
                guard UserDefaults.standard.string(forKey: "pose") == "searchfocus" else { return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                for _ in 0..<10 { focused = true; try? await Task.sleep(nanoseconds: 300_000_000); if focused { break } }
            }
        }
    }
}
