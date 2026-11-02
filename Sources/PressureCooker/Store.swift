import Foundation
import PressureCookerCore
import Security
import UserNotifications

@MainActor let store = Store()

@MainActor @Observable
final class Store {
    private(set) var snapshot: Snapshot?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var lastRefresh: Date?
    private(set) var tokenSource = ""  // "personal access token" / "gh CLI" / "" while there is none

    /// Accounts (users or orgs) whose repositories are watched; new repositories in them are picked up on every refresh.
    var owners = UserDefaults.standard.stringArray(forKey: "owners") ?? [] {
        didSet { UserDefaults.standard.set(owners, forKey: "owners"); changed() }
    }
    /// Repositories of the watched owners to leave out. Stored as exclusions so new repositories show up on their own.
    var excluded = Set(UserDefaults.standard.stringArray(forKey: "excluded") ?? []) {
        didSet { UserDefaults.standard.set(excluded.sorted(), forKey: "excluded"); changed() }
    }
    /// Also list everyone else's open PRs in the watched repositories.
    var showAll = UserDefaults.standard.bool(forKey: "showAll") {
        didSet { UserDefaults.standard.set(showAll, forKey: "showAll"); changed() }
    }
    /// People or bots (e.g. renovate) whose PRs are left out of everyone else's.
    var hiddenAuthors = UserDefaults.standard.stringArray(forKey: "hiddenAuthors") ?? [] {
        didSet { UserDefaults.standard.set(hiddenAuthors, forKey: "hiddenAuthors"); changed() }
    }
    /// Others' PRs I won't review, so they stop needing me. Applied without a refresh.
    // ponytail: ids of closed PRs stay in here; a few bytes each, prune them if that ever matters
    var skipped = Set(UserDefaults.standard.stringArray(forKey: "skipped") ?? []) {
        didSet { UserDefaults.standard.set(skipped.sorted(), forKey: "skipped"); snapshot?.skipped = skipped }
    }

    private var ghToken: String?
    private var skipNotify = true  // the first refresh is the baseline, not news
    private var again = false

    init() {
        UserDefaults.standard.register(defaults: [
            "refreshMinutes": 2.0, "notifyFailing": true, "notifyReady": true, "notifyReviews": true, "notifyDeployments": true,
        ])
    }

    func start() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(max(1, UserDefaults.standard.double(forKey: "refreshMinutes")) * 60))
            }
        }
    }

    func refresh() async {
        guard !loading else { again = true; return }
        loading = true
        defer {
            loading = false
            if again { again = false; Task { await refresh() } }
        }
        if isDemo {
            var demo = Snapshot.demo.hiding(authors: hiddenAuthors)
            demo.skipped = skipped
            (snapshot, lastRefresh, tokenSource) = (demo, .now, "demo data")
            return
        }
        guard let token = await token() else {
            error = "No GitHub token. Add one in Settings, or sign in with `gh auth login`."
            return
        }
        do {
            var new = try await GitHub(token: token).snapshot(owners: owners, excluded: excluded, showAll: showAll).hiding(authors: hiddenAuthors)
            new.skipped = skipped
            if let old = snapshot, !skipNotify { notify(events(from: old, to: new)) }
            (snapshot, error, lastRefresh, skipNotify) = (new, nil, .now, false)
        } catch {
            self.error = error.localizedDescription
            if (error as? GitHubError)?.isUnauthorized == true { ghToken = nil }  // gh may have a new token by now
        }
    }

    func setToken(_ token: String?) {
        Keychain.token = token
        changed()
    }

    /// Settings changed what is watched: refresh now, and don't announce what merely came into view.
    private func changed() {
        skipNotify = true
        Task { await refresh() }
    }

    private func token() async -> String? {
        if let token = Keychain.token {
            tokenSource = "personal access token"
            return token
        }
        if ghToken == nil { ghToken = await Task.detached { Self.readGhToken() }.value }
        tokenSource = ghToken == nil ? "" : "gh CLI"
        return ghToken
    }

    /// A login shell, because apps don't inherit the PATH that finds Homebrew's gh.
    nonisolated private static func readGhToken() -> String? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "gh auth token"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let token = output.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return process.terminationStatus == 0 && !token.isEmpty ? token : nil
    }

    private func notify(_ events: [Event]) {
        guard isBundled else { return }
        for event in events {
            let (key, title, body, url): (String, String, String, URL) = switch event {
            case .failing(let pr): ("notifyFailing", "Checks failed", "\(pr.repo) #\(pr.number): \(pr.title)", pr.url)
            case .ready(let pr): ("notifyReady", "Ready to merge", "\(pr.repo) #\(pr.number): \(pr.title)", pr.url)
            case .reviewRequested(let pr): ("notifyReviews", "\(pr.author) requests your review", "\(pr.repo) #\(pr.number): \(pr.title)", pr.url)
            case .deployment(let d): ("notifyDeployments", "\(d.environments.joined(separator: ", ")) waits for your approval", "\(d.repo): \(d.title)", d.url)
            }
            guard UserDefaults.standard.bool(forKey: key) else { continue }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = ["url": url.absoluteString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// The personal access token, kept in the login keychain.
enum Keychain {
    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.techtheory.pressurecooker",
         kSecAttrAccount as String: "github-token"]
    }

    static var token: String? {
        get {
            var out: AnyObject?
            let query = item.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            SecItemDelete(item as CFDictionary)
            guard let value = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            SecItemAdd(item.merging([kSecValueData as String: Data(value.utf8)]) { $1 } as CFDictionary, nil)
        }
    }
}
