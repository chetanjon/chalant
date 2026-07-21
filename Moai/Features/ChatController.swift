import SwiftUI
import WebKit

/// Claude in the island: the real claude.ai session in a panel, no
/// API key. Sign in once; the login lives in the default website
/// data store and survives relaunches. The web view is created on
/// first use and kept alive so the conversation survives collapses.
@MainActor
final class ChatController: NSObject, ObservableObject {
    static let homeURL = URL(string: "https://claude.ai/new")!

    @Published private(set) var isLoading = true

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: configuration)
        // Google's sign-in refuses embedded browsers by user agent;
        // Safari's own string keeps every login door open.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"
            + " AppleWebKit/605.1.15 (KHTML, like Gecko)"
            + " Version/17.4 Safari/605.1.15"
        web.navigationDelegate = self
        web.uiDelegate = self
        // The pane is part of the island: dark, always.
        web.appearance = NSAppearance(named: .darkAqua)
        web.underPageBackgroundColor = .black
        web.load(URLRequest(url: Self.homeURL))
        return web
    }()

    func goHome() {
        webView.load(URLRequest(url: Self.homeURL))
    }
}

extension ChatController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
    }
}

extension ChatController: WKUIDelegate {
    /// Login flows love popups; route them through the same view
    /// instead of asking a panel to spawn windows.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

/// The chat surface: claude.ai as a quiet rounded card inside the
/// island, with a shimmer while pages settle.
struct ChatPane: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        ZStack {
            ChatWebView(webView: chat.webView)
                .clipShape(RoundedRectangle(
                    cornerRadius: Theme.Radius.card, style: .continuous
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            if chat.isLoading {
                ThinkingDots()
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.content, value: chat.isLoading)
    }
}

private struct ChatWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
