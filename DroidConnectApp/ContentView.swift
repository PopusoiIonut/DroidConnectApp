import SwiftUI
import WebKit

class Coordinator: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let msgString = message.body as? String else { return }
        
        if message.name == "nativeAppBridge" {
            DispatchQueue.main.async {
                switch msgString {
                case "scan_devices":
                    self.performScan()
                case "start_mirroring":
                    self.performMirror()
                default:
                    self.showAlert(message: "Action Received", info: "ID: \(msgString)")
                }
            }
        }
    }
    
    private func performScan() {
        let devices = ADBService.shared.listDevices()
        let jsonArray = devices.description // Simple array string
        
        // Return results to JS
        let js = "if(window.updateDevices) { window.updateDevices(\(jsonArray)); }"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    
    private func performMirror() {
        let devices = ADBService.shared.listDevices()
        if let first = devices.first {
            ADBService.shared.startMirroring(deviceId: first)
        } else {
            showAlert(message: "Mirroring Failed", info: "No device connected to mirror.")
        }
    }
    
    private func showAlert(message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = (message.contains("Failed") || message.contains("Required")) ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        context.coordinator.webView = webView
        
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
