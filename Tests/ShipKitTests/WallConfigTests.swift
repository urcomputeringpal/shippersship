import Foundation
@testable import ShipKit
import Testing

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "wall-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test func configRoundTrips() throws {
    let url = try temporaryDirectory().appending(path: "wall/config.json")
    let config = WallConfig(org: "acme", appID: 123, installationID: 456, keyFile: "/tmp/app-key.pem")
    try config.save(to: url)
    #expect(try WallConfig.load(from: url) == config)
    #expect(try mode(url.deletingLastPathComponent()) == 0o700)
}

@Test(arguments: [
    ("", "it isn't valid JSON"),
    (#"{"org":"acme","appID":1,"installationID":2}"#, #""keyFile" is missing"#),
    (#"{"org":"acme","appID":"1","installationID":2,"keyFile":"k"}"#, #""appID" has the wrong type"#),
    (#"{"org":"acme","appID":0,"installationID":2,"keyFile":"k"}"#, #""appID" must be a positive number"#),
    (#"{"org":"-acme","appID":1,"installationID":2,"keyFile":"k"}"#, #""org" isn't a GitHub organization"#),
    (#"{"org":"acme","appID":1,"installationID":2,"keyFile":""}"#, #""keyFile" is empty"#),
])
func configErrorsSayWhatsWrong(json: String, message: String) throws {
    let url = try temporaryDirectory().appending(path: "config.json")
    try Data(json.utf8).write(to: url)
    #expect(throws: WallConfigError.invalidConfig(url.path, message)) { try WallConfig.load(from: url) }
}

@Test func missingConfigPointsAtConfigure() throws {
    let url = try temporaryDirectory().appending(path: "config.json")
    #expect(throws: WallConfigError.missingConfig(url.path)) { try WallConfig.load(from: url) }
    #expect(WallConfigError.missingConfig(url.path).localizedDescription.contains("ShippersShipWall configure"))
}

@Test func keyFileIsPrivate() throws {
    let url = try temporaryDirectory().appending(path: "new/app-key.pem")
    try KeyFile.write("first", to: url)
    try KeyFile.write("second", to: url)
    #expect(try KeyFile.read(url) == "second")
    #expect(try mode(url) == 0o600)
    #expect(try mode(url.deletingLastPathComponent()) == 0o700)
    // No temporary files left behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["app-key.pem"])
}

@Test func refusesAKeyOthersCanRead() throws {
    let url = try temporaryDirectory().appending(path: "app-key.pem")
    try KeyFile.write("key", to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect(throws: WallConfigError.keyTooOpen(url.path, 0o644)) { try KeyFile.read(url) }
    #expect(throws: WallConfigError.missingKey("/nonexistent/app-key.pem")) {
        try KeyFile.read(URL(filePath: "/nonexistent/app-key.pem"))
    }
}
