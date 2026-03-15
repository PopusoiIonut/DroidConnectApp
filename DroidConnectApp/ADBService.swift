import Foundation

final class ADBService {
    static let shared = ADBService()
    private init() {}
    
    // MARK: - Binary Detection Logic
    
    private var activeAdbPath: String? {
        // 1. Try bundled binary first
        if let bundled = binaryURL(named: "adb") {
            return bundled.path
        }
        
        // 2. Common system paths
        let adbPaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Android/sdk/platform-tools/adb"
        ]
        
        for path in adbPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        
        // 3. Check shell PATH
        return whichBinary("adb")
    }
    
    private var activeScrcpyPath: String? {
        // 1. Try bundled binary first
        if let bundled = binaryURL(named: "scrcpy") {
            return bundled.path
        }
        
        // 2. Fallback to common system paths
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
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Resources/Binaries"),
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Binaries"),
            Bundle.main.resourceURL?.appendingPathComponent("Resources/Binaries/\(name)", isDirectory: false),
            Bundle.main.resourceURL?.appendingPathComponent("Binaries/\(name)", isDirectory: false)
        ]
        for url in candidates.compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
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
    
    func listDevices() -> [String] {
        guard let adb = activeAdbPath else {
            NSLog("[ADBService] adb binary not found in any path.")
            return []
        }
        
        let output = runCommand(path: adb, arguments: ["devices"])
        let lines = output.components(separatedBy: .newlines)
        
        var devices: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.lowercased().contains("list of devices") else { continue }
            
            let parts = trimmed.components(separatedBy: .whitespaces)
            if parts.contains("device") {
                devices.append(parts[0].trimmingCharacters(in: .whitespaces))
            }
        }
        return devices
    }
    
    func startMirroring(deviceId: String) {
        guard let scrcpy = activeScrcpyPath else {
            NSLog("[ADBService] scrcpy binary not found.")
            return
        }
        
        // Launch scrcpy as a detached process
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
        guard let adb = activeAdbPath else { return "ADB not found" }
        return runCommand(path: adb, arguments: ["pair", address, code])
    }
    
    func listFiles(deviceId: String, path: String = "/sdcard/") -> [String] {
        guard let adb = activeAdbPath else { return [] }
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
