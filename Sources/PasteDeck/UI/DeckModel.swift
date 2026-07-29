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

    /// ↑ / ↓ walk the three zones. Order is top-to-bottom on screen, so the
    /// key direction matches what moves.
    func moveFocus(by offset: Int) {
        let order: [FocusZone] = [.search, .categories, .items]
        guard let index = order.firstIndex(of: focusZone) else { return }
        let next = min(max(index + offset, 0), order.count - 1)
        guard next != index else { return }
        focusZone = order[next]
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

    func pasteSelected() {
        guard let item = selectedItem else { return }
        paste(item)
    }

    func paste(_ item: ClipItem) {
        let wantsAutoPaste = preferences.pasteAutomatically
        isAccessibilityTrusted = Permissions.isAccessibilityTrusted

        // Without Accessibility the ⌘V never arrives, and silently copying
        // instead reads as "Enter does nothing". Stay open and say so.
        if wantsAutoPaste, !isAccessibilityTrusted {
            _ = pasteService.copyToPasteboard(item: item)
            showToast("Copied — but macOS won't let PasteDeck press ⌘V yet. Grant Accessibility below.", for: 3.4)
            Log.error("paste blocked: AXIsProcessTrusted() == false")
            if !hasPromptedForAccessibility {
                hasPromptedForAccessibility = true
                Permissions.requestAccessibility()
            }
            return
        }

        dismiss(immediately: true)
        pasteService.paste(item: item, into: targetApplication, autoPaste: wantsAutoPaste)
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
