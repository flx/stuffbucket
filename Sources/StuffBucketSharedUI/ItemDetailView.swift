import CoreData
import SwiftUI
import StuffBucketCore
import UniformTypeIdentifiers
import WebKit
#if os(macOS)
import AppKit
#else
import QuickLook
#endif

// MARK: - Platform Actions

/// Singleton holder for platform-specific actions that can be set at app launch
public final class PlatformActions {
    public static let shared = PlatformActions()
    private init() {}

    /// Set by macOS app to enable "Show in Finder" functionality
    public var showInFinder: ((URL) -> Void)?
}

struct ArchivePresentation: Identifiable {
    let id = UUID()
    let itemID: UUID
    let url: URL
    let title: String
    let assetManifestJSON: String?
    let archiveZipData: Data?
}

struct ArchiveError: Identifiable {
    let id = UUID()
    let message: String
}

struct DocumentError: Identifiable {
    let id = UUID()
    let message: String
}

#if os(macOS)
private struct LeftAlignedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String? = nil
    var font: NSFont? = nil

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.alignment = .left
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = placeholder
        if let font {
            field.font = font
        }
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.alignment != .left {
            nsView.alignment = .left
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if let font, nsView.font != font {
            nsView.font = font
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: LeftAlignedTextField

        init(_ parent: LeftAlignedTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
#endif

struct ItemDetailView: View {
    let itemID: UUID

    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var items: FetchedResults<Item>
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Item.updatedAt, ascending: false)]
    )
    private var allItems: FetchedResults<Item>
    @State private var tagsText = ""
    @State private var collectionsText = ""
    @State private var contentText = ""
    @State private var linkText = ""
    @State private var titleText = ""
    @State private var linkUpdateTask: Task<Void, Never>?
    @State private var archivePresentation: ArchivePresentation?
    @State private var isImportingDocument = false
    @State private var quickLookURL: URL?
    @State private var archiveError: ArchiveError?
    @State private var documentError: DocumentError?
    @State private var isPreparingArchive = false
    @State private var isPreparingDocument = false
    @State private var useReaderMode = false
    @State private var isEditingLink = false
    @State private var isEditingSnippet = false
    @State private var isShowingTagSuggestions = false
    @ObservedObject private var aiKeyStorage = AIKeyStorage.shared

    init(itemID: UUID) {
        self.itemID = itemID
        let request = NSFetchRequest<Item>(entityName: "Item")
        request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Item.updatedAt, ascending: false),
            NSSortDescriptor(keyPath: \Item.createdAt, ascending: false)
        ]
        request.fetchLimit = 1
        _items = FetchRequest(fetchRequest: request, animation: .default)
    }

    var body: some View {
        Group {
            if let item = items.first {
                detailView(for: item)
            } else {
                missingView
            }
        }
        .alert(
            "Archive Unavailable",
            isPresented: Binding(
                get: { archiveError != nil },
                set: { isPresented in
                    if !isPresented {
                        archiveError = nil
                    }
                }
            )
        ) {
            Button("OK") {
                archiveError = nil
            }
        } message: {
            Text(archiveError?.message ?? "")
        }
        .alert(
            "Document Unavailable",
            isPresented: Binding(
                get: { documentError != nil },
                set: { isPresented in
                    if !isPresented {
                        documentError = nil
                    }
                }
            )
        ) {
            Button("OK") {
                documentError = nil
            }
        } message: {
            Text(documentError?.message ?? "")
        }
    }

    private func detailView(for item: Item) -> some View {
        let base = baseDetailView(for: item)

#if os(iOS)
        return base
            .sheet(item: $archivePresentation) { presentation in
                ArchivedLinkSheet(
                    itemID: presentation.itemID,
                    url: presentation.url,
                    title: presentation.title,
                    assetManifestJSON: presentation.assetManifestJSON,
                    archiveZipData: presentation.archiveZipData
                )
                .environment(\.managedObjectContext, context)
            }
            .sheet(isPresented: $isShowingTagSuggestions) {
                if let item = items.first {
                    tagSuggestionSheet(for: item)
                }
            }
            .quickLookPreview($quickLookURL)
#else
        return base
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.windowBackgroundColor))
            .sheet(isPresented: $isShowingTagSuggestions) {
                if let item = items.first {
                    tagSuggestionSheet(for: item)
                }
            }
#endif
    }

    private func baseDetailView(for item: Item) -> some View {
        var base = AnyView(detailForm(for: item))
        base = AnyView(base.navigationTitle(displayTitle(for: item)))
        base = AnyView(base.onAppear { syncFromItem(item) })
        base = AnyView(base.onChange(of: item.title ?? "") { _, _ in syncFromItem(item) })
        base = AnyView(base.onChange(of: item.tags ?? "") { _, _ in syncFromItem(item) })
        base = AnyView(base.onChange(of: item.textContent ?? "") { _, _ in syncFromItem(item) })
        base = AnyView(base.onChange(of: item.linkURL ?? "") { _, _ in syncFromItem(item) })
        base = AnyView(base.onChange(of: linkText) { _, newValue in
            // Only auto-apply link changes when NOT in edit mode
            // In edit mode, changes are applied when user taps Done
            guard !isEditingLink else { return }
            linkUpdateTask?.cancel()
            linkUpdateTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                _ = await MainActor.run {
                    applyLink(newValue, to: item)
                }
            }
        })
        base = AnyView(base.onChange(of: titleText) { _, newValue in
            applyTitle(newValue, to: item)
        })
        base = AnyView(base.onChange(of: isEditingLink) { _, isEditing in
            // When exiting edit mode, apply the link
            if !isEditing {
                linkUpdateTask?.cancel()
                applyLink(linkText, to: item)
            }
        })
        base = AnyView(base.onChange(of: tagsText) { _, newValue in
            applyTags(newValue, to: item)
        })
        base = AnyView(base.onChange(of: collectionsText) { _, newValue in
            applyCollections(newValue, to: item)
        })
        base = AnyView(base.onChange(of: contentText) { _, newValue in
            // Only auto-apply content changes when NOT in edit mode
            // In edit mode, changes are applied when user taps Done
            guard !isEditingSnippet else { return }
            applyContent(newValue, to: item)
        })
        base = AnyView(base.onChange(of: isEditingSnippet) { _, isEditing in
            // When exiting snippet edit mode, apply the content
            if !isEditing {
                applyContent(contentText, to: item)
            }
        })
        base = AnyView(base.fileImporter(
            isPresented: $isImportingDocument,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    attachDocument(url, to: item)
                }
            case .failure:
                break
            }
        })
        return base
    }

    private func detailForm(for item: Item) -> some View {
        Form {
            detailFormContent(for: item)
        }
    }

    @ViewBuilder
    private func detailFormContent(for item: Item) -> some View {
        let hasSnippet = item.hasText
        Section("Details") {
            titleField(for: item)
            if let type = item.itemType?.rawValue {
                Text(type.capitalized)
                    .foregroundStyle(.secondary)
            }
        }

        // Snippet at top if it has content (not when editing from empty)
        if hasSnippet && !isEditingSnippet {
            Section("Snippet") {
                contentEditor
            }
        }

        Section("Link") {
            linkSection(for: item)
        }

        if item.hasLink {
            Section("Archive") {
                archiveSection(for: item)
            }
        }

        Section("Document") {
            documentSection(for: item)
        }

        Section("Collections") {
            collectionsField
        }

        Section("Tags") {
            tagsField
            if aiKeyStorage.hasValidKey {
                Button {
                    isShowingTagSuggestions = true
                } label: {
                    Label("Suggest Tags", systemImage: "sparkles")
                }
            }
        }

        // Snippet at bottom if empty or editing from empty state
        if !hasSnippet || isEditingSnippet {
            Section("Snippet") {
                snippetSection(for: item, hasContent: hasSnippet)
            }
        }

        Section {
            if item.isTrashed {
                Button("Restore from Trash") {
                    restoreItem(item)
                }
                Button("Delete Permanently", role: .destructive) {
                    permanentlyDeleteItem(item)
                }
                if let trashedAt = item.trashedAt {
                    Text("Will be permanently deleted \(deletionDateText(from: trashedAt))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Move to Trash", role: .destructive) {
                    trashItem(item)
                }
            }
        }
    }

    private var missingView: some View {
        VStack(spacing: 8) {
            Text("Item not found")
                .font(.title2.bold())
            Text("The item may have been deleted or is not synced yet.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func displayTitle(for item: Item) -> String {
        item.displayTitle
    }

    @ViewBuilder
    private func titleField(for item: Item) -> some View {
#if os(iOS)
        TextField("Title", text: $titleText, prompt: Text(displayTitle(for: item)))
            .font(.headline)
#else
        LeftAlignedTextField(
            text: $titleText,
            placeholder: displayTitle(for: item),
            font: NSFont.preferredFont(forTextStyle: .headline)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
#endif
    }

    @ViewBuilder
    private var tagsField: some View {
#if os(iOS)
        TextField("Add tags", text: $tagsText)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
#else
        LeftAlignedTextField(text: $tagsText)
            .frame(maxWidth: .infinity, alignment: .leading)
#endif
    }

    @ViewBuilder
    private var collectionsField: some View {
#if os(iOS)
        TextField("Add collections", text: $collectionsText)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
#else
        LeftAlignedTextField(text: $collectionsText)
            .frame(maxWidth: .infinity, alignment: .leading)
#endif
    }

    @ViewBuilder
    private var contentEditor: some View {
#if os(iOS)
        TextEditor(text: $contentText)
            .frame(minHeight: 140)
#else
        TextEditor(text: $contentText)
            .frame(minHeight: 180)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
#endif
    }

    @ViewBuilder
    private func snippetSection(for item: Item, hasContent: Bool) -> some View {
        if isEditingSnippet {
            // Edit mode: show text editor with Done/Cancel buttons
            VStack(alignment: .leading, spacing: 8) {
                contentEditor
                HStack {
                    Button("Cancel") {
                        // Revert to saved value
                        contentText = item.textContent ?? ""
                        isEditingSnippet = false
                    }
                    Spacer()
                    Button("Done") {
                        isEditingSnippet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else if hasContent {
            // Has content - show inline editor (section is at top)
            contentEditor
        } else {
            // No content yet - show "Add Snippet" button
            Button {
                contentText = ""
                isEditingSnippet = true
            } label: {
                HStack {
                    Image(systemName: "text.badge.plus")
                    Text("Add Snippet")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func linkSection(for item: Item) -> some View {
        if isEditingLink {
            // Edit mode: show text field with Done/Cancel buttons
            VStack(alignment: .leading, spacing: 8) {
                linkField
                HStack {
                    Button("Cancel") {
                        // Revert to saved value
                        linkText = item.linkURL ?? ""
                        isEditingLink = false
                    }
                    Spacer()
                    Button("Done") {
                        isEditingLink = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else if let urlString = item.linkURL,
                  !urlString.isEmpty,
                  let url = URL(string: urlString),
                  let host = url.host,
                  host.contains(".") {
            // Display mode with valid URL
            Link(destination: url) {
                HStack {
                    Text(urlString)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
            }
            Button("Edit Link") {
                isEditingLink = true
            }
            .font(.subheadline)
        } else if let urlString = item.linkURL, !urlString.isEmpty {
            // Display mode with incomplete/invalid URL
            HStack {
                Text(urlString)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Invalid URL")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Edit Link") {
                isEditingLink = true
            }
            .font(.subheadline)
        } else {
            // No link yet - show "Add Link" button
            Button {
                linkText = ""
                isEditingLink = true
            } label: {
                HStack {
                    Image(systemName: "link.badge.plus")
                    Text("Add Link")
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var linkField: some View {
#if os(iOS)
        TextField("Enter URL", text: $linkText)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .keyboardType(.URL)
#else
        TextField("Enter URL", text: $linkText)
#endif
    }

    private func syncFromItem(_ item: Item) {
        let currentTitle = item.title ?? ""
        if currentTitle != titleText {
            titleText = currentTitle
        }
        let currentTags = item.displayTagList.joined(separator: ", ")
        if currentTags != tagsText {
            tagsText = currentTags
        }
        let currentCollections = item.collectionList.joined(separator: ", ")
        if currentCollections != collectionsText {
            collectionsText = currentCollections
        }
        let currentContent = item.textContent ?? ""
        if currentContent != contentText {
            contentText = currentContent
        }
        let currentLink = item.linkURL ?? ""
        if currentLink != linkText {
            linkText = currentLink
        }
    }

    private func applyTags(_ text: String, to item: Item) {
        let parsed = parseTags(text)
        guard parsed != item.displayTagList else { return }
        item.setDisplayTagList(parsed)
        item.updatedAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func applyCollections(_ text: String, to item: Item) {
        let parsed = parseTags(text)
        guard parsed != item.collectionList else { return }
        item.setCollectionList(parsed)
        item.updatedAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func applyContent(_ text: String, to item: Item) {
        let current = item.textContent ?? ""
        guard text != current else { return }
        item.textContent = text
        item.updatedAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func applyTitle(_ text: String, to item: Item) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? nil : trimmed
        let currentRaw = item.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentValue = (currentRaw?.isEmpty == false) ? currentRaw : nil
        guard newValue != currentValue else { return }
        item.title = newValue
        item.updatedAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
        }
    }

    private func applyLink(_ text: String, to item: Item) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard item.linkURL != nil || item.linkTitle != nil || item.archiveStatus != nil else { return }
            item.linkURL = nil
            item.linkTitle = nil
            item.linkAuthor = nil
            item.linkPublishedDate = nil
            item.htmlRelativePath = nil
            item.archiveStatus = nil
            item.updatedAt = Date()
            do {
                try context.save()
            } catch {
                context.rollback()
            }
            return
        }

        guard let url = normalizedURL(from: trimmed) else { return }
        let newValue = url.absoluteString
        let current = item.linkURL ?? ""
        guard newValue != current else { return }

        item.linkURL = newValue
        let hostTitle = url.host ?? newValue
        if item.title == nil || item.title?.isEmpty == true || item.title == item.linkTitle {
            item.title = hostTitle
        }
        item.linkTitle = hostTitle
        item.linkAuthor = nil
        item.linkPublishedDate = nil
        item.htmlRelativePath = nil
        item.archiveStatus = nil
        item.updatedAt = Date()
        do {
            try context.save()
        } catch {
            context.rollback()
            return
        }
        triggerArchive(for: item)
    }

    private func normalizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "https://\(trimmed)")
    }

    private func triggerArchive(for item: Item) {
        guard let itemID = item.id else { return }
        let backgroundContext = PersistenceController.shared.container.newBackgroundContext()
        LinkArchiver.shared.archive(itemID: itemID, context: backgroundContext)
    }

    @ViewBuilder
    private func documentSection(for item: Item) -> some View {
        if item.hasDocument {
            Label(item.documentFileName ?? "Document", systemImage: "doc.fill")
                .foregroundStyle(.secondary)
        } else {
            Text("No document attached yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let documentURL = item.documentURL {
#if os(macOS)
            HStack(spacing: 12) {
                Button {
                    openDocument(at: documentURL, relativePath: item.documentRelativePath, item: item)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                if let showInFinder = PlatformActions.shared.showInFinder {
                    Button {
                        showInFinder(documentURL)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
            }
#else
            Button {
                openDocument(at: documentURL, relativePath: item.documentRelativePath, item: item)
            } label: {
                Label(isPreparingDocument ? "Preparing..." : "Open Document", systemImage: "doc.text")
            }
            .disabled(isPreparingDocument)
            if isPreparingDocument {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Preparing document...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
#endif
        }

        Button(item.hasDocument ? "Replace Document..." : "Attach Document...") {
            isImportingDocument = true
        }
    }

    private func openDocument(at url: URL, relativePath: String?, item: Item?) {
#if os(macOS)
        Task {
            await openDocumentOnMac(url, relativePath: relativePath, item: item)
        }
#else
        Task {
            await openDocumentOnIOS(url, relativePath: relativePath, item: item)
        }
#endif
    }

#if os(macOS)
    private func openDocumentOnMac(_ url: URL, relativePath: String?, item: Item?) async {
        // Run file resolution on background thread
        let resolvedURL: URL = await Task.detached(priority: .userInitiated) {
            // Try DocumentResolver if we have the item
            if let item = item, let resolved = DocumentResolver.resolve(item: item) {
                if resolved.isFromCache {
                    return resolved.documentURL
                }

                if resolved.needsDownload {
                    DocumentResolver.startDownloading(resolved.documentURL)
                }

                // Check if file is ready
                if FileManager.default.fileExists(atPath: resolved.documentURL.path) && DocumentResolver.isFileReady(resolved.documentURL) {
                    return resolved.documentURL
                }

                // Try bundle fallback
                if let fallback = DocumentResolver.resolve(item: item, forceExtract: true), fallback.isFromCache {
                    return fallback.documentURL
                }
            }
            return url
        }.value

        await MainActor.run {
            NSWorkspace.shared.open(resolvedURL)
        }

        // Trigger cleanup if iCloud is synced (fire and forget)
        if let item = item {
            let ctx = context
            Task.detached(priority: .background) {
                await ctx.perform {
                    DocumentResolver.cleanupBundleIfSynced(item: item, context: ctx)
                }
            }
        }
    }
#endif

#if os(iOS)
    private func openDocumentOnIOS(_ url: URL, relativePath: String?, item: Item?) async {
        if isPreparingDocument {
            return
        }
        await MainActor.run {
            isPreparingDocument = true
        }
        defer {
            Task { @MainActor in
                isPreparingDocument = false
            }
        }

        guard let previewURL = await prepareDocumentPreviewURL(url, relativePath: relativePath, item: item) else { return }
        await MainActor.run {
            quickLookURL = previewURL
        }

        // Trigger cleanup if document is from cache but iCloud is now synced
        if let item = item {
            triggerDocumentCleanupIfNeeded(item: item)
        }
    }

    private func prepareDocumentPreviewURL(_ url: URL, relativePath: String?, item: Item?) async -> URL? {
        // Run file checks on background thread to avoid blocking main thread
        let resolvedURL: URL? = await Task.detached(priority: .userInitiated) {
            // Try to use DocumentResolver if we have the item
            if let item = item, let resolved = DocumentResolver.resolve(item: item) {
                if resolved.isFromCache {
                    // Bundle was extracted, return cached file
                    return resolved.documentURL
                }

                if resolved.needsDownload {
                    // Start download
                    DocumentResolver.startDownloading(resolved.documentURL)
                }

                // Check if file is available
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: resolved.documentURL.path) && DocumentResolver.isFileReady(resolved.documentURL) {
                    return resolved.documentURL
                }
            }

            // Fallback: try direct URL approach
            let fileManager = FileManager.default
            let isUbiquitous = fileManager.isUbiquitousItem(at: url)
            if isUbiquitous {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
            }

            if !fileManager.fileExists(atPath: url.path) {
                if let relativePath = relativePath {
                    DocumentStorage.ensureICloudDownload(forRelativePath: relativePath)
                }
            }

            return url
        }.value

        guard let targetURL = resolvedURL else {
            await MainActor.run {
                documentError = DocumentError(
                    message: "Document isn't available yet. Check iCloud Drive and try again."
                )
            }
            return nil
        }

        // Wait for file to be ready (with timeout)
        let ready = await waitForFileOnBackground(targetURL, timeoutSeconds: 12)
        if !ready {
            // Try fallback to bundle if available
            if let item = item, let resolved = await Task.detached(priority: .userInitiated, operation: {
                DocumentResolver.resolve(item: item, forceExtract: true)
            }).value, resolved.isFromCache {
                // Use cached version from bundle
                let cacheReady = await waitForFileOnBackground(resolved.documentURL, timeoutSeconds: 2)
                if cacheReady {
                    return await makePreviewCopyOnBackground(of: resolved.documentURL)
                }
            }

            await MainActor.run {
                documentError = DocumentError(
                    message: "Document isn't available yet. Check iCloud Drive and try again."
                )
            }
            return nil
        }

        return await makePreviewCopyOnBackground(of: targetURL)
    }

    private func waitForFileOnBackground(_ url: URL, timeoutSeconds: Double) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)
            let step: UInt64 = 200_000_000
            var waited: UInt64 = 0

            while waited < timeoutNanos {
                if Task.isCancelled { return false }
                if DocumentResolver.isFileReady(url) {
                    return true
                }
                try? await Task.sleep(nanoseconds: step)
                waited += step
            }
            return DocumentResolver.isFileReady(url)
        }.value
    }

    private func makePreviewCopyOnBackground(of url: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let previewRoot = fileManager.temporaryDirectory.appendingPathComponent(
                "StuffBucketPreview",
                isDirectory: true
            )
            try? fileManager.createDirectory(at: previewRoot, withIntermediateDirectories: true)

            let ext = url.pathExtension
            let fileName = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
            let destination = previewRoot.appendingPathComponent(fileName)

            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }

            do {
                try fileManager.copyItem(at: url, to: destination)
                return destination
            } catch {
                return url // Return original if copy fails
            }
        }.value
    }

    private func triggerDocumentCleanupIfNeeded(item: Item) {
        context.perform {
            DocumentResolver.cleanupBundleIfSynced(item: item, context: context)
        }
    }
#endif

    private func attachDocument(_ url: URL, to item: Item) {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try ItemImportService.attachDocument(fileURL: url, to: item, in: context)
            try context.save()
        } catch {
            context.rollback()
        }
    }

    @ViewBuilder
    private func archiveSection(for item: Item) -> some View {
        let pageURL = item.archivedPageURL
        let readerURL = item.archivedReaderURL
        let pageExpected = (item.htmlRelativePath?.isEmpty == false)
        let readerAvailable = archiveFileExists(readerURL)

        Toggle("Reader Mode", isOn: $useReaderMode)
            .disabled(!readerAvailable)

        Button("View Archive") {
            let url: URL?
            let title: String
            if useReaderMode, let reader = readerURL, readerAvailable {
                url = reader
                title = "Reader Archive"
            } else {
                url = pageURL
                title = "Page Archive"
            }
            guard let archiveURL = url else { return }
            openArchive(item: item, url: archiveURL, title: title)
        }
        .disabled(!pageExpected)

#if os(macOS)
        if isPreparingArchive {
            HStack(spacing: 8) {
                ProgressView()
                Text("Downloading archive assets...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
#endif

        if !pageExpected {
            Text("Archive is being created...")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if !readerAvailable {
            Text("Reader mode not available for this page.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func archiveFileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func openArchive(item: Item, url: URL, title: String) {
#if os(iOS)
        archivePresentation = ArchivePresentation(
            itemID: item.id ?? UUID(),
            url: url,
            title: title,
            assetManifestJSON: item.assetManifestJSON,
            archiveZipData: item.archiveZipData
        )
#elseif os(macOS)
        Task {
            await openArchiveOnMac(item: item, url: url, title: title)
        }
#endif
    }

#if os(macOS)
    private func openArchiveOnMac(item: Item, url: URL, title: String) async {
        if isPreparingArchive {
            return
        }

        await MainActor.run {
            isPreparingArchive = true
        }
        defer {
            Task { @MainActor in
                isPreparingArchive = false
            }
        }

        // Build list of files to download from iCloud (run on background)
        let filesToDownload = await Task.detached(priority: .userInitiated) {
            self.buildFilesToDownload(url: url, assetManifestJSON: item.assetManifestJSON)
        }.value

        // Start downloads on background thread
        await Task.detached(priority: .userInitiated) {
            ArchiveResolver.startDownloading(filesToDownload)
        }.value

        // Wait for iCloud files (with timeout) on background thread
        let iCloudReady = await waitForFilesOnBackground(filesToDownload, timeoutSeconds: 5)

        if iCloudReady {
            // iCloud files ready, open them and trigger cleanup
            await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            triggerArchiveCleanupIfNeeded(item: item)
            return
        }

        // iCloud not ready, try bundle fallback (run extraction on background thread)
        if let itemID = item.id, let bundleData = item.archiveZipData {
            let cachePageURL: URL? = await Task.detached(priority: .userInitiated) { () -> URL? in
                let cacheDir = LinkStorage.localCacheDirectoryURL(for: itemID)
                let cachePageURL = LinkStorage.localCachePageURL(for: itemID)

                // Extract if not already cached
                if !FileManager.default.fileExists(atPath: cachePageURL.path) {
                    _ = ArchiveBundle.extract(bundleData, to: cacheDir)
                }

                if FileManager.default.fileExists(atPath: cachePageURL.path) {
                    return cachePageURL
                }
                return nil
            }.value

            if let cachePageURL = cachePageURL {
                await MainActor.run {
                    NSWorkspace.shared.open(cachePageURL)
                }
                return
            }
        }

        // No bundle available and iCloud not ready
        await MainActor.run {
            archiveError = ArchiveError(
                message: "Archive is still syncing from iCloud. Try again in a moment."
            )
        }
    }

    private func buildFilesToDownload(url: URL, assetManifestJSON: String?) -> [URL] {
        var files: [URL] = [url]
        let archiveFolder = url.deletingLastPathComponent()
        let assetsFolder = archiveFolder.appendingPathComponent("assets", isDirectory: true)

        // Use manifest if available
        if let manifestJSON = assetManifestJSON,
           let manifestData = manifestJSON.data(using: .utf8),
           let assetFileNames = try? JSONDecoder().decode([String].self, from: manifestData) {
            for fileName in assetFileNames {
                files.append(assetsFolder.appendingPathComponent(fileName))
            }
        }

        return files
    }

    private func waitForFilesOnBackground(_ urls: [URL], timeoutSeconds: Double) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)
            let step: UInt64 = 200_000_000
            var waited: UInt64 = 0

            while waited < timeoutNanos {
                if Task.isCancelled { return false }
                if urls.allSatisfy({ ArchiveResolver.isFileReady($0) }) {
                    return true
                }
                try? await Task.sleep(nanoseconds: step)
                waited += step
            }
            return urls.allSatisfy({ ArchiveResolver.isFileReady($0) })
        }.value
    }

    private func triggerArchiveCleanupIfNeeded(item: Item) {
        context.perform {
            ArchiveResolver.cleanupBundleIfSynced(item: item, context: context)
        }
    }
#endif

    @ViewBuilder
    private func tagSuggestionSheet(for item: Item) -> some View {
        let existingTags = LibrarySummaryBuilder.tags(from: Array(allItems)).map { $0.name }
        TagSuggestionView(
            item: item,
            existingLibraryTags: existingTags,
            onApply: { suggestedTags in
                applyAISuggestedTags(suggestedTags, to: item)
                isShowingTagSuggestions = false
            },
            onCancel: {
                isShowingTagSuggestions = false
            }
        )
    }

    private func applyAISuggestedTags(_ suggestedTags: [String], to item: Item) {
        var currentTags = item.displayTagList
        for tag in suggestedTags {
            let normalizedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalizedTag.isEmpty && !currentTags.contains(where: { $0.lowercased() == normalizedTag }) {
                currentTags.append(tag)
            }
        }
        item.setDisplayTagList(currentTags)
        item.updatedAt = Date()
        if context.hasChanges {
            try? context.save()
        }
        syncFromItem(item)
    }

    private func parseTags(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Trash Actions

    private func trashItem(_ item: Item) {
        item.moveToTrash()
        if context.hasChanges {
            try? context.save()
        }
    }

    private func restoreItem(_ item: Item) {
        item.restoreFromTrash()
        if context.hasChanges {
            try? context.save()
        }
    }

    private func permanentlyDeleteItem(_ item: Item) {
        // Delete associated files
        if let itemID = item.id {
            let archiveDir = LinkStorage.archiveDirectoryURL(for: itemID)
            try? FileManager.default.removeItem(at: archiveDir)

            let cacheDir = LinkStorage.localCacheDirectoryURL(for: itemID)
            try? FileManager.default.removeItem(at: cacheDir)

            if let docPath = item.documentRelativePath {
                let docURL = DocumentStorage.url(forRelativePath: docPath)
                try? FileManager.default.removeItem(at: docURL.deletingLastPathComponent())
            }
        }

        context.delete(item)
        if context.hasChanges {
            try? context.save()
        }
    }

    private func deletionDateText(from trashedAt: Date) -> String {
        let deletionDate = Calendar.current.date(byAdding: .day, value: 10, to: trashedAt) ?? trashedAt
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: deletionDate, relativeTo: Date())
    }
}

#Preview {
    ItemDetailView(itemID: UUID())
}

struct QuickAddSnippetView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    let onSave: ((UUID) -> Void)?

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $text)
                    .frame(minHeight: 200)
            }
            .padding()
            .navigationTitle("New Snippet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSnippet()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveSnippet() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let itemID = ItemImportService.createSnippetItem(text: trimmed, in: context) else { return }
        do {
            try context.save()
        } catch {
            context.rollback()
            return
        }
        onSave?(itemID)
        dismiss()
    }
}

#if os(iOS)
struct ArchivedLinkSheet: View {
    let itemID: UUID
    let url: URL
    let title: String
    let assetManifestJSON: String?
    let archiveZipData: Data?

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var resolvedURL: URL?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if let resolvedURL {
                    ArchivedLinkWebView(url: resolvedURL)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Preparing archive...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        checkTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            resolveArchive()
        }
        .onDisappear {
            checkTask?.cancel()
        }
    }

    private func resolveArchive() {
        checkTask = Task {
            // First, try to download from iCloud Drive (run on background)
            let filesToDownload = await Task.detached(priority: .userInitiated) {
                self.buildFilesToDownload()
            }.value

            await Task.detached(priority: .userInitiated) {
                ArchiveResolver.startDownloading(filesToDownload)
            }.value

            // Wait for iCloud files (with timeout) on background thread
            let iCloudReady = await waitForFilesOnBackground(filesToDownload, timeoutSeconds: 5)

            if iCloudReady {
                // iCloud files are ready, use them
                await MainActor.run {
                    resolvedURL = url
                }
                // Trigger cleanup of bundle since iCloud is synced
                triggerCleanupIfNeeded()
                return
            }

            // iCloud not ready, try bundle fallback (run extraction on background thread)
            if let bundleData = archiveZipData {
                let extractedURL: URL? = await Task.detached(priority: .userInitiated) {
                    let cacheDir = LinkStorage.localCacheDirectoryURL(for: self.itemID)
                    let cachePageURL = LinkStorage.localCachePageURL(for: self.itemID)

                    // Extract if not already cached
                    if !FileManager.default.fileExists(atPath: cachePageURL.path) {
                        _ = ArchiveBundle.extract(bundleData, to: cacheDir)
                    }

                    if FileManager.default.fileExists(atPath: cachePageURL.path) {
                        return cachePageURL
                    }
                    return nil
                }.value

                if let extractedURL = extractedURL {
                    await MainActor.run {
                        resolvedURL = extractedURL
                    }
                    return
                }
            }

            // Last resort: show iCloud URL anyway (may be incomplete)
            await MainActor.run {
                resolvedURL = url
            }
        }
    }

    private func buildFilesToDownload() -> [URL] {
        var files: [URL] = [url]
        let archiveFolder = url.deletingLastPathComponent()
        let assetsFolder = archiveFolder.appendingPathComponent("assets", isDirectory: true)

        // Use manifest if available
        if let manifestJSON = assetManifestJSON,
           let manifestData = manifestJSON.data(using: .utf8),
           let assetFileNames = try? JSONDecoder().decode([String].self, from: manifestData) {
            for fileName in assetFileNames {
                files.append(assetsFolder.appendingPathComponent(fileName))
            }
        }

        return files
    }

    private func waitForFilesOnBackground(_ urls: [URL], timeoutSeconds: Double) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)
            let step: UInt64 = 200_000_000
            var waited: UInt64 = 0

            while waited < timeoutNanos {
                if Task.isCancelled { return false }
                if urls.allSatisfy({ ArchiveResolver.isFileReady($0) }) {
                    return true
                }
                try? await Task.sleep(nanoseconds: step)
                waited += step
            }
            return urls.allSatisfy({ ArchiveResolver.isFileReady($0) })
        }.value
    }

    private func triggerCleanupIfNeeded() {
        // Clean up bundle data now that iCloud is synced
        context.perform {
            let request = NSFetchRequest<Item>(entityName: "Item")
            request.predicate = NSPredicate(format: "id == %@", self.itemID as CVarArg)
            request.fetchLimit = 1
            guard let item = try? self.context.fetch(request).first else { return }
            ArchiveResolver.cleanupBundleIfSynced(item: item, context: self.context)
        }
    }
}

struct ArchivedLinkWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        let accessURL = url.deletingLastPathComponent()
        webView.loadFileURL(url, allowingReadAccessTo: accessURL)
        context.coordinator.loadedURL = url
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}
#endif
