import Foundation
import ZmkonfigKit

/// Finds ZmkonfigKit's resource bundle (the vendored ZMK metadata).
///
/// SwiftPM's own `Bundle.module` accessor only looks for it beside
/// `Bundle.main.bundleURL`. For a bare executable that is the build directory
/// and works fine, but inside a .app `bundleURL` is the bundle root — a place
/// `codesign` refuses to seal. `make bundle` therefore puts it in
/// `Contents/Resources`, and this looks in both places.
enum AppResources {
    static let bundleName = "Zmkonfig_ZmkonfigKit.bundle"

    static let kit: Bundle? = {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        for base in candidates.compactMap({ $0 }) {
            let url = base.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()

    static func loadBehaviors() throws -> [ZMKBehavior] {
        try ZMKMetadata.loadBehaviors(bundle: kit ?? ZMKMetadata.resourceBundle)
    }

    static func loadKeycodes() throws -> [ZMKKeycode] {
        try ZMKMetadata.loadKeycodes(bundle: kit ?? ZMKMetadata.resourceBundle)
    }
}
