# Implementation Plan (v0.3)

## 0. Project structure (Xcode project, no Swift package)
- Create `StuffBucket.xcodeproj` with app targets: completed [x]
  - `StuffBucket` (iOS universal target covering iPadOS)
  - `StuffBucketMac` (macOS)
- Add a shared framework target (e.g. `StuffBucketCore`) for models, persistence, search, import, and AI services. completed [x]
- Share the Core Data model (`.xcdatamodeld`) across targets via the framework target. completed [x]
- Keep platform-specific UI and permissions in each app target. completed [x]
- Add a shared UI folder for views used across targets (item detail, search bar). completed [x]
- Add iOS and macOS share extension targets for Safari share sheet capture. completed [x]
- Handle share extension URL extraction from URL or plain-text payloads. completed [x]
- Ensure share extension Info.plists include bundle identifiers for embedding. completed [x]
- Align share extension version values with the parent app. completed [x]
- Add CFBundleExecutable to share extension Info.plists for simulator install. completed [x]
- Use NSViewController's beginRequest override for macOS share extension handling. completed [x]
- Set bundle identifiers and App Group to `com.digitalhandstand.stuffbucket.app` / `group.com.digitalhandstand.stuffbucket.app`. completed [x]
- Sync Xcode recommended project settings into Xcodegen (app sandbox/network/app groups, asset symbol generation, Xcode version). completed [x]

## 1. Core Data and storage updates
- Update the Core Data model with new fields: completed [x]
  - `source`, `sourceExternalID`, `sourceFolderPath`
  - `aiSummary`, `aiArtifactsJSON`, `aiModelID`, `aiUpdatedAt`
- Add item body and document path fields: completed [x]
  - `textContent`
  - `documentRelativePath`
- Add `tags` to the Core Data model. completed [x]
- Add lightweight migration support for existing stores. completed [x]
- Ensure CloudKit schema updates and resolve any merge policies for new fields.
- Make Core Data attributes CloudKit-compatible (optional or default values for non-optional fields). completed [x]
- Enable iCloud CloudKit + iCloud Drive capabilities for iOS/macOS targets with container `iCloud.com.digitalhandstand.stuffbucket`. completed [x]
- Point `NSPersistentCloudKitContainer` at the same iCloud container ID. completed [x]
- Use the same iCloud container ID for link/document storage paths. completed [x]
- Add a small metadata table for search index versioning and last indexed timestamps. completed [x]
- Load the Core Data model from the framework bundle to avoid runtime lookup failures. completed [x]
- Import shared links from the share extension into Core Data. completed [x]
- Refresh App Group defaults before dequeuing shared items to reduce share-import latency. completed [x]
- Fetch link metadata and persist HTML snapshots after share import. completed [x]
- Capture rendered HTML via WKWebView, download assets, and rewrite HTML/CSS for offline link archives (fallback to raw HTML). completed [x]
- Generate a reader-mode HTML snapshot (reader.html) alongside the full archive (page.html). completed [x]
- Decode common HTML entities in link metadata parsing without AppKit dependencies. completed [x]
- Add document storage helper for iCloud Drive file copies. completed [x]
- Add import helper for links, snippets, and documents. completed [x]
- Unify item attachments so link/text/document can co-exist on any item. completed [x]
  - Add attachment flags on Item (hasLink/hasText/hasDocument). completed [x]
  - Archive pending links by `linkURL` presence instead of creation type. completed [x]

## 2. High-quality search engine

### 2.1 Index storage and schema
- Implement a local SQLite index (in app container) using FTS5. completed [x]
- Schema suggestion:
  - `items_fts(id, title, tags, collection, content, annotations, ai_summary)`
  - Use column weights for ranking (title > tags > content).
- Track `lastIndexedAt` per item to support incremental updates.

### 2.2 Indexing pipeline
- Build `SearchIndexer` service in `StuffBucketCore`: completed [x]
  - Extract text from notes/snippets directly.
  - Extract text from HTML snapshots via `NSAttributedString` HTML import or WebKit text capture.
  - For documents, index filename plus extracted text where possible.
- Respect protection rules: completed [x]
  - If locked, only index title/tags/collection; exclude body content.
- Run indexing in the background with throttling and batch updates.

### 2.3 Query parsing and ranking
- Implement a query parser supporting: completed [x]
  - `type:`, `tag:`, `collection:`, `source:` filters
  - quoted phrases
  - prefix matching
- Ranking:
  - Use FTS5 `bm25` with column weights. completed [x]
  - Boost recency and exact-title matches.
- Typo tolerance:
  - Maintain a token dictionary from the index.
  - Implement a small SymSpell-style lookup or edit-distance expansion for low-result queries.
- Provide highlighted snippets from FTS `snippet()`. completed [x]

### 2.4 UI integration
- iOS/iPadOS:
  - Add searchable UI and preview snippets. completed [x]
  - Add filters and sort by relevance/recency.
- Replace placeholder landing UI with tag/collection lists. completed [x]
- Use a custom search bar for consistent alignment. completed [x]
- Ensure search input modifiers are platform-appropriate (iOS-only autocap settings). completed [x]
- Add a recent items list on the empty state. completed [x]
  - Show live-updating link archive status badges in lists. completed [x]
- macOS:
  - Add basic search UI and result preview. completed [x]
  - Add search sidebar and filter controls.
  - Replace placeholder landing UI with tag/collection lists. completed [x]
  - Use a custom search bar for consistent alignment. completed [x]
  - Add a recent items list on the empty state. completed [x]
  - Show live-updating link archive status badges in lists. completed [x]

## 3. Safari bookmarks import and sync (macOS only)

### 3.1 Import sources and permissions
- Provide a macOS Settings screen for Safari import.
- Use `NSOpenPanel` to grant access to:
  - `~/Library/Safari/Bookmarks.plist` (preferred)
  - HTML export from Safari (fallback)
- Store a security-scoped bookmark for persistent access.

### 3.2 Parsing and mapping
- Parse `Bookmarks.plist` (binary plist) and walk the tree to:
  - Capture URL, title, and folder path.
  - Extract a stable bookmark UUID when available for `sourceExternalID`.
- For HTML export, parse bookmarks and generate a stable ID from URL + folder path.
- Map folder paths to Collections and apply the `Safari` tag.

### 3.3 De-duplication and updates
- De-dup by `sourceExternalID` when present; fallback to URL + folder path.
- Update title and folder path if the bookmark changes.
- Never overwrite user-edited notes/tags/custom titles.
- Provide a user setting for handling deleted bookmarks:
  - delete vs mark as removed.

### 3.4 Sync mechanism
- Watch the Safari bookmarks file using `DispatchSourceFileSystemObject` or `NSFilePresenter`.
- Trigger re-import on file changes (debounced).
- Provide a manual "Sync Now" action in macOS settings.

## 4. OpenAI integration (BYOK only)

### 4.1 Authentication and billing model
- ChatGPT Plus cannot be used for API auth or billing.
- Users supply their own OpenAI API key (BYOK).
- Store the key in Keychain; never log or export it.
- Require explicit user consent before sending content.

### 4.2 API key management
- Add Settings UI to add, validate, and remove the API key.
- Validation call (exact): `GET https://api.openai.com/v1/models`
  - Headers: `Authorization: Bearer <user_api_key>`, `Content-Type: application/json`
  - Success: HTTP 200; cache the returned model list for defaults and availability checks.
- Store the key in Keychain only after a successful validation.
- Error handling rules for validation:
  - 401: invalid or revoked key -> show "Invalid API key" and keep the key unsaved.
  - 403: access denied -> show "Key lacks access to this account or model set."
  - 402: billing issue or insufficient quota -> show "Billing problem. Check your OpenAI plan."
  - 429: rate limit -> show "Rate limited. Try again in a few minutes."
  - 5xx: OpenAI outage -> show "OpenAI is unavailable. Try again later."
  - Network/timeouts -> show "No connection. Check your network and retry."

### 4.3 Model selection
- Default model: `gpt-4o-mini` (fast + low cost baseline).
- Optional model picker (Advanced): show after key validation and list models from `/v1/models`.
- Filter to a recommended allowlist (e.g. `gpt-4o-mini`, `gpt-4o`) and hide unsupported models.
- If the selected model becomes unavailable, fall back to default and notify the user.

### 4.4 AI service layer
- Add `AIService` in `StuffBucketCore`:
  - Summarize item
  - Generate key points
  - Suggest tags
- Support structured outputs and store in `aiArtifactsJSON`.
- Save `aiSummary`, `aiModelID`, and `aiUpdatedAt` with each run.

### 4.5 Safeguards and UX
- For protected items, require unlock and an extra confirmation.
- Handle rate limits and failures with clear retry UI.
- Allow users to delete or regenerate AI outputs.

## 5. App-specific UI work

### iOS/iPadOS
- Search updates (filters, sorting, snippet previews).
- Tag editor on item detail view. completed [x]
- Shared item detail view for item metadata (tags). completed [x]
- Ensure tag input modifiers are platform-appropriate. completed [x]
- Add quick-add menu for new snippets and document import. completed [x]
- Add in-app prompt to save a link by pasting a URL. completed [x]
- Show an empty-state Import Document button. completed [x]
- Show an empty-state Add Link button. completed [x]
- Parse share sheet comment text into snippet + tags with quote-boundary rules (ignore apostrophes, ignore nested quotes), notify running instances, and open the app after share import. completed [x]
- Add link archive viewer actions (open page/reader HTML in-app). completed [x]
- Add Archive with Login sheet using a persistent in-app WebView for paywalled captures. completed [x]
- Add a temporary Delete All Data toolbar button for debugging (remove before release). completed [x]
- Allow link and text editing on all item types in detail view. completed [x]
- Allow document attach/replace on all item types in detail view. completed [x]
- Item detail actions for AI tasks (summarize, key points, tags).
- AI settings screen (API key management + advanced model picker).
- Show a pricing disclosure line with per-token rates sourced from the OpenAI pricing page.
- Maintain share sheet capture flow for links.

### macOS
- Safari import settings UI and status indicators.
- Search improvements aligned with iOS behavior.
- Tag editor on item detail view. completed [x]
- Shared item detail view for item metadata (tags). completed [x]
- Add quick-add menu for new snippets and document import. completed [x]
- Add in-app prompt to save a link by pasting a URL. completed [x]
- Support paste/drag URL capture in the main view. completed [x]
- Allow drag-and-drop document import in the main view. completed [x]
- Add “Show in Finder” for document items. completed [x]
- Show an empty-state Import Document button. completed [x]
- Add list row context menu to reveal document items. completed [x]
- Open the app and notify running instances after share sheet capture to surface new items. completed [x]
- Activate the macOS app when share capture is triggered to bring it to the foreground. completed [x]
- Parse share sheet comment text into snippet + tags with quote-boundary rules (ignore apostrophes, ignore nested quotes). completed [x]
- Add link archive viewer actions (open archived HTML in default browser). completed [x]
- Add Archive with Login sheet using a persistent in-app WebView for paywalled captures. completed [x]
- Add a temporary Delete All Data toolbar button for debugging (remove before release). completed [x]
- Allow link and text editing on all item types in detail view. completed [x]
- Allow document attach/replace on all item types in detail view. completed [x]
- AI actions integrated into item detail and toolbar.
- AI settings screen (API key management + advanced model picker).
- Show a pricing disclosure line with per-token rates sourced from the OpenAI pricing page.

## 6. Background tasks and performance
- Add background tasks for:
  - HTML archiving
  - Search indexing
  - Safari sync re-import (macOS)
- Auto-archive pending link items on app launch/activation to ensure HTML snapshots are captured. completed [x]
- Throttle indexing on large imports and show progress.
- Ensure on-device search remains responsive under heavy load.

## 7. Testing and validation
- Unit tests:
  - Search query parsing and builder output. completed [x]
  - Tag list encoding/decoding via in-memory Core Data. completed [x]
  - Link metadata parsing and HTML entity decoding. completed [x]
  - macOS unit test target mirrors core parsing/encoding coverage. completed [x]
  - macOS unit tests use an app host path configuration for Xcodegen builds. completed [x]
  - Test helpers create items using context-scoped entity lookup to avoid Core Data entity ambiguity warnings. completed [x]
  - Item import helper tests (snippet + document) on iOS and macOS. completed [x]
  - Item attachment flags and creation-kind invariants (link/text/document) on iOS and macOS. completed [x]
  - Share sheet comment parsing with quote-boundary rules (ignore apostrophes, ignore nested quotes) on iOS and macOS. completed [x]
  - FTS indexing and snippet generation
  - Safari bookmark parsing (sample plist and HTML export)
  - AI payload formatting and storage
- Integration tests:
  - Import 500+ bookmarks and validate sync updates
  - Search performance on large datasets
- Manual QA:
  - Protected item search behavior
  - AI API key entry and consent prompts

## 8. Release checklist
- Verify CloudKit schema migration.
- Verify iCloud Drive file layout remains intact.
- Confirm macOS Safari import permissions and file watch stability.
- Confirm BYOK handling and that no hardcoded API keys ship in the client.
- Confirm AI features are opt-in and clearly disclosed.
