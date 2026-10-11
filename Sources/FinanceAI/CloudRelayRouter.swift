import Foundation

private final class NoRelayRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum RoutingPolicy: Sendable { case localOnly, allowCloudForUnrecognizedRequests }

/// Default policy never uploads text. An explicit host setting can permit sending
/// an unrecognized request to Aryan's authenticated model relay; no provider key in app.
public struct HybridRouter: IntentRouting {
    private let local: any IntentRouting
    private let cloud: any IntentRouting
    private let policy: RoutingPolicy
    public init(local: any IntentRouting = OnDeviceRouter(), cloud: any IntentRouting, policy: RoutingPolicy = .localOnly) {
        self.local = local
        self.cloud = cloud
        self.policy = policy
    }
    public func route(_ text: String) async throws -> RoutedRequest {
        let result = try await local.route(text)
        if policy == .allowCloudForUnrecognizedRequests && result.request.intent == .unknown {
            return try await cloud.route(text)
        }
        return result
    }
}

/// POST {"text": "..."}; response is FinanceRequest. The relay must authenticate the
/// user using this short-lived session token, not a client-supplied user identifier.
public struct CloudRelayRouter: IntentRouting {
    private let endpoint: URL
    private let session: URLSession
    private let token: @Sendable () async throws -> String
    public init(endpoint: URL, session: URLSession? = nil,
                token: @escaping @Sendable () async throws -> String) throws {
        guard endpoint.scheme == "https", endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil else { throw FinanceAIError.invalidConfiguration }
        self.endpoint = endpoint
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoRelayRedirects(), delegateQueue: nil)
        self.token = token
    }
    public func route(_ text: String) async throws -> RoutedRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 2_000 else {
            throw FinanceAIError.invalidInput
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = try await token()
        guard !bearer.isEmpty, !bearer.contains("\n"), !bearer.contains("\r") else { throw FinanceAIError.invalidConfiguration }
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["text": text])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count < 32_768 else {
            throw FinanceAIError.unavailable("The AI relay did not return a valid response.")
        }
        let route = try JSONDecoder().decode(FinanceRequest.self, from: data)
        if route.intent == .proposeCancellation {
            guard let target = route.target, !target.isEmpty, target.count <= 160,
                  text.range(of: target, options: .caseInsensitive) != nil else { throw FinanceAIError.invalidConfiguration }
        }
        return RoutedRequest(request: route, source: .cloudRelay, notice: "This request was processed by the cloud relay.")
    }
}
