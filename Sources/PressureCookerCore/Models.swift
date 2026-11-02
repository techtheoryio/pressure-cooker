import Foundation

public struct PullRequest: Identifiable, Hashable, Sendable {
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let repo: String  // owner/name
    public let author: String
    public let isDraft: Bool
    public let updatedAt: Date
    public let reviewDecision: String?  // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED; nil when no review is required
    public let mergeable: String  // MERGEABLE, CONFLICTING, UNKNOWN
    public let checks: String?  // statusCheckRollup: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED; nil without checks

    public init(id: String, number: Int, title: String, url: URL, repo: String, author: String, isDraft: Bool,
                updatedAt: Date, reviewDecision: String?, mergeable: String, checks: String?) {
        (self.id, self.number, self.title, self.url, self.repo, self.author) = (id, number, title, url, repo, author)
        (self.isDraft, self.updatedAt, self.reviewDecision, self.mergeable, self.checks) = (isDraft, updatedAt, reviewDecision, mergeable, checks)
    }

    public var status: PRStatus {
        if checks == "FAILURE" || checks == "ERROR" { return .failing }
        if mergeable == "CONFLICTING" { return .conflicts }
        if isDraft { return .draft }
        if reviewDecision == "CHANGES_REQUESTED" { return .changesRequested }
        if checks == "PENDING" || checks == "EXPECTED" { return .running }
        if reviewDecision == "REVIEW_REQUIRED" { return .needsReview }
        return .ready
    }
}

/// One status per PR, most urgent first; the order is also the sort order of "My pull requests".
public enum PRStatus: Int, Comparable, Sendable {
    case failing, conflicts, draft, changesRequested, running, needsReview, ready
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A workflow run waiting at an environment ("Review pending deployments") that the viewer may approve.
public struct PendingDeployment: Identifiable, Hashable, Sendable {
    public let id: Int  // run id
    public let repo: String
    public let workflow: String
    public let title: String
    public let branch: String
    public let actor: String
    public let environments: [String]
    public let url: URL
    public let createdAt: Date

    public init(id: Int, repo: String, workflow: String, title: String, branch: String, actor: String,
                environments: [String], url: URL, createdAt: Date) {
        (self.id, self.repo, self.workflow, self.title, self.branch) = (id, repo, workflow, title, branch)
        (self.actor, self.environments, self.url, self.createdAt) = (actor, environments, url, createdAt)
    }
}

/// A deploy running right now (a run on the default branch or for a release): only to see, never counted.
public struct RunningDeploy: Identifiable, Hashable, Sendable {
    public let id: Int  // run id
    public let repo: String
    public let workflow: String
    public let title: String
    public let ref: String  // the branch, or the release's tag
    public let isRelease: Bool
    public let actor: String
    public let url: URL
    public let startedAt: Date

    public init(id: Int, repo: String, workflow: String, title: String, ref: String, isRelease: Bool, actor: String, url: URL, startedAt: Date) {
        (self.id, self.repo, self.workflow, self.title, self.ref) = (id, repo, workflow, title, ref)
        (self.isRelease, self.actor, self.url, self.startedAt) = (isRelease, actor, url, startedAt)
    }
}

/// A run is a deploy when it ships the default branch (pushed or started by hand) or a release.
// ponytail: CI that also runs on pushes to main counts too; match workflow names if that gets noisy
public func isDeploy(event: String, branch: String?, defaultBranch: String?) -> Bool {
    event == "release" || (branch != nil && branch == defaultBranch && (event == "push" || event == "workflow_dispatch"))
}

public struct Snapshot: Sendable {
    public var viewer = ""
    public var accounts: [String] = []  // the viewer and their orgs, offered as owners in Settings
    public var repos: [String] = []  // repositories of the watched owners, for Settings
    public var mine: [PullRequest] = []
    public var reviews: [PullRequest] = []
    public var others: [PullRequest] = []  // open PRs in watched repos that are neither mine nor waiting for my review
    public var deployments: [PendingDeployment] = []
    public var running: [RunningDeploy] = []
    public var skipped: Set<String> = []  // ids of others' PRs the viewer won't review, set by the app

    public init() {}

    /// Everyone else's PRs that still need a review and that the viewer hasn't skipped: up for grabs.
    public var unreviewed: [PullRequest] { others.filter { $0.status == .needsReview && !skipped.contains($0.id) } }

    /// What the menu bar counts: anything waiting for the viewer to act.
    public var attention: Int {
        deployments.count + reviews.count + unreviewed.count + mine.filter { $0.status == .failing || $0.status == .ready }.count
    }

    /// Leaves out other people's PRs by these logins, people or bots ("renovate" and "renovate[bot]" both hide the bot).
    public func hiding(authors: [String]) -> Snapshot {
        let hidden = Set(authors.map(normalizedLogin))
        let keep = { (pr: PullRequest) in !hidden.contains(normalizedLogin(pr.author)) }
        var s = self
        s.reviews = reviews.filter(keep)
        s.others = others.filter(keep)
        return s
    }
}

/// GraphQL names a bot "renovate", REST and the web "renovate[bot]".
public func normalizedLogin(_ login: String) -> String {
    let l = login.trimmingCharacters(in: .whitespaces).lowercased()
    return l.hasSuffix("[bot]") ? String(l.dropLast(5)) : l
}

public enum Event: Hashable, Sendable {
    case failing(PullRequest), ready(PullRequest), reviewRequested(PullRequest), deployment(PendingDeployment)
}

/// Notifications between two refreshes: a PR of mine turning red or mergeable, a new review request, a new waiting deployment.
public func events(from old: Snapshot, to new: Snapshot) -> [Event] {
    let oldStatus = Dictionary(old.mine.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
    let oldReviews = Set(old.reviews.map(\.id)), oldRuns = Set(old.deployments.map(\.id))
    var result: [Event] = []
    for pr in new.mine where oldStatus[pr.id] != pr.status {
        if pr.status == .failing { result.append(.failing(pr)) }
        if pr.status == .ready { result.append(.ready(pr)) }
    }
    result += new.reviews.filter { !oldReviews.contains($0.id) }.map(Event.reviewRequested)
    result += new.deployments.filter { !oldRuns.contains($0.id) }.map(Event.deployment)
    return result
}
