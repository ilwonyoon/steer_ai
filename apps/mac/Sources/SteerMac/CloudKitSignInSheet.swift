import SwiftUI
import WebKit

/// SwiftUI sheet that walks the user through CloudKit Web Services
/// sign-in. We open the redirect URL Apple gave us, let the user log
/// in with their Apple ID, then read the resulting `ckWebAuthToken`
/// out of the redirect via the API token's `Post Message` callback.
///
/// CloudKit Console issues an API token whose Sign-In Callback is set
/// to "Post Message", which means after a successful login the auth
/// page calls `window.parent.postMessage({ ckWebAuthToken: ... }, '*')`.
/// We intercept that with a WKScriptMessageHandler.
struct CloudKitSignInSheet: View {
    let initialURL: URL
    let onToken: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to iCloud")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            CloudKitAuthWebView(initialURL: initialURL, onToken: onToken)
                .frame(minWidth: 480, minHeight: 600)
        }
        .frame(width: 480, height: 640)
    }
}

private struct CloudKitAuthWebView: NSViewRepresentable {
    let initialURL: URL
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = config.userContentController
        userContent.add(context.coordinator, name: "ckAuth")

        // Bridge `window.postMessage` calls into the native handler.
        // CloudKit's Web Services auth page posts an object containing
        // `ckWebAuthToken` once the user signs in successfully.
        let script = """
        window.addEventListener('message', function(event) {
            try {
                if (event.data && event.data.ckWebAuthToken) {
                    window.webkit.messageHandlers.ckAuth.postMessage({
                        token: event.data.ckWebAuthToken
                    });
                }
            } catch (e) {
                window.webkit.messageHandlers.ckAuth.postMessage({
                    error: String(e)
                });
            }
        });
        """
        userContent.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: initialURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onToken: (String) -> Void

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "ckAuth",
                  let body = message.body as? [String: Any],
                  let token = body["token"] as? String,
                  !token.isEmpty
            else { return }
            onToken(token)
        }
    }
}
