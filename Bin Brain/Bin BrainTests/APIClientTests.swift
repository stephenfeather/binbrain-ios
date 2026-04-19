// APIClientTests.swift
// Bin BrainTests
//
// XCTest coverage for APIClient.swift using MockURLProtocol to intercept
// URLSession calls without a live server.

import XCTest
@testable import Bin_Brain

// MARK: - MockURLProtocol

/// A URLProtocol subclass that intercepts all requests for testing.
///
/// Set `requestHandler` before each test and clear it in `tearDown`.
final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - URLRequest body helper

private extension URLRequest {
    /// Returns the request body as `Data`, reading from `httpBody` or `httpBodyStream`.
    ///
    /// `URLSession` converts `httpBody` to a stream before passing the request to
    /// `URLProtocol`, so both sources must be checked.
    var bodyData: Data? {
        if let data = httpBody { return data }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: bufferSize)
            guard bytesRead > 0 else { break }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return data
    }
}

// MARK: - Helpers

/// Builds a minimal `HTTPURLResponse` for use in mock handlers.
private func makeResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "http://mock")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

// MARK: - APIClientTests

@MainActor
final class APIClientTests: XCTestCase {

    var sut: APIClient!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "serverURL")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        sut = APIClient(
            session: mockSession,
            keychain: InMemoryKeychainHelper(seeded: ["apiKey": "test-key"])
        )
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        UserDefaults.standard.removeObject(forKey: "serverURL")
        sut = nil
        try await super.tearDown()
    }

    // MARK: - Test 1: health() happy path

    func testHealthReturnsDecodedResponse() async throws {
        MockURLProtocol.requestHandler = { _ in
            let json = Data("""
            {
                "version": "1",
                "ok": true,
                "db_ok": true,
                "embed_model": "BAAI/bge-small-en-v1.5",
                "expected_dims": 384
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        let result = try await sut.health()

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.dbOk)
        XCTAssertEqual(result.version, "1")
        XCTAssertEqual(result.embedModel, "BAAI/bge-small-en-v1.5")
    }

    // MARK: - Test 2: health() error path — 503 throws APIError

    func testHealthThrowsAPIErrorOn503() async throws {
        MockURLProtocol.requestHandler = { _ in
            let json = Data("""
            {
                "version": "1",
                "error": {
                    "code": "service_unavailable",
                    "message": "Database is unavailable"
                }
            }
            """.utf8)
            return (makeResponse(statusCode: 503), json)
        }

        do {
            _ = try await sut.health()
            XCTFail("Expected APIError to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.error.code, "service_unavailable")
            XCTAssertEqual(error.error.message, "Database is unavailable")
        }
    }

    // MARK: - Test 3: listBins() sorts by binId alphanumeric ascending

    func testListBinsReturnsSortedByBinId() async throws {
        // Return bins in reverse order; listBins() must re-sort ascending.
        MockURLProtocol.requestHandler = { _ in
            let json = Data("""
            {
                "version": "1",
                "bins": [
                    {
                        "bin_id": "BIN-0003",
                        "item_count": 2,
                        "photo_count": 1,
                        "last_updated": "2025-01-03T00:00:00Z"
                    },
                    {
                        "bin_id": "BIN-0001",
                        "item_count": 5,
                        "photo_count": 2,
                        "last_updated": "2025-01-01T00:00:00Z"
                    },
                    {
                        "bin_id": "BIN-0002",
                        "item_count": 3,
                        "photo_count": 0,
                        "last_updated": "2025-01-02T00:00:00Z"
                    }
                ]
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        let result = try await sut.listBins()

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].binId, "BIN-0001")
        XCTAssertEqual(result[1].binId, "BIN-0002")
        XCTAssertEqual(result[2].binId, "BIN-0003")
    }

    // MARK: - Test 4: getBin() returns decoded response with items and photos

    func testGetBinReturnsDecodedResponse() async throws {
        MockURLProtocol.requestHandler = { _ in
            let json = Data("""
            {
                "version": "1",
                "bin_id": "B-42",
                "items": [
                    {
                        "item_id": 12,
                        "name": "M3 Screw",
                        "category": "fastener",
                        "quantity": 50,
                        "confidence": 0.92
                    }
                ],
                "photos": [
                    { "photo_id": 7, "url": "/photos/7/file" }
                ]
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        let result = try await sut.getBin("B-42")

        XCTAssertEqual(result.binId, "B-42")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].name, "M3 Screw")
        XCTAssertEqual(result.items[0].itemId, 12)
        XCTAssertEqual(result.photos.count, 1)
        XCTAssertEqual(result.photos[0].photoId, 7)
    }

    // MARK: - Test 5: ingest() sends multipart/form-data with bin_id field

    func testIngestBuildsMultipartRequest() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "bin_id": "B-42",
                "photos": [{ "photo_id": 7, "url": "/photos/7/file" }]
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.ingest(jpegData: Data("fake-jpeg-bytes".utf8), binId: "B-42")

        let contentType = try XCTUnwrap(capturedRequest?.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(
            contentType.contains("multipart/form-data"),
            "Content-Type should contain 'multipart/form-data', got: \(contentType)"
        )

        let bodyString = capturedRequest?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(
            bodyString.contains("B-42"),
            "Multipart body should contain bin_id value 'B-42'"
        )
        XCTAssertTrue(
            bodyString.contains("bin_id"),
            "Multipart body should contain field name 'bin_id'"
        )
    }

    // MARK: - Test 5b: ingest() with deviceMetadata includes device_metadata field

    func testIngestWithDeviceMetadataIncludesField() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "bin_id": "B-42",
                "photos": [{ "photo_id": 7, "url": "/photos/7/file" }]
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        let metadata = "{\"device_processing\":{\"version\":\"1\"}}"
        _ = try await sut.ingest(
            jpegData: Data("fake-jpeg-bytes".utf8),
            binId: "B-42",
            deviceMetadata: metadata
        )

        let bodyString = capturedRequest?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(
            bodyString.contains("device_metadata"),
            "Multipart body should contain field name 'device_metadata'"
        )
        XCTAssertTrue(
            bodyString.contains("device_processing"),
            "Multipart body should contain the metadata JSON value"
        )
    }

    // MARK: - Test 5c: ingest() without deviceMetadata excludes device_metadata field

    func testIngestWithoutDeviceMetadataExcludesField() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "bin_id": "B-42",
                "photos": [{ "photo_id": 7, "url": "/photos/7/file" }]
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.ingest(jpegData: Data("fake-jpeg-bytes".utf8), binId: "B-42")

        let bodyString = capturedRequest?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(
            bodyString.contains("device_metadata"),
            "Multipart body should NOT contain 'device_metadata' when nil"
        )
    }

    // MARK: - Test 6: ingest() returns decoded photo ID

    func testIngestReturnsPhotoId() async throws {
        MockURLProtocol.requestHandler = { _ in
            let json = Data("""
            {
                "version": "1",
                "bin_id": "B-42",
                "photos": [{ "photo_id": 99, "url": "/photos/99/file" }]
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        let result = try await sut.ingest(jpegData: Data(), binId: "B-42")

        XCTAssertEqual(result.binId, "B-42")
        XCTAssertEqual(result.photos[0].photoId, 99)
    }

    // MARK: - Test 7: upsertItem() omits nil fields from body

    func testUpsertItemOmitsNilFields() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "item_id": 1,
                "fingerprint": "widget|",
                "name": "Widget",
                "category": null
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.upsertItem(
            name: "Widget",
            category: nil,
            quantity: nil,
            confidence: nil,
            binId: nil
        )

        let bodyString = capturedRequest?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(bodyString.contains("category"), "category should be omitted when nil")
        XCTAssertFalse(bodyString.contains("quantity"), "quantity should be omitted when nil")
        XCTAssertFalse(bodyString.contains("bin_id"), "bin_id should be omitted when nil")
        XCTAssertFalse(bodyString.contains("confidence"), "confidence should be omitted when nil")
        XCTAssertTrue(bodyString.contains("name"), "name must always be present")
    }

    // MARK: - Test 8: upsertItem() includes all fields when non-nil

    func testUpsertItemIncludesAllFields() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "item_id": 1,
                "fingerprint": "screw|fastener",
                "name": "Screw",
                "category": "fastener"
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.upsertItem(
            name: "Screw",
            category: "fastener",
            quantity: 10.0,
            confidence: 0.9,
            binId: "B-1"
        )

        let bodyString = capturedRequest?.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(bodyString.contains("name"), "name must be present")
        XCTAssertTrue(bodyString.contains("category"), "category must be present when non-nil")
        XCTAssertTrue(bodyString.contains("quantity"), "quantity must be present when non-nil")
        XCTAssertTrue(bodyString.contains("confidence"), "confidence must be present when non-nil")
        XCTAssertTrue(bodyString.contains("bin_id"), "bin_id must be present when non-nil")
    }

    // MARK: - Test 9: search() builds correct query string with min_score

    func testSearchBuildsCorrectQueryString() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {"version":"1","q":"screw","limit":20,"offset":0,"min_score":0.5,"results":[]}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.search(query: "screw", minScore: 0.5)

        let urlString = try XCTUnwrap(capturedRequest?.url?.absoluteString)
        XCTAssertTrue(urlString.contains("q=screw"), "URL must contain q= param")
        XCTAssertTrue(urlString.contains("min_score="), "URL must contain min_score= param")
    }

    // MARK: - Test 10: search() omits min_score when nil

    func testSearchWithNilMinScoreOmitsParam() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {"version":"1","q":"bolt","limit":20,"offset":0,"min_score":null,"results":[]}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.search(query: "bolt", minScore: nil)

        let urlString = try XCTUnwrap(capturedRequest?.url?.absoluteString)
        XCTAssertTrue(urlString.contains("q=bolt"), "URL must contain q= param")
        XCTAssertFalse(urlString.contains("min_score"), "URL must NOT contain min_score when nil")
    }

    // MARK: - Test 11: request() throws invalidURL for malformed base URL

    func testRequestThrowsOnInvalidBaseURL() async throws {
        // A malformed IPv6 literal (unclosed `[`) is guaranteed to fail URL(string:)
        UserDefaults.standard.set("http://[invalid", forKey: "serverURL")

        do {
            _ = try await sut.health()
            XCTFail("Expected APIClientError.invalidURL to be thrown")
        } catch let error as APIClientError {
            guard case .invalidURL = error else {
                XCTFail("Expected .invalidURL, got \(error)")
                return
            }
            // Correct error type — test passes
        }
    }

    // MARK: - Test 12: suggest() sends correct photo ID in URL path

    func testSuggestUsesCorrectPhotoIdInPath() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "photo_id": 42,
                "model": "qwen3-vl:4b",
                "vision_elapsed_ms": 21000,
                "suggestions": []
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.suggest(photoId: 42)

        let path = try XCTUnwrap(capturedRequest?.url?.path)
        XCTAssertTrue(
            path.contains("/photos/42/suggest"),
            "URL path should contain '/photos/42/suggest', got: \(path)"
        )
    }

    // MARK: - Test 13: non-JSON 4xx body falls back to APIClientError.unexpectedStatusCode

    func testRequestThrowsUnexpectedStatusCodeWhenErrorBodyUnparseable() async throws {
        MockURLProtocol.requestHandler = { _ in
            let data = Data("not json at all".utf8)
            return (makeResponse(statusCode: 404), data)
        }

        do {
            _ = try await sut.health()
            XCTFail("Expected error to be thrown")
        } catch let error as APIClientError {
            guard case .unexpectedStatusCode(let code) = error else {
                XCTFail("Expected .unexpectedStatusCode, got \(error)")
                return
            }
            XCTAssertEqual(code, 404)
        }
    }

    // MARK: - Test 14: confirmClass() sends POST with class_name in JSON body

    func testConfirmClassSendsCorrectPayload() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "class_name": "scissors",
                "added": true,
                "active_class_count": 47,
                "reload_triggered": true
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        let result = try await sut.confirmClass(className: "scissors", category: "tools")

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        let path = try XCTUnwrap(capturedRequest?.url?.path)
        XCTAssertTrue(path.contains("/classes/confirm"), "Path should contain /classes/confirm, got: \(path)")

        let bodyData = try XCTUnwrap(capturedRequest?.bodyData)
        let payload = try JSONDecoder().decode([String: String].self, from: bodyData)
        XCTAssertEqual(payload["class_name"], "scissors")
        XCTAssertEqual(payload["category"], "tools")
        XCTAssertEqual(payload["source"], "vision_llm")
        XCTAssertEqual(payload["version"], "1")

        XCTAssertEqual(result.className, "scissors")
        XCTAssertTrue(result.added)
        XCTAssertEqual(result.activeClassCount, 47)
    }

    func testConfirmClassOmitsCategoryWhenNil() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "class_name": "wire cutters",
                "added": true,
                "active_class_count": 48,
                "reload_triggered": true
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.confirmClass(className: "wire cutters", category: nil)

        let bodyData = try XCTUnwrap(capturedRequest?.bodyData)
        let payload = try JSONDecoder().decode([String: String].self, from: bodyData)
        XCTAssertEqual(payload["class_name"], "wire cutters")
        XCTAssertNil(payload["category"], "category should be absent when nil")
    }

    // MARK: - Test 15: getBin() sends GET to correct path

    // MARK: - Issue #15 / F-07: path-component percent-encoding

    func testGetBinPercentEncodesSlashInBinId() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {"version":"1","bin_id":"a/b","items":[],"photos":[]}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try? await sut.getBin("a/b")

        let url = try XCTUnwrap(captured?.url?.absoluteString)
        XCTAssertTrue(url.contains("/bins/a%2Fb"),
                      "`/` in bin ID must be percent-encoded to prevent path traversal; got \(url)")
        XCTAssertFalse(url.contains("/bins/a/b"),
                       "Raw `/` must not appear in the encoded segment; got \(url)")
    }

    func testGetBinPercentEncodesQueryAndFragmentChars() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {"version":"1","bin_id":"x","items":[],"photos":[]}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try? await sut.getBin("BIN?admin=1")
        let urlQ = try XCTUnwrap(captured?.url?.absoluteString)
        XCTAssertTrue(urlQ.contains("BIN%3Fadmin"),
                      "`?` must be percent-encoded in path segment to prevent query injection; got \(urlQ)")
        XCTAssertFalse(urlQ.contains("?admin"),
                       "Raw `?` must not appear — would split path into query; got \(urlQ)")

        _ = try? await sut.getBin("BIN#frag")
        let urlH = try XCTUnwrap(captured?.url?.absoluteString)
        XCTAssertTrue(urlH.contains("BIN%23frag"),
                      "`#` must be percent-encoded in path segment; got \(urlH)")
    }

    func testRemoveItemPercentEncodesBinIdInPath() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {"version":"1","bin_id":"a/b","item_id":5,"removed":true}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try? await sut.removeItem(itemId: 5, binId: "a/b")

        let url = try XCTUnwrap(captured?.url?.absoluteString)
        XCTAssertTrue(url.contains("/bins/a%2Fb/items/5"),
                      "Bin ID `/` must be encoded; got \(url)")
    }

    // MARK: - F-11: createLocation sends JSON body

    func testCreateLocationSendsJSONBodyWithNameAndDescription() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {"version":"1","location":{"location_id":1,"name":"Garage","description":"North wall","created_at":"2025-01-01T00:00:00Z"}}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.createLocation(name: "Garage", description: "North wall")

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let bodyData = try XCTUnwrap(captured?.bodyData)
        let payload = try JSONDecoder().decode([String: String].self, from: bodyData)
        XCTAssertEqual(payload["name"], "Garage")
        XCTAssertEqual(payload["description"], "North wall")
    }

    func testCreateLocationOmitsDescriptionWhenNil() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {"version":"1","location":{"location_id":2,"name":"Shed","description":null,"created_at":"2025-01-01T00:00:00Z"}}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.createLocation(name: "Shed", description: nil)

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let bodyData = try XCTUnwrap(captured?.bodyData)
        // Encoded JSON should contain name but encode description as null or omit it.
        let object = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let obj = try XCTUnwrap(object)
        XCTAssertEqual(obj["name"] as? String, "Shed")
        // Swift's default JSONEncoder encodes Optional.none as null unless the key is omitted;
        // with a plain `String?` property it's emitted as `null`. Either behavior is acceptable.
        if let descAny = obj["description"] {
            XCTAssertTrue(descAny is NSNull, "description should be null when nil, got \(descAny)")
        }
    }

    func testAssignLocationPercentEncodesBinId() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {"version":"1","bin_id":"a?b","location_id":1}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try? await sut.assignLocation(binId: "a?b", locationId: 1)

        let url = try XCTUnwrap(captured?.url?.absoluteString)
        XCTAssertTrue(url.contains("/bins/a%3Fb/location"),
                      "Bin ID `?` must be encoded; got \(url)")
    }

    func testGetBinUsesCorrectBinIdInPath() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let json = Data("""
            {
                "version": "1",
                "bin_id": "BIN-0007",
                "items": [],
                "photos": []
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.getBin("BIN-0007")

        let path = try XCTUnwrap(capturedRequest?.url?.path)
        XCTAssertTrue(
            path.contains("BIN-0007"),
            "URL path should contain the bin ID, got: \(path)"
        )
        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
    }

    // MARK: - /associate request shape

    /// Asserts /associate is sent as application/json with snake_case fields
    /// `bin_id` / `item_id` (not `binId` / `itemId`).
    /// Matches live OpenAPI contract: AssociateItemBody JSON body.
    func testAssociateItemSendsJSONWithSnakeCaseFields() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {"ok":true,"bin_id":"BIN-0003","item_id":42}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.associateItem(
            binId: "BIN-0003",
            itemId: 42,
            confidence: 0.9,
            quantity: 2.0
        )

        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/associate",
                       "Must hit exactly /associate — not /bins/.../associate or /associates")

        let contentType = try XCTUnwrap(req.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(contentType, "application/json",
                       "Server's AssociateItemBody is a Pydantic JSON body. Got: \(contentType)")

        let body = try XCTUnwrap(req.bodyData)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(decoded["bin_id"] as? String, "BIN-0003")
        XCTAssertEqual(decoded["item_id"] as? Int, 42)
        XCTAssertEqual(decoded["confidence"] as? Double, 0.9)
        XCTAssertEqual(decoded["quantity"] as? Double, 2.0)
        XCTAssertNil(decoded["binId"], "Must not send camelCase")
        XCTAssertNil(decoded["itemId"], "Must not send camelCase")
    }

    // MARK: - Finding #8-B: fetchPhotoData attaches X-API-Key

    func testFetchPhotoDataAttachesAPIKeyAndHitsCorrectPath() async throws {
        UserDefaults.standard.set("http://10.1.1.205:8000", forKey: "serverURL")
        defer { UserDefaults.standard.removeObject(forKey: "serverURL") }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let boundSut = APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: [
                KeychainHelper.apiKeyAccount: "test-key",
                KeychainHelper.boundHostAccount: "http://10.1.1.205:8000"
            ])
        )

        var captured: URLRequest?
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        MockURLProtocol.requestHandler = { request in
            captured = request
            return (makeResponse(statusCode: 200), jpegBytes)
        }

        let data = try await boundSut.fetchPhotoData(photoId: 42, width: 200)

        XCTAssertEqual(data, jpegBytes, "Returned bytes must match server payload")
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "test-key",
                       "fetchPhotoData must attach X-API-Key — this is the whole point of Finding #8-B")
        XCTAssertEqual(req.url?.path, "/photos/42/file", "Path must be /photos/{id}/file")
        XCTAssertEqual(req.url?.query, "w=200", "Width must round-trip as ?w=<n>")
    }

    func testFetchPhotoDataThrowsOnMissingKey() async {
        // Isolate from any BuildConfig.defaultAPIKey leaking in via Info.plist.
        BuildConfig.lookup = { _ in nil }
        defer { BuildConfig.lookup = { key in Bundle.main.object(forInfoDictionaryKey: key) } }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let unkeyedSut = APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper()
        )

        do {
            _ = try await unkeyedSut.fetchPhotoData(photoId: 42, width: nil)
            XCTFail("Expected missingAPIKey to throw")
        } catch APIClientError.missingAPIKey {
            // expected
        } catch {
            XCTFail("Expected APIClientError.missingAPIKey, got \(error)")
        }
    }

    func testFetchPhotoDataThrowsUnexpectedStatusOnNon2xx() async {
        UserDefaults.standard.set("http://10.1.1.205:8000", forKey: "serverURL")
        defer { UserDefaults.standard.removeObject(forKey: "serverURL") }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let boundSut = APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: [
                KeychainHelper.apiKeyAccount: "test-key",
                KeychainHelper.boundHostAccount: "http://10.1.1.205:8000"
            ])
        )
        MockURLProtocol.requestHandler = { _ in
            (makeResponse(statusCode: 401), Data())
        }

        do {
            _ = try await boundSut.fetchPhotoData(photoId: 42, width: nil)
            XCTFail("Expected non-2xx to throw")
        } catch APIClientError.unexpectedStatusCode(let code) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("Expected unexpectedStatusCode, got \(error)")
        }
    }

    func testAssociateItemOmitsOptionalFieldsWhenNil() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {"ok":true,"bin_id":"BIN-0003","item_id":42}
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        _ = try await sut.associateItem(
            binId: "BIN-0003",
            itemId: 42,
            confidence: Double?.none,
            quantity: Double?.none
        )

        let body = try XCTUnwrap(captured?.bodyData)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertNil(decoded["confidence"],
                     "nil confidence must be omitted, not sent as null")
        XCTAssertNil(decoded["quantity"],
                     "nil quantity must be omitted, not sent as null")
        XCTAssertEqual(decoded["bin_id"] as? String, "BIN-0003",
                       "bin_id is required — must still be present")
        XCTAssertEqual(decoded["item_id"] as? Int, 42,
                       "item_id is required — must still be present")
    }

    // MARK: - Swift2_022: deleteBin

    /// Server contract per `docs/openapi.yaml:1222-1290` — 200 response carries
    /// `moved_item_count`; the method issues a `DELETE /bins/{id}` request.
    func testDeleteBinReturnsDecodedResponseOnSuccess() async throws {
        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = Data("""
            {
                "status": "deleted",
                "bin_id": "BIN-0042",
                "moved_item_count": 3,
                "deleted_at": "2026-04-19T22:30:00Z"
            }
            """.utf8)
            return (makeResponse(statusCode: 200), json)
        }

        let result = try await sut.deleteBin(binId: "BIN-0042")

        XCTAssertNotNil(result, "200 must decode a non-nil response")
        XCTAssertEqual(result?.movedItemCount, 3)
        XCTAssertEqual(result?.binId, "BIN-0042")
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.url?.path, "/bins/BIN-0042")
    }

    /// 404 (bin not found / already soft-deleted) is idempotent success — the
    /// method returns nil so callers can refresh without surfacing a crash.
    func testDeleteBinReturnsNilOn404AlreadyGone() async throws {
        MockURLProtocol.requestHandler = { _ in
            let json = Data("""
            {"version":"1","error":{"code":"not_found","message":"Bin not found"}}
            """.utf8)
            return (makeResponse(statusCode: 404), json)
        }

        let result = try await sut.deleteBin(binId: "BIN-GONE")

        XCTAssertNil(result, "404 is treated as idempotent success — nil return, no throw")
    }

    /// 400 `cannot_delete_sentinel` must surface the typed error so the UI
    /// can log a warning (we have a latent UI bug if this ever reaches us).
    func testDeleteBinThrowsAPIErrorOn400CannotDeleteSentinel() async throws {
        MockURLProtocol.requestHandler = { _ in
            let json = Data("""
            {"version":"1","error":{"code":"cannot_delete_sentinel","message":"The UNASSIGNED bin cannot be deleted."}}
            """.utf8)
            return (makeResponse(statusCode: 400), json)
        }

        do {
            _ = try await sut.deleteBin(binId: "UNASSIGNED")
            XCTFail("Expected APIError to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.error.code, "cannot_delete_sentinel")
        }
    }
}

// MARK: - Host binding gate tests (#13)

@MainActor
final class APIClientHostBindingTests: XCTestCase {

    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        MockURLProtocol.requestHandler = nil
        UserDefaults.standard.removeObject(forKey: "serverURL")
        session = nil
        try await super.tearDown()
    }

    private static let healthJSON = Data("""
    {"version":"1","ok":true,"db_ok":true,"embed_model":"BAAI/bge-small-en-v1.5","expected_dims":384,"auth_ok":true,"role":"user"}
    """.utf8)

    private static func ok(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private static let binsJSON = Data("""
    {"version":"1","bins":[]}
    """.utf8)

    // MARK: - normalizedOrigin

    func testNormalizedOriginIncludesPort() {
        XCTAssertEqual(APIClient.normalizedOrigin(of: "http://10.1.1.205:8000"),
                       "http://10.1.1.205:8000")
    }

    func testNormalizedOriginStripsPathAndTrailingSlash() {
        XCTAssertEqual(APIClient.normalizedOrigin(of: "https://raspberrypi.local:8000/"),
                       "https://raspberrypi.local:8000")
        XCTAssertEqual(APIClient.normalizedOrigin(of: "https://host:8000/api/v1"),
                       "https://host:8000")
    }

    func testNormalizedOriginLowercasesHost() {
        XCTAssertEqual(APIClient.normalizedOrigin(of: "HTTP://Example.COM:8000"),
                       "http://example.com:8000")
    }

    func testNormalizedOriginReturnsNilWhenSchemeMissing() {
        XCTAssertNil(APIClient.normalizedOrigin(of: "10.1.1.205"))
    }

    func testNormalizedOriginReturnsNilWhenHostMissing() {
        XCTAssertNil(APIClient.normalizedOrigin(of: "http://"))
    }

    // MARK: - Gate behavior

    func testAuthenticatedRequestAttachesKeyOnMatchingBoundHost() async throws {
        UserDefaults.standard.set("http://10.1.1.205:8000", forKey: "serverURL")
        let keychain = InMemoryKeychainHelper(seeded: [
            KeychainHelper.apiKeyAccount: "test-key",
            KeychainHelper.boundHostAccount: "http://10.1.1.205:8000"
        ])
        let sut = APIClient(session: session, keychain: keychain)

        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            return (Self.ok(for: request), Self.binsJSON)
        }

        _ = try await sut.listBins()

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "X-API-Key"), "test-key",
                       "X-API-Key must be attached when baseURL origin matches the bound host")
    }

    func testAuthenticatedRequestOmitsKeyOnMismatchedBoundHost() async throws {
        UserDefaults.standard.set("http://evil.example.com:8000", forKey: "serverURL")
        let keychain = InMemoryKeychainHelper(seeded: [
            KeychainHelper.apiKeyAccount: "test-key",
            KeychainHelper.boundHostAccount: "http://10.1.1.205:8000"
        ])
        let sut = APIClient(session: session, keychain: keychain)

        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            return (Self.ok(for: request), Self.binsJSON)
        }

        _ = try await sut.listBins()

        XCTAssertNil(captured?.value(forHTTPHeaderField: "X-API-Key"),
                     "X-API-Key MUST NOT leak to a host other than the bound host (F-04)")
    }

    func testAuthenticatedRequestOmitsKeyWhenBoundHostMissing() async throws {
        UserDefaults.standard.set("http://10.1.1.205:8000", forKey: "serverURL")
        let keychain = InMemoryKeychainHelper(seeded: [
            KeychainHelper.apiKeyAccount: "test-key"
            // no boundHost — TOFU not yet completed
        ])
        let sut = APIClient(session: session, keychain: keychain)

        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            return (Self.ok(for: request), Self.binsJSON)
        }

        _ = try await sut.listBins()

        XCTAssertNil(captured?.value(forHTTPHeaderField: "X-API-Key"),
                     "X-API-Key must be omitted when no bound host is recorded")
    }

    func testHealthDefaultDoesNotAttachKey() async throws {
        UserDefaults.standard.set("http://10.1.1.205:8000", forKey: "serverURL")
        let keychain = InMemoryKeychainHelper(seeded: [
            KeychainHelper.apiKeyAccount: "test-key",
            KeychainHelper.boundHostAccount: "http://10.1.1.205:8000"
        ])
        let sut = APIClient(session: session, keychain: keychain)

        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            return (Self.ok(for: request), Self.healthJSON)
        }

        _ = try await sut.health()

        XCTAssertNil(captured?.value(forHTTPHeaderField: "X-API-Key"),
                     "Default health() probe must not send the key (F-10) — auth_ok inspection is opt-in via probeWithCurrentKey")
    }

    func testHealthWithProbeAttachesKeyEvenWhenBoundHostMismatched() async throws {
        UserDefaults.standard.set("http://10.1.1.205:8000", forKey: "serverURL")
        let keychain = InMemoryKeychainHelper(seeded: [
            KeychainHelper.apiKeyAccount: "test-key",
            KeychainHelper.boundHostAccount: "http://other:9000"
        ])
        let sut = APIClient(session: session, keychain: keychain)

        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            return (Self.ok(for: request), Self.healthJSON)
        }

        _ = try await sut.health(probeWithCurrentKey: true)

        XCTAssertEqual(captured?.value(forHTTPHeaderField: "X-API-Key"), "test-key",
                       "probeWithCurrentKey is the explicit re-bind escape hatch — must attach the key")
    }
}
