import SwiftUI
import WebKit

public struct KimiWebView: NSViewRepresentable {
    let url: URL
    @Binding var reloadTrigger: UUID
    @Binding var estimatedProgress: Double

    public init(url: URL, reloadTrigger: Binding<UUID>, estimatedProgress: Binding<Double> = .constant(0.0)) {
        self.url = url
        self._reloadTrigger = reloadTrigger
        self._estimatedProgress = estimatedProgress
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = preferences
        #if DEBUG
        // 仅调试构建开放 Inspect Element，生产包不暴露
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        // 注册页面 → 原生的通知桥与 Agent 遥测桥
        config.userContentController.add(context.coordinator, name: "kimiNotify")
        config.userContentController.add(context.coordinator, name: "kimiTelemetry")

        // 注入 WebSocket 监听脚本（捕获 Agent 事件、SubAgent、Token 速度与缓存）
        // 注意：必须保留 window.WebSocket 的身份（静态常量 CONNECTING/OPEN/CLOSING/CLOSED
        // 与 prototype）。前端 Kimi web 的 stream 状态机会读 WebSocket.OPEN 等常量做
        // readyState 比较；如果直接覆盖构造器丢失这些常量，stream 会卡在「请求中」。
        // 修复点：仅 wrap 实例的 addEventListener 与 send，原型链与静态属性全部保留。
        let telemetryShim = """
        (function() {
            try {
                const OrigWS = window.WebSocket;
                if (!OrigWS || window.__kimi_ws_hooked__) return;
                window.__kimi_ws_hooked__ = true;

                const FILTER_TOKENS = ['usage','token','subagent','agent','step.','turn.','streamDuration','firstToken','dock','task','busy','pending_interaction','session_id'];

                function HookedWS(url, protocols) {
                    const ws = protocols !== undefined ? new OrigWS(url, protocols) : new OrigWS(url);

                    // 包装 addEventListener：仅拦截 'message' 事件做 telemetry 转发，
                    // 不影响 open/close/error/其他 message 监听器的多路注册语义。
                    const origAdd = ws.addEventListener.bind(ws);
                    ws.addEventListener = function(type, listener, options) {
                        if (type === 'message' && typeof listener === 'function') {
                            const wrapped = function(ev) {
                                try {
                                    if (typeof ev.data === 'string') {
                                        const text = ev.data;
                                        for (let i = 0; i < FILTER_TOKENS.length; i++) {
                                            if (text.indexOf(FILTER_TOKENS[i]) !== -1) {
                                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kimiTelemetry) {
                                                    window.webkit.messageHandlers.kimiTelemetry.postMessage(text);
                                                }
                                                break;
                                            }
                                        }
                                    }
                                } catch (err) {}
                                return listener.call(this, ev);
                            };
                            return origAdd(type, wrapped, options);
                        }
                        return origAdd(type, listener, options);
                    };

                    const origSend = ws.send.bind(ws);
                    ws.send = function(data) {
                        try {
                            if (typeof data === 'string' && (data.indexOf('session_id') !== -1 || data.indexOf('subscribe') !== -1)) {
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kimiTelemetry) {
                                    window.webkit.messageHandlers.kimiTelemetry.postMessage(data);
                                }
                            }
                        } catch (e) {}
                        return origSend(data);
                    };

                    // 直接返回原生 ws 实例，避免再次 new 引发的 prototype 链断裂。
                    return ws;
                }

                // 保留 WebSocket 身份：prototype + 全部静态属性
                // （CONNECTING/OPEN/CLOSING/CLOSED 必须在 HookedWS 上可读，
                //  否则前端 stream 状态机立刻坏掉，spinner 永远停不下来）。
                HookedWS.prototype = OrigWS.prototype;
                Object.setPrototypeOf(HookedWS, OrigWS);
                const STATIC_KEYS = ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED'];
                for (let i = 0; i < STATIC_KEYS.length; i++) {
                    const k = STATIC_KEYS[i];
                    try { HookedWS[k] = OrigWS[k]; } catch (e) {}
                }
                // 兜底：复制浏览器可能定义的其他静态属性（兼容性扩展）
                const origKeys = Object.getOwnPropertyNames(OrigWS);
                for (let i = 0; i < origKeys.length; i++) {
                    const k = origKeys[i];
                    if (!(k in HookedWS)) {
                        try {
                            const desc = Object.getOwnPropertyDescriptor(OrigWS, k);
                            if (desc) Object.defineProperty(HookedWS, k, desc);
                        } catch (e) {}
                    }
                }

                window.WebSocket = HookedWS;

                // 监听 URL 或前端状态切换会话
                window.addEventListener('hashchange', function() {
                    const m = window.location.href.match(/session_[a-zA-Z0-9\\-]+/);
                    if (m && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.kimiTelemetry) {
                        window.webkit.messageHandlers.kimiTelemetry.postMessage(JSON.stringify({
                            type: "session_switched",
                            session_id: m[0]
                        }));
                    }
                });
            } catch(e) {}
        })();
        """
        let telemetryScript = WKUserScript(source: telemetryShim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(telemetryScript)

        // 页面 Notification API shim：kimi web 任务完成时若调用 Notification，
        // 自动授予权限并转发给原生本地通知（窗口隐藏后也能收到提醒）。
        let notificationShim = """
        (function() {
            try {
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.kimiNotify) return;
                function ShimNotification(title, options) {
                    options = options || {};
                    this.title = title;
                    this.body = options.body || '';
                    this.tag = options.tag || '';
                    try {
                        window.webkit.messageHandlers.kimiNotify.postMessage(JSON.stringify({
                            title: String(title || 'Kimi Code'),
                            body: String(this.body)
                        }));
                    } catch (e) {}
                }
                ShimNotification.prototype.close = function() {};
                ShimNotification.prototype.addEventListener = function() {};
                ShimNotification.prototype.removeEventListener = function() {};
                ShimNotification.prototype.dispatchEvent = function() { return false; };
                ShimNotification.permission = 'granted';
                ShimNotification.maxActions = 0;
                ShimNotification.requestPermission = function(callback) {
                    if (typeof callback === 'function') {
                        setTimeout(function() { callback('granted'); }, 0);
                    }
                    return Promise.resolve('granted');
                };
                window.Notification = ShimNotification;
            } catch (e) {}
        })();
        """
        let shimScript = WKUserScript(source: notificationShim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(shimScript)

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
            // 加载底色跟随系统外观：深色给深底、浅色给白底，避免闪色
            context.coordinator.applyUnderPageBackground(to: webView)
            context.coordinator.appearanceObservation = webView.observe(
                \.effectiveAppearance,
                options: [.initial]
            ) { [weak coordinator = context.coordinator] webView, _ in
                coordinator?.applyUnderPageBackground(to: webView)
            }
        }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        // 监听网页加载真实进度
        context.coordinator.progressObservation = webView.observe(
            \.estimatedProgress,
            options: [.new]
        ) { [weak coordinator = context.coordinator] wv, _ in
            DispatchQueue.main.async {
                coordinator?.parent.estimatedProgress = wv.estimatedProgress
            }
        }

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

    public class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: KimiWebView
        weak var webView: WKWebView?
        var lastReloadID: UUID?
        /// 跟随系统外观更新加载底色用的 KVO 句柄
        var appearanceObservation: NSKeyValueObservation?
        /// 页面加载进度 KVO
        var progressObservation: NSKeyValueObservation?

        init(_ parent: KimiWebView) {
            self.parent = parent
            self.lastReloadID = parent.reloadTrigger
        }

        func applyUnderPageBackground(to webView: WKWebView) {
            let isDark = webView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            webView.underPageBackgroundColor = isDark
                ? NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
                : NSColor.white
        }

        // MARK: - 导航策略：外链一律交给系统浏览器，避免把整个 App 导航走

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url, let host = url.host else {
                decisionHandler(.allow)
                return
            }
            let isLocal = host == "127.0.0.1" || host == "localhost"
            let isUserLink = navigationAction.navigationType == .linkActivated
            if !isLocal && (isUserLink || navigationAction.targetFrame == nil) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: - target="_blank" / window.open：本机链接在当前 WebView 加载，外链走系统浏览器

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if let host = url.host, host != "127.0.0.1" && host != "localhost" {
                NSWorkspace.shared.open(url)
            } else {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: - 页面通知桥与 Agent 遥测桥

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "kimiTelemetry", let raw = message.body as? String {
                AgentTelemetryManager.shared.handleIncomingTelemetryJSON(raw)
                return
            }

            guard message.name == "kimiNotify" else { return }
            // 启动冷却期内的通知直接吞掉。kimi web 在 App 启动 / 重新加载页面后
            // 会按 session 状态补一次「任务完成」通知，属于历史残留（任务在 App
            // 关闭期间已经完成，前端在恢复时只是重放），与用户当前操作无关。
            if NotificationGate.shared.isInQuietPeriod { return }

            var title = "Kimi Code"
            var body = ""
            if let raw = message.body as? String,
               let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let t = obj["title"] as? String, !t.isEmpty { title = t }
                if let b = obj["body"] as? String { body = b }
            }
            AppNotifications.post(title: title, body: body)
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
