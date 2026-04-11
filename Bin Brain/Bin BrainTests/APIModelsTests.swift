// APIModelsTests.swift
// Bin BrainTests
//
// XCTest coverage for APIModels.swift — pure decoding and computed property tests.

import XCTest
@testable import Bin_Brain

final class APIModelsTests: XCTestCase {

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        let data = Data(jsonString.utf8)
        return try JSONDecoder.binBrain.decode(type, from: data)
    }

    // MARK: - Test 1: BinSummary decoding

    func testBinSummaryDecodesAllFields() throws {
        let json = """
        {
            "bin_id": "BIN-0001",
            "item_count": 14,
            "photo_count": 3,
            "last_updated": "2025-02-25T12:00:00Z"
        }
        """
        let summary = try decode(BinSummary.self, from: json)

        XCTAssertEqual(summary.binId, "BIN-0001")
        XCTAssertEqual(summary.itemCount, 14)
        XCTAssertEqual(summary.photoCount, 3)
        // Confirm last_updated decoded as a valid non-epoch Date
        XCTAssertGreaterThan(summary.lastUpdated.timeIntervalSince1970, 0)
    }

    func testBinSummaryLastUpdatedParsesAsExpectedDate() throws {
        let json = """
        {
            "bin_id": "BIN-0042",
            "item_count": 0,
            "photo_count": 0,
            "last_updated": "2025-02-25T12:00:00Z"
        }
        """
        let summary = try decode(BinSummary.self, from: json)

        var formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedDate = try XCTUnwrap(formatter.date(from: "2025-02-25T12:00:00Z"))
        XCTAssertEqual(summary.lastUpdated, expectedDate)
    }

    // MARK: - Test 2: ListBinsResponse decoding

    func testListBinsResponseDecodesArray() throws {
        let json = """
        {
            "version": "1",
            "bins": [
                {
                    "bin_id": "BIN-0001",
                    "item_count": 5,
                    "photo_count": 1,
                    "last_updated": "2025-01-01T00:00:00Z"
                },
                {
                    "bin_id": "BIN-0002",
                    "item_count": 12,
                    "photo_count": 2,
                    "last_updated": "2025-01-02T00:00:00Z"
                },
                {
                    "bin_id": "BIN-0003",
                    "item_count": 0,
                    "photo_count": 0,
                    "last_updated": "2025-01-03T00:00:00Z"
                }
            ]
        }
        """
        let response = try decode(ListBinsResponse.self, from: json)

        XCTAssertEqual(response.version, "1")
        XCTAssertEqual(response.bins.count, 3)
        XCTAssertEqual(response.bins[0].binId, "BIN-0001")
        XCTAssertEqual(response.bins[1].binId, "BIN-0002")
        XCTAssertEqual(response.bins[2].binId, "BIN-0003")
    }

    // MARK: - Test 3: BinItemRecord with null optionals

    func testBinItemRecordDecodesNullOptionalsAsNil() throws {
        let json = """
        {
            "item_id": 42,
            "name": "M3 Screw",
            "category": null,
            "quantity": null,
            "confidence": null
        }
        """
        let item = try decode(BinItemRecord.self, from: json)

        XCTAssertEqual(item.itemId, 42)
        XCTAssertEqual(item.name, "M3 Screw")
        XCTAssertNil(item.category)
        XCTAssertNil(item.quantity)
        XCTAssertNil(item.confidence)
    }

    func testBinItemRecordDecodesAllOptionalFields() throws {
        let json = """
        {
            "item_id": 12,
            "name": "M3 Screw",
            "category": "fastener",
            "quantity": 50.0,
            "confidence": 0.92
        }
        """
        let item = try decode(BinItemRecord.self, from: json)

        XCTAssertEqual(item.itemId, 12)
        XCTAssertEqual(item.category, "fastener")
        let quantity = try XCTUnwrap(item.quantity)
        XCTAssertEqual(quantity, 50.0, accuracy: 1e-10)
        let confidence = try XCTUnwrap(item.confidence)
        XCTAssertEqual(confidence, 0.92, accuracy: 1e-10)
    }

    // MARK: - Test 4: SuggestionItem with null item_id

    func testSuggestionItemWithNullItemIdDecodesAsNil() throws {
        let json = """
        {
            "item_id": null,
            "name": "hex nut",
            "category": "fastener",
            "confidence": 0.61,
            "bins": []
        }
        """
        let suggestion = try decode(SuggestionItem.self, from: json)

        XCTAssertNil(suggestion.itemId)
        XCTAssertEqual(suggestion.name, "hex nut")
        XCTAssertEqual(suggestion.category, "fastener")
        XCTAssertEqual(suggestion.confidence, 0.61, accuracy: 1e-10)
        XCTAssertTrue(suggestion.bins.isEmpty)
    }

    func testSuggestionItemWithNonNullItemIdDecodesCorrectly() throws {
        let json = """
        {
            "item_id": 12,
            "name": "M3 Screw",
            "category": "fastener",
            "confidence": 0.84,
            "bins": ["B-42"]
        }
        """
        let suggestion = try decode(SuggestionItem.self, from: json)

        XCTAssertEqual(suggestion.itemId, 12)
        XCTAssertEqual(suggestion.bins, ["B-42"])
    }

    // MARK: - Test 5: SearchResultItem.score from server

    func testScoreDecodesDirectly() throws {
        let json = """
        {
            "item_id": 1,
            "name": "test",
            "score": 0.5,
            "bins": []
        }
        """
        let item = try decode(SearchResultItem.self, from: json)
        XCTAssertEqual(item.score, 0.5, accuracy: 1e-10)
    }

    func testScoreIdenticalVectors() throws {
        let json = """
        {
            "item_id": 1,
            "name": "test",
            "score": 1.0,
            "bins": []
        }
        """
        let item = try decode(SearchResultItem.self, from: json)
        XCTAssertEqual(item.score, 1.0, accuracy: 1e-10)
    }

    func testScoreOppositeVectors() throws {
        let json = """
        {
            "item_id": 1,
            "name": "test",
            "score": -1.0,
            "bins": []
        }
        """
        let item = try decode(SearchResultItem.self, from: json)
        XCTAssertEqual(item.score, -1.0, accuracy: 1e-10)
    }

    // MARK: - Test 6: APIError decoding

    func testAPIErrorDecodesFullErrorEnvelope() throws {
        let json = """
        {
            "version": "1",
            "error": {
                "code": "not_found",
                "message": "bin not found"
            }
        }
        """
        let apiError = try decode(APIError.self, from: json)

        XCTAssertEqual(apiError.version, "1")
        XCTAssertEqual(apiError.error.code, "not_found")
        XCTAssertEqual(apiError.error.message, "bin not found")
        XCTAssertEqual(apiError.errorDescription, "bin not found")
        // LocalizedError.localizedDescription surfaces errorDescription
        XCTAssertEqual(apiError.localizedDescription, "bin not found")
    }

    func testAPIErrorDecodesInternalErrorCode() throws {
        let json = """
        {
            "version": "1",
            "error": {
                "code": "internal_error",
                "message": "unexpected database failure"
            }
        }
        """
        let apiError = try decode(APIError.self, from: json)

        XCTAssertEqual(apiError.error.code, "internal_error")
        XCTAssertEqual(apiError.errorDescription, "unexpected database failure")
    }

    // MARK: - Test 7: GetBinResponse decoding

    func testGetBinResponseDecodesNestedItemsAndPhotos() throws {
        let json = """
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
                },
                {
                    "item_id": 13,
                    "name": "Arduino Nano",
                    "category": "electronics",
                    "quantity": null,
                    "confidence": null
                }
            ],
            "photos": [
                { "photo_id": 7, "path": "/data/photos/B-42/abc123.jpg" },
                { "photo_id": 8, "path": "/data/photos/B-42/def456.jpg" }
            ]
        }
        """
        let response = try decode(GetBinResponse.self, from: json)

        XCTAssertEqual(response.version, "1")
        XCTAssertEqual(response.binId, "B-42")
        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.photos.count, 2)
        XCTAssertEqual(response.items[0].name, "M3 Screw")
        XCTAssertEqual(response.items[1].name, "Arduino Nano")
        XCTAssertNil(response.items[1].confidence)
        XCTAssertNil(response.items[1].quantity)
        XCTAssertEqual(response.photos[0].photoId, 7)
        XCTAssertEqual(response.photos[1].path, "/data/photos/B-42/def456.jpg")
    }

    // MARK: - Test 8: PhotoSuggestResponse decoding

    func testPhotoSuggestResponseDecodesWithMixedNullItemIds() throws {
        let json = """
        {
            "version": "1",
            "photo_id": 7,
            "model": "qwen3-vl:4b",
            "vision_elapsed_ms": 21340,
            "suggestions": [
                {
                    "item_id": 12,
                    "name": "M3 Screw",
                    "category": "fastener",
                    "confidence": 0.84,
                    "bins": ["B-42"]
                },
                {
                    "item_id": null,
                    "name": "hex nut",
                    "category": "fastener",
                    "confidence": 0.61,
                    "bins": []
                },
                {
                    "item_id": 5,
                    "name": "washer",
                    "category": null,
                    "confidence": 0.55,
                    "bins": ["B-10", "B-42"]
                }
            ]
        }
        """
        let response = try decode(PhotoSuggestResponse.self, from: json)

        XCTAssertEqual(response.version, "1")
        XCTAssertEqual(response.photoId, 7)
        XCTAssertEqual(response.model, "qwen3-vl:4b")
        XCTAssertEqual(response.visionElapsedMs, 21340)
        XCTAssertEqual(response.suggestions.count, 3)
        // First suggestion: known item
        XCTAssertEqual(response.suggestions[0].itemId, 12)
        XCTAssertEqual(response.suggestions[0].bins, ["B-42"])
        // Second suggestion: vision-only (no DB match)
        XCTAssertNil(response.suggestions[1].itemId)
        XCTAssertTrue(response.suggestions[1].bins.isEmpty)
        // Third suggestion: present in multiple bins, null category
        XCTAssertEqual(response.suggestions[2].itemId, 5)
        XCTAssertNil(response.suggestions[2].category)
        XCTAssertEqual(response.suggestions[2].bins, ["B-10", "B-42"])
    }

    // MARK: - Test 9: Invalid JSON throws on missing required field

    func testDecodingBinSummaryThrowsOnMissingRequiredField() {
        // bin_id is required — omitting it must throw a DecodingError
        let json = """
        {
            "item_count": 5,
            "photo_count": 1,
            "last_updated": "2025-01-01T00:00:00Z"
        }
        """
        XCTAssertThrowsError(try decode(BinSummary.self, from: json)) { error in
            // Confirm the error is a decoding error, not some other kind
            XCTAssertTrue(error is DecodingError, "Expected DecodingError, got \(type(of: error))")
        }
    }

    func testDecodingBinItemRecordThrowsOnMissingName() {
        // name is required in BinItemRecord
        let json = """
        {
            "item_id": 42,
            "category": "fastener"
        }
        """
        XCTAssertThrowsError(try decode(BinItemRecord.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - Additional coverage: HealthResponse, IngestResponse, UpsertItemResponse, SearchResponse

    func testHealthResponseDecodesAllFields() throws {
        let json = """
        {
            "version": "1",
            "ok": true,
            "db_ok": true,
            "embed_model": "BAAI/bge-small-en-v1.5",
            "expected_dims": 384
        }
        """
        let response = try decode(HealthResponse.self, from: json)

        XCTAssertEqual(response.version, "1")
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.dbOk)
        XCTAssertEqual(response.embedModel, "BAAI/bge-small-en-v1.5")
        XCTAssertEqual(response.expectedDims, 384)
    }

    func testIngestResponseDecodesWithMultiplePhotos() throws {
        let json = """
        {
            "version": "1",
            "bin_id": "B-42",
            "photos": [
                { "photo_id": 7, "path": "/data/photos/B-42/abc123.jpg" },
                { "photo_id": 8, "path": "/data/photos/B-42/def456.jpg" }
            ]
        }
        """
        let response = try decode(IngestResponse.self, from: json)

        XCTAssertEqual(response.version, "1")
        XCTAssertEqual(response.binId, "B-42")
        XCTAssertEqual(response.photos.count, 2)
        XCTAssertEqual(response.photos[0].photoId, 7)
        XCTAssertEqual(response.photos[1].photoId, 8)
    }

    func testUpsertItemResponseDecodesWithNullCategory() throws {
        let json = """
        {
            "version": "1",
            "item_id": 12,
            "fingerprint": "m3 screw|fastener",
            "name": "M3 Screw",
            "category": null
        }
        """
        let response = try decode(UpsertItemResponse.self, from: json)

        XCTAssertEqual(response.version, "1")
        XCTAssertEqual(response.itemId, 12)
        XCTAssertEqual(response.fingerprint, "m3 screw|fastener")
        XCTAssertEqual(response.name, "M3 Screw")
        XCTAssertNil(response.category)
    }

    func testSearchResponseDecodesResultsContainer() throws {
        let json = """
        {
            "version": "1",
            "q": "m3 screw",
            "limit": 20,
            "offset": 0,
            "min_score": null,
            "results": [
                {
                    "item_id": 12,
                    "name": "M3 Screw",
                    "category": "fastener",
                    "score": 0.96,
                    "bins": ["B-42"]
                }
            ]
        }
        """
        let response = try decode(SearchResponse.self, from: json)

        XCTAssertEqual(response.version, "1")
        XCTAssertEqual(response.q, "m3 screw")
        XCTAssertEqual(response.limit, 20)
        XCTAssertEqual(response.offset, 0)
        XCTAssertNil(response.minScore)
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results[0].name, "M3 Screw")
        XCTAssertEqual(response.results[0].score, 0.96, accuracy: 1e-10)
    }

    func testSearchResultItemDecodesUpc() throws {
        let json = """
        {
            "item_id": 1,
            "name": "widget",
            "upc": "049000042566",
            "score": 0.9,
            "bins": ["B-42"]
        }
        """
        let item = try decode(SearchResultItem.self, from: json)
        XCTAssertEqual(item.upc, "049000042566")
        XCTAssertEqual(item.bins, ["B-42"])
    }

    // MARK: - PhotoRecord with device_metadata

    func testPhotoRecordDecodesWithDeviceMetadata() throws {
        let json = """
        {
            "photo_id": 7,
            "path": "/data/photos/B-42/abc.jpg",
            "device_metadata": {
                "device_processing": {
                    "version": "1",
                    "pipeline_ms": 420,
                    "ios_version": "18.4",
                    "device_model": "iPhone16,1",
                    "quality_scores": {
                        "blur_variance": 150.5,
                        "exposure_mean": 0.45,
                        "saliency_coverage": 0.72,
                        "shortest_side": 1920
                    },
                    "ocr": [],
                    "barcodes": [],
                    "classifications": [],
                    "crop_applied": null
                }
            }
        }
        """
        let record = try decode(PhotoRecord.self, from: json)

        XCTAssertEqual(record.photoId, 7)
        XCTAssertEqual(record.path, "/data/photos/B-42/abc.jpg")
        let metadata = try XCTUnwrap(record.deviceMetadata)
        XCTAssertEqual(metadata.deviceProcessing.version, "1")
        XCTAssertEqual(metadata.deviceProcessing.pipelineMs, 420)
        XCTAssertEqual(metadata.deviceProcessing.qualityScores.blurVariance, 150.5, accuracy: 1e-10)
    }

    func testPhotoRecordDecodesWithoutDeviceMetadata() throws {
        let json = """
        {
            "photo_id": 7,
            "path": "/data/photos/B-42/abc.jpg"
        }
        """
        let record = try decode(PhotoRecord.self, from: json)

        XCTAssertEqual(record.photoId, 7)
        XCTAssertNil(record.deviceMetadata)
    }

    func testPhotoRecordDecodesWithNullDeviceMetadata() throws {
        let json = """
        {
            "photo_id": 7,
            "path": "/data/photos/B-42/abc.jpg",
            "device_metadata": null
        }
        """
        let record = try decode(PhotoRecord.self, from: json)

        XCTAssertEqual(record.photoId, 7)
        XCTAssertNil(record.deviceMetadata)
    }

    // MARK: - SuggestionMatch decoding

    func testSuggestionItemWithMatchDecodes() throws {
        let json = """
        {
            "item_id": null,
            "name": "hex nut",
            "category": "fastener",
            "confidence": 0.61,
            "bins": [],
            "match": {
                "item_id": 42,
                "name": "Hex Nut M3",
                "category": "fastener",
                "score": 0.87,
                "bins": ["B-10", "B-42"]
            }
        }
        """
        let suggestion = try decode(SuggestionItem.self, from: json)

        XCTAssertNil(suggestion.itemId)
        let match = try XCTUnwrap(suggestion.match)
        XCTAssertEqual(match.itemId, 42)
        XCTAssertEqual(match.name, "Hex Nut M3")
        XCTAssertEqual(match.score, 0.87, accuracy: 1e-10)
        XCTAssertEqual(match.bins, ["B-10", "B-42"])
    }

    func testSuggestionItemWithNullMatchDecodes() throws {
        let json = """
        {
            "item_id": null,
            "name": "unknown widget",
            "category": null,
            "confidence": 0.3,
            "bins": [],
            "match": null
        }
        """
        let suggestion = try decode(SuggestionItem.self, from: json)

        XCTAssertNil(suggestion.match)
    }

    // MARK: - New model structs decoding

    func testListModelsResponseDecodes() throws {
        let json = """
        {
            "version": "1",
            "active_model": "qwen3-vl:4b",
            "models": [
                {"name": "qwen3-vl:4b", "size": 3295636135, "modified_at": "2025-06-01T10:00:00Z"},
                {"name": "llava:7b", "size": null, "modified_at": null}
            ]
        }
        """
        let response = try decode(ListModelsResponse.self, from: json)

        XCTAssertEqual(response.activeModel, "qwen3-vl:4b")
        XCTAssertEqual(response.models.count, 2)
        XCTAssertEqual(response.models[0].name, "qwen3-vl:4b")
        XCTAssertEqual(response.models[0].size, 3295636135)
        XCTAssertNil(response.models[1].size)
    }

    func testSelectModelResponseDecodes() throws {
        let json = """
        {
            "version": "1",
            "previous_model": "llava:7b",
            "active_model": "qwen3-vl:4b"
        }
        """
        let response = try decode(SelectModelResponse.self, from: json)

        XCTAssertEqual(response.previousModel, "llava:7b")
        XCTAssertEqual(response.activeModel, "qwen3-vl:4b")
    }

    func testImageSizeResponseDecodes() throws {
        let json = """
        {"version": "1", "max_image_px": 1280}
        """
        let response = try decode(ImageSizeResponse.self, from: json)

        XCTAssertEqual(response.maxImagePx, 1280)
    }

    func testSetImageSizeResponseDecodes() throws {
        let json = """
        {"version": "1", "previous_max_image_px": 1280, "max_image_px": 800}
        """
        let response = try decode(SetImageSizeResponse.self, from: json)

        XCTAssertEqual(response.previousMaxImagePx, 1280)
        XCTAssertEqual(response.maxImagePx, 800)
    }

    // MARK: - ConfirmClassResponse decoding

    func testConfirmClassResponseDecodesAllFields() throws {
        let json = """
        {
            "version": "1",
            "class_name": "scissors",
            "added": true,
            "active_class_count": 47,
            "reload_triggered": true
        }
        """
        let response = try decode(ConfirmClassResponse.self, from: json)

        XCTAssertEqual(response.version, "1")
        XCTAssertEqual(response.className, "scissors")
        XCTAssertTrue(response.added)
        XCTAssertEqual(response.activeClassCount, 47)
        XCTAssertTrue(response.reloadTriggered)
    }

    func testConfirmClassResponseDecodesWhenNotAdded() throws {
        let json = """
        {
            "version": "1",
            "class_name": "scissors",
            "added": false,
            "active_class_count": 47,
            "reload_triggered": false
        }
        """
        let response = try decode(ConfirmClassResponse.self, from: json)

        XCTAssertFalse(response.added)
        XCTAssertFalse(response.reloadTriggered)
    }
}
