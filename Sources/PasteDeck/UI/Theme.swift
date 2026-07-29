import PasteDeckCore
import SwiftUI

/// Every length, radius and colour the deck draws with.
///
/// Nothing in the UI layer writes a raw number. Two scales cover the whole
/// interface, and one formula ties them together, so a change here is a change
/// everywhere and no two surfaces can drift apart.
enum Theme {

    // MARK: - Spacing scale
    //
    // Layout distances — gaps between rows, sections, cards — are multiples of
    // `unit`. Padding *inside* a small control may use the half step: a 24 pt
    // pill needs 10 pt of side padding, and forcing that to 8 or 12 makes it
    // look either pinched or stretched.

    static let unit: CGFloat = 4
    static let half: CGFloat = unit / 2      // 2

    static let space1: CGFloat = unit        // 4
    static let space15: CGFloat = 6
    static let space2: CGFloat = 2 * unit    // 8
    static let space3: CGFloat = 3 * unit    // 12
    static let space4: CGFloat = 4 * unit    // 16

    // MARK: - Radius ladder
    //
    // One formula governs every corner in the deck:
    //
    //     radius(container) = radiusTile + padding(container)
    //
    // which is the concentric rule `inner = outer − inset` read from the
    // inside out. Start at the atom — a 4 pt tile — and each container that
    // wraps it with `p` of padding takes `4 + p`, so the curves stay parallel
    // however deep the nesting goes:
    //
    //     panel  4 + 12 = 16  ─ padding 12 ─▶  4  (a tile at the panel edge)
    //     card   4 +  8 = 12  ─ padding  8 ─▶  4  (the image well, colour chip)
    //     tile                                 4  (keycaps, thumbnails)
    //
    // The previous system derived the panel from the *card* (12 + 12 = 24).
    // That double-counted: cards sit in the middle of the panel and never
    // touch its corners, so the panel ended up far rounder than anything
    // nested in it, and the two things that do live in its corners — the
    // search field and the meta bar — got crowded by the curve.

    /// The smallest corner in the system. Everything else is built from it.
    static let radiusTile: CGFloat = unit    // 4

    static func radius(padding: CGFloat) -> CGFloat { radiusTile + padding }

    static let radiusPanel: CGFloat = radius(padding: space3)   // 16
    static let radiusCard: CGFloat = radius(padding: space2)    // 12

    /// Side padding for a pill of the given height.
    ///
    /// Pills are the one shape the formula above can't reach — their radius is
    /// half their height by definition — so their padding is derived from the
    /// height instead of picked by eye: 28 → 12, 24 → 10, 18 → 7.
    static func pillPadding(_ height: CGFloat) -> CGFloat { height / 2 - half }

    /// Ring drawn on whatever the keyboard is currently steering.
    static let focusRing: CGFloat = 1.5
    static let hairline: CGFloat = 1

    // MARK: - Layout

    /// Gap between the panel and the screen edges.
    static let screenInset: CGFloat = space3     // 12
    /// Panel edge → its contents. Sets `radiusPanel`.
    static let panelPadding: CGFloat = space3    // 12
    /// Card edge → its contents. Sets `radiusCard`.
    static let cardPadding: CGFloat = space2     // 8

    static let cardGap: CGFloat = space2         // 8   card → card
    static let chipGap: CGFloat = space15        // 6   chip → chip
    static let rowGap: CGFloat = space2          // 8   search → categories
    static let sectionGap: CGFloat = space3      // 12  header → deck → meta

    // MARK: - Heights
    //
    // Fixed so the panel's total height is exact arithmetic rather than
    // whatever the text happens to measure. A card whose footer grows by two
    // points because it shows a size instead of a ⌘-number would otherwise
    // shift every card's body height.

    static let searchHeight: CGFloat = 7 * unit       // 28
    static let chipHeight: CGFloat = 6 * unit         // 24
    /// Inline tag next to a title, smaller than a chip you can click.
    static let badgeHeight: CGFloat = 4 * unit + half // 18
    static let cardWidth: CGFloat = 58 * unit         // 232
    static let cardHeight: CGFloat = 24 * unit        // 96
    static let cardHeaderHeight: CGFloat = 7 * unit   // 28
    static let cardFooterHeight: CGFloat = 6 * unit   // 24
    static let detailHeight: CGFloat = 13 * unit      // 52

    /// Panel top edge → bottom of the category row.
    static var headerHeight: CGFloat {
        panelPadding + searchHeight + rowGap + chipHeight        // 72
    }

    /// The panel measures itself from its parts, so a row can never leave dead
    /// space or overflow the window it is hosted in.
    static var deckHeight: CGFloat {
        headerHeight                                             // 72
            + sectionGap + cardHeight + sectionGap               // 120
            + hairline                                           // 1
            + detailHeight                                       // 52
    }                                                            // = 245

    // MARK: - Large preview

    /// The preview is for *reading*, so it's shaped like a page rather than
    /// like the deck. Trapped inside the 245 pt strip it could only ever be a
    /// letterbox, which is why it gets its own window.
    static let previewRatio: CGFloat = 1.618        // height ÷ width
    static let previewMinHeight: CGFloat = 320
    static let previewMaxHeight: CGFloat = 760

    /// Fills the band between the top of the screen and the top of the deck,
    /// keeping the golden ratio and never overlapping the deck itself.
    static func previewSize(inScreen visible: CGRect) -> CGSize {
        let band = visible.height - screenInset * 2 - deckHeight - sectionGap
        let height = min(previewMaxHeight, max(previewMinHeight, band))
        return CGSize(width: (height / previewRatio).rounded(), height: height.rounded())
    }

    // MARK: - Colour

    static func color(named name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "indigo": return .indigo
        case "gray": return .secondary
        default: return .accentColor
        }
    }

    static func accent(for kind: ClipKind) -> Color {
        switch kind {
        case .text: return .secondary
        case .richText: return .indigo
        case .code: return .green
        case .link: return .blue
        case .color: return .pink
        case .image: return .purple
        case .file: return .teal
        case .prompt: return .indigo
        case .other: return .secondary
        }
    }

    // MARK: - Formatting

    /// "2m", "3h", "Tue" — compact enough for a card header.
    static func shortRelative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<45: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = seconds < 365 * 86_400 ? "d MMM" : "MMM yyyy"
            return formatter.string(from: date)
        }
    }

    static func fullTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    /// Parses `#rgb`, `#rrggbb` and `#rrggbbaa` for the colour swatch.
    static func swatch(fromHex hex: String) -> Color? {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 || digits.count == 4 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }

        let hasAlpha = digits.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// AppKit blur behind the panel.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
    }
}

/// A one-pixel rule. `Divider()` measures differently depending on where it
/// lands, which would make ``Theme/deckHeight`` a guess rather than a sum.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.1))
            .frame(height: Theme.hairline)
    }
}

/// A small key-cap style hint, e.g. ⌘V. The atom of the radius ladder.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, Theme.space15)
            .padding(.vertical, Theme.half)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .foregroundStyle(.secondary)
    }
}
