import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
  private let model = ShareSaveModel()
  private var loading: Task<Void, Never>?
  override func viewDidLoad() {
    super.viewDidLoad()
    let host = UIHostingController(
      rootView: ShareSaveView(model: model) { [weak self] in self?.finish() })
    addChild(host)
    view.addSubview(host.view)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    // Reads the share and, with one link and a usable session, saves it without a Save tap.
    loading = Task { await model.run(items) }
  }
  private func finish() {
    loading?.cancel()
    extensionContext?.completeRequest(returningItems: nil)
  }
}
