import Foundation

public struct GitHubError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public var isUnauthorized: Bool { status == 401 }
    public var errorDescription: String? {
        status == 401 ? "GitHub rejected the token (401). Check it in Settings → Account." : "GitHub: \(message) (\(status))"
    }
}

/// Talks to GitHub with a token: a personal access token, the gh CLI's token, or a GitHub App user token all work.
public struct GitHub: Sendable {
    let token: String
    let api: URL

    public init(token: String, api: URL = URL(string: "https://api.github.com/")!) {
        (self.token, self.api) = (token, api)
    }

    /// One GraphQL request for my PRs, review requests and the watched owners' repositories, one for everyone else's PRs,
    /// then the REST API for waiting and running deploys (GraphQL has no workflow runs). Without owners, PRs from everywhere
    /// are shown and there are no deployments.
    public func snapshot(owners: [String], excluded: Set<String>, showAll: Bool) async throws -> Snapshot {
        let base = (["is:pr is:open archived:false"] + owners.map { "user:\($0)" }).joined(separator: " ")  // user: matches orgs too
        var vars: [String: String] = ["mine": "\(base) author:@me", "reviews": "\(base) review-requested:@me"]
        for (i, owner) in owners.enumerated() { vars["o\(i)"] = owner }

        // Everyone else's PRs get a request of their own: in a busy org they are the heavy part, and GitHub cuts GraphQL off
        // after 10 seconds, which would take my PRs down with them.
        // ponytail: the 50 most recently updated, and without `mergeable` (computed on demand, the slowest field), so others'
        // PRs never show conflicts; paginate if 50 is too few
        let everyone = Task {
            guard showAll && !owners.isEmpty else { return [String: GraphQLResponse.Field?]() }
            return try await graphql("query($all: String!) { all: search(query: $all, type: ISSUE, first: 50) { nodes { ...pr } } } \(prFragment(mergeable: false))",
                                     ["all": "\(base) sort:updated-desc"])
        }

        // ponytail: first 100 PRs per search and 100 repos per owner (most recently pushed), paginate if anyone outgrows it
        let search = { (name: String) in "\(name): search(query: $\(name), type: ISSUE, first: 100) { nodes { ...pr } }" }
        let query = """
            query(\(vars.keys.sorted().map { "$\($0): String!" }.joined(separator: ", "))) {
              viewer { login organizations(first: 100) { nodes { login } } }
              \(search("mine")) \(search("reviews"))
              \(owners.indices.map { "o\($0): repositoryOwner(login: $o\($0)) { repositories(first: 100, isArchived: false, orderBy: {field: PUSHED_AT, direction: DESC}) { nodes { nameWithOwner pushedAt defaultBranchRef { name } } } }" }.joined(separator: "\n"))
            }
            \(prFragment(mergeable: true))
            """
        let data = try await graphql(query, vars).merging(try await everyone.value) { a, _ in a }

        let field = { (key: String) in data[key] ?? nil }
        let repoNodes = owners.indices.flatMap { i in
            (field("o\(i)")?.repositories?.nodes ?? []).filter { $0.nameWithOwner.lowercased().hasPrefix(owners[i].lowercased() + "/") }  // a user's list includes collaborations
        }
        let watched = { (pr: PullRequest) in !excluded.contains(pr.repo) }
        let prs = { (key: String) in (field(key)?.nodes ?? []).map(\.pullRequest).filter(watched) }

        var snapshot = Snapshot()
        snapshot.viewer = field("viewer")?.login ?? ""
        snapshot.accounts = [snapshot.viewer] + (field("viewer")?.organizations?.nodes.map(\.login) ?? [])
        snapshot.repos = repoNodes.map(\.nameWithOwner)
        snapshot.mine = prs("mine").sorted { ($0.status, $1.updatedAt) < ($1.status, $0.updatedAt) }
        snapshot.reviews = prs("reviews").sorted { $0.updatedAt > $1.updatedAt }
        let shown = Set((snapshot.mine + snapshot.reviews).map(\.id))
        snapshot.others = prs("all").filter { !shown.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }

        // A run waits for approval at most 30 days, so repositories without a push since then can't have one.
        let cutoff = Date.now.addingTimeInterval(-30 * 86400)
        let active = repoNodes.filter { !excluded.contains($0.nameWithOwner) && ($0.pushedAt ?? .distantPast) > cutoff }
        // ponytail: running deploys only in repos pushed to in the last day (a push or a release tag starts them); a deploy
        // started by hand in a quiet repo is missed, widen the window if that matters
        let recent = active.filter { ($0.pushedAt ?? .distantPast) > .now.addingTimeInterval(-86400) }
        async let deployments = gather(active) { try await pendingDeployments(in: $0.nameWithOwner) }
        async let running = gather(recent) { try await runningDeploys(in: $0.nameWithOwner, defaultBranch: $0.defaultBranchRef?.name) }
        snapshot.deployments = try await deployments.sorted { $0.createdAt < $1.createdAt }
        snapshot.running = try await running.sorted { $0.startedAt > $1.startedAt }
        return snapshot
    }

    private func graphql(_ query: String, _ variables: [String: String]) async throws -> [String: GraphQLResponse.Field?] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let response = try decoder.decode(GraphQLResponse.self, from: try await send("graphql", body: body))
        guard let data = response.data else { throw GitHubError(status: 200, message: response.errors?.first?.message ?? "empty response") }
        return data
    }

    /// `fetch` for every repo in parallel. One repo without Actions access shouldn't hide the others; all of them failing
    /// means the token can't read Actions.
    private func gather<T: Sendable>(_ repos: [RepoNode], _ fetch: @escaping @Sendable (RepoNode) async throws -> [T]) async throws -> [T] {
        try await withThrowingTaskGroup(of: Result<[T], Error>.self) { group in
            for repo in repos { group.addTask { await Result { try await fetch(repo) } } }
            var found: [T] = [], failures: [Error] = []
            for try await result in group {
                switch result {
                case .success(let items): found += items
                case .failure(let e): failures.append(e)
                }
            }
            if let first = failures.first, failures.count == repos.count { throw first }
            return found
        }
    }

    func runningDeploys(in repo: String, defaultBranch: String?) async throws -> [RunningDeploy] {
        let runs = try decoder.decode(Runs.self, from: try await send("repos/\(repo)/actions/runs?status=in_progress&per_page=30")).workflowRuns
        return runs.filter { isDeploy(event: $0.event, branch: $0.headBranch, defaultBranch: defaultBranch) }.map { run in
            RunningDeploy(id: run.id, repo: repo, workflow: run.name ?? "Workflow", title: run.displayTitle, ref: run.headBranch ?? "",
                          isRelease: run.event == "release", actor: run.actor?.login ?? "", url: run.htmlUrl,
                          startedAt: run.runStartedAt ?? run.createdAt)
        }
    }

    func pendingDeployments(in repo: String) async throws -> [PendingDeployment] {
        let runs = try decoder.decode(Runs.self, from: try await send("repos/\(repo)/actions/runs?status=waiting&per_page=30")).workflowRuns
        var result: [PendingDeployment] = []
        for run in runs {
            let pending = try decoder.decode([Pending].self, from: try await send("repos/\(repo)/actions/runs/\(run.id)/pending_deployments"))
            let environments = pending.filter(\.currentUserCanApprove).map(\.environment.name)
            guard !environments.isEmpty else { continue }
            result.append(PendingDeployment(id: run.id, repo: repo, workflow: run.name ?? "Workflow", title: run.displayTitle,
                                            branch: run.headBranch ?? "", actor: run.actor?.login ?? "", environments: environments,
                                            url: run.htmlUrl, createdAt: run.createdAt))
        }
        return result
    }

    private func send(_ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: api)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GitHubError(status: status, message: (try? decoder.decode(Message.self, from: data))?.message ?? "request failed")
        }
        return data
    }
}

private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}()

// MARK: - Wire format

private func prFragment(mergeable: Bool) -> String {
    """
    fragment pr on PullRequest {
      id number title url isDraft updatedAt reviewDecision \(mergeable ? "mergeable" : "")
      author { login } repository { nameWithOwner }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    """
}

private struct Message: Decodable { let message: String }
private struct Login: Decodable, Sendable { let login: String }
private struct Nodes<T: Decodable & Sendable>: Decodable, Sendable { let nodes: [T] }

/// Every top-level field of the query decodes into this: viewer fills login/organizations, a search fills nodes,
/// a repositoryOwner fills repositories (or is null when the owner doesn't exist).
private struct GraphQLResponse: Decodable {
    struct Field: Decodable, Sendable {
        let login: String?
        let organizations: Nodes<Login>?
        let nodes: [PRNode]?
        let repositories: Nodes<RepoNode>?
    }
    let data: [String: Field?]?
    let errors: [Message]?
}

private struct RepoNode: Decodable, Sendable {
    struct Branch: Decodable, Sendable { let name: String }
    let nameWithOwner: String
    let pushedAt: Date?
    let defaultBranchRef: Branch?  // nil for an empty repository
}

private struct PRNode: Decodable, Sendable {
    struct Repo: Decodable, Sendable { let nameWithOwner: String }
    struct Rollup: Decodable, Sendable { let state: String }
    struct Commit: Decodable, Sendable { let statusCheckRollup: Rollup? }
    struct CommitNode: Decodable, Sendable { let commit: Commit }
    let id: String, number: Int, title: String, url: URL, isDraft: Bool, updatedAt: Date
    let reviewDecision: String?, mergeable: String?  // not asked for in everyone else's PRs
    let author: Login?  // nil for deleted users
    let repository: Repo
    let commits: Nodes<CommitNode>

    var pullRequest: PullRequest {
        PullRequest(id: id, number: number, title: title, url: url, repo: repository.nameWithOwner, author: author?.login ?? "ghost",
                    isDraft: isDraft, updatedAt: updatedAt, reviewDecision: reviewDecision, mergeable: mergeable ?? "UNKNOWN",
                    checks: commits.nodes.first?.commit.statusCheckRollup?.state)
    }
}

private struct Runs: Decodable {
    struct Run: Decodable {
        let id: Int, name: String?, displayTitle: String, htmlUrl: URL, headBranch: String?, actor: Login?, createdAt: Date
        let event: String, runStartedAt: Date?
    }
    let workflowRuns: [Run]
}

private struct Pending: Decodable {
    struct Environment: Decodable { let name: String }
    let environment: Environment
    let currentUserCanApprove: Bool
}
