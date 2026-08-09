import Foundation
import Testing

@testable import ZmkonfigKit

/// The user's real 34-key Cradio keymap and its layout, as shipped test data.
enum Fixture {
    static func url(_ name: String, _ ext: String) throws -> URL {
        try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
            "missing fixture \(name).\(ext)"
        )
    }

    static func cradioSource() throws -> Data {
        try Data(contentsOf: url("cradio", "keymap"))
    }

    static func cradioText() throws -> String {
        String(decoding: try cradioSource(), as: UTF8.self)
    }

    static func cradioLayout() throws -> [KeyPosition] {
        let data = try Data(contentsOf: url("cradio-layout", "json"))
        let definition = try JSONDecoder().decode(KeyboardDefinition.self, from: data)
        return try #require(definition.defaultLayout).layout
    }

    /// The fixture parsed for editing. The single place that says how a keymap
    /// is opened, so a second fixture is one change rather than thirty.
    static func cradio() throws -> KeymapFile {
        try KeymapFile(source: try cradioSource())
    }

    static func cradioDocument() throws -> DTDocument {
        try DTDocument(source: try cradioSource())
    }

    /// Serializes against the fixture's own layout and decodes the result.
    static func write(_ keymap: KeymapFile) throws -> String {
        String(decoding: try keymap.serialized(layout: try cradioLayout()), as: UTF8.self)
    }

    static func combo(_ keymap: KeymapFile, named name: String) throws -> KeymapCombo {
        try #require(keymap.combos.first { $0.nodeName == name }, "no combo named \(name)")
    }

    /// The lines of a named layer's rendered bindings block, without the framing.
    static func bindingLines(of layer: String, in text: String) throws -> [String] {
        let header = "        \(layer) {\n            bindings = <\n"
        let start = try #require(text.range(of: header), "no \(layer) bindings block")
        let end = try #require(
            text.range(of: "\n            >;", range: start.upperBound..<text.endIndex)
        )
        return String(text[start.upperBound..<end.lowerBound]).components(separatedBy: "\n")
    }

    static func differingLines(_ before: String, _ after: String) -> [(String, String)] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        guard old.count == new.count else { return [("<line count changed>", "")] }
        return zip(old, new).filter { $0 != $1 }.map { ($0, $1) }
    }
}
