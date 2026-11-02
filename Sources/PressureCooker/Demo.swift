import Foundation
import PressureCookerCore

/// `PC_DEMO=1`: made-up data in every state instead of GitHub, for screenshots and design work.
let isDemo = ProcessInfo.processInfo.environment["PC_DEMO"] != nil

extension Snapshot {
    static var demo: Snapshot {
        func ago(_ minutes: Double) -> Date { .now.addingTimeInterval(-minutes * 60) }
        func pr(_ n: Int, _ repo: String, _ title: String, by author: String = "octocat", _ minutes: Double, draft: Bool = false,
                review: String? = "REVIEW_REQUIRED", mergeable: String = "MERGEABLE", checks: String? = "SUCCESS") -> PullRequest {
            PullRequest(id: "\(repo)#\(n)", number: n, title: title, url: URL(string: "https://github.com/\(repo)/pull/\(n)")!, repo: repo,
                        author: author, isDraft: draft, updatedAt: ago(minutes), reviewDecision: review, mergeable: mergeable, checks: checks)
        }
        func run(_ id: Int, _ repo: String, _ title: String, _ envs: [String], _ minutes: Double) -> PendingDeployment {
            PendingDeployment(id: id, repo: repo, workflow: "Deploy", title: title, branch: "main", actor: "octocat", environments: envs,
                              url: URL(string: "https://github.com/\(repo)/actions/runs/\(id)")!, createdAt: ago(minutes))
        }
        var s = Snapshot()
        s.viewer = "octocat"
        s.accounts = ["octocat", "github", "actions"]
        s.repos = ["github/docs", "github/roadmap", "github/linguist", "actions/checkout", "actions/cache", "actions/runner"]
        s.deployments = [run(1, "github/docs", "Retry webhooks with backoff", ["stage"], 25), run(2, "actions/runner", "Release 2.320.0", ["production"], 190)]
        s.running = [
            RunningDeploy(id: 3, repo: "actions/cache", workflow: "Deploy", title: "Add rate limiting to the restore API", ref: "main",
                          isRelease: false, actor: "octocat", url: URL(string: "https://github.com/actions/cache/actions/runs/3")!, startedAt: ago(4)),
            RunningDeploy(id: 4, repo: "github/linguist", workflow: "Release", title: "v9.1.0", ref: "v9.1.0",
                          isRelease: true, actor: "octocat", url: URL(string: "https://github.com/github/linguist/actions/runs/4")!, startedAt: ago(9)),
        ]
        s.mine = [
            pr(482, "github/docs", "Migrate billing jobs to the new queue", 20, checks: "FAILURE"),
            pr(1290, "github/linguist", "Bump grammar submodules", 130, mergeable: "CONFLICTING"),
            pr(77, "actions/cache", "Add rate limiting to the restore API", 60, review: "APPROVED"),
            pr(301, "actions/checkout", "Cache sparse checkouts between jobs", 5, checks: "PENDING"),
            pr(58, "github/roadmap", "Document webhook signatures", 1500),
            pr(12, "actions/runner", "Spike: event-sourced job state", 4300, draft: true, checks: nil),
        ]
        s.reviews = [
            pr(1293, "github/linguist", "Fix flaky highlighting test", by: "mona", 10),
            pr(305, "actions/cache", "Support zstd for large caches", by: "hubot", 240, checks: "PENDING"),
        ]
        s.others = [
            pr(1301, "github/docs", "Typo in the Actions quickstart", by: "defunkt", 600, review: nil),
            pr(1310, "github/docs", "Explain environment protection rules", by: "mona", 45),
            pr(88, "actions/cache", "Update dependency typescript to v5.7", by: "renovate", 90),
        ]
        return s
    }
}
