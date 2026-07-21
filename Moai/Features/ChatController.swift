import SwiftUI
import WebKit

/// A chat service in the island: the real site in a panel, no API
/// key. The user picks whose subscription they bring (Claude,
/// ChatGPT, or Gemini) and signs in with their own account; the
/// login lives in the default website data store and survives
/// relaunches. The web view is created on first use and kept alive
/// so the conversation survives collapses. Moai is not affiliated
/// with any of these services; this is a small site-specific browser.
@MainActor
final class ChatController: NSObject, ObservableObject {
    enum Service: String, CaseIterable {
        case claude, chatgpt, gemini

        var home: URL {
            switch self {
            case .claude: return URL(string: "https://claude.ai/new")!
            case .chatgpt: return URL(string: "https://chatgpt.com")!
            case .gemini: return URL(string: "https://gemini.google.com/app")!
            }
        }
    }

    /// Settings key holding the chosen service's raw value.
    static let serviceKey = "chatService"

    private var service: Service {
        Service(rawValue: UserDefaults.standard.string(forKey: Self.serviceKey) ?? "") ?? .claude
    }

    @Published private(set) var isLoading = true
    private var lastServiceRaw: String?

    override init() {
        super.init()
        lastServiceRaw = UserDefaults.standard.string(forKey: Self.serviceKey)
        // The settings picker writes a default; the pane follows
        // without a relaunch, but only if it was ever opened.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.serviceMayHaveChanged() }
        }
    }

    private func serviceMayHaveChanged() {
        let raw = UserDefaults.standard.string(forKey: Self.serviceKey)
        guard raw != lastServiceRaw else { return }
        lastServiceRaw = raw
        guard createdWebView != nil else { return }
        goHome()
    }

    /// A quiet coat of Moai over claude.ai: pure black behind the
    /// chat so the card melts into the island, and slim scrollbars.
    /// Unknown selectors no-op harmlessly if the site changes.
    private static let blendCSS = "html,body{background:#000 !important}"
        + ":root{--bg-000:#000;--bg-100:#000}"
        + "::-webkit-scrollbar{width:6px;height:6px}"
        + "::-webkit-scrollbar-thumb{background:rgba(255,255,255,.14);border-radius:3px}"
        + "::-webkit-scrollbar-track,::-webkit-scrollbar-corner{background:transparent}"

    private var createdWebView: WKWebView?

    var webView: WKWebView {
        if let createdWebView { return createdWebView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let styler = WKUserScript(
            source: "var s=document.createElement('style');"
                + "s.textContent=\"\(Self.blendCSS)\";"
                + "document.documentElement.appendChild(s);",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(styler)
        let web = WKWebView(frame: .zero, configuration: configuration)
        // Page zoom is owned by ChatPane: compact and full modes
        // each set their own scale on attach.
        // Trackpad swipes travel the chat history like a browser.
        web.allowsBackForwardNavigationGestures = true
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
        web.load(URLRequest(url: service.home))
        createdWebView = web
        return web
    }

    func goHome() {
        webView.load(URLRequest(url: service.home))
    }

    func goBack() {
        if webView.canGoBack { webView.goBack() }
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
    @State private var hovered = false
    /// Compact keeps the island at its everyday width and a single
    /// column; full grows to the desktop layout with the sidebar.
    @AppStorage("chatFull") private var chatFull = false

    var body: some View {
        ZStack {
            ChatWebView(webView: chat.webView, zoom: chatFull ? 0.8 : 0.75)
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
        // A login page can dead-end with no way out; back and home
        // float in on hover so a stuck page is never a trap, and the
        // expand glyph trades footprint for the sidebar layout.
        .overlay(alignment: .topTrailing) {
            if hovered {
                HStack(spacing: Theme.Space.xs) {
                    HoverGlyphButton(
                        symbol: "chevron.left", scale: .s, tint: Theme.textSecondary
                    ) {
                        chat.goBack()
                    }
                    HoverGlyphButton(
                        symbol: "house", scale: .s, tint: Theme.textSecondary
                    ) {
                        chat.goHome()
                    }
                    HoverGlyphButton(
                        symbol: chatFull
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        scale: .s,
                        tint: Theme.textSecondary
                    ) {
                        chatFull.toggle()
                    }
                }
                .padding(Theme.Space.xs)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .padding(Theme.Space.s)
                .transition(.opacity)
            }
        }
        .onHover { hovered = $0 }
        .animation(Theme.Motion.hover, value: hovered)
        .animation(Theme.Motion.content, value: chat.isLoading)
    }
}

private struct ChatWebView: NSViewRepresentable {
    let webView: WKWebView
    let zoom: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        webView.pageZoom = zoom
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if nsView.pageZoom != zoom { nsView.pageZoom = zoom }
    }
}
