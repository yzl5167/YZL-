import SwiftUI
import WebKit

/// 微软 v1.0 授权码流：登录完成后微软会重定向到
/// `https://login.live.com/oauth20_desktop.srf?code=...`。这里在 WKWebView 里
/// 拦下这次跳转、取出 code，不让页面真的加载（该地址只用于原生客户端回调）。
///
/// 之所以不用设备码流：`00000000402b5328` 是 MSA v1.0 原生客户端，只存在于
/// Live Connect 目录，不是 Azure 注册应用。设备码端点虽然会发 code，但用户
/// 在网页授权后 token 端点会返回 interaction_required，无法完成登录。
struct MicrosoftBrowserSignInView: UIViewRepresentable {
    let url: URL
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onCode: (String) -> Void
        private let onFailure: (String) -> Void
        private var finished = false

        init(onCode: @escaping (String) -> Void,
             onFailure: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onFailure = onFailure
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  let callback = MicrosoftAuthService.parseAuthorizationCallback(url) else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async {
                switch callback {
                case .code(let code):
                    self.onCode(code)
                case .failure(let message):
                    self.onFailure(message)
                }
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let nsError = error as NSError
            guard !finished, nsError.code != NSURLErrorCancelled else { return }
            finished = true
            DispatchQueue.main.async {
                self.onFailure("加载微软登录页失败：\(error.localizedDescription)")
            }
        }
    }
}
