import Foundation

class ADBService {
    static let shared = ADBService()
    
    // Common paths for ADB - in a bundled app, this would point to the internal Resources folder
    private var activeAdbPath: String? {
        // 1. Try bundled binary first
        if let bundledPath = Bundle.main.path(forResource: "adb", ofType: nil) {
            return bundledPath
        }
        
        // 2. Fallback to common system paths
        let adbPaths = [
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            "/usr/bin/adb"
        ]
        
        for path in adbPaths {
            if FileManager.default.fileExists(atPath: path) {
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
