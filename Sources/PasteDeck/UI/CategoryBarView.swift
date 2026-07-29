import PasteDeckCore
import SwiftUI

/// Smart filters followed by the user's own categories, plus a "+" to add one.
///
/// Focus is shown the same way the card strip shows it: the *selected* chip
/// brightens and takes a full-strength ring when the arrows are steering this
/// row, and fades back to a quiet tint when they move elsewhere. A rule under
/// the whole bar would say "somewhere in here" — this says exactly where.
struct CategoryBarView: View {
    @ObservedObject var model: DeckModel
    @FocusState.Binding var categoryFieldFocused: Bool

    private var isFocusedZone: Bool { model.focusZone == .categories }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.chipGap) {
                ForEach(model.tabs) { tab in
                    tabChip(tab)
                }

                if model.isCreatingCategory {
                    newCategoryField
                } else {
                    addButton
                }
            }
            .frame(height: Theme.chipHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Theme.chipHeight)
    }

    private func tabChip(_ tab: FilterTab) -> some View {
        let isSelected = tab.id == model.selectedTabID
        let tint = Theme.color(named: tab.colorName)
        let isSteering = isSelected && isFocusedZone

        return Button {
            model.selectedTabID = tab.id
            model.focusZone = .categories
            model.preferences.lastFilterID = tab.id
        } label: {
            HStack(spacing: Theme.space1) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.pillPadding(Theme.chipHeight))
            .frame(height: Theme.chipHeight)
            .background(
                Capsule().fill(
                    isSelected
                        ? tint.opacity(isSteering ? 0.3 : 0.16)
                        : Color.primary.opacity(0.06)
                )
            )
            // Tint says which filter this is; the accent ring says the arrows
            // are on it right now. Same split the card strip uses, so one
            // colour means "focus" everywhere in the deck — a grey-tinted tab
            // like All would otherwise get a ring nobody can see.
            .overlay(
                Capsule().strokeBorder(
                    isSteering ? Color.accentColor : (isSelected ? tint.opacity(0.35) : .clear),
                    lineWidth: isSteering ? Theme.focusRing : 1
                )
            )
            .foregroundStyle(isSelected ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if tab.isUserCategory, let id = tab.categoryID,
               let category = model.categories.first(where: { $0.id == id }) {
                Button("Add Selected Clipping") {
                    if let item = model.selectedItem { model.toggleCategory(category, for: item) }
                }
                Divider()
                Button("Delete “\(category.name)”", role: .destructive) {
                    model.deleteCategory(category)
                }
            }
        }
    }

    private var addButton: some View {
        Button {
            model.isCreatingCategory = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: Theme.chipHeight, height: Theme.chipHeight)
                .background(Circle().fill(Color.primary.opacity(0.07)))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("New category (⌘N)")
    }

    private var newCategoryField: some View {
        HStack(spacing: Theme.space1) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            TextField("Category name", text: $model.newCategoryName)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .frame(width: 110)
                .focused($categoryFieldFocused)
                .onSubmit {
                    // Enter files the selected clipping straight into the new list.
                    model.createCategory(named: model.newCategoryName, addingSelected: true)
                }
                .onAppear { categoryFieldFocused = true }
        }
        .padding(.horizontal, Theme.pillPadding(Theme.chipHeight))
        .frame(height: Theme.chipHeight)
        .background(Capsule().fill(Color.primary.opacity(0.09)))
        .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: Theme.focusRing))
    }
}
