import Foundation
import AppKit

final class ADBService {
    static let shared = ADBService()
    
    private var serverProcess: Process?
    
    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.serverProcess?.terminate()
        }
    }
    
    func ensureAdbServerRunning() {
        guard let adbPath = getAdbPath().path else { return }
        
        if serverProcess == nil || !serverProcess!.isRunning {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["nodaemon", "server"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            
            do {
                try process.run()
                self.serverProcess = process
                Thread.sleep(forTimeInterval: 0.5)
            } catch {
                print("Failed to run adb nodaemon server: \(error)")
            }
        }
    }
    
    // MARK: - Binary Detection Logic
    
    func getAdbPath() -> (path: String?, checked: [String]) {
        var checkedPaths: [String] = []
        
        // 1. Try bundled binary FIRST (required and optimal for Sandboxed Mac App Store distribution)
        if let bundled = binaryURL(named: "adb") {
            return (bundled.path, ["Bundled: \(bundled.path)"])
        }
        checkedPaths.append("(Bundled App Resources not found)")
        
        // 2. Try common system paths (for legacy/diagnostics outside of strict sandbox constraints)
        let adbPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Android/sdk/platform-tools/adb"
        ]
        
        for path in adbPaths {
            checkedPaths.append(path)
            if FileManager.default.fileExists(atPath: path) {
                return (path, checkedPaths)
            }
        }
        
        // 3. Check shell PATH
        if let pathFromWhich = whichBinary("adb") {
            checkedPaths.append("(Shell PATH: \(pathFromWhich))")
            return (pathFromWhich, checkedPaths)
        }
        checkedPaths.append("(Not in shell PATH)")
        
        return (nil, checkedPaths)
    }
    
    private var activeScrcpyPath: String? {
        if let bundled = binaryURL(named: "scrcpy") {
            return bundled.path
        }
        let scrcpyPaths = ["/usr/local/bin/scrcpy", "/opt/homebrew/bin/scrcpy"]
        for path in scrcpyPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return whichBinary("scrcpy")
    }
    
    private var scrcpyServerPath: String? {
        // 1. App Store Sandboxed Resources Location FIRST
        let resourcePath = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/scrcpy-server").path
        if FileManager.default.fileExists(atPath: resourcePath) {
            return resourcePath
        }
        
        // 2. Fallback: search main bundle resources
        if let bundlePath = Bundle.main.path(forResource: "scrcpy-server", ofType: nil) {
            return bundlePath
        }
        
        // 3. Deep fallback to common host homebrew folders for development outside sandbox
        let fallbackPaths = [
            "/opt/homebrew/share/scrcpy/scrcpy-server",
            "/usr/local/share/scrcpy/scrcpy-server"
        ]
        for path in fallbackPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        return nil
    }
    
    private func binaryURL(named name: String) -> URL? {
        // 1. App Store Sandboxed Helper Location FIRST
        let helperCandidates = [
            Bundle.main.url(forAuxiliaryExecutable: name),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        ]
        for url in helperCandidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path) && FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Resources/Binaries"),
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Binaries"),
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/Binaries/\(name)", isDirectory: false),
            Bundle.main.resourceURL?.appendingPathComponent("Binaries/\(name)", isDirectory: false)
        ]
        for url in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path) {
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }
    
    private func whichBinary(_ name: String) -> String? {
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = [name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        
        if task.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                return path
            }
        }
        return nil
    }
    
    // MARK: - Public API
    
    func listDevices() -> (devices: [String], error: String?, raw: String) {
        ensureAdbServerRunning()
        
        let result = getAdbPath()
        guard let adb = result.path else {
            let pathsStr = result.checked.joined(separator: "\n• ")
            return ([], "ADB not found. Searched:\n• \(pathsStr)", "")
        }
        
        let versionRes = runCommand(path: adb, arguments: ["version"])
        var outputRes = runCommand(path: adb, arguments: ["devices", "-l"])
        
        // If empty, try one reset
        if outputRes.output.contains("List of devices attached") && outputRes.output.components(separatedBy: .newlines).count < 3 {
             _ = runCommand(path: adb, arguments: ["kill-server"])
             ensureAdbServerRunning() // Ensure foreground server restarts inside sandbox
             outputRes = runCommand(path: adb, arguments: ["devices", "-l"])
        }

        let output = outputRes.output
        let exitCode = outputRes.status
        
        if exitCode != 0 {
            let errorMsg = "ADB Failed (Exit Code: \(exitCode))\nPath: \(adb)\nOutput: \(output)"
            return ([], errorMsg, output)
        }
        
        if output.isEmpty {
            let errorMsg = "ADB produced NO output.\nPath: \(adb)\nVersion Res: \(versionRes.output) (Exit \(versionRes.status))"
            return ([], errorMsg, "")
        }
        
        let lines = output.components(separatedBy: .newlines)
        var devices: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.lowercased().contains("list of devices") else { continue }
            
            if (trimmed.contains("device") || trimmed.contains("unauthorized") || trimmed.contains("offline")) {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if !parts.isEmpty {
                    devices.append(parts[0])
                }
            }
        }
        
        let error: String? = devices.isEmpty ? "No devices found.\nADB Output:\n\(output)" : nil
        return (devices, error, output)
    }
    
    func startMirroring(deviceId: String) {
        ensureAdbServerRunning()
        guard let scrcpy = activeScrcpyPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: scrcpy)
            task.arguments = ["-s", deviceId]
            
            // Forward environment variables so scrcpy knows where to find our resolved binaries
            var env = ProcessInfo.processInfo.environment
            if let adbPath = self.getAdbPath().path {
                env["ADB"] = adbPath
            }
            if let serverPath = self.scrcpyServerPath {
                env["SCRCPY_SERVER_PATH"] = serverPath
            }
            task.environment = env
            
            try? task.run()
        }
    }
    
    func pairDevice(address: String, code: String) -> String {
        ensureAdbServerRunning()
        guard let adb = getAdbPath().path else { return "ADB not found" }
        return runCommand(path: adb, arguments: ["pair", address, code]).output
    }
    
    func connectDevice(address: String) -> String {
        ensureAdbServerRunning()
        guard let adb = getAdbPath().path else { return "ADB not found" }
        return runCommand(path: adb, arguments: ["connect", address]).output
    }
    
    func listFiles(deviceId: String, path: String = "/sdcard/") -> [String] {
        ensureAdbServerRunning()
        guard let adb = getAdbPath().path else { return [] }
        let escapedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let output = runCommand(path: adb, arguments: ["-s", deviceId, "shell", "ls", "-F", escapedPath]).output
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    func deleteFile(deviceId: String, path: String) -> String {
        ensureAdbServerRunning()
        guard let adb = getAdbPath().path else { return "ADB not found" }
        let escapedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return runCommand(path: adb, arguments: ["-s", deviceId, "shell", "rm", "-rf", escapedPath]).output
    }
    
    func createFolder(deviceId: String, path: String) -> String {
        ensureAdbServerRunning()
        guard let adb = getAdbPath().path else { return "ADB not found" }
        let escapedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return runCommand(path: adb, arguments: ["-s", deviceId, "shell", "mkdir", "-p", escapedPath]).output
    }
    
    func downloadFile(deviceId: String, path: String, destinationPath: String) -> String {
        ensureAdbServerRunning()
        guard let adb = getAdbPath().path else { return "ADB not found" }
        return runCommand(path: adb, arguments: ["-s", deviceId, "pull", path, destinationPath]).output
    }
    
    func uploadFile(deviceId: String, localPath: String, destinationDir: String) -> String {
        ensureAdbServerRunning()
        guard let adb = getAdbPath().path else { return "ADB not found" }
        return runCommand(path: adb, arguments: ["-s", deviceId, "push", localPath, destinationDir]).output
    }
    
    private func runCommand(path: String, arguments: [String]) -> (output: String, status: Int32) {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = arguments
        task.executableURL = URL(fileURLWithPath: path)
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output, task.terminationStatus)
        } catch {
            return ("Error: \(error.localizedDescription)", -1)
        }
    }
    
    // MARK: - Diagnostics Helper
    
    func isServerRunning() -> Bool {
        return serverProcess?.isRunning ?? false
    }
    
    func getDiagnostics() -> [String: Any] {
        let pathResult = getAdbPath()
        let adbPath = pathResult.path ?? "None (Not found)"
        let checkedPaths = pathResult.checked
        let serverRunning = isServerRunning()
        
        var rawOutput = ""
        var scanError = "None"
        
        if let adb = pathResult.path {
            let outputRes = runCommand(path: adb, arguments: ["devices", "-l"])
            rawOutput = outputRes.output
            
            let lines = rawOutput.components(separatedBy: .newlines)
            var count = 0
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.lowercased().contains("list of devices") else { continue }
                if (trimmed.contains("device") || trimmed.contains("unauthorized") || trimmed.contains("offline")) {
                    count += 1
                }
            }
            if count == 0 {
                scanError = "No devices found."
            }
        } else {
            scanError = "ADB path not found."
        }
        
        return [
            "adbPath": adbPath,
            "checkedPaths": checkedPaths,
            "serverRunning": serverRunning,
            "rawDevicesOutput": rawOutput,
            "scanError": scanError
        ]
    }
}
