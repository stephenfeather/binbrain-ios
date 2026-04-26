// SharedCoders.swift
// Bin Brain
//
// Shared JSONDecoder and JSONEncoder configured for Bin Brain API responses.

import Foundation

// MARK: - Shared Decoder

extension JSONDecoder {
    /// A shared decoder configured for Bin Brain API responses.
    ///
    /// Uses ISO 8601 date decoding to parse `last_updated` and other date fields.
    static let binBrain: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    /// A shared encoder configured for Bin Brain API request bodies.
    ///
    /// Uses ISO 8601 date encoding so `Date` fields (e.g. `shown_at` in
    /// `PhotoSuggestionOutcome`) land on the wire in the format FastAPI's
    /// Pydantic `datetime` validators accept without coercion.
    static let binBrain: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
