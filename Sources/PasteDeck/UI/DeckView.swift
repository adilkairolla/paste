import AppKit
import PasteDeckCore
import SwiftUI

/// The whole deck: search, categories, card strip, meta bar.
///
/// The vertical rhythm is arithmetic, not luck — see ``Theme/deckHeight``. Each
/// section owns a fixed height and the panel is exactly their sum, so the
/// hosting window can never crop a row or leave a dead strip at the bottom.
struct DeckView: View {
    @ObservedObject var model: DeckModel
    @FocusState private var searchFocused: Bool
    @FocusState private var categoryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header                                   // 72
            deck                                     // 120
            Hairline()                               // 1
            DetailBarView(model: model)              // 52
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
        // The large preview is a window of its own — see PreviewWindowController.
        .overlay { promptSheet }
        .overlay(alignment: .top) { toast }
        .onChange(of: model.focusRequest) { searchFocused = true }
        .onAppear { searchFocused = true }
    }

    // MARK: Header — search on top, categories beneath it

    /// One padded block, so the two rows share a left edge with each other and
    /// with the first card below them.
    private var header: some View {
        VStack(spacing: Theme.rowGap) {
            searchRow
            CategoryBarView(model: model, categoryFieldFocused: $categoryFieldFocused)
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.top, Theme.panelPadding)
    }

    private var searchRow: some View {
        HStack(spacing: Theme.space2) {
            searchField
            Spacer(minLength: 0)
            Text(countSummary)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(height: Theme.searchHeight)
    }

    /// Exactly one card wide, so its left and right edges line up with the
    /// first card in the strip below.
    private var searchField: some View {
        HStack(spacing: Theme.space15) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search history", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .frame(maxWidth: .infinity)
                .onSubmit { model.pasteSelected() }

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.pillPadding(Theme.searchHeight))
        .frame(width: Theme.cardWidth, height: Theme.searchHeight)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(
            Capsule().strokeBorder(
                model.focusZone == .search ? Color.accentColor : Color.clear,
                lineWidth: Theme.focusRing
            )
        )
        .contentShape(Capsule())
        .onTapGesture { model.focusZone = .search }
    }

    private var countSummary: String {
        let count = model.items.count
        let noun = count == 1 ? "clipping" : "clippings"
        if !model.searchText.isEmpty { return "\(count) \(noun) matching" }
        return model.selectedTab.filter == .all
            ? "\(count) \(noun)"
            : "\(count) \(noun) in \(model.selectedTab.title)"
    }

    // MARK: Card strip

    private var deck: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.cardGap) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        ClipCardView(
                            model: model,
                            item: item,
                            isSelected: item.id == model.selectedItemID,
                            position: index + 1
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, Theme.panelPadding)
                .frame(height: Theme.cardHeight)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Theme.cardHeight)
            .padding(.vertical, Theme.sectionGap)
            .overlay { if model.items.isEmpty { emptyState } }
            .onChange(of: model.selectedItemID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.space1) {
            Image(systemName: model.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(emptySubtitle)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No matches for “\(model.searchText)”" }
        switch model.selectedTab.filter {
        case .all: return "Nothing copied yet"
        case .pinned: return "No pinned clippings"
        case .category: return "This category is empty"
        case .prompts: return "No prompts yet"
        case .kinds: return "No \(model.selectedTab.title.lowercased()) yet"
        }
    }

    private var emptySubtitle: String {
        if !model.searchText.isEmpty { return "Try a shorter search term" }
        switch model.selectedTab.filter {
        case .all: return "Copy something and it will show up here"
        case .pinned: return "Select a clipping and press ⌘P to keep it forever"
        case .category: return "Right-click a clipping to file it here"
        case .prompts: return "Press ⌘⇧N to write one, or ⌘E to reuse a clipping"
        case .kinds: return "Copy something of this type to see it here"
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var promptSheet: some View {
        if let fill = model.promptFill {
            PromptFillView(model: model, fill: fill)
                // Keyed by item so switching prompts rebuilds the fields rather
                // than leaving the previous prompt's focus behind.
                .id(fill.item.id)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.toast {
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, Theme.pillPadding(Theme.searchHeight))
                .frame(height: Theme.searchHeight)
                .background(Capsule().fill(.thickMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .padding(.top, Theme.headerHeight + Theme.space2)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
