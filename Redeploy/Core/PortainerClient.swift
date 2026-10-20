import Foundation

protocol PortainerClient: Sendable {
    /// Portainer's version string, or nil if the server doesn't report one.
    func version() async throws -> String?
    func environments() async throws -> [PortainerEnvironment]
    func stacks() async throws -> [Stack]
    func stack(id: Int) async throws -> Stack
    func containers(endpointId: Int, project: String) async throws -> [DockerContainer]
    /// Pulls the stack's Git repository and redeploys it. Depending on the
    /// Portainer version this returns after the deploy finished, or right away
    /// with the stack in the deploying state.
    func redeploy(stack: Stack, repullImages: Bool, prune: Bool) async throws -> Stack
}

enum PortainerError: Error, Equatable, LocalizedError {
    case notConfigured
    case invalidURL
    case unauthorized
    case forbidden(String?)
    case notFound(String?)
    case conflict(String?)
    case server(status: Int, message: String?)
    case unreachable(String)
    case tlsFailure
    case insecureConnectionBlocked
    case timeout
    case invalidResponse(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your Portainer address and API token in Settings."
        case .invalidURL:
            return "The server address isn't a valid URL."
        case .unauthorized:
            return "Portainer rejected the API token. It may have expired or been revoked."
        case .forbidden(let message):
            return "Portainer refused the request" + Self.suffix(message)
        case .notFound(let message):
            return "Not found on the server" + Self.suffix(message)
        case .conflict(let message):
            return "Portainer is busy with this stack" + Self.suffix(message)
        case .server(let status, let message):
            return "Portainer returned an error (HTTP \(status))" + Self.suffix(message)
        case .unreachable(let reason):
            return "Can't reach the server. Check that Tailscale is connected. (\(reason))"
        case .tlsFailure:
            return "The server's certificate isn't trusted. Use a valid certificate, for example with tailscale serve."
        case .insecureConnectionBlocked:
            return "iOS blocks plain HTTP to this address. Use HTTPS, or see the README for the exception."
        case .timeout:
            return "The server took too long to answer."
        case .invalidResponse(let detail):
            return "Unexpected response from Portainer (\(detail))."
        case .cancelled:
            return "The request was cancelled."
        }
    }

    private static func suffix(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "." }
        return ": \(message)"
    }
}

struct LivePortainerClient: PortainerClient {
    static let defaultTimeout: TimeInterval = 20
    /// Pulling images can take minutes, and Portainer 2.39 only answers once the deploy is done.
    static let redeployTimeout: TimeInterval = 15 * 60

    let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .portainer) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func version() async throws -> String? {
        for path in ["api/system/version", "api/status"] {
            do {
                let info = try await send(makeRequest(method: "GET", path: path), as: VersionInfo.self)
                if let version = info.serverVersion ?? info.version {
                    return version
                }
            } catch PortainerError.notFound(_) {
                continue
            }
        }
        return nil
    }

    func environments() async throws -> [PortainerEnvironment] {
        try await send(makeRequest(method: "GET", path: "api/endpoints"), as: [PortainerEnvironment].self)
    }

    func stacks() async throws -> [Stack] {
        try await send(makeRequest(method: "GET", path: "api/stacks"), as: [Stack].self)
    }

    func stack(id: Int) async throws -> Stack {
        try await send(makeRequest(method: "GET", path: "api/stacks/\(id)"), as: Stack.self)
    }

    func containers(endpointId: Int, project: String) async throws -> [DockerContainer] {
        try await send(makeContainersRequest(endpointId: endpointId, project: project), as: [DockerContainer].self)
    }

    func redeploy(stack: Stack, repullImages: Bool, prune: Bool) async throws -> Stack {
        try await send(makeRedeployRequest(stack: stack, repullImages: repullImages, prune: prune), as: Stack.self)
    }

    // MARK: Request building (internal for tests)

    func makeContainersRequest(endpointId: Int, project: String) throws -> URLRequest {
        // Compose lowercases project names.
        let filter = ["label": ["com.docker.compose.project=\(project.lowercased())"]]
        let filterJSON = String(decoding: try JSONEncoder().encode(filter), as: UTF8.self)
        return try makeRequest(
            method: "GET",
            path: "api/endpoints/\(endpointId)/docker/containers/json",
            query: [URLQueryItem(name: "all", value: "true"), URLQueryItem(name: "filters", value: filterJSON)]
        )
    }

    func makeRedeployRequest(stack: Stack, repullImages: Bool, prune: Bool) throws -> URLRequest {
        guard let endpointId = stack.endpointId else {
            throw PortainerError.invalidResponse("the stack has no environment")
        }
        let body = try JSONEncoder().encode(RedeployRequest(stack: stack, repullImages: repullImages, prune: prune))
        // endpointId must always be sent: Portainer re-points the stack to whatever is passed, 0 included.
        return try makeRequest(
            method: "PUT",
            path: "api/stacks/\(stack.id)/git/redeploy",
            query: [URLQueryItem(name: "endpointId", value: String(endpointId))],
            body: body,
            timeout: Self.redeployTimeout
        )
    }

    func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval = LivePortainerClient.defaultTimeout
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            throw PortainerError.invalidURL
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + "/" + path
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(Self.encode($0.name))=\(Self.encode($0.value ?? ""))" }
                .joined(separator: "&")
        }
        guard let url = components.url else { throw PortainerError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: Sending and error mapping

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = result.1 as? HTTPURLResponse else {
            throw PortainerError.invalidResponse("not an HTTP response")
        }
        if let error = Self.mapStatus(http.statusCode, data: result.0) {
            throw error
        }
        do {
            return try JSONDecoder().decode(T.self, from: result.0)
        } catch {
            throw PortainerError.invalidResponse(Self.describe(decodingError: error))
        }
    }

    static func mapStatus(_ status: Int, data: Data) -> PortainerError? {
        if (200..<300).contains(status) { return nil }
        let message = (try? JSONDecoder().decode(ServerErrorBody.self, from: data))?.text
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden(message)
        case 404: return .notFound(message)
        case 409: return .conflict(message)
        default: return .server(status: status, message: message)
        }
    }

    static func mapTransportError(_ error: Error) -> PortainerError {
        if let error = error as? PortainerError { return error }
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else {
            return .unreachable(error.localizedDescription)
        }
        switch urlError.code {
        case .timedOut:
            return .timeout
        case .cancelled:
            return .cancelled
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
             .secureConnectionFailed:
            return .tlsFailure
        case .appTransportSecurityRequiresSecureConnection:
            return .insecureConnectionBlocked
        case .badURL, .unsupportedURL:
            return .invalidURL
        default:
            return .unreachable(urlError.localizedDescription)
        }
    }

    private static func describe(decodingError error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        if case .keyNotFound(let key, _) = error {
            return "missing field \(key.stringValue)"
        }
        let context: DecodingError.Context?
        if case .typeMismatch(_, let found) = error {
            context = found
        } else if case .valueNotFound(_, let found) = error {
            context = found
        } else if case .dataCorrupted(let found) = error {
            context = found
        } else {
            context = nil
        }
        let path = context?.codingPath.map(\.stringValue).joined(separator: ".") ?? ""
        return path.isEmpty ? "could not decode the response" : "field \(path)"
    }

    private static let queryAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? value
    }
}

extension URLSession {
    /// Ephemeral: no cookies, cache or credentials written to disk.
    static let portainer: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = LivePortainerClient.redeployTimeout + 60
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()
}
