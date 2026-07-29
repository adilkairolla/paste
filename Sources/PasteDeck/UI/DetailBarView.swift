import PasteDeckCore
import SwiftUI

/// Everything known about the selected clipping, plus the keys that act on it.
///
/// Sits in the panel's two bottom corners, so its content keeps a full
/// ``Theme/panelPadding`` from every edge rather than crowding the curve.
struct DetailBarView: View {
    @ObservedObject var model: DeckModel

    /// Auto-paste is on but macOS won't let us press ⌘V — worth the whole
    /// right-hand side, because until it's fixed Enter looks like it does
    /// nothing at all.
    private var needsAccessibility: Bool {
        !model.isAccessibilityTrusted && model.preferences.pasteAutomatically
    }

    var body: some View {
        HStack(spacing: Theme.space3) {
            if let item = model.selectedItem {
                details(for: item)
            } else {
                Text("\(model.items.count) clippings")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Theme.space2)

            if needsAccessibility {
                accessibilityNotice
            } else {
                shortcutHints
            }
        }
        .padding(.horizontal, Theme.panelPadding)
        .frame(height: Theme.detailHeight)
    }

    private func details(for item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.half) {
            HStack(spacing: Theme.space15) {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent(for: item.kind))
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                ForEach(model.categories(for: item)) { category in
                    HStack(spacing: Theme.half) {
                        Image(systemName: category.symbolName)
                            .font(.system(size: 8))
                        Text(category.name)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .padding(.horizontal, Theme.pillPadding(Theme.badgeHeight))
                    .frame(height: Theme.badgeHeight)
                    .background(Capsule().fill(Theme.color(named: category.colorName).opacity(0.22)))
                    .foregroundStyle(Theme.color(named: category.colorName))
                }
            }

            Text(metadataLine(for: item))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func metadataLine(for item: ClipItem) -> String {
        var parts: [String] = []
        if !item.sourceAppName.isEmpty { parts.append("from \(item.sourceAppName)") }
        parts.append(Theme.fullTimestamp(item.updatedAt))
        parts.append(ByteFormat.string(item.byteSize))
        parts.append(contentsOf: item.metadata.displayPairs().map { "\($0.0): \($0.1)" })
        if item.useCount > 0 {
            parts.append("pasted \(item.useCount)×")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var accessibilityNotice: some View {
        Button {
            model.requestAccessibility()
        } label: {
            HStack(spacing: Theme.space1) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text("Enter can't paste — grant Accessibility")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, Theme.pillPadding(Theme.chipHeight))
            .frame(height: Theme.chipHeight)
            .background(Capsule().fill(Color.orange.opacity(0.2)))
            .overlay(Capsule().strokeBorder(Color.orange.opacity(0.5)))
            .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help("PasteDeck can copy without this, but pressing ⌘V for you needs Accessibility access. Click to open System Settings.")
    }

    private var shortcutHints: some View {
        HStack(spacing: Theme.space2) {
            hint("↩", "paste")
            hint("⇥", "next")
            hint("↑↓", zoneHint)
            hint("space", "preview")
            hint("⌘P", "pin")
            hint("⌘⌫", "delete")
        }
        .fixedSize()
    }

    /// Names the zone ↑↓ would move to, so the hint stays true as focus changes.
    private var zoneHint: String {
        switch model.focusZone {
        case .search: return "categories"
        case .categories: return "search / items"
        case .items: return "categories"
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: Theme.space1) {
            KeyCap(text: key)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}
