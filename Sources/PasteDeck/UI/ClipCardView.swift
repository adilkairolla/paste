import AppKit
import PasteDeckCore
import SwiftUI

/// One clipping in the deck.
///
/// Header, body and footer all sit ``Theme/cardPadding`` in from the card edge
/// on every side, which is what sets the card's own ``Theme/radiusCard`` and
/// the ``Theme/radiusTile`` of anything drawn inside it. Header and footer are
/// fixed heights so a card showing a ⌘-number and a card showing a byte count
/// give their bodies exactly the same room.
///
/// Clicking a card pastes it — selection is what the keyboard does, activation
/// is what the mouse does.
struct ClipCardView: View {
    @ObservedObject var model: DeckModel
    let item: ClipItem
    let isSelected: Bool
    /// 1-9 get a ⌘N shortcut badge.
    let position: Int

    @State private var isHovering = false

    private var isSteering: Bool { isSelected && model.focusZone == .items }

    /// 1-based position in the stack, when this card is in it.
    private var stackPosition: Int? { model.stackPosition(of: item) }

    /// Two independent things need showing at once — where the cursor is, and
    /// what's been gathered — so they get separate channels. The ring is only
    /// ever about selection; being stacked shows as fill plus a numbered badge.
    /// Sharing the ring made a selected, stacked card indistinguishable from a
    /// stacked one the cursor had already left.
    private var ringColor: Color {
        if isSelected {
            // Dim the selection ring while the arrows are steering another
            // zone, so there's never a question about what the keys will move.
            return isSteering ? Color.accentColor : Color.accentColor.opacity(0.4)
        }
        return stackPosition == nil ? Color.primary.opacity(0.08) : Color.indigo.opacity(0.5)
    }

    private var ringWidth: CGFloat { isSelected ? Theme.focusRing : 1 }

    private var fillColor: Color {
        if stackPosition != nil { return Color.indigo.opacity(isSelected ? 0.28 : 0.18) }
        return Color.primary.opacity(isSelected ? 0.12 : (isHovering ? 0.085 : 0.055))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Theme.cardPadding)
                .frame(height: Theme.cardHeaderHeight)

            content
                .padding(.horizontal, Theme.cardPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
                .padding(.horizontal, Theme.cardPadding)
                .frame(height: Theme.cardFooterHeight)
                .background(Color.primary.opacity(0.04))
                .clipShape(
                    .rect(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: Theme.radiusCard,
                        bottomTrailingRadius: Theme.radiusCard,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
        }
        .frame(width: Theme.cardWidth, height: Theme.cardHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(ringColor, lineWidth: ringWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture {
            model.selectedItemID = item.id
            model.focusZone = .items
            model.paste(item)
        }
        .contextMenu { contextMenu }
        .help(item.title)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.space1) {
            if let icon = model.icon(for: item) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: Theme.small))
                    .foregroundStyle(.tertiary)
            }

            Text(item.sourceAppName.isEmpty ? "Unknown" : item.sourceAppName)
                .font(.system(size: Theme.body, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.secondary)

            Spacer(minLength: Theme.half)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: Theme.caption))
                    .foregroundStyle(.orange)
            }

            Text(Theme.shortRelative(item.updatedAt))
                .font(.system(size: Theme.small))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            imageContent
        case .color:
            colorContent
        case .file:
            fileContent
        case .link:
            linkContent
        case .code:
            textContent(font: .system(size: Theme.body, design: .monospaced), lines: Theme.cardBodyLines)
        case .prompt:
            promptContent
        default:
            textContent(font: .system(size: Theme.body), lines: Theme.cardBodyLines)
        }
    }

    /// Slots are drawn in the prompt accent so a template reads as a form to
    /// fill in rather than text with stray punctuation.
    private var promptContent: some View {
        PromptTemplate(body: item.preview)
            .segments
            .reduce(Text(verbatim: "")) { partial, segment in
                switch segment {
                case .literal(let text):
                    return partial + Text(verbatim: text)
                case .slot(let name):
                    return partial + Text(verbatim: "{{\(name)}}")
                        .foregroundColor(.indigo)
                        .fontWeight(.semibold)
                }
            }
            .font(.system(size: Theme.body))
            .lineLimit(Theme.cardBodyLines)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var imageContent: some View {
        // Color.clear takes exactly the space the body offers; the overlay fills
        // it and gets clipped. Sizing the Image directly would let a tall
        // thumbnail overflow the card and paint over the header and footer.
        Color.clear
            .overlay {
                if let thumbnail = model.thumbnail(for: item) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: Theme.display))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous))
    }

    private var colorContent: some View {
        HStack(spacing: Theme.cardPadding) {
            // Square, not stretched: a swatch is a sample of a colour, and a
            // tall bar of it reads as a divider. 44 exactly fills the body of a
            // short card, so this only changes anything on a taller one.
            RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                .fill(Theme.swatch(fromHex: item.metadata.colorHex ?? "") ?? .gray)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15))
                )
                .frame(width: 44, height: 44)
            Text((item.metadata.colorHex ?? item.title).uppercased())
                .font(.system(size: Theme.large, weight: .semibold, design: .monospaced))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, Theme.space1)
    }

    private var fileContent: some View {
        VStack(alignment: .leading, spacing: Theme.half) {
            ForEach(Array((item.metadata.filePaths ?? []).prefix(2).enumerated()), id: \.offset) { _, path in
                HStack(spacing: Theme.space1) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 13, height: 13)
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: Theme.body))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if (item.metadata.fileCount ?? 0) > 2 {
                Text("+\((item.metadata.fileCount ?? 0) - 2) more")
                    .font(.system(size: Theme.small))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var linkContent: some View {
        VStack(alignment: .leading, spacing: Theme.half) {
            Text(item.metadata.host ?? "Link")
                .font(.system(size: Theme.body, weight: .semibold))
                .lineLimit(1)
            Text(item.metadata.url ?? item.preview)
                .font(.system(size: Theme.small))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func textContent(font: Font, lines: Int) -> some View {
        Text(item.preview.isEmpty ? item.title : item.preview)
            .font(font)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.space1) {
            if let stackPosition {
                stackBadge(stackPosition)
            }

            Image(systemName: item.kind.symbolName)
                .font(.system(size: Theme.caption, weight: .semibold))
            Text(footerLabel)
                .font(.system(size: Theme.small, weight: .medium))

            Spacer(minLength: Theme.half)

            if let category = model.categories(for: item).first {
                Image(systemName: "folder.fill")
                    .font(.system(size: Theme.caption))
                    .foregroundStyle(Theme.color(named: category.colorName))
            }

            if position <= 9 {
                KeyCap(text: "⌘\(position)")
            } else {
                Text(ByteFormat.string(item.byteSize))
                    .font(.system(size: Theme.small))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(Theme.accent(for: item.kind))
    }

    /// A prompt's slot count is more use than the word "Prompt" repeated on
    /// every card in the tab.
    private var footerLabel: String {
        guard item.kind == .prompt else { return item.kind.displayName }
        let count = item.metadata.promptVariables?.count ?? 0
        switch count {
        case 0: return "No slots"
        case 1: return "1 slot"
        default: return "\(count) slots"
        }
    }

    /// The card's place in the composed paste — the same number the detail bar
    /// counts up to.
    private func stackBadge(_ number: Int) -> some View {
        Text("\(number)")
            .font(.system(size: Theme.caption, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 13, height: 13)
            .background(Circle().fill(Color.indigo))
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        Button("Paste") { model.paste(item) }
        Button("Copy") {
            model.selectedItemID = item.id
            model.copySelected()
        }

        if item.kind.isStackable {
            Button(stackPosition == nil ? "Add to Stack" : "Remove from Stack") {
                model.toggleStack(item)
            }
        }

        Divider()
        if item.kind == .prompt {
            Button("Edit Prompt…") {
                model.dismiss(immediately: true)
                PromptEditorWindowController.shared.show(model: model, editing: item)
            }
        } else {
            Button("Save as Prompt") { model.savePromptFromItem(item) }
        }
        if item.kind != .text, item.kind != .prompt, model.pasteService.plainText(for: item) != nil {
            Button("Copy as Plain Text") {
                model.pasteService.copyPlainText(for: item)
                model.dismiss(immediately: true)
            }
        }
        Divider()
        // Prompts are already exempt from pruning, so pinning one would be a
        // switch that does nothing.
        if item.kind != .prompt {
            Button(item.isPinned ? "Unpin" : "Pin") {
                model.selectedItemID = item.id
                model.togglePinSelected()
            }
        }
        if !model.categories.isEmpty {
            Menu("Categories") {
                ForEach(model.categories) { category in
                    Button {
                        model.toggleCategory(category, for: item)
                    } label: {
                        Label(
                            category.name,
                            systemImage: item.categoryIDs.contains(category.id) ? "checkmark" : category.symbolName
                        )
                    }
                }
            }
        }
        Button("New Category…") {
            model.selectedItemID = item.id
            model.isCreatingCategory = true
        }
        if item.kind == .link, let url = item.metadata.url.flatMap(URL.init(string:)) {
            Divider()
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .file, let path = item.metadata.filePaths?.first {
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Divider()
        Button("Delete") {
            model.selectedItemID = item.id
            model.deleteSelected()
        }
    }
}
