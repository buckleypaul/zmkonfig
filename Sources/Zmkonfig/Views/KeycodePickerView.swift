import SwiftUI
import ZmkonfigKit

/// Searchable keycode list, grouped the way ZMK groups them (Keyboard, Keypad,
/// Consumer, …). Anything not in the list can still be typed in.
struct KeycodePickerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let keycodes: [ZMKKeycode]
    let current: String
    let onPick: (String) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Filtering walks all 366 keycodes and their descriptions, and grouping
        // then buckets and sorts what survived. The list, the count in the
        // footer and the custom entry each need the result, so both are
        // computed once per body rather than repeated per keystroke.
        let matches = matches
        let groups = Self.groups(of: matches)
        VStack(spacing: 0) {
            header(groups)
            Divider()
            list(groups)
            Divider()
            footer(matchCount: matches.count)
        }
        .frame(width: theme.metric(.sheetWidthSmall), height: theme.metric(.sheetHeightSmall))
        .background(theme.color(.panelBackground))
    }

    private func header(_ groups: [KeycodeGroup]) -> some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
            HStack {
                SheetTitle("Keycode")
                Spacer()
                Text(current.isEmpty ? "unset" : current)
                    .font(theme.font(.monoSmall))
                    .foregroundStyle(theme.color(.secondaryText))
            }
            TextField("Search names and descriptions", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit { pickFirstMatch(in: groups) }
        }
        .padding(theme.metric(.spacingM))
        .onAppear { searchFocused = true }
    }

    private func list(_ groups: [KeycodeGroup]) -> some View {
        List {
            if let custom = customEntry {
                Section {
                    Button {
                        choose(custom)
                    } label: {
                        HStack {
                            Text(custom).font(theme.font(.mono))
                            Spacer()
                            Caption("use as typed")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } header: {
                    SectionLabel(text: "Custom")
                }
            }

            ForEach(groups, id: \.context) { group in
                Section {
                    ForEach(group.keycodes) { keycode in
                        row(keycode)
                    }
                } header: {
                    SectionLabel(text: group.context)
                }
            }
        }
        .listStyle(.inset)
    }

    private func row(_ keycode: ZMKKeycode) -> some View {
        Button {
            choose(keycode.primaryName)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: theme.metric(.spacingS)) {
                Text(keycode.primaryName)
                    .font(theme.font(.mono))
                    .foregroundStyle(theme.color(.primaryText))
                if keycode.names.count > 1 {
                    Caption(keycode.names.dropFirst().joined(separator: " "), tone: .tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: theme.metric(.spacingS))
                if let description = keycode.description {
                    Caption(description)
                        .lineLimit(1)
                        .frame(maxWidth: 170, alignment: .trailing)
                }
                // A keycode ZMK records as not working somewhere. The row says
                // only that there is something to know; the tooltip says what.
                if keycode.unsupportedSummary != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.color(.warning))
                }
                if keycode.primaryName == current {
                    Image(systemName: "checkmark")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.color(.accent))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The row truncates the description to one line to keep 366 of them
        // scannable; this is where the rest of it lives.
        .help(keycode.detail)
    }

    private func footer(matchCount: Int) -> some View {
        HStack {
            Caption("\(matchCount) of \(keycodes.count)", tone: .tertiaryText)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(theme.metric(.spacingM))
    }

    // MARK: - Filtering

    /// The same test the assistant's `find_keycodes` runs, so the picker and
    /// the tool agree on what a query matches — names, description *and*
    /// context. The query is folded once here rather than once per keycode:
    /// `ZMKKeycode.matches` takes it pre-folded because case-folding 366 names
    /// through ICU on every keystroke was most of the cost of typing in this
    /// sheet.
    private var matches: [ZMKKeycode] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return keycodes }
        return keycodes.filter { $0.matches(needle) }
    }

    typealias KeycodeGroup = (context: String, keycodes: [ZMKKeycode])

    private static func groups(of matches: [ZMKKeycode]) -> [KeycodeGroup] {
        let grouped = Dictionary(grouping: matches) { $0.context ?? "Other" }
        return grouped.keys.sorted(by: Self.contextPrecedes).map { key in
            (key, grouped[key]?.sorted { $0.primaryName < $1.primaryName } ?? [])
        }
    }

    /// An uppercase token the user typed that is not in the metadata — still a
    /// legal keycode as far as ZMK is concerned.
    private var customEntry: String? {
        let needle = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard !needle.isEmpty else { return nil }
        guard !keycodes.contains(where: { $0.names.contains(needle) }) else { return nil }
        return needle
    }

    private static let contextOrder = ["Keyboard", "Keypad", "Consumer", "Consumer Media"]

    private static func contextPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = contextOrder.firstIndex(of: lhs) ?? contextOrder.count
        let right = contextOrder.firstIndex(of: rhs) ?? contextOrder.count
        return left == right ? lhs < rhs : left < right
    }

    private func pickFirstMatch(in groups: [KeycodeGroup]) {
        if let first = groups.first?.keycodes.first {
            choose(first.primaryName)
        } else if let custom = customEntry {
            choose(custom)
        }
    }

    private func choose(_ value: String) {
        onPick(value)
        dismiss()
    }
}
