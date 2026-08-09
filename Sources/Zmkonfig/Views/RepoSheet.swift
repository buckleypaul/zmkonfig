import SwiftUI
import ZmkonfigKit

struct RepoSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @Bindable var model: AppModel
    @State private var slug = ""

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metric(.spacingM)) {
            SheetTitle("Open repository")

            Caption("A GitHub owner/name slug. It is cloned on first use and reused after that.")
                .fixedSize(horizontal: false, vertical: true)

            TextField("owner/name", text: $slug)
                .textFieldStyle(.roundedBorder)
                .font(theme.font(.mono))
                .onSubmit(open)

            if let repo = model.repo {
                Caption("Currently open: \(repo.localURL.path)", tone: .tertiaryText)
                    .lineLimit(2)
                    .truncationMode(.head)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") { open() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!RepoManager.isValidSlug(slug.trimmingCharacters(in: .whitespaces)))
            }
        }
        .padding(theme.metric(.spacingL))
        .frame(width: theme.metric(.dialogWidth))
        .background(theme.color(.panelBackground))
        .onAppear { slug = model.repo?.slug ?? "" }
    }

    private func open() {
        let target = slug.trimmingCharacters(in: .whitespaces)
        guard RepoManager.isValidSlug(target) else { return }
        dismiss()
        Task { await model.openRepo(slug: target) }
    }
}

struct CatalogSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @Bindable var model: AppModel
    @State private var query = ""

    var body: some View {
        // Filtering the whole catalog is not free, and the list and the count
        // below it must agree about what it found.
        let matches = self.matches
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: theme.metric(.spacingS)) {
                SheetTitle("Keyboard")
                TextField("Search the keyboard catalog", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(theme.metric(.spacingM))

            Divider()

            if model.isLoadingCatalog {
                VStack {
                    ProgressView()
                    Caption("Loading catalog…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.catalog.isEmpty {
                Hint(text: "The catalog is empty. Check your network connection and try again.")
            } else {
                List(matches) { entry in
                    Button {
                        dismiss()
                        Task { await model.chooseKeyboard(id: entry.id) }
                    } label: {
                        HStack {
                            Text(entry.name)
                                .font(theme.font(.body))
                                .foregroundStyle(theme.color(.primaryText))
                            Spacer()
                            Text(entry.id)
                                .font(theme.font(.monoSmall))
                                .foregroundStyle(theme.color(.tertiaryText))
                            if entry.id == model.keyboard?.id {
                                Image(systemName: "checkmark")
                                    .font(theme.font(.caption))
                                    .foregroundStyle(theme.color(.accent))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Caption("\(matches.count) keyboards", tone: .tertiaryText)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(theme.metric(.spacingM))
        }
        .frame(width: theme.metric(.sheetWidthMedium), height: theme.metric(.sheetHeightSmall))
        .background(theme.color(.panelBackground))
        .task { await model.loadCatalog() }
    }

    private var matches: [CatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return model.catalog }
        return model.catalog.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.id.localizedCaseInsensitiveContains(needle)
        }
    }
}
