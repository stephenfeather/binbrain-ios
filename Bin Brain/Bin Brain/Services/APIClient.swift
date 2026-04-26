// APIClient.swift
// Bin Brain
//
// All HTTP calls to the Bin Brain backend. Reads base URL from UserDefaults
// at call time so Settings changes take effect immediately.

import Foundation
import OSLog
import Observation

private let logger = Logger(subsystem: "com.binbrain.app", category: "APIClient")
private let apiSignposter = OSSignposter(subsystem: "com.binbrain.app", category: "APIClient")

// MARK: - URL Path Encoding

private extension String {
    /// Percent-encodes the receiver for use as a single URL path component.
    ///
    /// Defense-in-depth against IDs that contain `/`, `?`, `#`, or other
    /// reserved characters. Applied to every ID interpolated into a path,
    /// not just scanner-sourced values (see issue #15 / F-07). Returns the
    /// original string unchanged if encoding fails (rare — only with
    /// malformed Unicode scalars).
    var urlPathComponentEncoded: String {
        // `.urlPathAllowed` permits `/` because paths contain segment
        // separators; for a single segment we must also encode `/`,
        // otherwise a bin ID like `../../foo` would traverse the path.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

// MARK: - Error Types

/// Errors thrown by `APIClient` itself (not decoded from the server).
enum APIClientError: LocalizedError {
    case invalidURL(String)
    case missingAPIKey
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .missingAPIKey: return "No API key configured. Please set one in Settings."
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

    /// The base URL read at call time, resolved in priority order:
    /// `UserDefaults("serverURL")` → `BuildConfig.defaultServerURL` (from
    /// `Development.xcconfig` via `Info.plist` in Debug) → hardcoded fallback.
    var baseURL: String {
        UserDefaults.standard.string(forKey: "serverURL")
            ?? BuildConfig.defaultServerURL
            ?? "http://10.1.1.206:8000"
    }

    /// The API key read at call time, resolved in priority order:
    /// Keychain (via the injected `keychain`) → `BuildConfig.defaultAPIKey`
    /// (from `Development.xcconfig` via `Info.plist` in Debug) → `nil`.
    ///
    /// Sent as the `X-API-Key` header on every request when non-nil.
    var apiKey: String? {
        if let stored = keychain.readString(forKey: KeychainHelper.apiKeyAccount),
           !stored.isEmpty {
            return stored
        }
        return BuildConfig.defaultAPIKey
    }

    /// Whether a non-empty API key is configured.
    var hasAPIKey: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }

    // MARK: - Private Properties

    private let session: URLSession
    private let keychain: KeychainReading

    // MARK: - Initializer

    /// Creates an `APIClient` with an optional `URLSession` and `KeychainReading` for testability.
    ///
    /// - Parameters:
    ///   - session: The session used for all network calls. Defaults to `.shared`.
    ///   - keychain: The Keychain facade used to resolve the API key. Defaults to `KeychainHelper.shared`.
    init(session: URLSession = .shared, keychain: KeychainReading = KeychainHelper.shared) {
        self.session = session
        self.keychain = keychain
    }

    // MARK: - Tracing

    /// Lets a `tracedRequest` body emit a custom terminal-event payload
    /// (e.g. `status=missing_api_key retryCount=3`) before re-throwing the
    /// real error. Caught only by `tracedRequest`; `underlying` is rethrown.
    private struct TracedRequestFailure: Error {
        let payload: String
        let underlying: Error
    }

    /// Wraps `body` with `OSSignposter` begin / result / end ceremony.
    /// Emits `initialEvent(id)`, runs `body`, then emits `resultEventName`
    /// with `successPayload(result)` on return or `failurePayload()` on
    /// throw (or `TracedRequestFailure.payload` if the body throws one).
    /// Always closes the interval and re-throws so observable signpost
    /// output matches the original hand-rolled scaffolding verbatim.
    private func tracedRequest<T>(
        interval intervalName: StaticString,
        resultEvent resultEventName: StaticString,
        initialEvent: (OSSignpostID) -> Void = { _ in },
        successPayload: (T) -> String = { _ in "status=success" },
        failurePayload: () -> String = { "status=failure" },
        body: (OSSignpostID) async throws -> T
    ) async throws -> T {
        let id = apiSignposter.makeSignpostID()
        let interval = apiSignposter.beginInterval(intervalName, id: id)
        initialEvent(id)
        // Compute payload + outcome up front so the emit/end pair runs once.
        // `payload` is bound to a local because `OSLogMessage` captures
        // arguments via `@escaping @autoclosure`, which can't pull from a
        // non-escaping closure parameter directly.
        let payload: String
        let outcome: Result<T, Error>
        do {
            let value = try await body(id)
            payload = successPayload(value)
            outcome = .success(value)
        } catch let custom as TracedRequestFailure {
            payload = custom.payload
            outcome = .failure(custom.underlying)
        } catch {
            payload = failurePayload()
            outcome = .failure(error)
        }
        apiSignposter.emitEvent(resultEventName, id: id, "\(payload, privacy: .public)")
        apiSignposter.endInterval(intervalName, interval)
        return try outcome.get()
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
        var path = "\(baseURL)/photos/\(String(photoId).urlPathComponentEncoded)/file"
        if let width {
            path += "?w=\(width)"
        }
        return URL(string: path)
    }

    /// Fetches a photo's bytes from `/photos/{id}/file` with the `X-API-Key`
    /// header attached (routed through the same `shouldAttachKey` gate as
    /// every other authed request — Finding #8-B).
    ///
    /// `AsyncImage(url:)` cannot add headers, so photos previously rendered
    /// as placeholders on device. Callers should feed the returned `Data`
    /// into `UIImage(data:)`.
    ///
    /// - Parameters:
    ///   - photoId: The photo ID.
    ///   - width: Optional width in pixels (16–4096) for a server-side thumbnail.
    /// - Throws: `APIClientError.missingAPIKey` if no key is configured,
    ///   `APIClientError.invalidURL` if URL construction fails,
    ///   `APIClientError.unexpectedStatusCode` on non-2xx, or any underlying
    ///   `URLError`.
    func fetchPhotoData(photoId: Int, width: Int? = nil) async throws -> Data {
        guard hasAPIKey else { throw APIClientError.missingAPIKey }

        var path = "/photos/\(String(photoId).urlPathComponentEncoded)/file"
        if let width {
            path += "?w=\(width)"
        }
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw APIClientError.invalidURL(urlString)
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: 30)
        urlRequest.httpMethod = "GET"
        if let apiKey, shouldAttachKey(requiresAuth: true, probe: false) {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.unexpectedStatusCode(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIClientError.unexpectedStatusCode(http.statusCode)
        }
        return data
    }

    /// Returns the server health status.
    ///
    /// - Parameter probeWithCurrentKey: When `true`, attaches the configured
    ///   API key to the request **even if** the current `baseURL` does not
    ///   match the key's bound host. Used by the Settings "Re-bind key"
    ///   flow to let the server tell us whether the existing key is valid
    ///   for a new host. Default `false` — the routine `/health` probe
    ///   never leaks the key off-host.
    func health(probeWithCurrentKey: Bool = false) async throws -> HealthResponse {
        try await request(
            path: "/health",
            method: "GET",
            body: nil,
            contentType: nil,
            timeout: 10,
            requiresAuth: false,
            probeWithCurrentKey: probeWithCurrentKey
        )
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
            path: "/bins/\(binId.urlPathComponentEncoded)", method: "GET", body: nil, contentType: nil, timeout: 10
        )
    }

    /// Soft-deletes a bin and reattributes its items to the reserved
    /// `UNASSIGNED` sentinel in the same transaction (Swift2_022).
    ///
    /// 404 is treated as idempotent success (bin already gone) — the method
    /// returns `nil` so callers can refresh without a throw / catch dance,
    /// mirroring `endSession(id:)`.
    ///
    /// - Parameter binId: The bin to soft-delete. Callers must guard against
    ///   passing the reserved `UNASSIGNED` sentinel at the UI layer — the
    ///   server will reject it with `400 cannot_delete_sentinel`.
    /// - Returns: The decoded response on 200, `nil` on 404.
    /// - Throws: `APIError` on 400/5xx (including `cannot_delete_sentinel`),
    ///   `APIClientError.missingAPIKey` / `.invalidURL` /
    ///   `.unexpectedStatusCode`, or any underlying `URLError`.
    @discardableResult
    func deleteBin(binId: String) async throws -> DeleteBinResponse? {
        guard hasAPIKey else { throw APIClientError.missingAPIKey }
        let path = "/bins/\(binId.urlPathComponentEncoded)"
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw APIClientError.invalidURL(urlString)
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 10)
        urlRequest.httpMethod = "DELETE"
        if let apiKey, shouldAttachKey(requiresAuth: true, probe: false) {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.unexpectedStatusCode(-1)
        }
        if (200...299).contains(http.statusCode) {
            return try JSONDecoder.binBrain.decode(DeleteBinResponse.self, from: data)
        }
        if http.statusCode == 404 {
            return nil
        }
        if let apiError = try? JSONDecoder.binBrain.decode(APIError.self, from: data) {
            throw apiError
        }
        throw APIClientError.unexpectedStatusCode(http.statusCode)
    }

    /// Uploads a JPEG photo and associates it with the given bin.
    ///
    /// The bin is created automatically on the backend if it does not yet exist.
    ///
    /// - Parameters:
    ///   - jpegData: Compressed JPEG image data to upload.
    ///   - binId: The target bin identifier.
    ///   - deviceMetadata: Optional JSON string of on-device processing metadata
    ///     (quality scores, OCR, barcodes, classifications). Sent as a
    ///     `device_metadata` text field in the multipart body when non-nil.
    ///   - sessionId: Optional server-minted session UUID (`Swift2_019`).
    ///     Sent as a `session_id` multipart field. Server PR #35 rejects
    ///     any non-UUID value with 400 `invalid_session`.
    ///   - retryCount: Defaults to 0 (first attempt). When > 0, stamps
    ///     `X-Client-Retry-Count: <n>` on the request so server-side
    ///     telemetry can correlate "this ingest is a session-recovery
    ///     retry" vs an independent first attempt. Mirrors the pattern
    ///     PR #23 set for `/outcomes`. Observational only — server has
    ///     no behavior conditioned on the value (Swift2_019c / SEC-25-4).
    func ingest(
        jpegData: Data,
        binId: String,
        deviceMetadata: String? = nil,
        sessionId: UUID? = nil,
        retryCount: Int = 0
    ) async throws -> IngestResponse {
        var fields = ["bin_id": binId]
        if let deviceMetadata {
            fields["device_metadata"] = deviceMetadata
        }
        if let sessionId {
            fields["session_id"] = sessionId.uuidString.lowercased()
        }
        let (body, boundary) = multipartBody(
            fields: fields,
            fileData: jpegData,
            fileName: "photo.jpg",
            mimeType: "image/jpeg"
        )
        var extraHeaders: [String: String] = [:]
        if retryCount > 0 {
            extraHeaders["X-Client-Retry-Count"] = "\(retryCount)"
        }
        return try await tracedRequest(
            interval: "ingest",
            resultEvent: "ingest_result",
            initialEvent: { id in
                apiSignposter.emitEvent(
                    "ingest",
                    id: id,
                    "binId=\(binId, privacy: .public) size=\(jpegData.count, privacy: .public) retryCount=\(retryCount, privacy: .public)"
                )
            }
        ) { _ in
            try await request(
                path: "/ingest",
                method: "POST",
                body: body,
                contentType: "multipart/form-data; boundary=\(boundary)",
                timeout: 30,
                extraHeaders: extraHeaders
            )
        }
    }

    // MARK: - Sessions (Swift2_019)

    /// Creates a new server-minted cataloging session. Response row contains
    /// the `session_id` that subsequent `/ingest` calls must carry.
    ///
    /// - Parameter label: Optional human-readable hint, e.g.
    ///   `"Garage bins 2026-04-19"`. Max 120 chars server-side.
    /// - Returns: The freshly-opened `Session`.
    func createSession(label: String? = nil) async throws -> Session {
        let body: Data
        if let label {
            body = try JSONSerialization.data(withJSONObject: ["label": label])
        } else {
            body = try JSONSerialization.data(withJSONObject: [:] as [String: Any])
        }
        return try await request(
            path: "/sessions",
            method: "POST",
            body: body,
            contentType: "application/json",
            timeout: 10
        )
    }

    /// Closes the given session on the server. 404 / 410 responses are
    /// treated as idempotent success because both mean "already gone" —
    /// the server-side row is in a terminal state either way.
    ///
    /// - Parameter id: The session UUID to close.
    /// - Returns: The closed session row (or `nil` if 404/410).
    /// - Throws: `URLError` on transport failure so the caller can decide
    ///   whether to retry. All other HTTP-layer errors bubble up via
    ///   `APIClientError.unexpectedStatusCode`.
    @discardableResult
    func endSession(id: UUID) async throws -> Session? {
        // Bypass the generic request<T> path so we can treat 404/410 as
        // success without relying on throw/catch control flow.
        guard hasAPIKey else { throw APIClientError.missingAPIKey }
        let path = "/sessions/\(id.uuidString.lowercased())"
        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            throw APIClientError.invalidURL(urlString)
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 10)
        urlRequest.httpMethod = "DELETE"
        if let apiKey, shouldAttachKey(requiresAuth: true, probe: false) {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.unexpectedStatusCode(-1)
        }
        if (200...299).contains(http.statusCode) {
            do {
                return try JSONDecoder.binBrain.decode(Session.self, from: data)
            } catch {
                // Per global rule "Log errors, never swallow": surface decode
                // failures to OSLog so we don't lose visibility on a server-side
                // schema drift. Behavior preserved — caller still gets `nil`.
                logger.error("DELETE \(path, privacy: .private) DECODE ERROR: status=\(http.statusCode, privacy: .public) \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }
        if http.statusCode == 404 || http.statusCode == 410 {
            return nil
        }
        throw APIClientError.unexpectedStatusCode(http.statusCode)
    }

    /// Fetches a single session by id. 404 if not owned or not found.
    func getSession(id: UUID) async throws -> Session {
        try await request(
            path: "/sessions/\(id.uuidString.lowercased())",
            method: "GET",
            body: nil,
            contentType: nil,
            timeout: 10
        )
    }

    /// Runs AI vision inference on a stored photo and returns item suggestions.
    ///
    /// This call blocks until Ollama inference completes (typically 20–60 s on Pi + Hailo).
    /// Wrap in `UIApplication.shared.beginBackgroundTask` before calling from the foreground.
    ///
    /// - Parameter photoId: The photo ID returned by a prior `ingest` call.
    func suggest(photoId: Int) async throws -> PhotoSuggestResponse {
        // Finding #18 — cold qwen3-vl model load has been observed at 149 s on
        // device. 180 s covers the cold path plus warmup jitter without letting
        // a truly hung server hang the UI indefinitely.
        try await tracedRequest(
            interval: "suggest_request",
            resultEvent: "suggest_result",
            initialEvent: { id in
                apiSignposter.emitEvent(
                    "suggest_request",
                    id: id,
                    "photoId=\(photoId, privacy: .public)"
                )
            }
        ) { _ in
            try await request(
                path: "/photos/\(String(photoId).urlPathComponentEncoded)/suggest",
                method: "GET",
                body: nil,
                contentType: nil,
                timeout: 180
            )
        }
    }

    /// Posts the per-suggestion decision list for a photo as fire-and-forget telemetry.
    ///
    /// The server persists one row per decision to `photo_suggestion_outcomes`,
    /// idempotently per (`photoId`, `request.visionModel`) — safe to retry.
    /// This call is NOT on the confirm critical path; callers should wrap it
    /// in a detached `Task` and swallow errors. See Swift2_014 / Dev2_017.
    ///
    /// - Parameters:
    ///   - photoId: The photo ID returned by a prior `ingest` call.
    ///   - request: The batched outcomes request (`visionModel`, optional
    ///     `promptVersion`, and the full per-suggestion decision list).
    /// - Throws: `APIClientError.missingAPIKey` / `.invalidURL` /
    ///   `.unexpectedStatusCode`, or any underlying `URLError`. Callers are
    ///   expected to log and discard — outcomes failure must never surface.
    @discardableResult
    func postPhotoSuggestionOutcomes(
        photoId: Int,
        request: PhotoSuggestionOutcomesRequest,
        retryCount: Int = 0
    ) async throws -> PhotoSuggestionOutcomesResponse {
        let body = try JSONEncoder.binBrain.encode(request)
        return try await tracedRequest(
            interval: "outcomes_post",
            resultEvent: "outcomes_post_result",
            initialEvent: { id in
                apiSignposter.emitEvent(
                    "outcomes_post",
                    id: id,
                    "photoId=\(photoId, privacy: .public) size=\(body.count, privacy: .public) retryCount=\(retryCount, privacy: .public)"
                )
            },
            successPayload: { _ in "status=success retryCount=\(retryCount)" },
            failurePayload: { "status=failure retryCount=\(retryCount)" }
        ) { _ in
            try await self.request(
                path: "/photos/\(String(photoId).urlPathComponentEncoded)/outcomes",
                method: "POST",
                body: body,
                contentType: "application/json",
                timeout: 10
            )
        }
    }

    /// Raw variant of `postPhotoSuggestionOutcomes` used by the
    /// `OutcomeQueueManager` (Swift2_018). Returns the HTTP status code
    /// directly so the queue can classify retry behaviour without trying
    /// to decode a response body that may be empty on 4xx/5xx. Throws
    /// `URLError` on transport failure; never throws for HTTP-layer
    /// statuses.
    ///
    /// - Parameters:
    ///   - photoId: Server-side photo ID.
    ///   - body: Already-serialized JSON payload (frozen at enqueue time).
    ///   - clientRetryCount: Value forwarded as `X-Client-Retry-Count` so
    ///     the server can log the number of attempts it took to deliver.
    ///   - idempotencyKey: Stable client-side UUID forwarded as
    ///     `Idempotency-Key` (`Swift2_018b` F-6). Every retry for the
    ///     same `PendingOutcome` row reuses the same value so the server
    ///     can collapse duplicate attempts once the matching ApiDev PR
    ///     adds the dedup column. Until that server PR ships, the header
    ///     is ignored — still safe to send.
    /// - Returns: The HTTP status code returned by the server.
    func postPhotoSuggestionOutcomesRaw(
        photoId: Int,
        body: Data,
        clientRetryCount: Int,
        idempotencyKey: UUID
    ) async throws -> Int {
        try await tracedRequest(
            interval: "outcomes_post",
            resultEvent: "outcomes_post_result",
            initialEvent: { id in
                apiSignposter.emitEvent(
                    "outcomes_post",
                    id: id,
                    "photoId=\(photoId, privacy: .public) size=\(body.count, privacy: .public) retryCount=\(clientRetryCount, privacy: .public)"
                )
            },
            successPayload: { http in
                "status=\(http) retryCount=\(clientRetryCount)"
            }
        ) { id in
            guard hasAPIKey else {
                throw TracedRequestFailure(
                    payload: "status=missing_api_key retryCount=\(clientRetryCount)",
                    underlying: APIClientError.missingAPIKey
                )
            }
            let urlString = baseURL + "/photos/\(String(photoId).urlPathComponentEncoded)/outcomes"
            guard let url = URL(string: urlString) else {
                throw TracedRequestFailure(
                    payload: "status=invalid_url retryCount=\(clientRetryCount)",
                    underlying: APIClientError.invalidURL(urlString)
                )
            }
            var urlRequest = URLRequest(url: url, timeoutInterval: 10)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("\(max(clientRetryCount, 0))", forHTTPHeaderField: "X-Client-Retry-Count")
            urlRequest.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
            let shouldAttach = shouldAttachKey(requiresAuth: true, probe: false)
            if let apiKey, shouldAttach {
                urlRequest.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            }
            emitAuthAttachDecision(
                id: id,
                requiresAuth: true,
                attached: shouldAttach && apiKey != nil,
                probe: false
            )

            let response: URLResponse
            do {
                apiSignposter.emitEvent("request_sent", id: id)
                (_, response) = try await session.data(for: urlRequest)
            } catch {
                throw TracedRequestFailure(
                    payload: "status=network_failure retryCount=\(clientRetryCount)",
                    underlying: error
                )
            }
            guard let http = response as? HTTPURLResponse else {
                throw TracedRequestFailure(
                    payload: "status=non_http_response retryCount=\(clientRetryCount)",
                    underlying: APIClientError.unexpectedStatusCode(-1)
                )
            }
            return http.statusCode
        }
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
        var json: [String: Any] = ["name": name]
        // Server upserts items by fingerprint lower(name)|lower(category).
        // Lowercase here so callers don't have to remember.
        if let category { json["category"] = category.lowercased() }
        if let binId { json["bin_id"] = binId }
        if let confidence { json["confidence"] = confidence }
        if let quantity { json["quantity"] = quantity }
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await request(
            path: "/items",
            method: "POST",
            body: body,
            contentType: "application/json",
            timeout: 15
        )
    }

    /// Associates an existing item with a bin via `POST /associate`.
    ///
    /// The `/items` upsert path does not reliably create the `bin_items` join
    /// row when callers pass `bin_id` as a multipart field (see walkthrough
    /// Finding #6 — DB verification showed `bin_items` empty despite 200
    /// responses). Callers should upsert via `upsertItem(...)` and then follow
    /// up with `associateItem(...)` to guarantee the join row exists.
    ///
    /// - Parameters:
    ///   - binId: The bin identifier to associate the item with.
    ///   - itemId: The item ID returned by a prior `upsertItem(...)` call.
    ///   - confidence: Optional association confidence 0–1.
    ///   - quantity: Optional quantity in the bin.
    @discardableResult
    func associateItem(
        binId: String,
        itemId: Int,
        confidence: Double?,
        quantity: Double?
    ) async throws -> AssociateItemResponse {
        var json: [String: Any] = [
            "bin_id": binId,
            "item_id": itemId,
        ]
        if let confidence { json["confidence"] = confidence }
        if let quantity { json["quantity"] = quantity }
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await request(
            path: "/associate",
            method: "POST",
            body: body,
            contentType: "application/json",
            timeout: 10
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
            path: "/bins/\(binId.urlPathComponentEncoded)/items/\(String(itemId).urlPathComponentEncoded)",
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
            path: "/bins/\(binId.urlPathComponentEncoded)/items/\(String(itemId).urlPathComponentEncoded)",
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
        if let category { payload["category"] = category.lowercased() }
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

    private struct CreateLocationBody: Encodable {
        let name: String
        let description: String?
    }

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
        let body = try JSONEncoder().encode(CreateLocationBody(name: name, description: description))
        return try await request(
            path: "/locations",
            method: "POST",
            body: body,
            contentType: "application/json",
            timeout: 10
        )
    }

    /// Soft-deletes a location.
    ///
    /// - Parameter locationId: The location to delete.
    @discardableResult
    func deleteLocation(_ locationId: Int) async throws -> DeleteLocationResponse {
        try await request(
            path: "/locations/\(String(locationId).urlPathComponentEncoded)",
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
            path: "/bins/\(binId.urlPathComponentEncoded)/location",
            method: "PATCH",
            body: body,
            contentType: "application/json",
            timeout: 10
        )
    }

    // MARK: - Host Binding

    /// Normalizes a URL string to `scheme + host + port` — no path, no
    /// trailing slash, host lowercased.
    ///
    /// Used to compare the `baseURL` against the origin the API key is
    /// bound to. Returns `nil` if the input lacks a scheme or host, so
    /// callers can refuse to attach the key rather than guess.
    static func normalizedOrigin(of urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty,
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Whether the `X-API-Key` header should be attached to an outgoing request.
    ///
    /// The key is attached only when:
    /// 1. `probe == true` — caller explicitly opted into a key probe (the
    ///    Settings "Re-bind" flow), or
    /// 2. `requiresAuth == true` **and** the key is Keychain-backed **and**
    ///    the Keychain's bound host matches the normalized origin of the
    ///    current `baseURL`.
    ///
    /// A non-matching bound host, a missing bound host, or an unparseable
    /// `baseURL` all omit the header — indistinguishable server-side from
    /// "no key supplied", so `/health` reports `connectedNoKey` /
    /// authenticated endpoints return 401. Safe default.
    ///
    /// The `BuildConfig.defaultAPIKey` fallback has no binding and is
    /// only attached when `baseURL` matches `BuildConfig.defaultServerURL`,
    /// preserving Debug-build dev ergonomics while matching the gate's
    /// intent.
    private func shouldAttachKey(requiresAuth: Bool, probe: Bool) -> Bool {
        if probe { return true }
        guard requiresAuth else { return false }
        guard let currentOrigin = Self.normalizedOrigin(of: baseURL) else { return false }

        if let keychainKey = keychain.readString(forKey: KeychainHelper.apiKeyAccount),
           !keychainKey.isEmpty {
            guard let bound = keychain.readString(forKey: KeychainHelper.boundHostAccount),
                  !bound.isEmpty else {
                return false
            }
            return bound == currentOrigin
        }

        // Keychain empty → BuildConfig fallback. Attach only when the
        // request targets the BuildConfig default origin (Debug dev path).
        guard let defaultURL = BuildConfig.defaultServerURL,
              let defaultOrigin = Self.normalizedOrigin(of: defaultURL) else {
            return false
        }
        return defaultOrigin == currentOrigin
    }

    // MARK: - Private Helpers

    /// Emits the authentication attachment decision for a request.
    ///
    /// `probe == true` means the caller explicitly allowed probing the current
    /// key on an unbound host (Settings rebind flow). `attached` reflects the
    /// final decision after host-binding policy and key presence are applied.
    private func emitAuthAttachDecision(
        id: OSSignpostID,
        requiresAuth: Bool,
        attached: Bool,
        probe: Bool
    ) {
        apiSignposter.emitEvent(
            "auth_attach_decision",
            id: id,
            "requiresAuth=\(requiresAuth, privacy: .public) attached=\(attached, privacy: .public) probe=\(probe, privacy: .public)"
        )
    }

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
        timeout: TimeInterval,
        requiresAuth: Bool = true,
        probeWithCurrentKey: Bool = false,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        let requestID = apiSignposter.makeSignpostID()
        let bodySize = body?.count ?? 0
        let requestInterval = apiSignposter.beginInterval("api_request", id: requestID)
        apiSignposter.emitEvent(
            "api_request",
            id: requestID,
            "method=\(method, privacy: .public) path=\(path, privacy: .public) timeout=\(timeout, privacy: .public) bodySize=\(bodySize, privacy: .public)"
        )
        if requiresAuth {
            guard hasAPIKey else {
                logger.warning("\(method, privacy: .public) \(path, privacy: .private) BLOCKED: no API key configured")
                emitAuthAttachDecision(
                    id: requestID,
                    requiresAuth: requiresAuth,
                    attached: false,
                    probe: probeWithCurrentKey
                )
                apiSignposter.emitEvent(
                    "api_request_failed",
                    id: requestID,
                    "stage=\("missing_api_key", privacy: .public)"
                )
                apiSignposter.endInterval("api_request", requestInterval)
                throw APIClientError.missingAPIKey
            }
        }

        let urlString = baseURL + path
        guard let url = URL(string: urlString) else {
            logger.error("Invalid URL: \(urlString, privacy: .private)")
            apiSignposter.emitEvent(
                "api_request_failed",
                id: requestID,
                "stage=\("invalid_url", privacy: .public)"
            )
            apiSignposter.endInterval("api_request", requestInterval)
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
        let shouldAttach = shouldAttachKey(requiresAuth: requiresAuth, probe: probeWithCurrentKey)
        if let apiKey, shouldAttach {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        emitAuthAttachDecision(
            id: requestID,
            requiresAuth: requiresAuth,
            attached: shouldAttach && apiKey != nil,
            probe: probeWithCurrentKey
        )
        for (name, value) in extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let headerCount = urlRequest.allHTTPHeaderFields?.count ?? 0
        apiSignposter.emitEvent(
            "prepared_headers",
            id: requestID,
            "count=\(headerCount, privacy: .public)"
        )

        let bodySizeLog = body.map { "\($0.count) bytes" } ?? "none"
        logger.debug("\(method, privacy: .public) \(urlString, privacy: .private) (body: \(bodySizeLog, privacy: .public), timeout: \(timeout, privacy: .public)s)")

        let data: Data
        let response: URLResponse
        do {
            apiSignposter.emitEvent("request_sent", id: requestID)
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            logger.error("\(method, privacy: .public) \(path, privacy: .private) NETWORK ERROR: \(error.localizedDescription, privacy: .private)")
            apiSignposter.emitEvent(
                "api_request_failed",
                id: requestID,
                "stage=\("network", privacy: .public)"
            )
            apiSignposter.endInterval("api_request", requestInterval)
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("\(method, privacy: .public) \(path, privacy: .private) ERROR: non-HTTP response")
            apiSignposter.emitEvent(
                "api_request_failed",
                id: requestID,
                "stage=\("non_http_response", privacy: .public)"
            )
            apiSignposter.endInterval("api_request", requestInterval)
            throw APIClientError.unexpectedStatusCode(-1)
        }
        apiSignposter.emitEvent(
            "response_received",
            id: requestID,
            "status=\(httpResponse.statusCode, privacy: .public) bytes=\(data.count, privacy: .public)"
        )

        logger.debug("\(method, privacy: .public) \(path, privacy: .private) → \(httpResponse.statusCode, privacy: .public) (\(data.count, privacy: .public) bytes)")
        #if DEBUG
        let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary \(data.count) bytes>"
        logger.debug("Response: \(preview, privacy: .private)")
        #endif

        if (200...299).contains(httpResponse.statusCode) {
            do {
                apiSignposter.emitEvent("decode_started", id: requestID)
                let decoded = try JSONDecoder.binBrain.decode(T.self, from: data)
                apiSignposter.emitEvent("decode_ended", id: requestID)
                apiSignposter.endInterval("api_request", requestInterval)
                return decoded
            } catch {
                logger.error("\(method, privacy: .public) \(path, privacy: .private) DECODE ERROR: \(error.localizedDescription, privacy: .private)")
                apiSignposter.emitEvent(
                    "api_request_failed",
                    id: requestID,
                    "stage=\("decode", privacy: .public) status=\(httpResponse.statusCode, privacy: .public)"
                )
                apiSignposter.endInterval("api_request", requestInterval)
                throw error
            }
        } else {
            if let apiError = try? JSONDecoder.binBrain.decode(APIError.self, from: data) {
                logger.error("\(method, privacy: .public) \(path, privacy: .private) API ERROR: \(apiError.localizedDescription, privacy: .private)")
                apiSignposter.emitEvent(
                    "api_request_failed",
                    id: requestID,
                    "stage=\("api_error", privacy: .public) status=\(httpResponse.statusCode, privacy: .public)"
                )
                apiSignposter.endInterval("api_request", requestInterval)
                throw apiError
            }
            logger.error("\(method, privacy: .public) \(path, privacy: .private) HTTP ERROR: \(httpResponse.statusCode, privacy: .public)")
            apiSignposter.emitEvent(
                "api_request_failed",
                id: requestID,
                "stage=\("http_error", privacy: .public) status=\(httpResponse.statusCode, privacy: .public)"
            )
            apiSignposter.endInterval("api_request", requestInterval)
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
