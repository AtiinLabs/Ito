import Combine
import SwiftUI
import WebKit

/// The source's website, for signing in. It runs in a private web data store seeded with the
/// source's stored cookies, so one source's sign-in never reaches another source or Safari.
/// Done keeps the site's cookies; Cancel discards everything.
struct PluginSignInSheet: View {
    @StateObject private var viewModel: PluginSignInViewModel
    @StateObject private var page: PluginSignInPage
    @Environment(\.dismiss) private var dismiss

    init(viewModel: PluginSignInViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _page = StateObject(wrappedValue: PluginSignInPage())
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let message = viewModel.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                PluginSignInWebView(page: page)
            }
            .navigationTitle("Sign In to \(viewModel.target.pluginName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            let cookies = await page.cookies()
                            if viewModel.finish(with: cookies) { dismiss() }
                        }
                    }
                    .disabled(!page.isReady)
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            await page.open(viewModel.target.siteURL, seeding: viewModel.existingCookies())
        }
    }
}

/// Owns the sign-in web view and its private data store.
@MainActor
final class PluginSignInPage: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var isReady = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func open(_ url: URL, seeding cookies: [HTTPCookie]) async {
        guard !isReady else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await store.setCookie(cookie)
        }
        isReady = true
        webView.load(URLRequest(url: url))
    }

    func cookies() async -> [HTTPCookie] {
        await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
    }

    /// The page may only move between web pages: other schemes (app links, files) are refused.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        let isWeb = scheme == "http" || scheme == "https" || scheme == "about"
        decisionHandler(isWeb ? .allow : .cancel)
    }
}

private struct PluginSignInWebView: UIViewRepresentable {
    let page: PluginSignInPage

    func makeUIView(context: Context) -> WKWebView { page.webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
