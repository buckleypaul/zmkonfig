import Foundation

/// The safety rule for a string that becomes one path component — a directory
/// under the support directory, a cache filename, a URL path segment.
///
/// Shared so `owner/name` slugs and keyboard ids cannot drift apart: both need
/// exactly this, and both would be a traversal bug if they disagreed.
enum PathComponent {
    /// Rejects anything that could escape its parent directory or confuse a URL:
    /// empty, `.`, `..`, and any character outside ASCII letters, digits, `.`,
    /// `_` and `-` — which excludes `/` and every shell metacharacter.
    static func isSafe(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        return component.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
        }
    }
}
