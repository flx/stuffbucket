import CoreData
import SwiftUI
import StuffBucketCore
import UniformTypeIdentifiers
import WebKit
#if os(macOS)
import AppKit
#endif

struct ArchivePresentation: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct ItemDetailView: View {
    let itemID: UUID

    @Environment(\.managedObjectContext) private var context
    @FetchRequest private var items: FetchedResults<Item>
    @State private var tagsText = ""
    @State private var contentText = ""
    @State private var linkText = ""
    @State private var linkUpdateTask: Task<Void, Never>?
    @State private var archivePresentation: ArchivePresentation?
    @State private var isShowingLoginArchive = false
    @State private var loginArchiveURL: URL?
    @State private var isImportingDocument = false

    init(itemID: UUID) {
        self.itemID = itemID
        _items = FetchRequest(
            sortDescriptors: [],
            predicate: NSPredicate(format: "id == %@", itemID as CVarArg),
            animation: .default
        )
    }

    var body: some View {
        Group {
            if let item = items.first {
                detailView(for: item)
            } else {
                missingView
            }
        }
    }

    private func detailView(for item: Item) -> some View {
        let base = Form {
            Section("Details") {
                Text(displayTitle(for: item))
                    .font(.headline)
                if let type = item.itemType?.rawValue {
                    Text(type.capitalized)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Link") {
                linkField
                if item.hasLink {
                    Text(item.linkURL ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No link attached yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if item.hasLink {
                Section("Archive") {
                    archiveSection(for: item)
                }
            }

            Section("Content") {
                contentEditor
            }

            Section("Document") {
                documentSection(for: item)
            }

            Section("Tags") {
                tagsField
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
            linkUpdateTask?.cancel()
            linkUpdateTask = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    applyLink(newValue, to: item)
                }
            }
        }
        .onChange(of: tagsText) { _, newValue in
            applyTags(newValue, to: item)
        }
        .onChange(of: contentText) { _, newValue in
            applyContent(newValue, to: item)
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
                ArchivedLinkSheet(url: presentation.url, title: presentation.title)
            }
            .sheet(isPresented: $isShowingLoginArchive) {
                loginArchiveSheet
            }
#else
        return base
            .sheet(isPresented: $isShowingLoginArchive) {
                loginArchiveSheet
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
    private var linkField: some View {
#if os(iOS)
        TextField("https://example.com", text: $linkText)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .keyboardType(.URL)
#else
        TextField("https://example.com", text: $linkText)
#endif
    }

    private func syncFromItem(_ item: Item) {
        let current = item.tagList.joined(separator: ", ")
        if current != tagsText {
            tagsText = current
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
        guard parsed != item.tagList else { return }
        item.setTagList(parsed)
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
        VStack(alignment: .leading, spacing: 8) {
            if item.hasDocument {
                Text(item.documentFileName ?? "Document")
                    .foregroundStyle(.secondary)
            } else {
                Text("No document attached yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(item.hasDocument ? "Replace Document..." : "Attach Document...") {
                isImportingDocument = true
            }
#if os(macOS)
            if let documentURL = item.documentURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([documentURL])
                }
            }
#endif
        }
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
        let pageAvailable = archiveFileExists(pageURL)
        let readerAvailable = archiveFileExists(readerURL)

        Button("Open Page Archive") {
            guard let url = pageURL else { return }
            openArchive(url: url, title: "Page Archive")
        }
        .disabled(!pageAvailable)

        Button("Open Reader Archive") {
            guard let url = readerURL else { return }
            openArchive(url: url, title: "Reader Archive")
        }
        .disabled(!readerAvailable)

        Button("Archive with Login") {
            guard let linkURL = item.linkURL, let url = URL(string: linkURL) else { return }
            loginArchiveURL = url
            isShowingLoginArchive = true
        }
        .disabled(item.linkURL == nil)

        if !pageAvailable {
            Text("Archive not ready yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if !readerAvailable {
            Text("Reader archive not ready yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func archiveFileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func openArchive(url: URL, title: String) {
#if os(iOS)
        archivePresentation = ArchivePresentation(url: url, title: title)
#elseif os(macOS)
        // Start download if needed, then open
        if FileManager.default.isUbiquitousItem(at: url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        NSWorkspace.shared.open(url)
#endif
    }

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

    private func parseTags(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var isFileReady = false
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if isFileReady {
                    ArchivedLinkWebView(url: url)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading archive...")
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
            startFileCheck()
        }
        .onDisappear {
            checkTask?.cancel()
        }
    }

    private func startFileCheck() {
        checkTask = Task {
            // Start download if needed
            if FileManager.default.isUbiquitousItem(at: url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }

            // Poll until file is available (max ~5 seconds)
            for _ in 0..<50 {
                if Task.isCancelled { return }

                if isFileAvailableLocally(url) {
                    await MainActor.run {
                        isFileReady = true
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            // Timeout - show anyway and let WebView handle it
            await MainActor.run {
                isFileReady = true
            }
        }
    }

    private func isFileAvailableLocally(_ url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }

        // Check if it's still downloading from iCloud
        if fm.isUbiquitousItem(at: url) {
            do {
                let downloadStatus: URLResourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if let status = downloadStatus.ubiquitousItemDownloadingStatus {
                    return status == .current
                }
            } catch {
                // If we can't check status, assume it's ready if file exists
            }
        }
        return true
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
                    await MainActor.run {
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
