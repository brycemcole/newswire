import SafariServices
import SwiftUI
import UIKit

@MainActor
enum InAppWeb {
    static func handle(_ url: URL) -> OpenURLAction.Result {
        guard isWeb(url) else { return .systemAction }
        open(url)
        return .handled
    }

    static func open(_ url: URL) {
        guard isWeb(url) else {
            UIApplication.shared.open(url)
            return
        }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow),
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = .tintColor
        top.present(controller, animated: true)
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}
