@testable import ShipKit
import Testing

private func c(_ id: String, _ kind: StatusKind, eligible: Bool = true) -> NotificationPlanner.Candidate {
    .init(id: id, kind: kind, eligible: eligible)
}

@Test func newerNotableStatusReplacesOlder() {
    // Same id → the system replaces the delivered notification.
    let plan = NotificationPlanner.plan(previous: ["a": .ciFailing], current: [c("a", .ready)])
    #expect(plan == .init(post: ["a"], clear: []))
}

@Test func movingToAQuietStatusClearsTheOldNotification() {
    let plan = NotificationPlanner.plan(previous: ["a": .ciFailing], current: [c("a", .ciRunning)])
    #expect(plan == .init(post: [], clear: ["a"]))
}

@Test func unchangedStatusDoesNothing() {
    let plan = NotificationPlanner.plan(previous: ["a": .ciFailing], current: [c("a", .ciFailing)])
    #expect(plan == .init())
}

@Test func newPRsNotifyOnlyWhenNotable() {
    let plan = NotificationPlanner.plan(previous: [:], current: [c("a", .reviewRequested), c("b", .ciRunning)])
    #expect(plan.post == ["a"])
}

@Test func vanishedOrQuietPRsAreCleared() {
    let plan = NotificationPlanner.plan(
        previous: ["gone": .merged, "quiet": .ciFailing],
        current: [c("quiet", .ciFailing, eligible: false)]
    )
    #expect(plan == .init(post: [], clear: ["quiet", "gone"]))
}
