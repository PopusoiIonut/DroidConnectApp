import SwiftUI
import WebKit

class Coordinator: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "nativeAppBridge", let msgString = message.body as? String {
            DispatchQueue.main.async {
                let alert = NSAlert()
                if msgString == "device_required_files" || msgString == "device_required_mirror" {
                    alert.messageText = "Device Required"
                    alert.informativeText = "Please connect an Android handset via USB or Wireless ADB to use this feature."
                    alert.alertStyle = .warning
                } else if msgString == "start_mirroring" {
                    alert.messageText = "Initializing Screen Stream"
                    alert.informativeText = "Preparing ADB and launching scrcpy..."
                    alert.alertStyle = .informational
                } else {
                    alert.messageText = "Action Received"
                    alert.informativeText = "ID: \(msgString)"
                    alert.alertStyle = .informational
                }
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}

struct WebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "nativeAppBridge")
        configuration.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.clear
            
            if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html") {
                WebView(url: indexURL)
                    .ignoresSafeArea()
            } else {
                VStack {
                    Text("⚠️")
                        .font(.system(size: 60))
                    Text("Resource 'index.html' not found.")
                        .font(.headline)
                        .padding()
                }
            }
        }
        .background(VisualEffectView().ignoresSafeArea())
    }
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                window.isMovableByWindowBackground = true
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.minSize = NSSize(width: 800, height: 600)
            }
        }
    }
}
