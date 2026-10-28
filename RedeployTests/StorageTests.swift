import XCTest
@testable import Redeploy

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!

    override func setUpWithError() throws {
        store = KeychainStore(service: "nl.r-huijts.phonetainer.tests.\(UUID().uuidString)", account: "token")
    }

    override func tearDownWithError() throws {
        try store.delete()
    }

    func testRoundTrip() throws {
        XCTAssertNil(try store.read())
        try store.save("ptr_first")
        XCTAssertEqual(try store.read(), "ptr_first")
        try store.save("ptr_second")
        XCTAssertEqual(try store.read(), "ptr_second", "saving again replaces the value")
        try store.delete()
        XCTAssertNil(try store.read())
    }

    func testDeletingMissingItemIsFine() throws {
        XCTAssertNoThrow(try store.delete())
    }
}

@MainActor
final class ActivityStoreTests: XCTestCase {
    private func entry(_ index: Int, succeeded: Bool = true) -> ActivityEntry {
        ActivityEntry(stackId: index, stackName: "stack-\(index)", date: Date(timeIntervalSince1970: TimeInterval(index)),
                      succeeded: succeeded, message: "msg", duration: 12)
    }

    func testKeepsNewestFiftyAndPersists() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("activity.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = ActivityStore(fileURL: url)
        for index in 0..<55 { store.record(entry(index)) }
        XCTAssertEqual(store.entries.count, ActivityStore.limit)
        XCTAssertEqual(store.entries.first?.stackId, 54)
        XCTAssertEqual(store.entries.last?.stackId, 5)

        let reloaded = ActivityStore(fileURL: url)
        XCTAssertEqual(reloaded.entries, store.entries)

        reloaded.clear()
        XCTAssertTrue(ActivityStore(fileURL: url).entries.isEmpty)
    }

    func testInMemoryStore() {
        let store = ActivityStore(fileURL: nil)
        store.record(entry(1, succeeded: false))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(store.entries[0].succeeded)
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    func testNormalizesServerAddress() {
        XCTAssertEqual(AppSettings.normalizedURL("portainer.tail1234.ts.net")?.absoluteString, "https://portainer.tail1234.ts.net")
        XCTAssertEqual(AppSettings.normalizedURL("  https://host:9443/ ")?.absoluteString, "https://host:9443")
        XCTAssertEqual(AppSettings.normalizedURL("http://100.101.102.103:9000")?.absoluteString, "http://100.101.102.103:9000")
        XCTAssertNil(AppSettings.normalizedURL(""))
        XCTAssertNil(AppSettings.normalizedURL("ftp://host"))
    }

    func testPersistsAndDefaults() throws {
        let suite = "nl.r-huijts.phonetainer.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.serverAddress, "")
        XCTAssertNil(settings.environmentId)
        XCTAssertTrue(settings.requireAuthentication)
        XCTAssertTrue(settings.repullImagesByDefault)
        XCTAssertTrue(settings.notifyWhenFinished)

        settings.serverAddress = "https://portainer.tail1234.ts.net"
        settings.environmentId = 3
        settings.requireAuthentication = false
        settings.save()

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.serverAddress, "https://portainer.tail1234.ts.net")
        XCTAssertEqual(reloaded.environmentId, 3)
        XCTAssertFalse(reloaded.requireAuthentication)
        XCTAssertTrue(reloaded.isTailscaleAddress)
    }

    func testDetectsTailscaleAddresses() throws {
        let suite = "nl.r-huijts.phonetainer.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.serverAddress = "http://100.101.102.103:9000"
        XCTAssertTrue(settings.isTailscaleAddress)
        settings.serverAddress = "https://192.168.1.10:9443"
        XCTAssertFalse(settings.isTailscaleAddress)
    }

    func testTokenIsNeverWrittenToUserDefaults() throws {
        let suite = "nl.r-huijts.phonetainer.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: suite, account: "token")
        defer { try? keychain.delete() }

        let state = AppState(settings: AppSettings(defaults: defaults), activity: ActivityStore(fileURL: nil), keychain: keychain)
        try state.saveToken("ptr_secret_value")
        state.settingsChanged()

        let stored = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(stored.contains { $0.contains("ptr_secret_value") })
        XCTAssertEqual(try keychain.read(), "ptr_secret_value")
    }
}
