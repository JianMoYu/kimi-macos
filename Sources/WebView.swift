import SwiftUI
import WebKit

public struct KimiWebView: NSViewRepresentable {
    let url: URL
    @Binding var reloadTrigger: UUID

    public init(url: URL, reloadTrigger: Binding<UUID>) {
        self.url = url
        self._reloadTrigger = reloadTrigger
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = preferences
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // 注入自动鉴权脚本
        if let token = KimiServiceManager.shared.fetchServerToken(), !token.isEmpty {
            let injectScript = """
            (function() {
                const token = "\(token)";
                if (!token) return;

                // 1. 预先向 localStorage 注入官方凭证，让前端免去弹窗
                try {
                    const existing = localStorage.getItem("kimi-web.server-credential");
                    if (!existing) {
                        const credentialData = {
                            version: 1,
                            credential: token,
                            expiresAt: Date.now() + 10080 * 60 * 1000
                        };
                        localStorage.setItem("kimi-web.server-credential", JSON.stringify(credentialData));
                    }
                } catch(e) {
                    console.error("Token injection error:", e);
                }

                // 2. 如果页面已经渲染了输入 Token 弹窗，自动填入并点击“连接”
                function tryAutoFill() {
                    const input = document.querySelector('input[placeholder="Token"]');
                    if (input && !input.value) {
                        input.value = token;
                        input.dispatchEvent(new Event('input', { bubbles: true }));
                        input.dispatchEvent(new Event('change', { bubbles: true }));
                        setTimeout(function() {
                            const buttons = Array.from(document.querySelectorAll('button'));
                            const btn = buttons.find(b => b.textContent && (b.textContent.includes('连接') || b.textContent.includes('Connect')));
                            if (btn) {
                                btn.click();
                            }
                        }, 120);
                    }
                }

                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', tryAutoFill);
                } else {
                    tryAutoFill();
                }

                // 3. 动态元素监听兜底
                const observer = new MutationObserver(function() {
                    tryAutoFill();
                });
                observer.observe(document.documentElement, { childList: true, subtree: true });
            })();
            """
            let userScript = WKUserScript(source: injectScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            config.userContentController.addUserScript(userScript)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
        }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
        webView.load(request)

        context.coordinator.webView = webView
        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastReloadID != reloadTrigger {
            context.coordinator.lastReloadID = reloadTrigger
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            nsView.load(request)
        }
    }

    public class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: KimiWebView
        weak var webView: WKWebView?
        var lastReloadID: UUID?

        init(_ parent: KimiWebView) {
            self.parent = parent
            self.lastReloadID = parent.reloadTrigger
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 页面加载完成后，再次兜底触发一次填入
            if let token = KimiServiceManager.shared.fetchServerToken(), !token.isEmpty {
                let js = """
                (function() {
                    const token = "\(token)";
                    const input = document.querySelector('input[placeholder="Token"]');
                    if (input && !input.value) {
                        input.value = token;
                        input.dispatchEvent(new Event('input', { bubbles: true }));
                        input.dispatchEvent(new Event('change', { bubbles: true }));
                        setTimeout(function() {
                            const buttons = Array.from(document.querySelectorAll('button'));
                            const btn = buttons.find(b => b.textContent && (b.textContent.includes('连接') || b.textContent.includes('Connect')));
                            if (btn) btn.click();
                        }, 120);
                    }
                })();
                """
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = NSAlert()
            alert.messageText = "Kimi Web"
            alert.informativeText = message
            alert.addButton(withTitle: "确定")
            alert.runModal()
            completionHandler()
        }

        public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = "Kimi Web"
            alert.informativeText = message
            alert.addButton(withTitle: "确定")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn)
        }
    }
}
