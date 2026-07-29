import AppKit
import PasteDeckCore
import SwiftUI

/// The Space-bar look: the selected clipping as a page, with the rest of its
/// metadata spelled out underneath.
///
/// Shaped tall and narrow because the job is reading. It fills its own window
/// (see ``PreviewWindowController``) rather than floating inside the deck.
struct LargePreviewView: View {
    @ObservedObject var model: DeckModel
    let item: ClipItem

    @FocusState private var editorFocused: Bool

    private var isEditing: Bool { model.isEditingPreview }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            header
            Hairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Hairline()
            metadataGrid
        }
        .padding(Theme.panelPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(isEditing ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.14),
                              lineWidth: isEditing ? Theme.focusRing : 1)
        )
        // Only the chrome closes the page. Tapping the content starts an edit,
        // which would be impossible if any click anywhere dismissed first.
        .onTapGesture { if !isEditing { model.isPreviewingLarge = false } }
        .onChange(of: isEditing) { _, editing in editorFocused = editing }
    }

    private var header: some View {
        HStack(spacing: Theme.space2) {
            if let icon = model.icon(for: item) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(item.title)
                .font(.system(size: Theme.title, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.space2)
            headerHints
        }
    }

    /// Says what the keys do *right now* — the page has two modes and no other
    /// visible difference between them beyond the ring.
    @ViewBuilder
    private var headerHints: some View {
        if isEditing {
            HStack(spacing: Theme.space1) {
                KeyCap(text: "⌘↩")
                Text("save").font(.system(size: Theme.small)).foregroundStyle(.tertiary)
                KeyCap(text: "⎋")
                Text("discard").font(.system(size: Theme.small)).foregroundStyle(.tertiary)
            }
            .fixedSize()
        } else {
            HStack(spacing: Theme.space1) {
                if item.kind.isEditable {
                    KeyCap(text: "⌘E")
                    Text("edit").font(.system(size: Theme.small)).foregroundStyle(.tertiary)
                }
                KeyCap(text: "space")
                Text("close").font(.system(size: Theme.small)).foregroundStyle(.tertiary)
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            editor
        } else {
            readOnlyContent
                .contentShape(Rectangle())
                .onTapGesture {
                    // Clicking an image or a file list has nothing to edit, so
                    // it falls back to the chrome's behaviour instead of
                    // swallowing the click and doing nothing at all.
                    if item.kind.isEditable {
                        model.beginPreviewEdit()
                    } else {
                        model.isPreviewingLarge = false
                    }
                }
        }
    }

    private var editor: some View {
        TextEditor(
            text: Binding(
                get: { model.previewDraft ?? "" },
                set: { model.previewDraft = $0 }
            )
        )
        .font(.system(size: Theme.large, design: item.kind == .code ? .monospaced : .default))
        .scrollContentBackground(.hidden)
        .focused($editorFocused)
        .padding(Theme.space1)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .onAppear { editorFocused = true }
    }

    @ViewBuilder
    private var readOnlyContent: some View {
        switch item.kind {
        case .image:
            if let image = fullImage ?? model.thumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder
            }
        case .color:
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.swatch(fromHex: item.metadata.colorHex ?? "") ?? .gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.space15) {
                    ForEach(Array((item.metadata.filePaths ?? []).enumerated()), id: \.offset) { _, path in
                        HStack(spacing: Theme.space2) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 16, height: 16)
                            Text(path)
                                .font(.system(size: Theme.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            ScrollView {
                Text(fullText ?? item.preview)
                    .font(.system(size: Theme.large, design: item.kind == .code ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: item.kind.symbolName)
            .font(.system(size: Theme.hero, weight: .light))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Two columns rather than one long row: a page is too narrow to lay eight
    /// label/value pairs side by side without shearing most of them off.
    private var metadataGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: Theme.space3, alignment: .topLeading),
                GridItem(.flexible(), spacing: Theme.space3, alignment: .topLeading),
            ],
            alignment: .leading,
            spacing: Theme.space15
        ) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 1) {
                    Text(pair.0.uppercased())
                        .font(.system(size: Theme.caption, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(pair.1)
                        .font(.system(size: Theme.body))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pairs: [(String, String)] {
        var all: [(String, String)] = [
            ("Kind", item.kind.displayName),
            ("Source", item.sourceAppName.isEmpty ? "Unknown" : item.sourceAppName),
            ("Copied", Theme.fullTimestamp(item.updatedAt)),
            ("First seen", Theme.fullTimestamp(item.createdAt)),
            ("Size", ByteFormat.string(item.byteSize)),
        ]
        all.append(contentsOf: item.metadata.displayPairs())
        if item.useCount > 0 { all.append(("Pasted", "\(item.useCount)×")) }
        if let utis = item.metadata.utis { all.append(("Formats", "\(utis.count)")) }
        return all
    }

    /// The original bytes, not the thumbnail — worth loading for one item.
    private var fullImage: NSImage? {
        guard item.kind == .image,
              let payloads = try? model.store.payloads(itemID: item.id),
              let payload = payloads.first(where: { UTI.imageTypes.contains($0.uti) }),
              let data = model.store.data(for: payload)
        else { return nil }
        return NSImage(data: data)
    }

    private var fullText: String? {
        model.pasteService.plainText(for: item)
    }
}
