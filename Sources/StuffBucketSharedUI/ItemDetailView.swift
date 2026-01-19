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
    @State private var linkUpdateTask: Task<Void, Never>?
    @State private var archivePresentation: ArchivePresentation?
    @State private var isShowingLoginArchive = false
    @State private var loginArchiveURL: URL?
    @State private var isImportingDocument = false
    @State private var quickLookURL: URL?
    @State private var archiveError: ArchiveError?
    @State private var isPreparingArchive = false
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
    }

    private func detailView(for item: Item) -> some View {
        let hasSnippet = item.hasText
        let base = Form {
            Section("Details") {
                Text(displayTitle(for: item))
                    .font(.headline)
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

            Section("Collections") {
                collectionsField
                Text("Add collection names separated by commas")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .navigationTitle(displayTitle(for: item))
        .onAppear {
            syncFromItem(item)
        }
        .onChange(of: item.tags ?? "") { _, _ in
            syncFromItem(item)
        }
        .onChange(of: item.textContent ?? "") { _, _ in
            syncFromItem(item)
        }
        .onChange(of: item.linkURL ?? "") { _, _ in
            syncFromItem(item)
        }
        .onChange(of: linkText) { _, newValue in
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
        }
        .onChange(of: isEditingLink) { _, isEditing in
            // When exiting edit mode, apply the link
            if !isEditing {
                linkUpdateTask?.cancel()
                applyLink(linkText, to: item)
            }
        }
        .onChange(of: tagsText) { _, newValue in
            applyTags(newValue, to: item)
        }
        .onChange(of: collectionsText) { _, newValue in
            applyCollections(newValue, to: item)
        }
        .onChange(of: contentText) { _, newValue in
            // Only auto-apply content changes when NOT in edit mode
            // In edit mode, changes are applied when user taps Done
            guard !isEditingSnippet else { return }
            applyContent(newValue, to: item)
        }
        .onChange(of: isEditingSnippet) { _, isEditing in
            // When exiting snippet edit mode, apply the content
            if !isEditing {
                applyContent(contentText, to: item)
            }
        }
        .fileImporter(
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
        }

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
            .sheet(isPresented: $isShowingLoginArchive) {
                loginArchiveSheet
            }
            .sheet(isPresented: $isShowingTagSuggestions) {
                if let item = items.first {
                    tagSuggestionSheet(for: item)
                }
            }
            .quickLookPreview($quickLookURL)
#else
        return base
            .sheet(isPresented: $isShowingLoginArchive) {
                loginArchiveSheet
            }
            .sheet(isPresented: $isShowingTagSuggestions) {
                if let item = items.first {
                    tagSuggestionSheet(for: item)
                }
            }
#endif
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
    private var tagsField: some View {
#if os(iOS)
        TextField("tag1, tag2", text: $tagsText)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
#else
        TextField("tag1, tag2", text: $tagsText)
#endif
    }

    @ViewBuilder
    private var collectionsField: some View {
#if os(iOS)
        TextField("collection1, collection2", text: $collectionsText)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
#else
        TextField("collection1, collection2", text: $collectionsText)
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
            Text(item.documentFileName ?? "Document")
                .foregroundStyle(.secondary)
        } else {
            Text("No document attached yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let documentURL = item.documentURL {
            Button("Open Document") {
                openDocument(at: documentURL)
            }
        }

#if os(macOS)
        if let documentURL = item.documentURL {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([documentURL])
            }
        }
#endif

        Button(item.hasDocument ? "Replace Document..." : "Attach Document...") {
            isImportingDocument = true
        }
    }

    private func openDocument(at url: URL) {
#if os(macOS)
        NSWorkspace.shared.open(url)
#else
        quickLookURL = url
#endif
    }

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

        Button("Re-archive with Login") {
            guard let linkURL = item.linkURL, let url = URL(string: linkURL) else { return }
            loginArchiveURL = url
            isShowingLoginArchive = true
        }
        .disabled(item.linkURL == nil)

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

        _ = await MainActor.run {
            isPreparingArchive = true
        }
        defer {
            Task { @MainActor in
                isPreparingArchive = false
            }
        }

        // Build list of files to download from iCloud
        let filesToDownload = buildFilesToDownload(url: url, assetManifestJSON: item.assetManifestJSON)
        ArchiveResolver.startDownloading(filesToDownload)

        // Wait for iCloud files (with timeout)
        let iCloudReady = await waitForFiles(filesToDownload, timeoutSeconds: 5)

        if iCloudReady {
            // iCloud files ready, open them and trigger cleanup
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            triggerCleanupIfNeeded(item: item)
            return
        }

        // iCloud not ready, try bundle fallback
        if let itemID = item.id, let bundleData = item.archiveZipData {
            let cacheDir = LinkStorage.localCacheDirectoryURL(for: itemID)
            let cachePageURL = LinkStorage.localCachePageURL(for: itemID)

            // Extract if not already cached
            if !FileManager.default.fileExists(atPath: cachePageURL.path) {
                _ = ArchiveBundle.extract(bundleData, to: cacheDir)
            }

            if FileManager.default.fileExists(atPath: cachePageURL.path) {
                _ = await MainActor.run {
                    NSWorkspace.shared.open(cachePageURL)
                }
                return
            }
        }

        // No bundle available and iCloud not ready
        _ = await MainActor.run {
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

    private func waitForFiles(_ urls: [URL], timeoutSeconds: Double) async -> Bool {
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
    }

    private func triggerCleanupIfNeeded(item: Item) {
        context.perform {
            ArchiveResolver.cleanupBundleIfSynced(item: item, context: context)
        }
    }
#endif

    @ViewBuilder
    private var loginArchiveSheet: some View {
        if let url = loginArchiveURL {
            ArchiveWithLoginView(itemID: itemID, url: url)
                .environment(\.managedObjectContext, context)
        } else {
            Text("Link unavailable.")
                .padding()
        }
    }

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
            // First, try to download from iCloud Drive
            let filesToDownload = buildFilesToDownload()
            ArchiveResolver.startDownloading(filesToDownload)

            // Wait for iCloud files (with timeout)
            let iCloudReady = await waitForFiles(filesToDownload, timeoutSeconds: 5)

            if iCloudReady {
                // iCloud files are ready, use them
                await MainActor.run {
                    resolvedURL = url
                }
                // Trigger cleanup of bundle since iCloud is synced
                triggerCleanupIfNeeded()
                return
            }

            // iCloud not ready, try bundle fallback
            if let bundleData = archiveZipData {
                let cacheDir = LinkStorage.localCacheDirectoryURL(for: itemID)
                let cachePageURL = LinkStorage.localCachePageURL(for: itemID)

                // Extract if not already cached
                if !FileManager.default.fileExists(atPath: cachePageURL.path) {
                    _ = ArchiveBundle.extract(bundleData, to: cacheDir)
                }

                if FileManager.default.fileExists(atPath: cachePageURL.path) {
                    await MainActor.run {
                        resolvedURL = cachePageURL
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

    private func waitForFiles(_ urls: [URL], timeoutSeconds: Double) async -> Bool {
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
    }

    private func triggerCleanupIfNeeded() {
        // Clean up bundle data now that iCloud is synced
        context.perform {
            let request = NSFetchRequest<Item>(entityName: "Item")
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            request.fetchLimit = 1
            guard let item = try? context.fetch(request).first else { return }
            ArchiveResolver.cleanupBundleIfSynced(item: item, context: context)
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

final class ArchiveLoginWebViewStore: ObservableObject {
    @Published var isLoading = false
    var webView: WKWebView?
}

struct ArchiveWithLoginView: View {
    let itemID: UUID
    let url: URL

    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @StateObject private var webViewStore = ArchiveLoginWebViewStore()
    @State private var isArchiving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in to the site, then tap Archive to capture the full page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                Divider()
                ArchiveLoginWebView(url: url, store: webViewStore)
                    .overlay {
                        if webViewStore.isLoading {
                            ProgressView()
                                .padding(8)
                                .background(.thinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                if let errorMessage {
                    Divider()
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            }
            .navigationTitle("Archive with Login")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isArchiving ? "Archiving..." : "Archive") {
                        archiveCurrentPage()
                    }
                    .disabled(isArchiving || webViewStore.webView == nil)
                }
            }
        }
    }

    private func archiveCurrentPage() {
        guard let webView = webViewStore.webView else { return }
        let currentURL = webView.url ?? url
        isArchiving = true
        errorMessage = nil
        webView.evaluateJavaScript(LinkArchiveScript.capturePayload) { result, error in
            if let error {
                finishArchiveFailure("Unable to read page: \(error.localizedDescription)")
                return
            }
            guard let payload = result as? String else {
                finishArchiveFailure("Unable to read page content.")
                return
            }
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            cookieStore.getAllCookies { cookies in
                Task {
                    let success = await LinkArchiver.shared.archiveCapturedPayload(
                        payload,
                        originalURL: currentURL,
                        itemID: itemID,
                        context: context,
                        cookies: cookies
                    )
                    _ = await MainActor.run {
                        isArchiving = false
                        if success {
                            dismiss()
                        } else {
                            errorMessage = "Archive failed. Try again."
                        }
                    }
                }
            }
        }
    }

    private func finishArchiveFailure(_ message: String) {
        DispatchQueue.main.async {
            isArchiving = false
            errorMessage = message
        }
    }
}

#if os(iOS)
struct ArchiveLoginWebView: UIViewRepresentable {
    let url: URL
    @ObservedObject var store: ArchiveLoginWebViewStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        store.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let store: ArchiveLoginWebViewStore

        init(store: ArchiveLoginWebViewStore) {
            self.store = store
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            store.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            store.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            store.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            store.isLoading = false
        }
    }
}
#else
struct ArchiveLoginWebView: NSViewRepresentable {
    let url: URL
    @ObservedObject var store: ArchiveLoginWebViewStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        store.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let store: ArchiveLoginWebViewStore

        init(store: ArchiveLoginWebViewStore) {
            self.store = store
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            store.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            store.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            store.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            store.isLoading = false
        }
    }
}
#endif
