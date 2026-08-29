import AppKit
import FineDisplayKit

/// Update check without auto-update machinery: ask GitHub for the latest release,
/// compare versions, and offer the download page. Manual via the menu; a quiet daily
/// check mentions each new version once.
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let latestURL = URL(string: "https://api.github.com/repos/ofbakirci/finedisplay/releases/latest")!
    private let notifiedKey = "updateNotifiedVersion"
    private var timer: Timer?
    private let defaults = UserDefaults(suiteName: Preferences.suiteName) ?? .standard

    struct Latest {
        let version: String
        let page: URL
    }

    func startDailyChecks() {
        // Not at launch — no reason to hit the network before the app is even useful.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
    }

    func check(manual: Bool) {
        fetchLatest { [weak self] latest in
            DispatchQueue.main.async { self?.present(latest, manual: manual) }
        }
    }

    func fetchLatest(completion: @escaping (Latest?) -> Void) {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                completion(nil)
                return
            }
            completion(Latest(version: tag, page: page))
        }.resume()
    }

    private func present(_ latest: Latest?, manual: Bool) {
        guard let latest else {
            if manual { info("Could not check for updates", "GitHub did not answer. Try again later.") }
            return
        }
        guard FineDisplayInfo.isNewer(latest.version, than: FineDisplayInfo.version) else {
            if manual { info("You're up to date", "FineDisplay \(FineDisplayInfo.version) is the latest version.") }
            return
        }
        if !manual, defaults.string(forKey: notifiedKey) == latest.version { return }

        // Accessory apps have no focus; without activation the alert can open buried.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "FineDisplay \(latest.version.trimmingCharacters(in: CharacterSet(charactersIn: "v"))) is available"
        alert.informativeText = "You have \(FineDisplayInfo.version). The download opens in your browser."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        // Mark only after the alert was actually dismissed by the user.
        defaults.set(latest.version, forKey: notifiedKey)
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(latest.page)
        }
    }

    private func info(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
