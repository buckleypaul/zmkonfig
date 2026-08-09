import Foundation

/// A single key binding, e.g. `&kp Q`, `&hml LEFT_GUI A`, `&kp LG(LS(SPACE))`.
///
/// Parameters keep their nested shape so the editor can offer a picker per
/// slot, but the round trip is text-first: `text` is what was read from the
/// file and what goes back into it unless the binding is explicitly edited.
public struct KeyBinding: Equatable, Sendable, Codable {
    /// The behavior reference including the ampersand, e.g. `&kp`.
    public var behavior: String
    /// Top-level parameters in source order.
    public var params: [BindingParam]

    public init(behavior: String, params: [BindingParam] = []) {
        self.behavior = behavior
        self.params = params
    }

    /// Canonical single-line rendering: `&behavior p1 p2`.
    public var text: String {
        params.isEmpty ? behavior : "\(behavior) \(params.map(\.text).joined(separator: " "))"
    }
}

/// A binding parameter, which may itself wrap parameters: `LG(LS(SPACE))`.
public struct BindingParam: Equatable, Sendable, Codable {
    public var value: String
    public var params: [BindingParam]

    public init(value: String, params: [BindingParam] = []) {
        self.value = value
        self.params = params
    }

    public var text: String {
        params.isEmpty ? value : "\(value)(\(params.map(\.text).joined(separator: ",")))"
    }
}
