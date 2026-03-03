import Foundation

class ADBService {
    static let shared = ADBService()
    
    // Common paths for ADB - for App Store compliance, we do not bundle adb
    private var activeAdbPath: String? {
        // 1. Common system paths (Homebrew, etc.)
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
        
        // 2. Check if it's in the PATH environment variable
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["adb"]
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
    
    private var activeScrcpyPath: String? {
        // 1. Try bundled binary first
        if let bundledPath = Bundle.main.path(forResource: "scrcpy", ofType: nil) {
            return bundledPath
        }
        
        // 2. Fallback to common system paths
        let scrcpyPaths = ["/usr/local/bin/scrcpy", "/opt/homebrew/bin/scrcpy"]
        for path in scrcpyPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    func listDevices() -> [String] {
        guard let adb = activeAdbPath else {
            print("ADBService: adb binary not found in common paths.")
            return []
        }
        
        let output = runCommand(path: adb, arguments: ["devices"])
        let lines = output.components(separatedBy: .newlines)
        
        var devices: [String] = []
        for line in lines {
            let parts = line.components(separatedBy: "\t")
            if parts.count == 2 && parts[1].trimmingCharacters(in: .whitespaces) == "device" {
                devices.append(parts[0].trimmingCharacters(in: .whitespaces))
            }
        }
        return devices
    }
    
    func startMirroring(deviceId: String) {
        guard let scrcpy = activeScrcpyPath else {
            print("ADBService: scrcpy binary not found.")
            return
        }
        
        // Launch scrcpy as a detached process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: scrcpy)
        task.arguments = ["-s", deviceId]
        
        do {
            try task.run()
        } catch {
            print("ADBService: Failed to launch scrcpy: \(error)")
        }
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
