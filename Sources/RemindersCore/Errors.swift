// ABOUTME: Error types for the RemindersCore library.
// ABOUTME: Provides descriptive, actionable error messages for all EventKit failure modes.

import Foundation

/// Errors that can occur when interacting with the Reminders store.
public enum RemindersError: LocalizedError, Sendable, Equatable {
    /// The user denied access to Reminders, or access has not been granted.
    case accessDenied

    /// The app was granted write-only access, but full (read+write) access is required.
    case writeOnlyAccess

    /// No reminder list was found matching the given name.
    case listNotFound(String)

    /// No reminder was found matching the given identifier or index.
    case reminderNotFound(String)

    /// A general operation failed with a descriptive reason.
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to Reminders was denied. "
                + "Please grant full access in System Settings > Privacy & Security > Reminders."

        case .writeOnlyAccess:
            return "Only write access to Reminders was granted, but full access is required. "
                + "Please update permissions in System Settings > Privacy & Security > Reminders."

        case .listNotFound(let name):
            return "No reminder list found with the name \"\(name)\". "
                + "Check your available lists and verify the spelling."

        case .reminderNotFound(let identifier):
            return "No reminder found matching \"\(identifier)\". "
                + "The reminder may have been deleted or the identifier may be incorrect."

        case .operationFailed(let reason):
            return "Reminders operation failed: \(reason)"
        }
    }
}
