import Foundation

final class ADBService {
    static let shared = ADBService()
    private init() {}
    
    // MARK: - Binary Detection Logic
    
    private func getAdbPath() -> (path: String?, checked: [String]) {
        var checkedPaths: [String] = []
        
        // 1. PRIORITIZE the known local path (since the bundled one is causing SIGTRAP)
        let localPath = "/Users/user/Documents/Documents - USER’s MacBook Air/projects/adb_tools/platform-tools/adb"
        checkedPaths.append(localPath)
        if FileManager.default.fileExists(atPath: localPath) {
            return (localPath, ["Local (Verified): \(localPath)"])
        }

        // 2. Try common system paths
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

        // 3. Try bundled binary as last resort
        if let bundled = binaryURL(named: "adb") {
            return (bundled.path, ["Bundled: \(bundled.path)"])
        }
        checkedPaths.append("(Bundled App Resources)")
        
        // 4. Check shell PATH
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
        guard let scrcpy = activeScrcpyPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: scrcpy)
            task.arguments = ["-s", deviceId]
            try? task.run()
        }
    }
    
    func pairDevice(address: String, code: String) -> String {
        guard let adb = getAdbPath().path else { return "ADB not found" }
        return runCommand(path: adb, arguments: ["pair", address, code]).output
    }
    
    func listFiles(deviceId: String, path: String = "/sdcard/") -> [String] {
        guard let adb = getAdbPath().path else { return [] }
        let output = runCommand(path: adb, arguments: ["-s", deviceId, "shell", "ls", "-F", path]).output
        return output.components(separatedBy: .newlines).filter { !$0.isEmpty }
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
}
