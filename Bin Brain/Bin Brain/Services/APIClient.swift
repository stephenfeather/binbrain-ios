// APIClient.swift
// Bin Brain
//
// All HTTP calls to the Bin Brain backend. Reads base URL from UserDefaults
// at call time so Settings changes take effect immediately.

import Foundation
import Observation

// MARK: - Error Types

/// Errors thrown by `APIClient` itself (not decoded from the server).
enum APIClientError: LocalizedError {
    case invalidURL(String)
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .unexpectedStatusCode(let code): return "Unexpected status code: \(code)"
        }
    }
}

// MARK: - APIClient

/// All HTTP calls to the Bin Brain backend.
///
/// Inject via `@Environment` key and call methods from `async` contexts.
/// Base URL is read from `UserDefaults` at call time — Settings changes
/// take effect immediately for subsequent calls.
@Observable
final class APIClient {

    // MARK: - Computed Properties

    /// The base URL read from `UserDefaults` at call time.
    ///
    /// Defaults to `https://raspberrypi.local:8000` when no value is stored.
    var baseURL: String {
        UserDefaults.standard.string(forKey: "serverURL") ?? "https://raspberrypi.local:8000"
    }

    // MARK: - Private Properties

    private let session: URLSession

    // MARK: - Initializer

    /// Creates an `APIClient` with an optional `URLSession` for testability.
    ///
    /// - Parameter session: The session used for all network calls. Defaults to `.shared`.
    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Returns the server health status.
    func health() async throws -> HealthResponse {
        try await request(path: "/health", method: "GET", body: nil, contentType: nil, timeout: 10)
    }

    /// Returns all bins sorted by bin ID alphanumeric ascending.
    ///
    /// The API returns bins ordered by most-recently-updated; this method
    /// re-sorts client-side using `localizedStandardCompare` before returning.
    func listBins() async throws -> [BinSummary] {
        let response: ListBinsResponse = try await request(
            path: "/bins", method: "GET", body: nil, contentType: nil, timeout: 10
        )
        return response.bins.sorted {
            $0.binId.localizedStandardCompare($1.binId) == .orderedAscending
        }
    }

    /// Returns the full contents of a single bin.
    ///
    /// - Parameter binId: The alphanumeric bin identifier (e.g. `BIN-0001`).
    func getBin(_ binId: String) async throws -> GetBinResponse {
        try await request(
            path: "/bins/\(binId)", method: "GET", body: nil, contentType: nil, timeout: 10
        )
    }

    /// Uploads a JPEG photo and associates it with the given bin.
    ///
    /// The bin is created automatically on the backend if it does not yet exist.
    ///
    /// - Parameters:
    ///   - jpegData: Compressed JPEG image data to upload.
    ///   - binId: The target bin identifier.
    func ingest(jpegData: Data, binId: String) async throws -> IngestResponse {
        let (body, boundary) = multipartBody(
            fields: ["bin_id": binId],
            fileData: jpegData,
            fileName: "photo.jpg",
            mimeType: "image/jpeg"
        )
        return try await request(
            path: "/ingest",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            timeout: 30
        )
    }

    /// Runs AI vision inference on a stored photo and returns item suggestions.
    ///
    /// This call blocks until Ollama inference completes (typically 20–60 s on Pi + Hailo).
    /// Wrap in `UIApplication.shared.beginBackgroundTask` before calling from the foreground.
    ///
    /// - Parameter photoId: The photo ID returned by a prior `ingest` call.
    func suggest(photoId: Int) async throws -> PhotoSuggestResponse {
        try await request(
            path: "/photos/\(photoId)/suggest",
            method: "GET",
            body: nil,
            contentType: nil,
            timeout: 120
        )
    }

    /// Creates or upserts an item in the catalogue, optionally linking it to a bin.
    ///
    /// Fields with `nil` values are omitted from the multipart request body.
    /// The backend upserts by fingerprint (`lower(name)|lower(category)`).
    ///
    /// - Parameters:
    ///   - name: The item name (required).
    ///   - category: Optional item category (e.g. `"fastener"`).
    ///   - quantity: Optional quantity in the bin. Only meaningful when `binId` is set.
    ///   - confidence: Optional association confidence 0–1. Only meaningful when `binId` is set.
    ///   - binId: Optional bin to associate the item with.
    func upsertItem(
        name: String,
        category: String?,
        quantity: Double?,
        confidence: Double?,
        binId: String?
    ) async throws -> UpsertItemResponse {
        var fields: [String: String] = ["name": name]
        if let category { fields["category"] = category }
        if let binId { fields["bin_id"] = binId }
        if let confidence { fields["confidence"] = String(confidence) }
        if let quantity { fields["quantity"] = String(quantity) }

        let (body, boundary) = multipartBody(
            fields: fields,
            fileData: nil,
            fileName: nil,
            mimeType: nil
        )
        return try await request(
            path: "/items",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
            timeout: 15
        )
    }

    /// Searches the item catalogue using a natural-language query.
    ///
    /// - Parameters:
    ///   - query: The natural-language search query (e.g. `"m3 screw"`).
    ///   - minScore: Optional minimum similarity score 0–1. Results below this threshold
    ///     are excluded. Pass `nil` to return all results.
    func search(query: String, minScore: Double?) async throws -> SearchResponse {
        var queryItems = [URLQueryItem(name: "q", value: query)]
        if let minScore {
            queryItems.append(URLQueryItem(name: "min_score", value: String(minScore)))
        }
        var components = URLComponents()
        components.queryItems = queryItems
        let queryString = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return try await request(
            path: "/search\(queryString)",
            method: "GET",
            body: nil,
            contentType: nil,
            timeout: 10
        )
    }

    // MARK: - Private Helpers

    /// Sends an HTTP request and decodes the response into `T`.
    ///
    /// - On HTTP 2xx: decodes response body with `JSONDecoder.binBrain`.
    /// - On HTTP 4xx/5xx: attempts to decode `APIError`; falls back to
    ///   `APIClientError.unexpectedStatusCode` if the body cannot be decoded.
    private func request<T: Decodable>(
        path: String,
        method: String,
        body: Data?,
        contentType: String?,
        timeout: TimeInterval
    ) async throws -> T {
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw APIClientError.invalidURL(urlString)
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = method
        if let body {
            urlRequest.httpBody = body
        }
        if let contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.unexpectedStatusCode(-1)
        }
        if (200...299).contains(httpResponse.statusCode) {
            return try JSONDecoder.binBrain.decode(T.self, from: data)
        } else {
            if let apiError = try? JSONDecoder.binBrain.decode(APIError.self, from: data) {
                throw apiError
            }
            throw APIClientError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }

    /// Builds a `multipart/form-data` request body.
    ///
    /// Text fields are added as plain parts. When `fileData` is provided, it is
    /// appended as a binary part with the field name `photos`.
    ///
    /// - Returns: A tuple of the encoded body `Data` and the boundary string.
    ///   The caller must set the `Content-Type` header to
    ///   `multipart/form-data; boundary=<boundary>`.
    private func multipartBody(
        fields: [String: String],
        fileData: Data?,
        fileName: String?,
        mimeType: String?
    ) -> (Data, boundary: String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        if let fileData, let fileName, let mimeType {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"photos\"; filename=\"\(fileName)\"\r\n".utf8))
            body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
            body.append(fileData)
            body.append(Data("\r\n".utf8))
        }

        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, boundary)
    }
}
