import Foundation
import Testing
@testable import PressureCookerCore

func pr(_ id: String = "1", by author: String = "me", draft: Bool = false, review: String? = nil, mergeable: String = "MERGEABLE",
        checks: String? = "SUCCESS") -> PullRequest {
    PullRequest(id: id, number: 1, title: "T", url: URL(string: "https://github.com/o/r/pull/1")!, repo: "o/r", author: author,
                isDraft: draft, updatedAt: .now, reviewDecision: review, mergeable: mergeable, checks: checks)
}

@Test func statusPicksTheMostUrgent() {
    #expect(pr(draft: true, checks: "FAILURE").status == .failing)
    #expect(pr(checks: "ERROR").status == .failing)
    #expect(pr(mergeable: "CONFLICTING").status == .conflicts)
    #expect(pr(draft: true).status == .draft)
    #expect(pr(review: "CHANGES_REQUESTED", checks: "PENDING").status == .changesRequested)
    #expect(pr(review: "REVIEW_REQUIRED", checks: "PENDING").status == .running)
    #expect(pr(review: "REVIEW_REQUIRED").status == .needsReview)
    #expect(pr(review: "APPROVED").status == .ready)
    #expect(pr(checks: nil).status == .ready)  // no checks, no required review
    #expect(pr(mergeable: "UNKNOWN").status == .ready)  // GitHub computes mergeability lazily
}

@Test func eventsFireOnTransitionsOnly() {
    let run = PendingDeployment(id: 7, repo: "o/r", workflow: "Deploy", title: "x", branch: "main", actor: "me",
                                environments: ["stage"], url: URL(string: "https://github.com")!, createdAt: .now)
    var old = Snapshot()
    old.mine = [pr("a", checks: "PENDING"), pr("b", checks: "FAILURE")]
    old.reviews = [pr("r1")]
    var new = old
    new.mine = [pr("a", checks: "FAILURE"), pr("b", checks: "FAILURE"), pr("c", review: "APPROVED")]
    new.reviews = [pr("r1"), pr("r2")]
    new.deployments = [run]

    #expect(Set(events(from: old, to: new)) == [.failing(new.mine[0]), .ready(new.mine[2]), .reviewRequested(new.reviews[1]), .deployment(run)])
    #expect(events(from: new, to: new).isEmpty)
    #expect(new.attention == 1 + 2 + 3)  // deployment + reviews + (two failing, one ready)
}

@Test func hiddenAuthorsLeaveOutOthersPRs() {
    var s = Snapshot()
    s.mine = [pr("m")]
    s.reviews = [pr("r1", by: "renovate"), pr("r2", by: "Mona")]
    s.others = [pr("o1", by: "dependabot"), pr("o2", by: "hubot")]
    let hidden = s.hiding(authors: ["Renovate[bot]", " mona ", "dependabot[bot]"])
    #expect(hidden.reviews.isEmpty)
    #expect(hidden.others.map(\.id) == ["o2"])
    #expect(hidden.mine.map(\.id) == ["m"])
    #expect(s.hiding(authors: []).others.count == 2)
}

@Test func othersAwaitingReviewNeedYouUntilSkipped() {
    var s = Snapshot()
    s.others = [pr("a", by: "mona", review: "REVIEW_REQUIRED"), pr("b", by: "mona", review: "REVIEW_REQUIRED"),
                pr("c", by: "mona", review: "APPROVED"), pr("d", by: "mona", draft: true, review: "REVIEW_REQUIRED")]
    #expect(s.unreviewed.map(\.id) == ["a", "b"])
    #expect(s.attention == 2)
    s.skipped = ["b"]
    #expect(s.unreviewed.map(\.id) == ["a"])
    #expect(s.attention == 1)
}

@Test func deploysAreRunsOfTheDefaultBranchOrAReleases() {
    #expect(isDeploy(event: "push", branch: "main", defaultBranch: "main"))
    #expect(isDeploy(event: "workflow_dispatch", branch: "main", defaultBranch: "main"))
    #expect(isDeploy(event: "release", branch: "0.4.0", defaultBranch: "main"))
    #expect(!isDeploy(event: "push", branch: "feature/x", defaultBranch: "main"))
    #expect(!isDeploy(event: "pull_request", branch: "main", defaultBranch: "main"))
    #expect(!isDeploy(event: "push", branch: nil, defaultBranch: nil))
}
