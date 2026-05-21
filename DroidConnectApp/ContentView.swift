import SwiftUI
import WebKit

class Coordinator: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let msgString = message.body as? String else { return }
        
        if message.name == "nativeAppBridge" {
            DispatchQueue.main.async {
                let parts = msgString.components(separatedBy: "|")
                guard let command = parts.first else { return }
                
                switch command {
                case "scan_devices":
                    self.performScan()
                case "start_mirroring":
                    self.performMirror()
                case "pair_device":
                    self.performPair(message: msgString)
                case "connect_device":
                    self.performConnect(message: msgString)
                case "list_files":
                    self.performListFiles(message: msgString)
                case "delete_file":
                    self.performDeleteFile(message: msgString)
                case "download_file":
                    self.performDownloadFile(message: msgString)
                case "upload_file":
                    self.performUploadFile(message: msgString)
                case "create_folder":
                    self.performCreateFolder(message: msgString)
                case "get_diagnostics":
                    self.performDiagnostics()
                case "device_required_files", "device_required_mirror":
                    // Guide the user back to the dashboard tab and show setup guide
                    let js = "switchTab('dashboard'); showPanel('guide');"
                    self.webView?.evaluateJavaScript(js, completionHandler: nil)
                default:
                    self.showAlert(message: "Action Received", info: "ID: \(msgString)")
                }
            }
        }
    }
    
    private func performPair(message: String) {
        let parts = message.components(separatedBy: "|")
        guard parts.count == 3 else { return }
        let result = ADBService.shared.pairDevice(address: parts[1], code: parts[2])
        showAlert(message: "Pairing Result", info: result)
    }
    
    private func performConnect(message: String) {
        let parts = message.components(separatedBy: "|")
        guard parts.count == 2 else { return }
        let result = ADBService.shared.connectDevice(address: parts[1])
        
        // Scan devices immediately to update UI if connection succeeded
        self.performScan()
        
        showAlert(message: "Connection Result", info: result)
    }
    
    private func refreshFiles(deviceId: String, directory: String) {
        let files = ADBService.shared.listFiles(deviceId: deviceId, path: directory)
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: files, options: []),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let escapedJSPath = directory
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let js = "if(window.updateFileList) { window.updateFileList(\(jsonStr), '\(escapedJSPath)'); }"
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }
    
    private func performListFiles(message: String) {
        let parts = message.components(separatedBy: "|")
        let path = parts.count > 1 ? parts[1] : "/sdcard/"
        
        let result = ADBService.shared.listDevices()
        guard let first = result.devices.first else {
            showAlert(message: "File Browser Failed", info: result.error ?? "No device connected.")
            return
        }
        
        self.refreshFiles(deviceId: first, directory: path)
    }
    
    private func performDeleteFile(message: String) {
        let parts = message.components(separatedBy: "|")
        guard parts.count > 1 else { return }
        let path = parts[1]
        
        let result = ADBService.shared.listDevices()
        guard let first = result.devices.first else {
            showAlert(message: "Delete Failed", info: "No device connected.")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ADBService.shared.deleteFile(deviceId: first, path: path)
            let parentDir = self.getDirectoryOfPath(path)
            self.refreshFiles(deviceId: first, directory: parentDir)
        }
    }
    
    private func performDownloadFile(message: String) {
        let parts = message.components(separatedBy: "|")
        guard parts.count > 1 else { return }
        let remotePath = parts[1]
        let fileName = remotePath.components(separatedBy: "/").last ?? "downloaded_file"
        
        let result = ADBService.shared.listDevices()
        guard let first = result.devices.first else {
            showAlert(message: "Download Failed", info: "No device connected.")
            return
        }
        
        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.title = "Download File from Android"
            savePanel.nameFieldStringValue = fileName
            savePanel.prompt = "Save"
            savePanel.begin { response in
                if response == .OK, let destinationURL = savePanel.url {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let pullResult = ADBService.shared.downloadFile(
                            deviceId: first,
                            path: remotePath,
                            destinationPath: destinationURL.path
                        )
                        DispatchQueue.main.async {
                            if pullResult.lowercased().contains("error") || pullResult.lowercased().contains("fail") {
                                self.showAlert(message: "Download Failed", info: pullResult)
                            } else {
                                self.showAlert(message: "Download Successful", info: "Saved to: \(destinationURL.lastPathComponent)")
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func performUploadFile(message: String) {
        let parts = message.components(separatedBy: "|")
        let destinationDir = parts.count > 1 ? parts[1] : "/sdcard/"
        
        let result = ADBService.shared.listDevices()
        guard let first = result.devices.first else {
            showAlert(message: "Upload Failed", info: "No device connected.")
            return
        }
        
        DispatchQueue.main.async {
            let openPanel = NSOpenPanel()
            openPanel.title = "Select File to Upload to Android"
            openPanel.allowsMultipleSelection = false
            openPanel.canChooseDirectories = false
            openPanel.canChooseFiles = true
            openPanel.prompt = "Upload"
            openPanel.begin { response in
                if response == .OK, let fileURL = openPanel.url {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let pushResult = ADBService.shared.uploadFile(
                            deviceId: first,
                            localPath: fileURL.path,
                            destinationDir: destinationDir
                        )
                        DispatchQueue.main.async {
                            if pushResult.lowercased().contains("error") || pushResult.lowercased().contains("fail") {
                                self.showAlert(message: "Upload Failed", info: pushResult)
                            } else {
                                self.refreshFiles(deviceId: first, directory: destinationDir)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func performCreateFolder(message: String) {
        let parts = message.components(separatedBy: "|")
        let currentDir = parts.count > 1 ? parts[1] : "/sdcard/"
        
        let result = ADBService.shared.listDevices()
        guard let first = result.devices.first else {
            showAlert(message: "Create Folder Failed", info: "No device connected.")
            return
        }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "New Folder"
            alert.informativeText = "Enter folder name:"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            
            let inputTextField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            inputTextField.placeholderString = "Folder Name"
            alert.accessoryView = inputTextField
            
            if let window = self.webView?.window {
                alert.beginSheetModal(for: window) { modalResponse in
                    self.handleCreateFolderResponse(modalResponse, input: inputTextField.stringValue, currentDir: currentDir, deviceId: first)
                }
            } else {
                let modalResponse = alert.runModal()
                self.handleCreateFolderResponse(modalResponse, input: inputTextField.stringValue, currentDir: currentDir, deviceId: first)
            }
        }
    }
    
    private func handleCreateFolderResponse(_ response: NSApplication.ModalResponse, input: String, currentDir: String, deviceId: String) {
        if response == .alertFirstButtonReturn {
            let folderName = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderName.isEmpty else { return }
            
            let fullPath = currentDir + folderName + "/"
            
            DispatchQueue.global(qos: .userInitiated).async {
                let createResult = ADBService.shared.createFolder(deviceId: deviceId, path: fullPath)
                DispatchQueue.main.async {
                    if createResult.lowercased().contains("error") || createResult.lowercased().contains("fail") {
                        self.showAlert(message: "Create Folder Failed", info: createResult)
                    } else {
                        self.refreshFiles(deviceId: deviceId, directory: currentDir)
                    }
                }
            }
        }
    }
    
    private func getDirectoryOfPath(_ path: String) -> String {
        if path.hasSuffix("/") {
            let clean = String(path.dropLast())
            if let lastIdx = clean.lastIndex(of: "/") {
                return String(clean[...lastIdx])
            }
            return "/sdcard/"
        } else {
            if let lastIdx = path.lastIndex(of: "/") {
                return String(path[...lastIdx])
            }
            return "/sdcard/"
        }
    }
    
    private func performScan() {
        let result = ADBService.shared.listDevices()
        
        if result.devices.isEmpty {
            let errorMsg = result.error ?? "No device detected. (Empty response)"
            showAlert(message: "Connection Status", info: errorMsg)
        }
        
        // Return results to JS using robust JSON serialization
        if let jsonData = try? JSONSerialization.data(withJSONObject: result.devices, options: []),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let js = "if(window.updateDevices) { window.updateDevices(\(jsonStr)); }"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    private func performDiagnostics() {
        let diagnostics = ADBService.shared.getDiagnostics()
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: diagnostics, options: []),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            let js = "if(window.updateDiagnostics) { window.updateDiagnostics(\(jsonStr)); }"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    private func performMirror() {
        let result = ADBService.shared.listDevices()
        if let first = result.devices.first {
            ADBService.shared.startMirroring(deviceId: first)
        } else {
            let errorMsg = result.error ?? "No device connected to mirror."
            showAlert(message: "Mirroring Failed", info: errorMsg)
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
        
        // Inject dynamic App Sandbox detection status before the document loads
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let scriptSource = "window.isAppSandboxed = \(isSandboxed);"
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        userContentController.addUserScript(userScript)
        
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
                window.minSize = NSSize(width: 600, height: 450)
            }
        }
    }
}
