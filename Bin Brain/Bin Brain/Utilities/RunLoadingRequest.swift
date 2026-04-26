// RunLoadingRequest.swift
// Bin Brain
//
// Free-function helper that centralises the isLoading / error / onSuccess
// cycle shared across the app's ViewModels and Views.

import Foundation

// MARK: - runLoadingRequest

/// Runs an async throwing request, toggling an `isLoading` flag and routing
/// the outcome to caller-supplied setters.
///
/// Centralises the four-line
/// `isLoading = true; error = nil; do { … } catch { … }; isLoading = false`
/// cycle used across the app's `@Observable` ViewModels and SwiftUI Views.
/// A free function is used rather than a protocol default or base-class method
/// so that it can serve both `@Observable` classes and SwiftUI `View` structs
/// without a shared inheritance hierarchy.
///
/// - Parameters:
///   - setLoading: Called with `true` before the request and `false` after,
///                 regardless of success or failure.
///   - setError:   Called with `nil` before the request starts; called with
///                 the localised failure description if `work` throws.
///   - onSuccess:  Called with the successful return value of `work`.
///   - work:       The async throwing operation to execute.
@MainActor
func runLoadingRequest<T>(
    setLoading: (Bool) -> Void,
    setError: (String?) -> Void,
    onSuccess: (T) -> Void,
    work: () async throws -> T
) async {
    setLoading(true)
    setError(nil)
    do {
        let value = try await work()
        onSuccess(value)
    } catch {
        setError(error.localizedDescription)
    }
    setLoading(false)
}
