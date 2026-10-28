import Foundation
import XCTest
@testable import Redeploy

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
        guard let url else {
            XCTFail("Fixture \(name).json is missing from the test bundle")
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    private final class BundleToken {}
}

/// Answers URLSession requests from a closure, and records them.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func reset() {
        handler = nil
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension Stack {
    static func sample(
        id: Int = 12,
        name: String = "spike-test",
        status: Int = 1,
        git: Bool = true,
        auth: Bool = false
    ) -> Stack {
        Stack(
            id: id,
            name: name,
            type: 2,
            endpointId: 3,
            status: status,
            env: [EnvironmentVariable(name: "TZ", value: "Europe/Amsterdam")],
            gitConfig: git
                ? GitConfig(url: "https://example.com/repo.git", referenceName: "refs/heads/main",
                            configFilePath: "docker-compose.yml", configHash: "4f2c9a1e0b7d",
                            authentication: auth ? GitAuthentication(username: "deploy", authorizationType: 0) : nil)
                : nil,
            updateDate: 1_760_000_000
        )
    }
}

extension DockerContainer {
    static func sample(_ name: String, state: String = "running", status: String = "Up 1 minute") -> DockerContainer {
        DockerContainer(id: name, names: ["/\(name)"], image: "\(name):latest", state: state, status: status, labels: nil)
    }
}
