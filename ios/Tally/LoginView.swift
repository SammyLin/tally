import SwiftUI
import WebKit

/// Cloudflare Access login: load the backend in a web view; once navigation is back on the backend's host and
/// the CF_Authorization cookie exists, that cookie's value is the Access JWT we send as `cf-access-token`.
struct LoginView: View {
    let url: URL
    let onToken: (String) -> Void
    let onCancel: () -> Void
    @State private var loading = true
    @State private var host = ""

    var body: some View {
        NavigationStack {
            LoginWebView(url: url, loading: $loading, host: $host, onToken: onToken)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .top) { // no address bar in a web view: show where the credentials go
                    Label(host, systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("目前網站：\(host)")
                        .accessibilityIdentifier("login.host")
                }
                .overlay { if loading { ProgressView() } }
                .navigationTitle("登入 \(url.host() ?? "")")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var host: String
    let onToken: (String) -> Void

    nonisolated static let cookieName = "CF_Authorization"

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Google refuses sign-in from embedded web views that announce themselves; present as Mobile Safari.
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        private var done = false
        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.loading = true }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { parent.host = webView.url?.host() ?? "" }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loading = false
            guard !done, let host = parent.url.host()?.lowercased(), webView.url?.host()?.lowercased() == host else { return }
            Task {
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                if let jwt = LoginWebView.token(in: cookies, host: host), !done {
                    done = true
                    parent.onToken(jwt)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.loading = false }
    }

    nonisolated static func token(in cookies: [HTTPCookie], host: String) -> String? {
        cookies.first { c in
            let domain = c.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return c.name == cookieName && (host == domain || host.hasSuffix("." + domain))
                && (c.expiresDate.map { $0 > .now } ?? true)
        }?.value
    }

    /// Logout: forget the Access session cookie so the next login really asks again.
    static func clearCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in await store.allCookies() where c.name == cookieName { await store.deleteCookie(c) }
    }
}
