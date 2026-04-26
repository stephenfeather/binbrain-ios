// ConfirmClass.swift
// Bin Brain
//
// DTOs for the /classes/confirm endpoint.

import Foundation

// MARK: - Class Confirmation

/// The response returned by `POST /classes/confirm`.
struct ConfirmClassResponse: Decodable {
    let version: String
    let className: String
    let added: Bool
    let activeClassCount: Int
    let reloadTriggered: Bool

    enum CodingKeys: String, CodingKey {
        case version
        case className = "class_name"
        case added
        case activeClassCount = "active_class_count"
        case reloadTriggered = "reload_triggered"
    }
}
