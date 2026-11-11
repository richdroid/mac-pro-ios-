#if os(iOS)
import SwiftUI
import UIKit

// The share sheet's entry: hosts the card (ShareSendView) and hands it what was shared.
final class ShareViewController: UIViewController {
    private let model = ShareModel()
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareSendView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        model.begin(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
    }
}
#endif
