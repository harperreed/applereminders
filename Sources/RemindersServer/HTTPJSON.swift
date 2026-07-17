// ABOUTME: JSON response helpers for the HTTP surface.
// ABOUTME: Encodes payloads and {"error": message} bodies with ISO-8601 dates.

import Foundation
import Hummingbird
import NIOCore

/// The error body shape for REST 400/404/500 responses (spec error mapping).
struct ErrorBody: Encodable {
    let error: String
}

/// Encodes `value` as JSON (ISO-8601 dates, sorted keys, matching the MCP
/// payload conventions) and wraps it in an HTTP response.
func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
        throw RESTError(status: .internalServerError, message: "Failed to encode response")
    }
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: .init(byteBuffer: ByteBuffer(string: json))
    )
}

/// Builds the {"error": message} response for a failed REST request.
func errorResponse(status: HTTPResponse.Status, message: String) throws -> Response {
    try jsonResponse(ErrorBody(error: message), status: status)
}

/// Decodes a JSON request body, mapping decode failures onto REST 400s.
/// Collects the body and decodes with plain Foundation so validation errors
/// thrown by DTO initializers (as RESTError) pass through intact.
func decodeJSONBody<T: Decodable>(
    _ type: T.Type,
    from request: Request,
    context: some RequestContext
) async throws -> T {
    let buffer = try await request.body.collect(upTo: context.maxUploadSize)
    do {
        return try JSONDecoder().decode(T.self, from: Data(buffer.readableBytesView))
    } catch let error as RESTError {
        throw error
    } catch DecodingError.keyNotFound(let key, _) {
        throw RESTError(status: .badRequest, message: "Missing required field \"\(key.stringValue)\"")
    } catch {
        throw RESTError(status: .badRequest, message: "Request body is not valid JSON for this endpoint")
    }
}
