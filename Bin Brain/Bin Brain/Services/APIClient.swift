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
        UserDefaults.standard.string(forKey: "serverURL") ?? "http://10.1.1.206:8000"
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

    /// Returns the URL for serving a photo file, optionally resized.
    ///
    /// Use with `AsyncImage` or a custom image loader. Pass `width` to
    /// request a JPEG thumbnail resized to the given width (aspect ratio preserved).
    ///
    /// - Parameters:
    ///   - photoId: The photo ID returned by a prior `ingest` call.
    ///   - width: Optional width in pixels (16–4096). `nil` returns the original.
    func photoFileURL(photoId: Int, width: Int? = nil) -> URL? {
        var path = "\(baseURL)/photos/\(photoId)/file"
        if let width {
            path += "?w=\(width)"
        }
        return URL(string: path)
    }

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

    /// Removes an item from a bin (deletes the association, not the item itself).
    ///
    /// - Parameters:
    ///   - itemId: The item ID to remove.
    ///   - binId: The bin to remove the item from.
    @discardableResult
    func removeItem(itemId: Int, binId: String) async throws -> RemoveItemResponse {
        try await request(
            path: "/bins/\(binId)/items/\(itemId)",
            method: "DELETE",
            body: nil,
            contentType: nil,
            timeout: 10
        )
    }

    /// Updates quantity and/or confidence for an item in a bin.
    ///
    /// - Parameters:
    ///   - itemId: The item ID to update.
    ///   - binId: The bin the item belongs to.
    ///   - quantity: New quantity value, or `nil` to leave unchanged.
    ///   - confidence: New confidence value, or `nil` to leave unchanged.
    @discardableResult
    func updateItem(
        itemId: Int,
        binId: String,
        quantity: Double?,
        confidence: Double?
    ) async throws -> UpdateItemResponse {
        var fields: [String: Any] = [:]
        if let quantity { fields["quantity"] = quantity }
        if let confidence { fields["confidence"] = confidence }
        let body = try JSONSerialization.data(withJSONObject: fields)
        return try await request(
            path: "/bins/\(binId)/items/\(itemId)",
            method: "PATCH",
            body: body,
            contentType: "application/json",
            timeout: 10
        )
    }

    /// Returns all Ollama models available on the server and the currently active model.
    func listModels() async throws -> ListModelsResponse {
        try await request(path: "/models", method: "GET", body: nil, contentType: nil, timeout: 10)
    }

    /// Returns models currently loaded in Ollama memory.
    func runningModels() async throws -> RunningModelsResponse {
        try await request(path: "/models/running", method: "GET", body: nil, contentType: nil, timeout: 10)
    }

    /// Selects and warms up a vision model on the server.
    ///
    /// Blocks until the model is loaded (typically 5–30 s).
    ///
    /// - Parameter model: The model name as listed by `listModels()`.
    func selectModel(_ model: String) async throws -> SelectModelResponse {
        let body = try JSONEncoder().encode(["model": model])
        return try await request(
            path: "/models/select", method: "POST", body: body,
            contentType: "application/json", timeout: 60
        )
    }

    /// Returns the current max image size setting for vision inference.
    func getImageSize() async throws -> ImageSizeResponse {
        try await request(
            path: "/settings/image-size", method: "GET", body: nil, contentType: nil, timeout: 10
        )
    }

    /// Sets the max image size for vision inference.
    ///
    /// - Parameter maxImagePx: Max longest side in pixels (128–4096).
    func setImageSize(_ maxImagePx: Int) async throws -> SetImageSizeResponse {
        let body = try JSONEncoder().encode(["max_image_px": maxImagePx])
        return try await request(
            path: "/settings/image-size", method: "POST", body: body,
            contentType: "application/json", timeout: 10
        )
    }

    /// Confirms a class name for YOLO-World detection training.
    ///
    /// Sends an approved or corrected item name to the server so it can be
    /// added to the active class list for faster future detection.
    ///
    /// - Parameters:
    ///   - className: The confirmed or corrected item name (e.g. `"scissors"`).
    ///   - category: Optional category for UI grouping (e.g. `"tools"`).
    @discardableResult
    func confirmClass(className: String, category: String?) async throws -> ConfirmClassResponse {
        var payload: [String: String] = [
            "version": "1",
            "class_name": className,
            "source": "vision_llm"
        ]
        if let category { payload["category"] = category }
        let body = try JSONEncoder().encode(payload)
        return try await request(
            path: "/classes/confirm",
            method: "POST",
            body: body,
            contentType: "application/json",
            timeout: 10
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

    // MARK: - Locations

    /// Returns all active locations sorted by name.
    func listLocations() async throws -> [LocationSummary] {
        let response: ListLocationsResponse = try await request(
            path: "/locations", method: "GET", body: nil, contentType: nil, timeout: 10
        )
        return response.locations.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Creates a new location.
    ///
    /// - Parameters:
    ///   - name: The location name (required).
    ///   - description: Optional description.
    func createLocation(name: String, description: String?) async throws -> CreateLocationResponse {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if let description {
            components.queryItems?.append(URLQueryItem(name: "description", value: description))
        }
        let body = Data((components.percentEncodedQuery ?? "").utf8)
        return try await request(
            path: "/locations",
            method: "POST",
            body: body,
            contentType: "application/x-www-form-urlencoded",
            timeout: 10
        )
    }

    /// Soft-deletes a location.
    ///
    /// - Parameter locationId: The location to delete.
    @discardableResult
    func deleteLocation(_ locationId: Int) async throws -> DeleteLocationResponse {
        try await request(
            path: "/locations/\(locationId)",
            method: "DELETE",
            body: nil,
            contentType: nil,
            timeout: 10
        )
    }

    /// Assigns, changes, or clears a bin's location.
    ///
    /// - Parameters:
    ///   - binId: The bin to update.
    ///   - locationId: The location to assign, or `nil` to clear.
    @discardableResult
    func assignLocation(binId: String, locationId: Int?) async throws -> AssignLocationResponse {
        let body: Data
        if let locationId {
            body = try JSONSerialization.data(withJSONObject: ["location_id": locationId])
        } else {
            body = try JSONSerialization.data(withJSONObject: ["location_id": NSNull()])
        }
        return try await request(
            path: "/bins/\(binId)/location",
            method: "PATCH",
            body: body,
            contentType: "application/json",
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
            print("[API] Invalid URL: \(urlString)")
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

        let bodySize = body.map { "\($0.count) bytes" } ?? "none"
        print("[API] \(method) \(urlString) (body: \(bodySize), timeout: \(timeout)s)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            print("[API] \(method) \(path) NETWORK ERROR: \(error.localizedDescription)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            print("[API] \(method) \(path) ERROR: non-HTTP response")
            throw APIClientError.unexpectedStatusCode(-1)
        }

        let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count) bytes>"
        print("[API] \(method) \(path) → \(httpResponse.statusCode) (\(data.count) bytes)")
        print("[API] Response: \(preview)")

        if (200...299).contains(httpResponse.statusCode) {
            do {
                let decoded = try JSONDecoder.binBrain.decode(T.self, from: data)
                return decoded
            } catch {
                print("[API] \(method) \(path) DECODE ERROR: \(error)")
                throw error
            }
        } else {
            if let apiError = try? JSONDecoder.binBrain.decode(APIError.self, from: data) {
                print("[API] \(method) \(path) API ERROR: \(apiError.localizedDescription)")
                throw apiError
            }
            print("[API] \(method) \(path) HTTP ERROR: \(httpResponse.statusCode)")
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
