// Errors.swift
// Bin Brain
//
// API error DTO decoded from the server's ErrorResponse envelope.

import Foundation

// MARK: - Errors

/// An API error decoded from the server's `ErrorResponse` envelope.
///
/// Conforms to `LocalizedError` so it can be surfaced directly in UI error messages.
struct APIError: Decodable, LocalizedError {
    let version: String
    let error: ErrorDetail

    /// The detail payload nested inside an `APIError` response.
    struct ErrorDetail: Decodable {
        let code: String
        let message: String
    }

    /// A human-readable description of the error, suitable for display to the user.
    var errorDescription: String? { error.message }
}
