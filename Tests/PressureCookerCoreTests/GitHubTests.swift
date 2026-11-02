import Foundation
import Testing
@testable import PressureCookerCore

/// Checks the queries and decoding against the real API: `GITHUB_TOKEN=$(gh auth token) GITHUB_OWNERS=org1,org2 swift test`
@Test(.enabled(if: ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil))
func liveSnapshot() async throws {
    let env = ProcessInfo.processInfo.environment
    let owners = env["GITHUB_OWNERS"]?.split(separator: ",").map(String.init) ?? []
    let s = try await GitHub(token: env["GITHUB_TOKEN"]!).snapshot(owners: owners, excluded: [], showAll: true)
    #expect(!s.viewer.isEmpty)
    #expect(owners.isEmpty || !s.repos.isEmpty)
    print("viewer \(s.viewer), \(s.repos.count) repos, mine \(s.mine.count), reviews \(s.reviews.count), others \(s.others.count), deployments \(s.deployments.count), running \(s.running.count)")
}
