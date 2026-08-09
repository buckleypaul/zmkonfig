import Foundation

/// An error worth putting in front of the user, carrying the real message
/// rather than a generic one.
struct AppError: Identifiable {
    let id = UUID()
    var title: String
    var message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(title: String, error: any Error) {
        self.title = title
        self.message = AppError.describe(error)
    }

    /// `localizedDescription` on a plain Swift error produces
    /// "The operation couldn't be completed. (Module.Error error 0.)", which
    /// tells the user nothing. Prefer whatever the error actually says.
    static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        // Cocoa/POSIX/URL errors have a genuinely useful localized message;
        // everything else describes better as its own Swift value.
        let bridged = error as NSError
        switch bridged.domain {
        case NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain:
            return bridged.localizedDescription
        default:
            return String(describing: error)
        }
    }
}
