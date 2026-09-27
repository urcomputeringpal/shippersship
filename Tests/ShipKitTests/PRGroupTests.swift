import Foundation
@testable import ShipKit
import Testing

private func pr(_ repo: String, author: String = "me", labels: [String] = []) -> PullRequest {
    PullRequest(id: UUID().uuidString, number: 1, title: "Something", url: URL(string: "https://github.com/\(repo)/pull/1")!,
                repo: repo, author: author, labels: labels.map { PRLabel(name: $0, color: "ffffff") })
}

@Test func groupMatchesAnyRule() {
    let group = PRGroup(name: "Deps", rules: ["author:dependabot", "label:dependencies"])
    #expect(group.matches(pr("acme/web", author: "dependabot[bot]")))
    #expect(group.matches(pr("acme/web", labels: ["dependencies"])))
    #expect(!group.matches(pr("acme/web")))
    #expect(!PRGroup(name: "Empty").matches(pr("acme/web")))
}

@Test func firstMatchingGroupWins() {
    let web = PRGroup(name: "Web", rules: ["repo:acme/web"])
    let deps = PRGroup(name: "Deps", rules: ["author:dependabot"])
    let bump = pr("acme/web", author: "dependabot[bot]")
    #expect(PRGroup.group(for: bump, in: [web, deps])?.name == "Web")
    #expect(PRGroup.group(for: bump, in: [deps, web])?.name == "Deps")
    #expect(PRGroup.group(for: pr("acme/api"), in: [web, deps]) == nil)
}

@Test func groupsRoundTripThroughJSON() throws {
    let groups = [PRGroup(name: "Deps", rules: ["author:dependabot"], quiet: false)]
    let decoded = try JSONDecoder().decode([PRGroup].self, from: JSONEncoder().encode(groups))
    #expect(decoded == groups)
}

@Test func suggestionsCoverRepoAuthorLabelsAndPR() {
    let suggestions = FilterSuggestion.suggestions(for: pr("acme/web", author: "hubot", labels: ["needs qa"]))
    #expect(suggestions.map(\.rule) == [
        "repo:acme/web", "author:hubot", "label:\"needs qa\"", "repo:acme/web title:Something",
    ])
    // Every suggestion must parse and match the PR it came from.
    let source = pr("acme/web", author: "hubot", labels: ["needs qa"])
    #expect(suggestions.allSatisfy { PRFilter($0.rule).isValid })
    #expect(suggestions.dropLast().allSatisfy { PRFilter($0.rule).matches(source) })
}
