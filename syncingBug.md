# Archive Asset Sync Bug (macOS)

## Summary
When a link is archived on iOS, the macOS app receives the item metadata and
opens the HTML archive, but images/styles are missing. The HTML renders without
its asset files even though the archive exists on iOS.

## Status
Open issue. Prefetching assets on macOS before opening the HTML did not resolve
missing images.

## Repro Steps
1) On iOS (simulator), share a link to StuffBucket and wait for the archive to finish.
2) Confirm that `page.html`, `reader.html`, and `assets/` are created under:
   `.../Library/Mobile Documents/iCloud~com~digitalhandstand~stuffbucketapp/Documents/StuffBucket/Links/<ItemID>/`
3) On macOS, open the same item and click "Open Page Archive".

## Expected
The HTML archive opens with images/styles intact.

## Actual
The HTML archive opens but images/styles are missing.

## What We Tried
- macOS now tries to download the archive folder and assets before opening.
- A "Downloading archive assets..." UI state is shown while waiting.
- The HTML still opens without images.

## Observations
- Metadata syncs correctly; `page.html` opens.
- Asset files appear to be missing or not downloaded locally on macOS.
- The simulator's iCloud container contains assets, but the macOS iCloud
  container may not contain them at open time, so relative asset paths resolve
  to missing files.

## Suspected Causes
1) iCloud Drive sync is not delivering `assets/` files to macOS reliably
   (especially from the simulator container).
2) Folder download requests do not guarantee child file downloads.
3) There is no persisted manifest of asset filenames to explicitly request
   downloads on macOS.

## Proposed Fix (Recommended)
Persist a manifest of asset filenames and use it to drive explicit downloads on
macOS before opening the archive.

### Steps
1) Add a new field on `Item` (e.g. `assetManifestJSON`) that stores a JSON array
   of asset filenames written during archiving.
2) When archiving on iOS/macOS, write the manifest alongside `page.html` and
   `reader.html`.
3) On macOS, read the manifest and call `startDownloadingUbiquitousItem` for
   every asset file; wait until `ubiquitousItemDownloadingStatusKey == .current`
   for all files.
4) If assets are still missing after timeout, show a retry button and keep
   "Open Page Archive" disabled until assets are local.

### Alternate Fix (Fallback)
Package the archive as a single bundle (zip or .webarchive) so iCloud only needs
to sync a single file. Unpack locally before opening.
