// FileProtectionTests.swift
// Bin BrainTests
//
// Smoke tests for `Bin_BrainApp.applyFileProtection(to:)`. File protection
// enforcement only kicks in on a locked physical device, and the iOS Simulator
// reports `.protectionKey` as `nil` for items set via `setAttributes(_:)`,
// so behavioral verification lives in manual/device QA. These tests verify
// the routine resolves a valid store URL and does not throw. Addresses #9.

import Foundation
import SwiftData
import Testing
@testable import Bin_Brain

struct FileProtectionTests {

    @Test @MainActor func storeURLResolvesToExistingFile() throws {
        let (container, _, cleanup) = try makeContainer()
        defer { cleanup() }

        guard let url = container.configurations.first?.url else {
            Issue.record("Model configuration has no URL")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test @MainActor func applyFileProtectionDoesNotThrow() throws {
        let (container, _, cleanup) = try makeContainer()
        defer { cleanup() }

        // Idempotent — two invocations should both succeed quietly even if
        // the simulator does not persist the protection attribute.
        Bin_BrainApp.applyFileProtection(to: container)
        Bin_BrainApp.applyFileProtection(to: container)
    }

    // MARK: - Helpers

    @MainActor
    private func makeContainer() throws -> (ModelContainer, URL, () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BinBrainFileProtectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("test.store")
        let schema = Schema([PendingUpload.self, PendingAnalysis.self])
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        _ = container.mainContext
        let cleanup: () -> Void = {
            _ = try? FileManager.default.removeItem(at: tempDir)
        }
        return (container, storeURL, cleanup)
    }
}
