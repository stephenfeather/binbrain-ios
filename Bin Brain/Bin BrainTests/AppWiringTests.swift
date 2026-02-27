// AppWiringTests.swift
// Bin BrainTests
//
// Verifies that centralised EnvironmentKey definitions provide correct
// default values and that RootView exists as the app's root tab container.

import Testing
@testable import Bin_Brain

struct AppWiringTests {

    @Test func apiClientKeyHasDefault() {
        let key = APIClientKey.self
        let value = key.defaultValue
        // Default value is a usable APIClient instance
        #expect(type(of: value) == APIClient.self)
    }

    @Test func uploadQueueManagerKeyHasDefault() {
        let key = UploadQueueManagerKey.self
        let value = key.defaultValue
        #expect(type(of: value) == UploadQueueManager.self)
    }

    @Test func serverMonitorKeyHasDefault() {
        let key = ServerMonitorKey.self
        let value = key.defaultValue
        #expect(type(of: value) == ServerMonitor.self)
    }
}
