// PhotoLoaderTests.swift
// Bin BrainTests
//
// XCTest coverage for PhotoLoader — the testable half of
// AuthenticatedAsyncImage (Finding #8-B). Confirms the loader drives the
// fetch through APIClient.fetchPhotoData (i.e. the authed path) and
// transitions through the three phases the SwiftUI view renders.

import XCTest
import UIKit
@testable import Bin_Brain

// Distinct URLProtocol to avoid symbol collision with other test files.
final class PhotoLoaderMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.requestHandler else {
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

@MainActor
final class PhotoLoaderTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.set("http://10.1.1.205:8000", forKey: "serverURL")
    }

    override func tearDown() async throws {
        PhotoLoaderMockURLProtocol.requestHandler = nil
        UserDefaults.standard.removeObject(forKey: "serverURL")
        try await super.tearDown()
    }

    private func makeAuthedClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PhotoLoaderMockURLProtocol.self]
        return APIClient(
            session: URLSession(configuration: config),
            keychain: InMemoryKeychainHelper(seeded: [
                KeychainHelper.apiKeyAccount: "test-key",
                KeychainHelper.boundHostAccount: "http://10.1.1.205:8000"
            ])
        )
    }

    private func response(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://mock/photos/1/file")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    /// Tiny valid 1x1 PNG so `UIImage(data:)` returns non-nil.
    private var tinyPNG: Data {
        let context = CGContext(
            data: nil,
            width: 1, height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(UIColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = UIImage(cgImage: context.makeImage()!)
        return image.pngData()!
    }

    // MARK: - Success

    func testLoadRoutesThroughAuthedAPIClientAndReportsSuccess() async throws {
        var sawAuthHeader = false
        var sawAuthedPath = false
        PhotoLoaderMockURLProtocol.requestHandler = { [self] request in
            sawAuthHeader = request.value(forHTTPHeaderField: "X-API-Key") == "test-key"
            sawAuthedPath = request.url?.path == "/photos/7/file"
            return (response(statusCode: 200), tinyPNG)
        }

        let loader = PhotoLoader(photoId: 7, width: 100, apiClient: makeAuthedClient())
        await loader.load()

        XCTAssertTrue(sawAuthHeader,
                      "PhotoLoader must route through APIClient so X-API-Key is attached (not bare URLSession)")
        XCTAssertTrue(sawAuthedPath, "Request must hit /photos/{id}/file")

        if case .success = loader.phase {
            // expected
        } else {
            XCTFail("Expected .success phase after 200 + valid image, got \(loader.phase)")
        }
    }

    // MARK: - Failure: non-2xx

    func testLoadReportsFailureOn401() async {
        PhotoLoaderMockURLProtocol.requestHandler = { [self] _ in
            (response(statusCode: 401), Data())
        }

        let loader = PhotoLoader(photoId: 7, width: nil, apiClient: makeAuthedClient())
        await loader.load()

        XCTAssertEqual(loader.phase, .failure, "401 must land on .failure")
    }

    // MARK: - Failure: undecodable bytes

    func testLoadReportsFailureWhenBytesAreNotAnImage() async {
        PhotoLoaderMockURLProtocol.requestHandler = { [self] _ in
            (response(statusCode: 200), Data("not-a-jpeg".utf8))
        }

        let loader = PhotoLoader(photoId: 7, width: nil, apiClient: makeAuthedClient())
        await loader.load()

        XCTAssertEqual(loader.phase, .failure,
                       "Non-decodable bytes must land on .failure, not crash")
    }

    // MARK: - Initial state

    func testInitialPhaseIsLoading() {
        let loader = PhotoLoader(photoId: 7, width: nil, apiClient: makeAuthedClient())
        XCTAssertEqual(loader.phase, .loading)
    }
}
