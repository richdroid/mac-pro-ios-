import Foundation
import LocalAuthentication
import Security
import SwiftUI

// Saved logins live only in this iPhone's keychain and need Face ID to read. They go to the Mac only when you tap one.
struct SavedLogin: Identifiable, Hashable { let name: String; var id: String { name } }

enum LoginVault {
    private static let service = "local.macpro.logins"
    static func all() -> [SavedLogin] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true, kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { ($0[kSecAttrAccount as String] as? String).map(SavedLogin.init) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func save(name: String, username: String, password: String) -> Bool {
        delete(name)
        guard let body = try? JSONEncoder().encode([username, password]),
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil) else { return false }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name, kSecValueData as String: body, kSecAttrAccessControl as String: access]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    // Asks for Face ID, off the main thread so the interface keeps moving.
    static func read(_ name: String) async -> (String, String)? {
        await Task.detached { () -> (String, String)? in
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name, kSecReturnData as String: true, kSecUseOperationPrompt as String: "Fill \(name) on the Mac"]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
                  let v = try? JSONDecoder().decode([String].self, from: d), v.count == 2 else { return nil }
            return (v[0], v[1])
        }.value
    }
    static func delete(_ name: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        SecItemDelete(q as CFDictionary)
    }
}

// One sheet for every sign-in: pick a saved login, or let iPhone AutoFill supply it, and it lands in the Mac's focused field.
struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    // Types what it's given into the Mac: username (if any), Tab, password, Return.
    let fill: (_ username: String, _ password: String) async -> String?
    @State private var saved: [SavedLogin] = []
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var keep = false
    @State private var note: String?
    @State private var busy = false

    func send(_ u: String, _ p: String) {
        Task {
            busy = true; defer { busy = false }
            if let e = await fill(u, p) { note = e } else { dismiss() }
        }
    }
    var body: some View {
        NavigationStack {
            Form {
                if !saved.isEmpty {
                    Section("Saved") {
                        ForEach(saved) { s in
                            Button {
                                Task {
                                    guard let v = await LoginVault.read(s.name) else { note = "Face ID didn’t unlock that login."; return }
                                    send(v.0, v.1)
                                }
                            } label: { Label(s.name, systemImage: "key.fill") }
                        }
                        .onDelete { i in i.forEach { LoginVault.delete(saved[$0].name) }; saved = LoginVault.all() }
                    }
                }
                Section {
                    field
                    Toggle("Save on this iPhone", isOn: $keep)
                    if keep { TextField("Name, such as Apple or Google", text: $name) }
                    Button(busy ? "Filling…" : "Fill on Mac") {
                        if keep, !name.isEmpty {
                            if LoginVault.save(name: name.trimmingCharacters(in: .whitespaces), username: username, password: password) { saved = LoginVault.all() }
                            else { note = "Couldn’t save that login." }
                        }
                        send(username, password)
                    }
                    .disabled(password.isEmpty || busy || (keep && name.isEmpty))
                } header: { Text("New sign-in") } footer: {
                    Text("Click the field on the Mac first. iPhone Passwords can fill these boxes from the keyboard.")
                }
                if let note { Section { Text(note).foregroundStyle(.red) } }
            }
            .navigationTitle("Sign In on Mac")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task { saved = LoginVault.all() }
    }
    @ViewBuilder private var field: some View {
        #if os(iOS)
        TextField("Username or email (optional)", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
        SecureField("Password", text: $password).textContentType(.password)
        #else
        TextField("Username or email (optional)", text: $username)
        SecureField("Password", text: $password)
        #endif
    }
}
