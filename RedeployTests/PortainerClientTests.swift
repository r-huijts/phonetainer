import XCTest
@testable import Redeploy

final class PortainerClientRequestTests: XCTestCase {
    private let client = LivePortainerClient(baseURL: URL(string: "https://portainer.example.ts.net")!, token: "ptr_secret")

    func testRequestCarriesTokenOnlyInHeader() throws {
        let request = try client.makeRequest(method: "GET", path: "api/stacks")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://portainer.example.ts.net/api/stacks")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "ptr_secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(request.url!.absoluteString.contains("ptr_secret"))
        XCTAssertEqual(request.timeoutInterval, LivePortainerClient.defaultTimeout)
    }

    func testKeepsBasePathAndPort() throws {
        let client = LivePortainerClient(baseURL: URL(string: "https://host:9443/portainer/")!, token: "t")
        let request = try client.makeRequest(method: "GET", path: "api/endpoints")
        XCTAssertEqual(request.url?.absoluteString, "https://host:9443/portainer/api/endpoints")
    }

    func testRedeployRequest() throws {
        let request = try client.makeRedeployRequest(stack: .sample(), repullImages: true, prune: false)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/api/stacks/12/git/redeploy")
        XCTAssertEqual(request.url?.query, "endpointId=3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, LivePortainerClient.redeployTimeout)
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(decoded["RepositoryReferenceName"] as? String, "refs/heads/main")
    }

    func testRedeployRequiresEnvironment() {
        var stack = Stack.sample()
        stack.endpointId = nil
        XCTAssertThrowsError(try client.makeRedeployRequest(stack: stack, repullImages: true, prune: false))
    }

    func testContainersFilterIsPercentEncodedJSON() throws {
        let request = try client.makeContainersRequest(endpointId: 3, project: "Spike-Test")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/api/endpoints/3/docker/containers/json")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "all" }?.value, "true")
        let filters = try XCTUnwrap(items.first { $0.name == "filters" }?.value)
        let parsed = try JSONSerialization.jsonObject(with: Data(filters.utf8)) as? [String: [String]]
        XCTAssertEqual(parsed, ["label": ["com.docker.compose.project=spike-test"]])
        XCTAssertFalse(url.query!.contains("{"), "JSON must be percent-encoded")
    }

    func testRejectsURLWithoutHost() {
        let client = LivePortainerClient(baseURL: URL(string: "file:///tmp")!, token: "t")
        XCTAssertThrowsError(try client.makeRequest(method: "GET", path: "api/stacks")) { error in
            XCTAssertEqual(error as? PortainerError, .invalidURL)
        }
    }
}

final class PortainerClientErrorTests: XCTestCase {
    private var client: LivePortainerClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        client = LivePortainerClient(baseURL: URL(string: "https://portainer.example.ts.net")!, token: "t",
                                     session: MockURLProtocol.session())
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testDecodesSuccessfulResponse() async throws {
        let data = try Fixture.data("stacks")
        MockURLProtocol.handler = { _ in (200, data) }
        let stacks = try await client.stacks()
        XCTAssertEqual(stacks.count, 3)
        XCTAssertEqual(MockURLProtocol.requests.first?.value(forHTTPHeaderField: "X-API-Key"), "t")
    }

    func testMaps401ToUnauthorized() async {
        MockURLProtocol.handler = { _ in (401, Data(#"{"message":"Unauthorized","details":"invalid API key"}"#.utf8)) }
        await assertThrows(.unauthorized) { _ = try await self.client.environments() }
    }

    func testMapsServerMessage() async {
        MockURLProtocol.handler = { _ in (500, Data(#"{"message":"Unable to clone git repository directory","details":"authentication required"}"#.utf8)) }
        await assertThrows(.server(status: 500, message: "Unable to clone git repository directory: authentication required")) {
            _ = try await self.client.redeploy(stack: .sample(), repullImages: true, prune: false)
        }
    }

    func testMapsConflictAndNotFound() async {
        MockURLProtocol.handler = { _ in (409, Data(#"{"message":"Unable to update stack"}"#.utf8)) }
        await assertThrows(.conflict("Unable to update stack")) { _ = try await self.client.stack(id: 12) }
        MockURLProtocol.handler = { _ in (404, Data()) }
        await assertThrows(.notFound(nil)) { _ = try await self.client.stack(id: 99) }
    }

    func testMapsUndecodableBody() async {
        MockURLProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        do {
            _ = try await client.stacks()
            XCTFail("expected an error")
        } catch {
            guard case .invalidResponse(_)? = error as? PortainerError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testVersionFallsBackToStatusEndpoint() async throws {
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/system/version" { return (404, Data()) }
            return (200, Data(#"{"Version":"2.19.4"}"#.utf8))
        }
        let version = try await client.version()
        XCTAssertEqual(version, "2.19.4")
    }

    func testTransportErrorMapping() {
        XCTAssertEqual(LivePortainerClient.mapTransportError(URLError(.timedOut)), .timeout)
        XCTAssertEqual(LivePortainerClient.mapTransportError(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(LivePortainerClient.mapTransportError(URLError(.serverCertificateUntrusted)), .tlsFailure)
        XCTAssertEqual(LivePortainerClient.mapTransportError(URLError(.secureConnectionFailed)), .tlsFailure)
        XCTAssertEqual(LivePortainerClient.mapTransportError(URLError(.appTransportSecurityRequiresSecureConnection)),
                       .insecureConnectionBlocked)
        XCTAssertEqual(LivePortainerClient.mapTransportError(CancellationError()), .cancelled)
        guard case .unreachable(_) = LivePortainerClient.mapTransportError(URLError(.cannotConnectToHost)) else {
            return XCTFail("expected unreachable")
        }
    }

    func testStatusMapping() {
        XCTAssertNil(LivePortainerClient.mapStatus(200, data: Data()))
        XCTAssertNil(LivePortainerClient.mapStatus(204, data: Data()))
        XCTAssertEqual(LivePortainerClient.mapStatus(403, data: Data(#"{"message":"Access denied"}"#.utf8)), .forbidden("Access denied"))
    }

    private func assertThrows(
        _ expected: PortainerError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PortainerError, expected, file: file, line: line)
        }
    }
}
