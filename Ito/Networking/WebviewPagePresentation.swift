import UIKit
import WebKit

/// Shows the shared plugin web view to the user, in a window above the app, while a script waits
/// on a page that needs the user (such as a verification the host can't complete). It only moves
/// the web view into the window and back home; `WebviewManager` decides when that happens.
@MainActor
final class PagePresentation {
    /// The origin the page belongs to, keyed as `WebviewManager` declines origins.
    let origin: String
    private let webView: WKWebView
    private let window: UIWindow
    private let homeSuperview: UIView?
    private let homeFrame: CGRect
    private let previousKeyWindow: UIWindow?

    /// The foreground window scene that can host a page, or nil while the app isn't in the foreground.
    static var foregroundScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    /// Moves `webView` into a new window above the app and makes that window key. Returns nil when
    /// no window scene is in the foreground to host it.
    init?(webView: WKWebView, origin: String, host: String, onClose: @escaping @MainActor () -> Void) {
        guard let scene = PagePresentation.foregroundScene else { return nil }
        self.origin = origin
        self.webView = webView
        homeSuperview = webView.superview
        homeFrame = webView.frame
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        // Adding the web view to the overlay moves it out of its home in the same turn, so it never
        // sits outside a window.
        window.rootViewController = PageOverlayViewController(host: host, webView: webView, onClose: onClose)
        self.window = window

        webView.alpha = 1
        webView.isUserInteractionEnabled = true
        window.makeKeyAndVisible()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// Moves the web view back to its home, hidden and inert as it was before the page was shown,
    /// then removes the overlay window.
    func end() {
        if let homeSuperview {
            homeSuperview.insertSubview(webView, at: 0)
        } else {
            webView.removeFromSuperview()
        }
        // Constraints laid out the web view in the overlay; its home lays it out by frame.
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.frame = homeFrame
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false

        window.isHidden = true
        window.rootViewController = nil
        // The window that was key may have been hidden meanwhile; never make a hidden window key.
        if let previousKeyWindow, !previousKeyWindow.isHidden {
            previousKeyWindow.makeKey()
        }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

/// The root view controller of the overlay window.
@MainActor
final class PageOverlayViewController: UIViewController {
    init(host: String, webView: WKWebView, onClose: @escaping @MainActor () -> Void) {
        super.init(nibName: nil, bundle: nil)
        view = PageOverlayView(host: host, webView: webView, onClose: onClose)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}

/// The overlay's root view: a header naming the page's host with a Close button, above the web view.
/// It is modal to VoiceOver, and the accessibility escape gesture closes the page like Close does.
@MainActor
final class PageOverlayView: UIView {
    private let onClose: @MainActor () -> Void

    init(host: String, webView: WKWebView, onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        accessibilityViewIsModal = true

        let header = UIView()
        header.backgroundColor = .secondarySystemBackground
        header.translatesAutoresizingMaskIntoConstraints = false

        let hostLabel = UILabel()
        hostLabel.text = host
        hostLabel.font = .preferredFont(forTextStyle: .headline)
        hostLabel.adjustsFontForContentSizeCategory = true
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Close", for: .normal)
        closeButton.accessibilityLabel = "Close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .primaryActionTriggered)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        header.addSubview(hostLabel)
        header.addSubview(closeButton)
        addSubview(webView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            hostLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            hostLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: header.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @objc private func closeTapped() {
        onClose()
    }

    override func accessibilityPerformEscape() -> Bool {
        onClose()
        return true
    }
}
