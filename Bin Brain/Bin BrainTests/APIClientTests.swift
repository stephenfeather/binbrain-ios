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

final class APIClientTests: XCTestCase {

    var sut: APIClient!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "serverURL")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        sut = APIClient(session: mockSession)
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
                    { "photo_id": 7, "path": "/data/photos/B-42/abc123.jpg" }
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
                "photos": [{ "photo_id": 7, "path": "/data/photos/B-42/abc.jpg" }]
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

    // MARK: - Test 6: ingest() returns decoded photo ID

    func testIngestReturnsPhotoId() async throws {
        MockURLProtocol.requestHandler = { _ in
            let json = Data("""
            {
                "version": "1",
                "bin_id": "B-42",
                "photos": [{ "photo_id": 99, "path": "/data/photos/B-42/xyz.jpg" }]
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
}
