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
                .strokeBorder(Color.primary.opacity(0.14))
        )
        .onTapGesture { model.isPreviewingLarge = false }
    }

    private var header: some View {
        HStack(spacing: Theme.space2) {
            if let icon = model.icon(for: item) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            KeyCap(text: "space")
            Text("close")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var content: some View {
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
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            ScrollView {
                Text(fullText ?? item.preview)
                    .font(.system(size: 12, design: item.kind == .code ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: item.kind.symbolName)
            .font(.system(size: 40, weight: .light))
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
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(pair.1)
                        .font(.system(size: 11))
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
