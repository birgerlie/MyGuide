import ImageIO
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// The expanded walking notification (spec 7.4) for categories BUZZ, MORE and STOP. Reads only the notification's
/// `userInfo` and its first attachment: no network, no key, no shared store. The system draws the actions («Lytt»,
/// «Hopp over»); they run in the app as before.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let hosting = UIHostingController(rootView: NotificationCard(payload: .empty, picture: nil))

    /// Longest side the picture is decoded to. The card is at most a phone's width at 3x, so this keeps the picture
    /// sharp while a large original cannot run the extension out of memory.
    private static let pictureMaxPixels = 1_400

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Theme.Colour.background)
        hosting.view.backgroundColor = .clear
        hosting.safeAreaRegions = []
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: Self, _) in
            controller.fitHeight()
        }
    }

    /// Called for the notification being expanded, and again for each later one of the same categories that arrives
    /// while it is open: each call replaces the card.
    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let payload = NotificationPayload.decode(content.userInfo) ?? Self.fallback(content)
        hosting.rootView = NotificationCard(payload: payload, picture: Self.picture(content.attachments.first))
        fitHeight()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitHeight()
    }

    /// Asks for the height the card needs at the current width. Changing only the height leaves the width as it is,
    /// so the layout pass it causes settles here without asking again.
    private func fitHeight() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let fitted = hosting.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        let size = CGSize(width: width, height: ceil(fitted.height))
        guard size != preferredContentSize else { return }
        preferredContentSize = size
    }

    /// A notification without a readable payload (posted before payloads existed) still shows its own texts.
    private static func fallback(_ content: UNNotificationContent) -> NotificationPayload {
        NotificationPayload(label: "", name: content.title,
                            line: content.subtitle.isEmpty ? nil : content.subtitle,
                            fact: content.body.isEmpty ? nil : content.body, credit: nil)
    }

    /// The attached picture, decoded while the attachment's security scope is open; nil without one or when it
    /// cannot be read, and the card then goes without a picture (and without its credit).
    private static func picture(_ attachment: UNNotificationAttachment?) -> UIImage? {
        guard let url = attachment?.url else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pictureMaxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private extension NotificationPayload {
    /// Shown only for the instant between the view loading and `didReceive`.
    static let empty = NotificationPayload(label: "", name: "", line: nil, fact: nil, credit: nil)
}
