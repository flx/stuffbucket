# StuffBucket — Product Specification (v0.3)

## 1. Goal and positioning
StuffBucket is a personal capture-and-retrieve app for **text**, **snippets**, **links**, and **documents**, organized by **tags** and **collections**, with a strong emphasis on **durability** and **user ownership**.

Key guarantees:
- Documents are stored as **normal files in iCloud Drive** (Finder / Files visible).
- **Links are persisted**, including **saved HTML snapshots**, to avoid link rot (e.g. NYTimes articles).
- Metadata is stored in **Core Data**, synced via **CloudKit**.
- First-class support for **iOS, iPadOS, and macOS**.
- **Full-text search** with relevance ranking and filters.
- Search uses a custom centered search bar on iOS and a capsule-style toolbar search field on macOS with an internal focus outline.
- Tag editing uses platform-appropriate text input behavior.
- Optional **AI assistance** (summaries, key points, tags) powered by Claude or ChatGPT, opt-in and user-controlled.

Non-goals (initial versions): collaboration, web client.

---

## Appendix: Repo hygiene (dev)
- Ignore local screenshots (`Screenshots/`) and personal notes (`resume.txt`) in git.
- Use context-scoped Core Data fetches in UI to avoid multi-bundle entity ambiguity.
- Item detail fetches include sort descriptors (required by NSFetchedResultsController).

## 2. Core concepts

### 2.1 Item types
Every captured object is an **Item**:

- **Snippet** – short plain text
- **Link** – URL + metadata + **persisted HTML snapshot**
- **Document** – user-visible file in iCloud Drive

All item types support:
- Tags
- Collections (via tag-based pseudo-collections)
- Optional attachments: **text**, **link**, and **document** can co-exist on any item.
- Attachments can be added/edited after creation in the item detail view.
- `type` is treated as the **creation kind** (how the item started), not a capability limiter.

### 2.2 Collections (tag-based)
Collections are implemented as special tags with a `collection:` prefix:
- A tag `collection:ProjectX` places the item in the "ProjectX" collection.
- The UI surfaces collections separately from regular tags, displaying just the collection name.
- Items can belong to multiple collections by having multiple `collection:` tags.
- Collection names are case-preserved but matched case-insensitively.
- Safari bookmark imports map folder paths to `collection:` tags.

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
    │       ├── reader.html
    │       ├── assets/        (images, css, js if needed)
    │       └── metadata.json  (optional, diagnostic)
    └── Inbox/
```

Principles:
- **Files remain files** (no opaque blobs).
- The user can browse and back up StuffBucket using Finder / Files.
- Deleting the app does not delete user data.
- iCloud container ID: `iCloud.com.digitalhandstand.stuffbucketapp`.

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
4. Automatically archive pending link items on app launch/activation to ensure every link is archived.

### 4.2 HTML persistence strategy

For each Link item:
- Capture the **rendered DOM** using `WKWebView` (non-persistent data store).
- Extract asset URLs (images, srcset, source tags, stylesheets, icons).
- Download assets into a local `assets/` folder and rewrite HTML/CSS references to local paths.
- Save both:
  - `page.html` (full page snapshot)
  - `reader.html` (reader-mode extraction)
- Fallback to a raw `URLSession` HTML fetch if WebKit capture fails.
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
- Store a raw HTML snapshot (without asset rewriting) when available.
- Mark link as **"partial archive"** in metadata.
If both rendered and raw capture fail:
- Mark link as **"failed archive."**

### 4.4 Archive sync strategy (hybrid)
Archives are synced using a hybrid approach combining iCloud Drive and CloudKit:

1. **Primary: iCloud Drive** – Archives are stored as files in iCloud Drive for user accessibility and Finder visibility.
2. **Fallback: CloudKit bundle** – A compressed archive bundle (`archiveZipData`) syncs via CloudKit as a fallback when iCloud Drive sync is slow or incomplete.
3. **Asset manifest** – A JSON list of asset filenames (`assetManifestJSON`) enables explicit iCloud file downloads.

When opening an archive:
- First attempt to load from iCloud Drive (with timeout).
- If unavailable, extract from CloudKit bundle to local cache.
- Once iCloud Drive sync completes, clean up the CloudKit bundle to avoid storage duplication.

### 4.5 Viewing links
- iOS/iPadOS: open the locally stored `page.html` (and `reader.html`) inside StuffBucket.
- If the archive lives in iCloud and is not yet downloaded, trigger download and show a loading state before displaying it.
- macOS: open the archived HTML in the default browser.
- macOS triggers iCloud download before opening archived HTML when needed.
- macOS allows opening page archives while syncing; if the file is not yet present locally, show a sync-pending message and an explicit unavailable alert.
- macOS attempts to download archive assets (images/styles) before opening and shows a brief "downloading assets" state.
- If iCloud Drive sync is incomplete, falls back to CloudKit bundle extraction.
- If archives are missing, show an unavailable state.
- Secondary action: Tapping the displayed URL opens the original link in the default browser.
- When captured from the macOS share sheet, StuffBucket should foreground and surface the new item quickly.
- Archive status badges should update live as the archive completes.

### 4.6 Why HTML, not PDF?
- Searchable
- Lightweight
- Preserves links and structure
- Future-proof

---

## 5. Metadata & Core Data model (amended)

### 5.1 Item entity (relevant fields)

- `id: UUID`
- `type: enum { snippet, link, document }`
- `title: String?`
- `textContent: String?`        // optional snippet body for any item
- `tags: [String]`              // includes regular tags and collection: prefixed tags
- `trashedAt: Date?`            // when item was moved to trash (nil = not trashed)
- `createdAt: Date`
- `updatedAt: Date`
- `collectionID: UUID?`         // legacy, unused - collections now via tags
- `source: enum { manual, share_sheet, safari_bookmarks, import }`
- `sourceExternalID: String?`   // stable ID for external sync (e.g. Safari)
- `sourceFolderPath: String?`   // external folder path (e.g. Safari bookmark folder)
- `documentRelativePath: String?` // Documents/<uuid>/<filename> (optional on any item)

#### Link-specific
- `linkURL: String?`           // optional on any item
- `linkTitle: String?`
- `linkAuthor: String?`
- `linkPublishedDate: Date?`
- `htmlRelativePath: String`   // Links/<uuid>/page.html
- `archiveStatus: enum { full, partial, failed }`
- `assetManifestJSON: String?` // JSON array of asset filenames for iCloud download
- `archiveZipData: Binary?`    // compressed archive bundle for CloudKit sync fallback

### 5.2 Derived / AI metadata (new)
- `aiSummary: String?`
- `aiArtifactsJSON: String?`   // structured AI outputs (key points, entities, tags)
- `aiModelID: String?`
- `aiUpdatedAt: Date?`

---

## 6. Sync model

### Metadata
- Core Data + `NSPersistentCloudKitContainer`
- CloudKit container: `iCloud.com.digitalhandstand.stuffbucketapp`
- Core Data schema remains CloudKit-compatible (non-optional attributes have defaults or are optional).
- Conflict resolution:
  - last-writer-wins for scalars
  - set merge for tags

### Files
- iCloud Drive handles sync.
- If iCloud storage is unavailable at write time, save locally and migrate into iCloud when the container becomes available (migration only touches `Links/` and `Documents/`, never the Core Data store).
- App watches for:
  - missing HTML files
  - externally modified files
- If HTML snapshot deleted externally:
  - show warning
  - allow re-fetch from original URL

---

## 7. Trash and deletion

### Soft delete
- Items can be moved to trash via a "Move to Trash" action in the item detail view.
- Trashed items are marked with a `trashcan` tag and `trashedAt` timestamp.
- Trashed items are hidden from the main view and search results.
- Searching for `trashcan` reveals trashed items.
- Trashed items can be restored via "Restore from Trash" action.
- Items in trash for more than 10 days are permanently deleted on app launch.

### Permanent deletion
- Permanent deletion removes:
  - The Core Data record (synced via CloudKit)
  - iCloud Drive archive files (Links/<uuid>/)
  - iCloud Drive document files (Documents/<uuid>/)
  - Local cache files
  - Search index entries
- Deletion propagates across devices via iCloud sync.

---

## 8. Debug tooling (temporary)
- Provide a temporary "Delete All Data" toolbar button to wipe Core Data items and stored files during development.
- This control is debug-only and should be removed before release.

---

## 9. Capture & import flows

### iOS / iPadOS Share Sheet
- In-app quick add:
  - New Snippet creates a text capture item immediately.
  - Add Link prompts for a URL and saves it as a Link item.
  - Import Document uses the Files picker and copies the file into StuffBucket/Documents.
- Saving a URL triggers:
  1. Immediate metadata save
  2. Background HTML fetch
  3. Archive status indicator
- Share extension captures URLs from Safari and queues them for the main app to import on launch.
- Share extension accepts URL attachments or plain-text URL payloads.
- iOS share sheet includes a comment field for optional snippets/tags.
- Share sheet comment text supports quotes for snippets: double quotes (straight/smart) and single quotes used as quote boundaries become `textContent` joined by newlines; apostrophes inside words and quotes inside quoted segments are ignored; unquoted tokens become tags (#tag supported).
- Share extension opens StuffBucket after capture to surface new items immediately.
- App listens for share-capture notifications to import while already running.
- Share extension bundle identifiers are prefixed by the main app bundle identifier.
- Share extension version numbers match the parent app.
- Share extension Info.plists include required bundle metadata for installation.
- App Group for share handoff storage: `group.com.digitalhandstand.stuffbucket.app`.
- macOS share extension follows the standard NSExtensionRequestHandling flow.
- On import, the app fetches metadata and persists an HTML snapshot when possible.

### macOS
- In-app quick add:
  - New Snippet creates a text capture item immediately.
  - Add Link prompts for a URL and saves it as a Link item.
  - Import Document uses a file picker and copies the file into StuffBucket/Documents.
- Paste URL
- Drag URL from browser
- Drag files from Finder to import documents.
- Services / Share menu
- Share extension captures URLs from Safari and queues them for the main app to import on launch.
- Share extension accepts URL attachments or plain-text URL payloads.
- Share extension opens StuffBucket after capture to surface new items immediately.
- Share sheet comment text supports quotes for snippets: double quotes (straight/smart) and single quotes used as quote boundaries become `textContent` joined by newlines; apostrophes inside words and quotes inside quoted segments are ignored; unquoted tokens become tags (#tag supported).
- The macOS app activates when opened via the share URL to bring new items into view.
- App listens for share-capture notifications to import while already running.
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
- Folder structure maps to `collection:` tags (e.g., `collection:Recipes`); a default `Safari` tag is applied.

---

## 10. UI behavior

### Browse
- Default view surfaces **Collections** and **Tags** with counts (collections first, then tags).
- Tags list shows regular tags only (excludes `collection:` prefixed tags).
- Collections list shows collection names extracted from `collection:` tags.
- Selecting a tag or collection pre-fills search with `tag:` / `collection:` filters.
- Recent items list is shown above tags and collections.
- Link items display an archive status badge (Pending / Archived / Partial / Failed).
- Empty states surface primary capture actions (Add Link, Import Document).

### Item detail
- Tag editing is available on the item detail view (comma-separated input).
- macOS tag input is left-aligned (no right-justified value column).
- Collection assignment is available separately from tag editing.
- macOS collection input is left-aligned (no right-justified value column).
- macOS tag/collection inputs omit placeholder text and are explicitly left-aligned.
- macOS content editor text is left-aligned.
- Tags display excludes `collection:` prefixed tags (shown in collections section).
- De-duplication based on URL + title + folder path; keep a sync link when possible.
- Document items show the filename and a "Show in Finder" action on macOS.
- macOS list rows expose "Show in Finder" for documents via context menu.

---

## 11. Search

### Scope
- Full-text search across:
  - Snippets
  - **Extracted text from saved HTML**
  - Filenames
  - User-added annotations
  - Tags, collections, and AI summaries (if present)

### Quality
- Relevance ranking with field weighting (title > tags > content).
- Diacritic-insensitive matching.
- Phrase search with quotes and prefix matching.

### Query features
- Filters: `type:`, `tag:`, `collection:`, `source:`.
- Tag/collection filters quote values with punctuation so hyphenated tags match (e.g. `tag:customer-service`).
- Sort by relevance or recency.
- macOS tag list supports command-click to accumulate multiple tag filters in the search bar.

### Indexing
- Incremental indexing as items change.
- Seed/rebuild the index on app launch to reconcile deletes while the app was closed.
- Background reindex if HTML snapshots or files update.
- Index remains local and is rebuilt if corrupted.

### Performance
- Typical queries return in <200ms on device.
- Large archives remain responsive with streaming results.

## 12. Safari Bookmarks import (macOS only)

### Import behavior
- Bulk import creates Link items with `source = safari_bookmarks`.
- Preserve bookmark titles and URLs; store Safari folder path in `sourceFolderPath`.
- Optional "Archive on import" to fetch HTML in the background.
- For HTML export imports, retain a synthetic `sourceExternalID` derived from URL + path.

### Duplicate handling
- De-dup by `sourceExternalID` when present; fall back to URL + folder path.
- If a URL already exists, merge metadata and keep the earliest Item ID.

## 13. AI Integration (Claude & OpenAI)

### Capabilities
- **Tag suggestions** for items based on content analysis.
- AI analyzes item title, snippet, URL, and archived article text.
- Suggestions prefer existing library tags over creating new ones.
- Actions are always user-initiated (manual "Suggest Tags" button).

### Supported Providers
- **Anthropic Claude** (claude-sonnet-4, claude-opus-4, claude-3.5-sonnet, claude-3.5-haiku)
- **OpenAI GPT** (gpt-4o, gpt-4o-mini, gpt-4-turbo, gpt-3.5-turbo)
- User selects provider and model in AI Settings.
- Default models: `claude-sonnet-4-20250514` (Anthropic), `gpt-4o` (OpenAI).

### Authentication and Storage
- BYOK (bring your own key) - user provides their own API keys.
- Keys stored in both iCloud Key-Value Store (cross-device sync) and UserDefaults (local fallback).
- Keys are never logged or exported.
- API key validation on save (test request to verify key works).

### Tag Suggestion Flow
1. User opens item detail view.
2. User taps "Suggest Tags" button (visible when API key is configured).
3. Sheet displays with loading state while AI analyzes content.
4. Suggested tags shown with checkboxes (all pre-selected by default).
5. Tags already in library marked with "existing" badge.
6. User reviews, adjusts selection, and taps "Apply" to add tags.

### Privacy
- Content sent to AI includes: title, snippet (truncated), URL, article text (truncated).
- No automatic/background AI calls - always user-initiated.
- AI outputs (suggested tags) are applied directly to items, not stored separately.


---

## 14. UX expectations for links

- Badge showing:
  - "Archived" / "Partial" / "Live only"
- Clear disclosure:
  - "This page is saved locally"

---

## 15. Edge cases

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

## 16. Acceptance criteria

- Saved NYTimes article remains readable offline after original URL changes.
- HTML file visible in iCloud Drive.
- Search finds words inside archived articles.
- Safari import can ingest 500+ bookmarks on macOS.
- User can generate AI tag suggestions using their API key and apply them to items.

---

## 17. Versioning
- v0.2: HTML-backed link persistence
- v0.3: Full-text search, Safari bookmarks import, AI tag suggestions (Claude & OpenAI)

---

## 18. Quality checks (engineering)
- Unit tests cover search query parsing/builder output, tag list encoding/decoding, and link metadata parsing with HTML entity decoding on both iOS and macOS targets.
- macOS unit tests run with an app host configuration so Xcodegen builds execute them reliably.
- Core Data item creation in tests uses context-scoped entity lookup to avoid entity ambiguity warnings when multiple models load.
- Xcodegen project generation mirrors Xcode-recommended settings for macOS targets (app sandbox/network/app groups), asset symbol generation, and the current Xcode version.

---

_End of specification_
