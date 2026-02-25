import Foundation

final class ADBService {
    static let shared = ADBService()
    private init() {}

    // MARK: - Public API expected by ContentView
    // Returns a list of connected device identifiers (strings). If adb is missing, return an empty list.
    func listDevices() -> [String] {
        guard let adbURL = binaryURL(named: "adb") else {
            NSLog("[ADBService] adb binary not found in app bundle Resources/Binaries.")
            return []
        }
        // Execute: adb devices -l and parse output. Keep it resilient; if anything fails, return empty.
        let output = runProcess(adbURL.path, arguments: ["devices", "-l"]) ?? ""
        // Parse lines that end with "device" or contain "device " after the serial.
        var devices: [String] = []
        output.split(separator: "\n").forEach { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip header line and empty lines
            guard !trimmed.isEmpty, !trimmed.lowercased().contains("list of devices") else { return }
            // Typical line: "ZY22D3ABC  device usb:3-4 product:..." or "emulator-5554  device"
            let parts = trimmed.split(separator: "\t").first ?? Substring(trimmed)
            let serial = parts.split(separator: " ").first.map(String.init) ?? String(parts)
            if !serial.isEmpty && trimmed.contains("device") && !trimmed.contains("unauthorized") && !trimmed.contains("offline") {
                devices.append(serial)
            }
        }
        return devices
    }

    // Attempts to start mirroring using scrcpy for the given device id.
    func startMirroring(deviceId: String) {
        guard let scrcpyURL = binaryURL(named: "scrcpy") else {
            NSLog("[ADBService] scrcpy binary not found in app bundle Resources/Binaries.")
            return
        }
        // Launch scrcpy detached so it doesn't block the app.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.runProcess(scrcpyURL.path, arguments: ["-s", deviceId])
        }
    }

    // MARK: - Helpers
    // Locate a binary in Resources/Binaries within the app bundle.
    private func binaryURL(named name: String) -> URL? {
        // The binaries are expected at Bundle.main.resourceURL/Resources/Binaries/<name>
        // Try common locations inside the bundle resources.
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

    // Run a process synchronously and return stdout as String.
    @discardableResult
    private func runProcess(_ launchPath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            NSLog("[ADBService] Failed to run process: \(launchPath) error: \(error)")
            return nil
        }

        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
