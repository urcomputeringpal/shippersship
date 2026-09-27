import Foundation
@testable import ShipKit
import Testing

private let bump = PullRequest(
    id: "1", number: 7, title: "Bump @octokit/rest from 20.1.1 to 21.0.2",
    url: URL(string: "https://github.com/acme/optional-workflows/pull/7")!,
    repo: "acme/optional-workflows", author: "dependabot[bot]",
    labels: [PRLabel(name: "dependencies", color: "0366d6"), PRLabel(name: "javascript", color: "168700")],
    relations: [.reviewRequested]
)

private func matches(_ rule: String, _ pr: PullRequest = bump) -> Bool { PRFilter(rule).matches(pr) }

@Test func globs() {
    #expect(glob("acme/*", "acme/rocket"))
    #expect(glob("*rocket", "acme/rocket"))
    #expect(glob("b?ps", "BOPS"))
    #expect(!glob("rocket", "acme/rocket"))
    #expect(glob("*", ""))
}

@Test func qualifiers() {
    #expect(matches("repo:acme/optional-*"))
    #expect(matches("repo:optional-workflows"))   // repo name without owner
    #expect(!matches("repo:rocket"))
    #expect(matches("org:acme"))
    #expect(matches("owner:ACME"))
    #expect(matches("author:dependabot"))                  // [bot] suffix optional
    #expect(matches("author:dependabot[bot]"))
    #expect(matches("label:dependencies"))
    #expect(matches("label:java*"))
    #expect(matches("title:bump*"))
    #expect(matches("is:review-requested"))
    #expect(!matches("is:draft"))
}

@Test func bareWordsAndPhrasesMatchTitle() {
    #expect(matches("octokit"))
    #expect(matches("\"bump @octokit\""))
    #expect(!matches("\"octokit bump\""))
    #expect(matches("label:\"dependencies\""))
}

@Test func termsAreAndedAndNegatable() {
    #expect(matches("org:acme author:dependabot"))
    #expect(!matches("org:acme author:octocat"))
    #expect(!matches("author:dependabot -label:dependencies"))
    #expect(matches("author:dependabot -label:security"))
}

@Test func invalidRulesNeverMatch() {
    let rule = PRFilter("colour:red author:dependabot")
    #expect(!rule.isValid)
    #expect(rule.errors == ["Unknown qualifier “colour:”"])
    #expect(!rule.matches(bump))
    #expect(!PRFilter("   ").matches(bump))
    #expect(!PRFilter("is:stale").isValid)
}
