# Implementation Plan (v0.3)

## 0. Project structure (Xcode project, no Swift package)
- Create `StuffBucket.xcodeproj` with app targets:
  - `StuffBucket` (iOS universal target covering iPadOS)
  - `StuffBucketMac` (macOS)
- Add a shared framework target (e.g. `StuffBucketCore`) for models, persistence, search, import, and AI services.
- Share the Core Data model (`.xcdatamodeld`) across targets via the framework target.
- Keep platform-specific UI and permissions in each app target.

## 1. Core Data and storage updates
- Update the Core Data model with new fields:
  - `source`, `sourceExternalID`, `sourceFolderPath`
  - `aiSummary`, `aiArtifactsJSON`, `aiModelID`, `aiUpdatedAt`
- Add lightweight migration support for existing stores.
- Ensure CloudKit schema updates and resolve any merge policies for new fields.
- Add a small metadata table for search index versioning and last indexed timestamps.

## 2. High-quality search engine

### 2.1 Index storage and schema
- Implement a local SQLite index (in app container) using FTS5.
- Schema suggestion:
  - `items_fts(id, title, tags, collection, content, annotations, ai_summary)`
  - Use column weights for ranking (title > tags > content).
- Track `lastIndexedAt` per item to support incremental updates.

### 2.2 Indexing pipeline
- Build `SearchIndexer` service in `StuffBucketCore`:
  - Extract text from notes/snippets directly.
  - Extract text from HTML snapshots via `NSAttributedString` HTML import or WebKit text capture.
  - For documents, index filename plus extracted text where possible.
- Respect protection rules:
  - If locked, only index title/tags/collection; exclude body content.
- Run indexing in the background with throttling and batch updates.

### 2.3 Query parsing and ranking
- Implement a query parser supporting:
  - `type:`, `tag:`, `collection:`, `source:` filters
  - quoted phrases
  - prefix matching
- Ranking:
  - Use FTS5 `bm25` with column weights.
  - Boost recency and exact-title matches.
- Typo tolerance:
  - Maintain a token dictionary from the index.
  - Implement a small SymSpell-style lookup or edit-distance expansion for low-result queries.
- Provide highlighted snippets from FTS `snippet()`.

### 2.4 UI integration
- iOS/iPadOS:
  - Update search UI with filters, sort by relevance/recency, and preview snippets.
- macOS:
  - Mirror the same search capabilities with a search sidebar and result preview.

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
- Item detail actions for AI tasks (summarize, key points, tags).
- AI settings screen (API key management + advanced model picker).
- Show a pricing disclosure line with per-token rates sourced from the OpenAI pricing page.
- Maintain share sheet capture flow for links.

### macOS
- Safari import settings UI and status indicators.
- Search improvements aligned with iOS behavior.
- AI actions integrated into item detail and toolbar.
- AI settings screen (API key management + advanced model picker).
- Show a pricing disclosure line with per-token rates sourced from the OpenAI pricing page.

## 6. Background tasks and performance
- Add background tasks for:
  - HTML archiving
  - Search indexing
  - Safari sync re-import (macOS)
- Throttle indexing on large imports and show progress.
- Ensure on-device search remains responsive under heavy load.

## 7. Testing and validation
- Unit tests:
  - Search query parsing and ranking
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
