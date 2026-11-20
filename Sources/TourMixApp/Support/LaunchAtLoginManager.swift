import AppKit
import Foundation
import Observation

/// Manages `/Applications` installation check, one-click move/copy to `/Applications`,
/// and resilient Launch-at-Login persistence via `~/Library/LaunchAgents/com.soundlab.tourmix.plist`
/// (immune to ad-hoc code-signing CDHash churn and Desktop TCC launchd blocks).
@MainActor
@Observable
public final class LaunchAtLoginManager {
    public static let agentLabel = "com.soundlab.tourmix"
    public static let appBundleName = "TourMix.app"
    public static let executableName = "TourMix"

    private var storedIsEnabled: Bool = false

    /// Whether `~/Library/LaunchAgents/com.soundlab.tourmix.plist` is currently active with `RunAtLoad = true`.
    public var isEnabled: Bool {
        get { storedIsEnabled }
        set {
            guard newValue != storedIsEnabled else { return }
            setEnabled(newValue)
        }
    }

    /// Standardized path of the currently running bundle (e.g. `Bundle.main.bundlePath`).
    public private(set) var currentBundlePath: String

    /// `true` when the currently running process itself lives inside `/Applications` or `~/Applications`.
    public private(set) var isRunningFromApplications: Bool = false

    /// `true` when `Bundle.main.bundlePath` is in `/Applications` or `~/Applications` (or after `installToApplications()` succeeds).
    public private(set) var isInstalledInApplications: Bool = false

    /// Path of the executable currently written in `com.soundlab.tourmix.plist`, if enabled.
    public private(set) var registeredExecutablePath: String?

    /// Human-readable error message from the last copy or plist write operation, if any.
    public private(set) var lastError: String?

    public let launchAgentPlistURL: URL
    private let fallbackExecutablePath: String?

    public init(
        bundlePath: String = Bundle.main.bundlePath,
        executablePath: String? = Bundle.main.executablePath,
        launchAgentPlistURL: URL? = nil
    ) {
        self.currentBundlePath = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        self.fallbackExecutablePath = executablePath
        if let launchAgentPlistURL {
            self.launchAgentPlistURL = launchAgentPlistURL
        } else {
            self.launchAgentPlistURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(Self.agentLabel).plist")
        }
        refresh()
    }

    /// Checks whether a given `.app` path resides under `/Applications` or `~/Applications`.
    public static func isPathInApplicationsDirectory(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasSuffix(".app") else { return false }

        let systemAppsPrefix = "/Applications/"
        let userAppsPrefix = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .standardizedFileURL.path + "/"

        return standardized.hasPrefix(systemAppsPrefix) || standardized.hasPrefix(userAppsPrefix)
    }

    /// Re-reads bundle installation location and `~/Library/LaunchAgents/com.soundlab.tourmix.plist` state.
    public func refresh() {
        let runningInApps = Self.isPathInApplicationsDirectory(currentBundlePath)
        self.isRunningFromApplications = runningInApps
        self.isInstalledInApplications = runningInApps || preferredInstalledAppBundleURL() != nil

        let fm = FileManager.default
        guard fm.fileExists(atPath: launchAgentPlistURL.path),
              let data = try? Data(contentsOf: launchAgentPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            self.storedIsEnabled = false
            self.registeredExecutablePath = nil
            return
        }

        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? true
        let args = plist["ProgramArguments"] as? [String]
        let execPath = args?.first ?? (plist["Program"] as? String)

        if runAtLoad, let execPath, !execPath.isEmpty {
            self.storedIsEnabled = true
            self.registeredExecutablePath = execPath
        } else {
            self.storedIsEnabled = false
            self.registeredExecutablePath = execPath
        }
    }

    /// Toggles Launch at Login on or off.
    public func toggle() {
        setEnabled(!storedIsEnabled)
    }

    /// Enables or disables Launch at Login by writing or removing `~/Library/LaunchAgents/com.soundlab.tourmix.plist`.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        let fm = FileManager.default

        if enabled {
            guard let targetExecutable = resolveExecutableForLaunchAgent() else {
                lastError = "未找到可写入开机自启项的 TourMix 可执行文件路径。"
                refresh()
                return false
            }

            let plistDict: [String: Any] = [
                "Label": Self.agentLabel,
                "ProgramArguments": [targetExecutable],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]

            do {
                let parentDir = launchAgentPlistURL.deletingLastPathComponent()
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plistDict,
                    format: .xml,
                    options: 0
                )
                try data.write(to: launchAgentPlistURL, options: .atomic)
                storedIsEnabled = true
                registeredExecutablePath = targetExecutable
                return true
            } catch {
                lastError = "写入 LaunchAgents 失败：\(error.localizedDescription)"
                refresh()
                return false
            }
        } else {
            do {
                if fm.fileExists(atPath: launchAgentPlistURL.path) {
                    try fm.removeItem(at: launchAgentPlistURL)
                }
                storedIsEnabled = false
                registeredExecutablePath = nil
                return true
            } catch {
                lastError = "移除 LaunchAgents 失败：\(error.localizedDescription)"
                refresh()
                return false
            }
        }
    }

    /// Copies the `.app` bundle into `/Applications/TourMix.app` (falling back to `~/Applications/TourMix.app`
    /// if `/Applications` is not writable by the current user). Optionally launches the installed copy and exits.
    @discardableResult
    public func installToApplications(relaunch: Bool = false) -> Bool {
        lastError = nil
        guard let sourceAppURL = locateSourceAppBundleURL() else {
            lastError = "当前未以 .app 应用包运行，请先执行 ./scripts/build_app.sh --install。"
            return false
        }

        let fm = FileManager.default
        let systemDest = URL(fileURLWithPath: "/Applications/\(Self.appBundleName)")
        let userAppsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let userDest = userAppsDir.appendingPathComponent(Self.appBundleName)

        let destinationURL: URL
        if fm.isWritableFile(atPath: "/Applications") {
            destinationURL = systemDest
        } else {
            do {
                try fm.createDirectory(at: userAppsDir, withIntermediateDirectories: true)
                destinationURL = userDest
            } catch {
                lastError = "无法创建应用程序目录：\(error.localizedDescription)"
                return false
            }
        }

        if sourceAppURL.standardizedFileURL == destinationURL.standardizedFileURL {
            refresh()
            return true
        }

        do {
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try copyAppBundlePreservingSignature(from: sourceAppURL, to: destinationURL)

            isInstalledInApplications = true
            // If Launch at Login was already enabled (e.g. pointing at dist/), re-point it to /Applications!
            if storedIsEnabled {
                _ = setEnabled(true)
            } else {
                refresh()
            }

            if relaunch {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: destinationURL, configuration: config) { _, error in
                    if error == nil {
                        Task { @MainActor in
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
            return true
        } catch {
            lastError = "复制到 \(destinationURL.path) 失败：\(error.localizedDescription)"
            refresh()
            return false
        }
    }

    // MARK: - Private Helpers

    private func preferredInstalledAppBundleURL() -> URL? {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/\(Self.appBundleName)"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(Self.appBundleName)")
        ]
        for url in candidates {
            let execURL = url.appendingPathComponent("Contents/MacOS/\(Self.executableName)")
            if fm.isExecutableFile(atPath: execURL.path) {
                return url
            }
        }
        return nil
    }

    private func locateSourceAppBundleURL() -> URL? {
        let fm = FileManager.default
        if currentBundlePath.hasSuffix(".app"), fm.fileExists(atPath: currentBundlePath) {
            return URL(fileURLWithPath: currentBundlePath)
        }
        let cwdDist = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("dist/\(Self.appBundleName)")
        if fm.fileExists(atPath: cwdDist.path) {
            return cwdDist
        }
        return nil
    }

    private func resolveExecutableForLaunchAgent() -> String? {
        let fm = FileManager.default

        // 1. If running directly from /Applications or ~/Applications, use this bundle's executable
        if Self.isPathInApplicationsDirectory(currentBundlePath) {
            let bundledExec = URL(fileURLWithPath: currentBundlePath)
                .appendingPathComponent("Contents/MacOS/\(Self.executableName)").path
            if fm.isExecutableFile(atPath: bundledExec) {
                return bundledExec
            }
        }

        // 2. If /Applications/TourMix.app (or ~/Applications/TourMix.app) already exists, prefer it over Desktop/dist
        if let installedApp = preferredInstalledAppBundleURL() {
            return installedApp.appendingPathComponent("Contents/MacOS/\(Self.executableName)").path
        }

        // 3. Fallback to current .app bundle executable or process executable
        if currentBundlePath.hasSuffix(".app") {
            let bundledExec = URL(fileURLWithPath: currentBundlePath)
                .appendingPathComponent("Contents/MacOS/\(Self.executableName)").path
            if fm.isExecutableFile(atPath: bundledExec) {
                return bundledExec
            }
        }

        return fallbackExecutablePath
    }

    private func copyAppBundlePreservingSignature(from source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ditto exit \(process.terminationStatus)"
            throw NSError(domain: "com.soundlab.TourMix.LaunchAtLogin", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errText
            ])
        }
    }
}
