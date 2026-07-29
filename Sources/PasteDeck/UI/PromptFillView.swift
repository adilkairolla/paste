import PasteDeckCore
import SwiftUI

/// The sheet that appears when a chosen prompt still has slots to fill.
///
/// It deliberately shows the rendered result underneath the fields: a template
/// is hard to picture from its variables alone, and seeing the actual text grow
/// as you type is what makes a slot feel like a slot rather than a form field.
struct PromptFillView: View {
    @ObservedObject var model: DeckModel
    let fill: PromptFill

    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            header
            Hairline()
            fields
            if !fill.resolvedBuiltIns.isEmpty { builtInNote }
            Hairline()
            preview
        }
        .padding(Theme.space3)
        // Wide enough for a sentence of rendered preview, narrow enough that
        // two short fields don't sprawl across a 1440 pt display.
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .topLeading)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.45), lineWidth: Theme.focusRing)
        )
        .padding(.horizontal, Theme.space4 * 3)
        .padding(.vertical, Theme.space3)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
        .onAppear { focused = fill.focusedName }
        // ⇥ is handled by the panel's key monitor, which moves the model's
        // focusedName; this mirrors that back onto the actual text field.
        .onChange(of: model.promptFill?.focusedName) { _, name in focused = name }
        .onChange(of: focused) { _, name in
            guard let name, model.promptFill?.focusedName != name else { return }
            model.promptFill?.focusedName = name
        }
    }

    private var header: some View {
        HStack(spacing: Theme.space2) {
            Image(systemName: "sparkles")
                .font(.system(size: Theme.body, weight: .semibold))
                .foregroundStyle(.indigo)
            Text(fill.item.title)
                .font(.system(size: Theme.large, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.space2)
            KeyCap(text: "⇥")
            Text("next")
                .font(.system(size: Theme.small))
                .foregroundStyle(.tertiary)
            KeyCap(text: "↩")
            Text("paste")
                .font(.system(size: Theme.small))
                .foregroundStyle(.tertiary)
            KeyCap(text: "⎋")
            Text("cancel")
                .font(.system(size: Theme.small))
                .foregroundStyle(.tertiary)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.space15) {
            ForEach(fill.fields) { variable in
                HStack(spacing: Theme.space2) {
                    Text(variable.displayName)
                        .font(.system(size: Theme.body, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)

                    // No placeholder: it would only repeat the label beside it.
                    TextField(
                        "",
                        text: Binding(
                            get: { model.promptFill?.values[variable.name] ?? "" },
                            set: { model.promptFill?.values[variable.name] = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.large))
                    .focused($focused, equals: variable.name)
                    .padding(.horizontal, Theme.pillPadding(Theme.chipHeight))
                    .frame(height: Theme.chipHeight)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .overlay(
                        Capsule().strokeBorder(
                            focused == variable.name ? Color.accentColor : .clear,
                            lineWidth: Theme.focusRing
                        )
                    )
                }
            }
        }
    }

    /// Says which slots PasteDeck filled on its own, so a prompt that quietly
    /// swallowed the clipboard doesn't look like it ignored half its template.
    private var builtInNote: some View {
        HStack(spacing: Theme.space1) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: Theme.small))
            Text(fill.resolvedBuiltIns.map { "{{\($0.name)}} — \($0.builtIn?.explanation ?? "")" }
                .joined(separator: "   "))
                .font(.system(size: Theme.small))
        }
        .foregroundStyle(.tertiary)
    }

    private var preview: some View {
        ScrollView {
            Text(fill.rendered)
                .font(.system(size: Theme.body))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }
}
