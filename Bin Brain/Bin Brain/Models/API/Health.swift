// Health.swift
// Bin Brain
//
// DTOs for the /health endpoint.

import Foundation

// MARK: - Health

/// The response returned by `GET /health`.
struct HealthResponse: Decodable {
    let version: String
    let ok: Bool
    let dbOk: Bool
    let embedModel: String
    let expectedDims: Int
    /// Authentication status reported by the server.
    ///
    /// - `true`: request carried a valid `X-API-Key` header.
    /// - `false`: request carried an `X-API-Key` header that the server rejected.
    /// - `nil`: no `X-API-Key` header was sent.
    let authOk: Bool?
    /// The role associated with the API key when `authOk == true`.
    let role: Role?

    /// The role granted to an authenticated API key.
    ///
    /// Present only when `authOk == true`. Matches the server-side role enum.
    enum Role: String, Decodable, Equatable {
        case user
        case admin
    }

    enum CodingKeys: String, CodingKey {
        case version
        case ok
        case dbOk = "db_ok"
        case embedModel = "embed_model"
        case expectedDims = "expected_dims"
        case authOk = "auth_ok"
        case role
    }
}
