@testable import ShipKit
import Testing

private let labels = ["bug", "documentation", "dependencies", "deploy:staging", "deploy:production",
                     "do not merge", "ignore-for-release", "ui-tests", "tvOS", "iOS"]

private func top(_ q: String) -> String? { FuzzyMatch.rank(labels, query: q, key: { $0 }).first?.item }

@Test func subsequenceRequired() {
    #expect(FuzzyMatch.match("dctn", in: "documentation") != nil)
    #expect(FuzzyMatch.match("xyz", in: "documentation") == nil)
    #expect(FuzzyMatch.match("tdoc", in: "documentation") == nil) // order matters
}

@Test func ranksPrefixesWordStartsAndExactMatches() {
    #expect(top("doc") == "documentation")
    #expect(top("dep") == "dependencies")
    #expect(top("dprod") == "deploy:production")
    #expect(top("dnm") == "do not merge")
    #expect(top("ios") == "iOS")
    #expect(top("ifr") == "ignore-for-release")
}

@Test func emptyQueryKeepsOrder() {
    #expect(FuzzyMatch.rank(labels, query: " ", key: { $0 }).map(\.item) == labels)
}

@Test func positionsForHighlighting() {
    #expect(FuzzyMatch.match("dnm", in: "do not merge")?.positions == [0, 3, 7])
}
