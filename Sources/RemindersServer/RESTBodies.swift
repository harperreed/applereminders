// ABOUTME: Request body DTOs for the REST write endpoints.
// ABOUTME: due_date stays a CLI-format string until parsed; PATCH keeps null-vs-absent distinct.

import Foundation
import RemindersCore

/// Body of POST /api/reminders.
struct CreateReminderRequest: Decodable {
    let list: String
    let title: String
    let notes: String?
    let dueDate: String?
    let priority: String?

    private enum CodingKeys: String, CodingKey {
        case list, title, notes, priority
        case dueDate = "due_date"
    }
}

/// Body of PATCH /api/reminders/{id}. `dueDate` is double-optional:
/// key absent = leave untouched, JSON null = clear, string = parse and set.
struct PatchReminderBody: Decodable {
    let title: String?
    let notes: String?
    let priority: String?
    let list: String?
    let dueDate: String??

    private enum CodingKeys: String, CodingKey {
        case title, notes, priority, list
        case dueDate = "due_date"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes)
        self.priority = try container.decodeIfPresent(String.self, forKey: .priority)
        self.list = try container.decodeIfPresent(String.self, forKey: .list)
        if container.contains(.dueDate) {
            if try container.decodeNil(forKey: .dueDate) {
                self.dueDate = .some(nil)
            } else {
                self.dueDate = .some(try container.decode(String.self, forKey: .dueDate))
            }
        } else {
            self.dueDate = nil
        }
    }
}

/// Maps a REST priority string to the domain type; unknown values are a 400.
func parsePriority(_ string: String?) throws -> ReminderPriority? {
    guard let string else { return nil }
    guard let priority = ReminderPriority(rawValue: string) else {
        throw RESTError(
            status: .badRequest,
            message: "Invalid priority \"\(string)\". Must be one of: none, low, medium, high."
        )
    }
    return priority
}

/// Parses a REST due_date string in the CLI formats; garbage is a 400.
func parseDueDate(_ string: String) throws -> Date {
    guard let date = parseDate(string) else {
        throw RESTError(
            status: .badRequest,
            message: "Invalid due_date \"\(string)\". Supported formats: \(supportedDateFormats)."
        )
    }
    return date
}
