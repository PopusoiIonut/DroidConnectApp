import Foundation

final class ADBService {
    static let shared = ADBService()
    private init() {}
    
    // MARK: - Binary Detection Logic
    
    private func getAdbPath() -> (path: String?, checked: [String]) {
        var checkedPaths: [String] = []
        
        // 1. Try bundled binary first
        if let bundled = binaryURL(named: "adb") {
            return (bundled.path, ["Bundled: \(bundled.path)"])
        }
        checkedPaths.append("(Bundled App Resources)")
        
        // 2. Common system paths
        let adbPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
            "/Users/user/Documents/Documents - USER’s MacBook Air/projects/adb_tools/platform-tools/adb",
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
    
    private func binaryURL(named name: String) -> URL? {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: nil),
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
                } else {
                    NSLog("[ADBService] Found binary at \(url.path) but it is NOT executable.")
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
    
    func listDevices() -> (devices: [String], error: String?) {
        let result = getAdbPath()
        guard let adb = result.path else {
            let pathsStr = result.checked.joined(separator: "\n• ")
            let errorMsg = "ADB not found. Searched:\n• \(pathsStr)"
            return ([], errorMsg)
        }
        
        let output = runCommand(path: adb, arguments: ["devices"])
        if output.starts(with: "Error:") { return ([], output) }
        
        let lines = output.components(separatedBy: .newlines)
        var devices: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.lowercased().contains("list of devices") else { continue }
            
            let parts = trimmed.components(separatedBy: .whitespaces)
            if parts.contains("device") {
                devices.append(parts[0].trimmingCharacters(in: .whitespaces))
            } else if trimmed.contains("unauthorized") {
                return ([], "Device found but unauthorized. Please check your phone for the 'Allow USB debugging' prompt.")
            } else if trimmed.contains("offline") {
                return ([], "Device is offline. Try reconnecting the cable.")
            }
        }
        return (devices, nil)
    }
    
    func startMirroring(deviceId: String) {
        guard let scrcpy = activeScrcpyPath else {
            NSLog("[ADBService] scrcpy binary not found.")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: scrcpy)
            task.arguments = ["-s", deviceId]
            do {
                try task.run()
            } catch {
                NSLog("[ADBService] Failed to launch scrcpy: \(error)")
            }
        }
    }
    
    func pairDevice(address: String, code: String) -> String {
        guard let adb = getAdbPath().path else { return "ADB not found" }
        return runCommand(path: adb, arguments: ["pair", address, code])
    }
    
    func listFiles(deviceId: String, path: String = "/sdcard/") -> [String] {
        guard let adb = getAdbPath().path else { return [] }
        let output = runCommand(path: adb, arguments: ["-s", deviceId, "shell", "ls", "-F", path])
        return output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
    
    private func runCommand(path: String, arguments: [String]) -> String {
        let task = Process()
        let pipe = Pipe()
        
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = arguments
        task.executableURL = URL(fileURLWithPath: path)
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
