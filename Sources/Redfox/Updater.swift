import AppKit
import Foundation

/// Checks the GitHub releases of rohitDurbha/Redfox and installs newer builds in place.
@MainActor
enum Updater {
    static let repository = "rohitDurbha/Redfox"
    private static let lastCheckKey = "redfox.lastUpdateCheck"

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Quietly checks at most once a day, and only speaks up when there is something new.
    static func checkInBackgroundIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 60 * 60 * 20 else { return }
        check(userInitiated: false)
    }

    static func check(userInitiated: Bool) {
        Task { @MainActor in
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Redfox/\(currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    if userInitiated { Alerts.message("No releases yet", "GitHub has not published a Redfox release yet. One appears a few minutes after each push to the main branch.") }
                    return
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard isNewer(latest, than: currentVersion),
                      let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
                    if userInitiated { Alerts.message("Redfox is up to date", "You are running version \(currentVersion), which is the newest release.") }
                    return
                }
                offer(version: latest, notes: release.body ?? "", dmg: dmg.browser_download_url, page: release.html_url)
            } catch {
                if userInitiated { Alerts.message("Could not check for updates", error.localizedDescription) }
            }
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func offer(version: String, notes: String, dmg: URL, page: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Redfox \(version) is available"
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have version \(currentVersion)."
            + (trimmed.isEmpty ? "" : "\n\nWhat changed in this release\n\(String(trimmed.prefix(600)))")
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(from: dmg)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(page)
        default: break
        }
    }

    /// Downloads the DMG, mounts it, and hands off to a tiny shell script that swaps the
    /// app bundle once this process has quit, then relaunches the new version.
    private static func install(from url: URL) {
        let target = Bundle.main.bundlePath
        guard target.hasSuffix(".app") else {
            Alerts.message("Redfox", "Updates can only be installed when Redfox runs from an app bundle in Applications.")
            return
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        JobRunner.batch("Downloading update") { progress in
            progress(0.1)
            let (downloaded, _) = try await URLSession.shared.download(from: url)
            let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("Redfox-update.dmg")
            try? FileManager.default.removeItem(at: dmg)
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            progress(0.7)

            let mount = FileManager.default.temporaryDirectory.appendingPathComponent("RedfoxUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try await Shell.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            let newApp = mount.appendingPathComponent("Redfox.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
                throw RFError("The downloaded update does not contain Redfox.app.")
            }
            progress(0.9)

            let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
            rm -rf "\(target)"
            /usr/bin/ditto "\(newApp.path)" "\(target)"
            /usr/bin/hdiutil detach "\(mount.path)" -quiet
            /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
            rm -f "\(dmg.path)"
            /usr/bin/open "\(target)"
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            try process.run()
            await MainActor.run { NSApp.terminate(nil) }
            return []
        }
    }
}
