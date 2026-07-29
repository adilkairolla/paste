import AppKit
import PasteDeckCore
import SwiftUI

/// Writing a prompt needs room to type, which the 245 pt deck doesn't have.
/// It gets an ordinary window instead — one at a time, reused across edits.
@MainActor
final class PromptEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = PromptEditorWindowController()

    private var window: NSWindow?

    func show(model: DeckModel, editing item: ClipItem?) {
        // Editing a different prompt while one is open would silently discard
        // whatever is half-typed, so the old window goes away deliberately.
        window?.close()
        window = nil

        let view = PromptEditorView(
            model: model,
            editing: item,
            initialTitle: item?.title ?? "",
            initialText: item.map { model.promptBody(for: $0) } ?? "",
            onClose: { [weak self] in self?.close() }
        )

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = item == nil ? "New Prompt" : "Edit Prompt"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 480))
        window.minSize = NSSize(width: 420, height: 340)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct PromptEditorView: View {
    @ObservedObject var model: DeckModel
    let editing: ClipItem?
    let onClose: () -> Void

    @State private var title: String
    @State private var text: String

    init(
        model: DeckModel,
        editing: ClipItem?,
        initialTitle: String,
        initialText: String,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.editing = editing
        self.onClose = onClose
        _title = State(initialValue: initialTitle)
        _text = State(initialValue: initialText)
    }

    private var template: PromptTemplate { PromptTemplate(body: text) }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space3) {
            TextField("Title (optional)", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: Theme.large, weight: .medium))

            TextEditor(text: $text)
                .font(.system(size: Theme.large, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(Theme.space2)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
                .frame(minHeight: 200)

            slotSummary
            buttons
        }
        .padding(Theme.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var buttons: some View {
        HStack {
            if editing != nil {
                Button("Delete", role: .destructive) {
                    guard let editing else { return }
                    try? model.store.delete(itemIDs: [editing.id])
                    model.reload()
                    onClose()
                }
            }
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            Button(editing == nil ? "Create" : "Save") {
                model.savePrompt(title: title, body: text, replacing: editing)
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
    }

    /// Live feedback on what the braces produced. Typing `{{ topic }}` and
    /// getting no slot back is the failure worth catching before saving.
    @ViewBuilder
    private var slotSummary: some View {
        let variables = template.variables
        HStack(alignment: .top, spacing: Theme.space2) {
            Image(systemName: variables.isEmpty ? "info.circle" : "sparkles")
                .font(.system(size: Theme.body))
                .foregroundStyle(variables.isEmpty ? Color.secondary : Color.indigo)

            if variables.isEmpty {
                Text("Wrap a word in double braces to make it a slot, like {{topic}}, and PasteDeck will ask for it before pasting. {{clipboard}} and {{stack}} fill themselves in.")
                    .font(.system(size: Theme.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.half) {
                    ForEach(variables) { variable in
                        HStack(spacing: Theme.space1) {
                            Text("{{\(variable.name)}}")
                                .font(.system(size: Theme.body, design: .monospaced))
                                .foregroundStyle(.indigo)
                            if let builtIn = variable.builtIn {
                                Text("— filled automatically with \(builtIn.explanation)")
                                    .font(.system(size: Theme.small))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48, alignment: .top)
    }
}
