import UIKit
import Security
import UniformTypeIdentifiers

// Send to TV from any app's share sheet. The Mac decides where a link goes; this only passes it along.
final class ShareViewController: UIViewController {
    private let label = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.149, green: 0.196, blue: 0.22, alpha: 1)
        label.textColor = UIColor(white: 0.93, alpha: 1); label.font = .systemFont(ofSize: 17, weight: .light); label.textAlignment = .center; label.numberOfLines = 0
        label.text = "Sending to the TV…"; label.frame = view.bounds.insetBy(dx: 24, dy: 24); label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
        Task { await run() }
    }
    private func finish(_ text: String) async {
        label.text = text
        try? await Task.sleep(nanoseconds: 900_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }
    private func item() async -> String? {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL { return u.absoluteString }
        }
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { return s }
        }
        return nil
    }
    // The TV app's address from its shared Keychain group (given by the TestFlight signing), else the one baked in.
    static func address() -> String? {
        let prefix = (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let team = prefix.flatMap({ $0.isEmpty ? nil : Substring($0) }) ?? Bundle.main.bundleIdentifier?.split(separator: ".").first(where: { $0.count == 10 && $0.allSatisfy { $0.isUppercase || $0.isNumber } }) {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.macpro.address", kSecAttrAccount as String: "address",
                                    kSecAttrAccessGroup as String: "\(team).local.macpro.TV.shared", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        }
        return Bundle.main.object(forInfoDictionaryKey: "DefaultAddress") as? String
    }
    private func run() async {
        guard let text = await item(), let address = Self.address(),
              let base = URL(string: address), let u = URL(string: address + "/api/tv/send") else { await finish("Nothing to send"); return }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 10
        r.setValue("\(base.scheme ?? "https")://\(base.host ?? "")", forHTTPHeaderField: "Origin")
        r.setValue("1", forHTTPHeaderField: "x-dash"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The TV shows it arriving, as it does anything flicked from the app: a card naming the site, at its bottom edge.
        let site = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.replacingOccurrences(of: "www.", with: "") ?? "Link"
        let receipt: [String: Any] = ["id": UUID().uuidString, "title": site, "kind": site.contains("youtu") ? "video" : "link"]
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "receipt": receipt])
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { await finish("Can’t reach the Mac. Is Tailscale on?"); return }
        await finish(j["ok"] as? Bool == true ? "Sent to the TV" : "That link can’t open on the TV. Try AirPlay.")
    }
}
