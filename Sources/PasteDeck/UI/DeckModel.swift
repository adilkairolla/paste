import AppKit
import Combine
import PasteDeckCore
import SwiftUI

/// Which strip of the deck the arrow keys are steering. Up and down move
/// between zones; left, right and tab move within the active one.
enum FocusZone: CaseIterable {
    case search
    case categories
    case items
}

/// A prompt waiting for its slots to be filled before it can be pasted.
///
/// Built-in slots are resolved when this is created, so the sheet only ever
/// shows fields the user actually has to type into.
struct PromptFill: Equatable {
    var item: ClipItem
    var template: PromptTemplate
    /// Keyed by ``PromptTemplate/Variable/name``.
    var values: [String: String]
    /// Which field ⇥ will leave next.
    var focusedName: String?

    var fields: [PromptTemplate.Variable] { template.userVariables }

    var rendered: String { template.rendered(with: values) }

    /// Built-in slots that were filled in automatically, for the sheet's footer.
    var resolvedBuiltIns: [PromptTemplate.Variable] { template.variables.filter(\.isBuiltIn) }
}

/// State behind the deck window: what's on screen, what's selected, and every
/// action the UI can take.
@MainActor
final class DeckModel: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var categories: [ClipCategory] = []
    @Published var searchText: String = "" { didSet { scheduleReload() } }
    @Published var selectedTabID: String = "all" { didSet { reload(resetSelection: true) } }
    @Published var selectedItemID: Int64?
    @Published private(set) var isAccessibilityTrusted = Permissions.isAccessibilityTrusted
    /// Set when the user needs to be told something ("Copied", "Pinned").
    @Published var toast: String?
    @Published var isCreatingCategory = false
    @Published var newCategoryName = ""
    /// Space toggles a full-height look at the selected clipping.
    @Published var isPreviewingLarge = false
    /// Clippings gathered with ⇧⏎, in the order they were added. Held as whole
    /// items rather than ids so switching tabs or searching can't dissolve a
    /// stack the user is halfway through building.
    @Published private(set) var stack: [ClipItem] = []
    /// Non-nil while a prompt's slots are being filled in.
    @Published var promptFill: PromptFill?
    /// What ←/→/⇥ act on. The search field keeps the text cursor throughout, so
    /// typing always searches no matter which zone is active.
    @Published var focusZone: FocusZone = .items
    /// Bumped every time the deck is shown, so the search field can retake focus
    /// even though the hosting view is reused between appearances.
    @Published private(set) var focusRequest = 0

    let store: ClipStore
    let pasteService: PasteService
    let preferences: Preferences

    /// The app that was frontmost when the deck opened — where pastes go.
    var targetApplication: NSRunningApplication?
    /// Invoked when an action should dismiss the deck. `immediately` skips the
    /// fade: a paste has to give up key window *before* the target app is asked
    /// to come forward, or the synthetic ⌘V lands on a window that is still
    /// animating away.
    var onDismiss: ((_ immediately: Bool) -> Void)?

    private var reloadWorkItem: DispatchWorkItem?
    private var thumbnailCache = NSCache<NSNumber, NSImage>()
    private var toastWorkItem: DispatchWorkItem?
    /// The system permission sheet is modal and steals the deck's key window,
    /// so it gets shown at most once per launch.
    private var hasPromptedForAccessibility = false

    init(store: ClipStore, pasteService: PasteService, preferences: Preferences = .shared) {
        self.store = store
        self.pasteService = pasteService
        self.preferences = preferences
        thumbnailCache.countLimit = 300

        NotificationCenter.default.addObserver(
            forName: ClipboardMonitor.didCaptureNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(preserveSelection: true) }
        }
    }

    // MARK: - Tabs

    var tabs: [FilterTab] {
        FilterTab.smartTabs + categories.map(FilterTab.tab(for:))
    }

    var selectedTab: FilterTab {
        tabs.first { $0.id == selectedTabID } ?? FilterTab.smartTabs[0]
    }

    var selectedItem: ClipItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    var selectedIndex: Int? {
        guard let selectedItemID else { return nil }
        return items.firstIndex { $0.id == selectedItemID }
    }

    // MARK: - Loading

    func reload(resetSelection: Bool = false, preserveSelection: Bool = false) {
        categories = (try? store.categories()) ?? []
        // A category tab can disappear while it's selected.
        if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = "all" }

        let query = ClipQuery(filter: selectedTab.filter, search: searchText, limit: 200)
        items = (try? store.items(query)) ?? []

        if resetSelection || selectedItemID == nil {
            selectedItemID = items.first?.id
        } else if !preserveSelection || !items.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = items.first?.id
        }

        // Searching or switching filters can empty the strip out from under the
        // cursor. Leaving focus on it would strand the arrows on nothing.
        if items.isEmpty, focusZone == .items {
            focusZone = .categories
        }
        if items.isEmpty, isPreviewingLarge {
            isPreviewingLarge = false
        }
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload(resetSelection: true) }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    func prepareForDisplay(target: NSRunningApplication?) {
        targetApplication = target
        isAccessibilityTrusted = Permissions.isAccessibilityTrusted
        isCreatingCategory = false
        isPreviewingLarge = false
        promptFill = nil
        // A stack is a single errand. Carrying one across openings would mean
        // the next ⏎ pastes something gathered minutes ago in another app.
        stack = []
        focusZone = .items
        searchText = ""
        focusRequest += 1
        if !preferences.restoreFilterOnOpen {
            selectedTabID = "all"
        } else {
            selectedTabID = preferences.lastFilterID
        }
        reload(resetSelection: true)
    }

    // MARK: - Selection

    func selectNext() { move(by: 1) }
    func selectPrevious() { move(by: -1) }

    func selectFirst() { selectedItemID = items.first?.id }
    func selectLast() { selectedItemID = items.last?.id }

    private func move(by offset: Int) {
        guard !items.isEmpty else { return }
        guard let current = selectedIndex else {
            selectedItemID = items.first?.id
            return
        }
        let next = min(max(current + offset, 0), items.count - 1)
        selectedItemID = items[next].id
    }

    func selectNextTab(by offset: Int) {
        let all = tabs
        guard let index = all.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let next = (index + offset + all.count) % all.count
        selectedTabID = all[next].id
        preferences.lastFilterID = selectedTabID
    }

    // MARK: - Focus

    /// Zones the arrows can actually land on. An empty deck has no cards to
    /// steer, so the card strip drops out rather than becoming a dead end that
    /// swallows the cursor and shows no focus ring anywhere.
    var reachableZones: [FocusZone] {
        items.isEmpty ? [.search, .categories] : [.search, .categories, .items]
    }

    /// ↑ / ↓ walk the zones top-to-bottom, wrapping at both ends the same way
    /// ← / → wrap through the category bar. On an empty category that means ↓
    /// goes straight back to the search field.
    func moveFocus(by offset: Int) {
        let zones = reachableZones
        let index = zones.firstIndex(of: focusZone) ?? 0
        focusZone = zones[(index + offset + zones.count) % zones.count]
    }

    /// ← / → / ⇥ inside whichever zone is active.
    func step(by offset: Int) {
        switch focusZone {
        case .items:
            offset > 0 ? selectNext() : selectPrevious()
        case .categories:
            selectNextTab(by: offset)
        case .search:
            // Leave the caret alone — the text field handles its own arrows.
            break
        }
    }

    // MARK: - Actions

    func dismiss(immediately: Bool = false) {
        onDismiss?(immediately)
    }

    /// ⏎. A non-empty stack outranks the cursor: gathering clippings is a
    /// deliberate act, and pasting just the selected one instead would throw
    /// the gathering away silently.
    func pasteSelected() {
        if !stack.isEmpty {
            pasteStack()
            return
        }
        guard let item = selectedItem else { return }
        paste(item)
    }

    func paste(_ item: ClipItem) {
        // A prompt isn't pasteable text until its slots are resolved.
        if item.kind == .prompt {
            guard let fill = makeFill(for: item) else {
                showToast("This prompt's text couldn't be read")
                return
            }
            if fill.fields.isEmpty {
                try? store.markUsed(itemID: item.id)
                pasteComposed(fill.rendered)
            } else {
                promptFill = fill
            }
            return
        }

        guard !isBlockedByAccessibility(copying: { [pasteService] in
            _ = pasteService.copyToPasteboard(item: item)
        }) else { return }

        dismiss(immediately: true)
        pasteService.paste(item: item, into: targetApplication, autoPaste: preferences.pasteAutomatically)
    }

    /// Pastes text that has no stored item behind it — a filled prompt, or a
    /// composed stack.
    func pasteComposed(_ text: String) {
        guard !text.isEmpty else { return }

        guard !isBlockedByAccessibility(copying: { [pasteService] in
            pasteService.copyText(text)
        }) else { return }

        dismiss(immediately: true)
        pasteService.pasteText(text, into: targetApplication, autoPaste: preferences.pasteAutomatically)
    }

    /// Without Accessibility the ⌘V never arrives, and silently copying instead
    /// reads as "Enter does nothing". Copy anyway, stay open, and say so.
    private func isBlockedByAccessibility(copying copy: () -> Void) -> Bool {
        isAccessibilityTrusted = Permissions.isAccessibilityTrusted
        guard preferences.pasteAutomatically, !isAccessibilityTrusted else { return false }

        copy()
        showToast("Copied — but macOS won't let PasteDeck press ⌘V yet. Grant Accessibility below.", for: 3.4)
        Log.error("paste blocked: AXIsProcessTrusted() == false")
        if !hasPromptedForAccessibility {
            hasPromptedForAccessibility = true
            Permissions.requestAccessibility()
        }
        return true
    }

    // MARK: - Stack

    /// 1-based position in the stack, or nil when the item isn't in it.
    func stackPosition(of item: ClipItem) -> Int? {
        stack.firstIndex { $0.id == item.id }.map { $0 + 1 }
    }

    func toggleStack(_ item: ClipItem) {
        if let index = stack.firstIndex(where: { $0.id == item.id }) {
            stack.remove(at: index)
            showToast(stack.isEmpty ? "Stack cleared" : "Removed — \(stack.count) still stacked")
            return
        }
        guard item.kind.isStackable else {
            showToast(item.kind == .prompt
                      ? "Prompts get filled in, not stacked — press ⏎ to use this one"
                      : "\(item.kind.displayName.lowercased()) has no text to stack")
            return
        }
        stack.append(item)
        showToast("Stacked \(stack.count) — ⏎ pastes them together")
    }

    func toggleStackSelected() {
        guard let item = selectedItem else { return }
        toggleStack(item)
    }

    func clearStack() {
        guard !stack.isEmpty else { return }
        stack = []
        showToast("Stack cleared")
    }

    /// The stack as one labelled block.
    func composedStack() -> String {
        StackComposer.compose(stack.compactMap { item in
            text(of: item).map { StackComposer.Entry(item: item, text: $0) }
        })
    }

    func pasteStack() {
        let composed = composedStack()
        guard !composed.isEmpty else {
            showToast("Nothing in the stack could be turned into text")
            return
        }
        for item in stack { try? store.markUsed(itemID: item.id) }
        pasteComposed(composed)
    }

    /// Whatever text a clipping can contribute. Falls back through the stored
    /// payload, then the kind's own fields, then the preview.
    func text(of item: ClipItem) -> String? {
        if let text = pasteService.plainText(for: item), !text.isEmpty { return text }
        switch item.kind {
        case .file: return item.metadata.filePaths?.joined(separator: "\n")
        case .color: return item.metadata.colorHex ?? item.title
        case .link: return item.metadata.url ?? item.preview
        default: return item.preview.isEmpty ? nil : item.preview
        }
    }

    // MARK: - Prompts

    /// Reads a prompt's body and resolves its built-in slots, so the sheet only
    /// shows fields the user has to type into.
    private func makeFill(for item: ClipItem) -> PromptFill? {
        guard let body = (try? store.promptBody(itemID: item.id)) ?? nil else { return nil }
        let template = PromptTemplate(body: body)

        var values: [String: String] = [:]
        for variable in template.variables {
            switch variable.builtIn {
            case .clipboard: values[variable.name] = NSPasteboard.general.string(forType: .string) ?? ""
            case .stack: values[variable.name] = composedStack()
            case nil: values[variable.name] = ""
            }
        }

        return PromptFill(
            item: item,
            template: template,
            values: values,
            focusedName: template.userVariables.first?.name
        )
    }

    func commitPromptFill() {
        guard let fill = promptFill else { return }
        promptFill = nil
        try? store.markUsed(itemID: fill.item.id)
        pasteComposed(fill.rendered)
    }

    func cancelPromptFill() {
        promptFill = nil
    }

    /// ⇥ inside the fill sheet, wrapping at both ends.
    func stepPromptField(by offset: Int) {
        guard var fill = promptFill, !fill.fields.isEmpty else { return }
        let names = fill.fields.map(\.name)
        let current = fill.focusedName.flatMap { names.firstIndex(of: $0) } ?? 0
        fill.focusedName = names[(current + offset + names.count) % names.count]
        promptFill = fill
    }

    /// Creates a prompt, or rewrites one in place when `replacing` is given.
    func savePrompt(title: String, body: String, replacing item: ClipItem?) {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let item {
            try? store.updatePrompt(itemID: item.id, title: title, body: body)
        } else {
            _ = try? store.createPrompt(title: title, body: body)
        }
        reload(preserveSelection: true)
    }

    /// "Save as Prompt" on an ordinary clipping — the usual way a prompt starts
    /// life is as something you already pasted once.
    func savePromptFromItem(_ item: ClipItem) {
        guard let body = text(of: item), !body.isEmpty else {
            showToast("There's no text here to save as a prompt")
            return
        }
        _ = try? store.createPrompt(title: item.title, body: body)
        showToast("Saved to Prompts")
        reload(preserveSelection: true)
    }

    func promptBody(for item: ClipItem) -> String {
        ((try? store.promptBody(itemID: item.id)) ?? nil) ?? item.preview
    }

    func copySelected() {
        guard let item = selectedItem else { return }
        dismiss(immediately: true)
        pasteService.copyToPasteboard(item: item)
    }

    func pasteItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        paste(items[index])
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        try? store.setPinned(!item.isPinned, itemID: item.id)
        showToast(item.isPinned ? "Unpinned" : "Pinned")
        reload(preserveSelection: true)
    }

    func deleteSelected() {
        guard let item = selectedItem, let index = selectedIndex else { return }
        try? store.delete(itemIDs: [item.id])
        thumbnailCache.removeObject(forKey: NSNumber(value: item.id))
        // A deleted clipping can't contribute text any more, and leaving it in
        // the stack would paste a hole.
        stack.removeAll { $0.id == item.id }
        reload()
        // Keep the cursor where it was rather than jumping to the top.
        if !items.isEmpty {
            selectedItemID = items[min(index, items.count - 1)].id
        }
    }

    func toggleCategory(_ category: ClipCategory, for item: ClipItem) {
        if item.categoryIDs.contains(category.id) {
            try? store.removeItem(item.id, fromCategory: category.id)
            showToast("Removed from \(category.name)")
        } else {
            try? store.addItem(item.id, toCategory: category.id)
            showToast("Added to \(category.name)")
        }
        reload(preserveSelection: true)
    }

    func createCategory(named name: String, addingSelected: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let category = try? store.createCategory(
            name: trimmed,
            symbolName: ClipCategory.symbolChoices.randomElement() ?? "folder",
            colorName: ClipCategory.paletteNames.randomElement() ?? "blue"
        ) else {
            showToast("A category called “\(trimmed)” already exists")
            return
        }
        if addingSelected, let item = selectedItem {
            try? store.addItem(item.id, toCategory: category.id)
        }
        newCategoryName = ""
        isCreatingCategory = false
        reload(preserveSelection: true)
    }

    func deleteCategory(_ category: ClipCategory) {
        try? store.deleteCategory(id: category.id)
        if selectedTabID == "category-\(category.id)" { selectedTabID = "all" }
        reload()
    }

    func renameCategory(_ category: ClipCategory, to name: String) {
        try? store.updateCategory(id: category.id, name: name)
        reload(preserveSelection: true)
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    func refreshPermissionState() {
        isAccessibilityTrusted = Permissions.isAccessibilityTrusted
    }

    // MARK: - Presentation helpers

    func thumbnail(for item: ClipItem) -> NSImage? {
        let key = NSNumber(value: item.id)
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let data = try? store.thumbnail(itemID: item.id), let image = NSImage(data: data) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    func icon(for item: ClipItem) -> NSImage? {
        AppSourceResolver.shared.icon(forBundleID: item.sourceBundleID)
    }

    func categories(for item: ClipItem) -> [ClipCategory] {
        categories.filter { item.categoryIDs.contains($0.id) }
    }

    func showToast(_ message: String, for duration: TimeInterval = 1.6) {
        toast = message
        toastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
