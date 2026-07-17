// ABOUTME: Shared helpers for HTTP endpoint tests in RemindersServerTests.
// ABOUTME: Builds an in-memory app over FakeEventStoreBackend; no TCC involved.

import Foundation
import Hummingbird
import HummingbirdTesting
import RemindersCore
import RemindersTestSupport
@testable import RemindersServer

/// Bearer token used by every endpoint test.
let testToken = "test-token"

/// Headers carrying the valid bearer token.
let authHeaders: HTTPFields = [.authorization: "Bearer test-token"]

/// A fake backend plus a store reading from it.
func makeTestStore() -> (backend: FakeEventStoreBackend, store: RemindersStore) {
    let backend = FakeEventStoreBackend()
    return (backend, RemindersStore(backend: backend))
}

/// Builds the app under test with request logging silenced.
func makeTestApp(store: RemindersStore) -> some ApplicationProtocol {
    Application(router: buildRouter(store: store, token: testToken, log: { _ in }))
}

/// Decodes a JSON response body using the server's date convention.
func decodeBody<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(String(buffer: response.body).utf8))
}
