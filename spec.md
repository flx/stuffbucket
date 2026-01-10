# StuffBucket — Product Specification (v0.3)

## 1. Goal and positioning
StuffBucket is a personal capture-and-retrieve app for **text**, **snippets**, **links**, and **documents**, organized by **tags** and **collections**, with a strong emphasis on **durability** and **user ownership**.

Key guarantees:
- Documents are stored as **normal files in iCloud Drive** (Finder / Files visible).
- **Links are persisted**, including **saved HTML snapshots**, to avoid link rot (e.g. NYTimes articles).
- Metadata is stored in **Core Data**, synced via **CloudKit**.
- First-class support for **iOS, iPadOS, and macOS**.
- Optional **per-item protection** for sensitive content.
- **High-quality search** with relevance ranking, typo tolerance, and filters.
- Search input disables autocapitalization on iOS while keeping native macOS behavior.
- Tag editing uses platform-appropriate text input behavior.
- Optional **AI assistance** (summaries, key points, tags) powered by ChatGPT models, opt-in and user-controlled.

Non-goals (initial versions): collaboration, web client.

---

## 2. Core concepts

### 2.1 Item types
Every captured object is an **Item**:

- **Note** – rich text or markdown
- **Snippet** – short plain text
- **Link** – URL + metadata + **persisted HTML snapshot**
- **Document** – user-visible file in iCloud Drive

All item types support:
- Tags
- Collections
- Optional protection (lock)

---

## 3. Storage architecture

### 3.1 iCloud Drive layout (user-visible)

```
iCloud Drive/
└── StuffBucket/
    ├── Documents/
    │   └── <uuid>/
    │       └── <original filename>
    ├── Links/
    │   └── <uuid>/
    │       ├── page.html
    │       ├── assets/        (images, css, js if needed)
    │       └── metadata.json  (optional, diagnostic)
    ├── Protected/
    │   └── <uuid>.sbf         (encrypted payloads)
    ├── Inbox/
    └── Exports/
```

Principles:
- **Files remain files** (no opaque blobs).
- The user can browse and back up StuffBucket using Finder / Files.
- Deleting the app does not delete user data.

---

## 4. Link persistence (NEW / UPDATED)

### 4.1 Link capture requirements
When a link is saved, StuffBucket must:

1. Store the original URL.
2. Fetch and store:
   - Page title
   - Author (if available)
   - Publication date (best-effort)
   - Decode common HTML entities in metadata values
3. **Persist the article content** to avoid link rot.

### 4.2 HTML persistence strategy

For each Link item:
- Fetch the HTML using `URLSession` with reader-friendly user agent.
- Store a **self-contained HTML snapshot**:
  - Inline critical CSS where feasible.
  - Download referenced images into a local `assets/` folder.
  - Rewrite relative URLs to local paths.
- Save as:
  ```
  StuffBucket/Links/<uuid>/page.html
  ```

Optional enhancements:
- Reader-mode extraction (`WKWebView` reader API or Readability-style parsing).
- Dual storage:
  - `original.html` (raw page)
  - `reader.html` (cleaned article)

### 4.3 Fallback modes
If full HTML capture fails:
- Store:
  - Plain-text extracted content
  - Title + URL
- Mark link as **“partial archive”** in metadata.

### 4.4 Viewing links
- Default: open the locally stored `page.html` inside StuffBucket.
- Secondary action: “Open Original URL” in browser.
- Provide **Export as HTML / PDF**.

### 4.5 Why HTML, not PDF?
- Searchable
- Lightweight
- Preserves links and structure
- Future-proof

PDF export is optional, not canonical.

---

## 5. Metadata & Core Data model (amended)

### 5.1 Item entity (relevant fields)

- `id: UUID`
- `type: enum { note, snippet, link, document }`
- `title: String?`
- `textContent: String?`        // note/snippet body
- `tags: [String]`
- `createdAt: Date`
- `updatedAt: Date`
- `isProtected: Bool`
- `collectionID: UUID?`
- `source: enum { manual, share_sheet, safari_bookmarks, import }`
- `sourceExternalID: String?`   // stable ID for external sync (e.g. Safari)
- `sourceFolderPath: String?`   // external folder path (e.g. Safari bookmark folder)
- `documentRelativePath: String?` // Documents/<uuid>/<filename>

#### Link-specific
- `linkURL: String`
- `linkTitle: String?`
- `linkAuthor: String?`
- `linkPublishedDate: Date?`
- `htmlRelativePath: String`   // Links/<uuid>/page.html
- `archiveStatus: enum { full, partial, failed }`

### 5.2 Derived / AI metadata (new)
- `aiSummary: String?`
- `aiArtifactsJSON: String?`   // structured AI outputs (key points, entities, tags)
- `aiModelID: String?`
- `aiUpdatedAt: Date?`

---

## 6. Protection / locking (unchanged conceptually)

### 6.1 Protected links
If a link is marked protected:
- The HTML snapshot is encrypted into a single `.sbf` file.
- Decrypted only after biometric/passcode unlock.
- No readable HTML remains in iCloud Drive when locked.

### 6.2 Encryption
- AES-GCM via CryptoKit
- Keys stored in Keychain (iCloud Keychain sync)
- Optional app passphrase (future)

---

## 7. Sync model

### 7.1 Metadata
- Core Data + `NSPersistentCloudKitContainer`
- Conflict resolution:
  - last-writer-wins for scalars
  - set merge for tags

### 7.2 Files
- iCloud Drive handles sync.
- App watches for:
  - missing HTML files
  - externally modified files
- If HTML snapshot deleted externally:
  - show warning
  - allow re-fetch from original URL

---

## 8. Capture & import flows (amended)

### iOS / iPadOS Share Sheet
- In-app quick add:
  - New Snippet creates a text capture item immediately.
  - Import Document uses the Files picker and copies the file into StuffBucket/Documents.
- Saving a URL triggers:
  1. Immediate metadata save
  2. Background HTML fetch
  3. Archive status indicator
- Share extension captures URLs from Safari and queues them for the main app to import on launch.
- Share extension accepts URL attachments or plain-text URL payloads.
- Share extension bundle identifiers are prefixed by the main app bundle identifier.
- Share extension version numbers match the parent app.
- Share extension Info.plists include required bundle metadata for installation.
- App Group for share handoff storage: `group.com.digitalhandstand.stuffbucket.app`.
- macOS share extension follows the standard NSExtensionRequestHandling flow.
- On import, the app fetches metadata and persists an HTML snapshot when possible.

### macOS
- In-app quick add:
  - New Snippet creates a text capture item immediately.
  - Import Document uses a file picker and copies the file into StuffBucket/Documents.
- Paste URL
- Drag URL from browser
- Services / Share menu
- Share extension captures URLs from Safari and queues them for the main app to import on launch.
- Share extension accepts URL attachments or plain-text URL payloads.
- Share extension bundle identifiers are prefixed by the main app bundle identifier.
- Share extension version numbers match the parent app.
- Share extension Info.plists include required bundle metadata for installation.
- App Group for share handoff storage: `group.com.digitalhandstand.stuffbucket.app`.
- On import, the app fetches metadata and persists an HTML snapshot when possible.

### Safari Bookmarks bulk import (new, macOS only)
- One-time import during onboarding or later via Settings (macOS).
- Sources (macOS):
  - User-granted access to Safari bookmarks file, or HTML export from Safari.
- Imported bookmarks become **Link** items (optional background archive).
- Folder structure maps to Collections; a default `Safari` tag is applied.

---

## 9. UI behavior (current)

### 9.1 Browse
- Default view surfaces **Tags** and **Collections** with counts.
- Selecting a tag or collection pre-fills search with `tag:` / `collection:` filters.
- Recent items list is shown above tags and collections.
- Link items display an archive status badge (Pending / Archived / Partial / Failed).

### 9.2 Item detail
- Tag editing is available on the item detail view (comma-separated input).
- De-duplication based on URL + title + folder path; keep a sync link when possible.

---

## 9. Search (high quality)

### 9.1 Scope
- Full-text search across:
  - Notes/snippets
  - **Extracted text from saved HTML**
  - Filenames
  - User-added annotations
  - Tags, collections, and AI summaries (if present)

### 9.2 Quality requirements
- Relevance ranking with field weighting (title > tags > content).
- Typo tolerance, diacritic-insensitive matching, and stemming.
- Phrase search with quotes and prefix matching.
- Protected items are searchable by title/tags only until unlocked.

### 9.3 Query features
- Filters: `type:`, `tag:`, `collection:`, `source:`.
- Sort by relevance or recency.
- Highlighted snippets and quick preview for matches.

### 9.4 Indexing
- Incremental indexing as items change.
- Background reindex if HTML snapshots or files update.
- Index remains local and is rebuilt if corrupted.

### 9.5 Performance
- Typical queries return in <200ms on device.
- Large archives remain responsive with streaming results.

### 9.6 Spotlight (optional v1.1)
- Index content and titles for system-wide search.

## 10. Safari Bookmarks import & sync (new, macOS only)

### 10.1 Import behavior
- Bulk import creates Link items with `source = safari_bookmarks`.
- Preserve bookmark titles and URLs; store Safari folder path in `sourceFolderPath`.
- Optional "Archive on import" to fetch HTML in the background.
- For HTML export imports, retain a synthetic `sourceExternalID` derived from URL + path.

### 10.2 Sync model
- Keep StuffBucket in sync with Safari bookmark changes:
  - Added bookmark => new Link item.
  - Renamed/moved bookmark => update title and folder path.
  - Removed bookmark => mark as removed or delete (user-configurable).
- Sync should not overwrite user edits (notes, tags, custom titles).
- On macOS, prefer file watching when allowed; otherwise use scheduled re-import.

### 10.3 Conflict and duplicate handling
- De-dup by `sourceExternalID` when present; fall back to URL + folder path.
- If a URL already exists, merge metadata and keep the earliest Item ID.

## 11. OpenAI / ChatGPT integration (new)

### 11.1 Capabilities
- Summaries, key points, and tag suggestions for items.
- Optional tasks: title refinement, entity extraction, and Q&A over a single item.
- Actions are always user-initiated (no silent background AI).

### 11.2 Models and authentication
- Support ChatGPT-class models (e.g. GPT-4o family).
- OpenAI API access requires API keys; keys must not be hardcoded or bundled with the client app.
- ChatGPT Plus subscriptions do **not** grant API access or API billing.
- Integration is BYOK only in v0.3 (user-provided API key).
- Keys are stored in Keychain and never logged or exported.
- Default model: `gpt-4o-mini` with an optional advanced model picker.

### 11.3 Privacy and protection
- Explicit confirmation before sending content to OpenAI.
- Protected items require unlock and an extra confirmation prompt.
- AI outputs are stored locally in Core Data; users can delete or regenerate them.


---

## 12. UX expectations for links

- Badge showing:
  - "Archived" / "Partial" / "Live only"
- Clear disclosure:
  - “This page is saved locally”
- One-click export/share

---

## 13. Edge cases

- Paywalled content (e.g. NYTimes):
  - Capture occurs using user’s authenticated session when possible (WKWebView-based fetch).
  - Otherwise fall back to reader/plain text.
- Dynamic sites / JS-heavy pages:
  - Snapshot post-load DOM via WebKit.
- Legal note:
  - This is **personal archival**, not redistribution.
- Safari import:
  - Bookmarks file unavailable or locked; fallback to HTML import.
  - Invalid or empty URLs; skip with a report.
- AI:
  - Network failures or rate limits; surface error and allow retry.
  - Large items exceed model limits; summarize extractively or chunk with user confirmation.

---

## 14. Acceptance criteria

- Saved NYTimes article remains readable offline after original URL changes.
- HTML file visible in iCloud Drive.
- Search finds words inside archived articles, including with minor typos.
- Protected links are unreadable without unlock.
- Safari import can ingest 500+ bookmarks and keep changes in sync on macOS.
- User can generate an AI summary using their API key and see it saved on the item.

---

## 15. Versioning
- v0.2: HTML-backed link persistence
- v0.3: high-quality search, Safari bookmarks import & sync, ChatGPT integration
- v0.4 (future): reader cleanup, PDF export, OCR

---

## 16. Quality checks (engineering)
- Unit tests cover search query parsing/builder output, tag list encoding/decoding, and link metadata parsing with HTML entity decoding on both iOS and macOS targets.
- macOS unit tests run with an app host configuration so Xcodegen builds execute them reliably.
- Core Data item creation in tests uses context-scoped entity lookup to avoid entity ambiguity warnings when multiple models load.

---

_End of specification_
