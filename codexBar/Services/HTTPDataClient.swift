import Foundation

/// Small URL loading seam used by account refresh services and deterministic tests.
protocol HTTPDataClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionHTTPDataClient: HTTPDataClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}
