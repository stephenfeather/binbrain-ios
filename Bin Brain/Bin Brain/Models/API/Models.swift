// Models.swift
// Bin Brain
//
// DTOs for the /models endpoints.

import Foundation

// MARK: - Models

/// An Ollama model available on the server.
struct OllamaModel: Decodable {
    let name: String
    let size: Int?
    let modifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case modifiedAt = "modified_at"
    }
}

/// The response returned by `GET /models`.
struct ListModelsResponse: Decodable {
    let version: String
    let activeModel: String
    let visionProvider: String?
    let models: [OllamaModel]

    enum CodingKeys: String, CodingKey {
        case version
        case activeModel = "active_model"
        case visionProvider = "vision_provider"
        case models
    }
}

/// An Ollama model currently loaded in memory.
struct RunningModel: Decodable {
    let name: String
    let size: Int?
    let sizeVram: Int?
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case sizeVram = "size_vram"
        case expiresAt = "expires_at"
    }
}

/// The response returned by `GET /models/running`.
struct RunningModelsResponse: Decodable {
    let version: String
    let activeModel: String
    let models: [RunningModel]

    enum CodingKeys: String, CodingKey {
        case version
        case activeModel = "active_model"
        case models
    }
}

/// The response returned by `POST /models/select`.
struct SelectModelResponse: Decodable {
    let version: String
    let previousModel: String
    let activeModel: String

    enum CodingKeys: String, CodingKey {
        case version
        case previousModel = "previous_model"
        case activeModel = "active_model"
    }
}
