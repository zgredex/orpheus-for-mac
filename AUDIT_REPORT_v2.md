# OrpheusUI Re-Audit Report (Post-Patches)

## Patches Verified as Fixed

### 1. `prepareRuntime` skips credentials stripping — **FIXED**
**`RuntimeLocator.swift:136-178`**
Now uses atomic staging: `installRuntimeTemplate` copies to a UUID-temp staging directory, calls `sanitizeCopiedSettings` (which strips creds), then commits via `replaceItemAt` (atomic on APFS). The old runtime is never deleted before the new one is fully ready.

### 2. Race condition in `OrpheusRunner.cancel()` — **FIXED**
**`OrpheusRunner.swift:223-234`**
`cancel()` now atomically sets `finished = true` and `self.process = nil` inside the same `lock.lock()`/`unlock()` block, eliminating the window where a leaked `Process` reference could persist.

### 3. `AsyncThrowingStream` thread safety — **FIXED**
**`OrpheusRunner.swift:97`**
Added `outputQueue: DispatchQueue` serial queue. All `continuation.yield()` and `continuation.finish()` calls (from `handleData` and `terminationHandler`) now dispatch via `outputQueue.async {}`.

### 4. `RunnerOutputParser` NSLock thread safety — **FIXED**
**`OrpheusRunner.swift:332`**
The `NSLock` was removed from `RunnerOutputParser`. The parser is now called exclusively from `outputQueue`, providing serialized access without blocking.

### 5. `revealInFinder` shows root folder — **FIXED**
**`MainViewModel.swift:725-733`**

`revealInFinder` now delegates to an injected `FinderRevealing` protocol and uses `item.resolvedOutputURL` (set by `DownloadOutputResolver` at download completion). The resolver scans the download root for the newest file/directory created after download start time.

### 6. `DownloadPreflightError` private — **FIXED**
**`MainViewModel.swift:1811`**
Changed from `private enum` to `enum DownloadPreflightError` (internal), accessible from tests.

### 7. `isPreflighting` stuck true — **FIXED**
**`MainViewModel.swift:971-977, 1346-1352`**

- Added `defer { self.isPreflighting = false; self.preflightTask = nil }` in the preflight task.
- Added explicit `cancelPreflight()` method, called by `cancelAllDownloads()`.
- Preflight task stored in dedicated `preflightTask` property with `Task.checkCancellation()` calls.

### 8. Stale `qobuzAPI` during preflight — **FIXED**
**`MainViewModel.swift:1176-1180, 1769-1774`**

- `DownloadPreflightContext` now includes `let api: any QobuzServicing`, captured at preflight start.
- `preflightQueuedDownloads` creates a fresh `QobuzAPI` if `qobuzAPI` is nil, preserving the API snapshot for the entire preflight lifecycle.
- `applySettings` (line 766-769) blocks settings changes during active preflight/download.

### 9. No error recovery after `loadSettings` failure — **FIXED**
**`ContentView.swift:82-86, 155-176`**

Added `settingsLoadFailed` published property. `ErrorPreviewView` now accepts an optional `retryAction` closure and renders a "Retry" button when `settingsLoadFailed` is true.

### 10. `cancelActiveDownload` marks completed as cancelled — **FIXED**
**`MainViewModel.swift:1365-1375`**

`markCancelled` now checks `download.status.isActive` and `queue.state.isActive` before overwriting status to `.cancelled`. Already-completed downloads are left intact.

### 11. `clearQueue` edge cases — **FIXED**
**`MainViewModel.swift:600-623`**

Now counts `removableCount` upfront and returns early with a specific message if zero items are removable. The notification text uses the exact count cleared.

---

## New Issues Found

### A. `cancelPreflight` race between `isPreflighting` and `preflightTask` assignment
**`MainViewModel.swift:966-1007` vs `1346-1352`**

```swift
// In startQueuedDownloads:
isPreflighting = true          // line 966

preflightTask = Task { ... }   // line 971 — assigned AFTER isPreflighting
```

```swift
// In cancelPreflight:
guard isPreflighting || preflightTask != nil else { return }
preflightTask?.cancel()         // nil if called between lines 966 and 971
isPreflighting = false
```

If `cancelPreflight` fires in the window between `isPreflighting = true` (line 966) and `preflightTask` assignment (line 971):
- `isPreflighting` is `true` — guard passes
- `preflightTask` is `nil` — `.cancel()` is a no-op
- `isPreflighting` is set to `false`
- The soon-to-be-created `preflightTask` runs independently with no `isPreflighting` tracking
- When the user retries, `preflightQueuedDownloads` sees `preflightTask != nil` and blocks
- The abandoned task's `defer` will eventually set `preflightTask = nil`, but not until it finishes — potentially minutes later

**Fix:** Swap the order — assign `preflightTask` first, then set `isPreflighting = true`.

---

### B. `DownloadOutputResolver` cutoff is 2 seconds — too narrow
**`MainViewModel.swift:1843`**

```swift
let cutoff = startedAt.addingTimeInterval(-2)
```

`startedAt` is captured at line 1020 when `runQueuedDownload` is called. But for large downloads (e.g., an artist with 200+ albums), the preflight phase can easily take 5-30 seconds verifying every album's availability. The actual `runDownload` call (line 1045) starts another `AsyncThrowingStream` which then launches the OrpheusDL process. The `startedAt` timestamp is from *before* all of this. If the full preflight + process launch takes >2 seconds, any files created within the window are outside the cutoff and won't be found.

**Fix:** Capture a new timestamp just before `runDownload` is called (line 1045), or widen the cutoff to 120+ seconds.

---

### C. `DownloadOutputResolver` picks wrong folder for concurrent completions
**`MainViewModel.swift:1848-1854`**

```swift
if let direct = candidates
    .filter({ $0.isDirectChild })
    .max(by: { $0.date < $1.date }) {
    return direct.url
}
return candidates.max(by: { $0.date < $1.date })?.url
```

The resolver returns the **single newest** file/directory in the root. If two downloads complete simultaneously (e.g., separate queue items both finishing), both calls to `resolveOutput` will return the same path — the newest folder, which belongs to whichever finished last. One "Show in Finder" will point to the wrong download.

**Fix:** Use a more specific heuristic (e.g., match the download URL to folder name patterns used by OrpheusDL), or have the OrpheusRunner stream return the output path.

---

### D. `NSLock` in `appendOutput` / `snapshotOutput` is dead code
**`OrpheusRunner.swift:308-314, 317-322`**

All callers of `appendOutput` and `snapshotOutput` now dispatch through `outputQueue.async {}`. The `NSLock` inside both methods is fully serialized by the queue — it acquires and releases immediately with zero contention. Not a functional bug, but wasted CPU cycles and misleading to readers. Remove the lock.

---

### E. `QobuzSearchArtist.stableBrowseID` defined but never used
**`QobuzModels.swift:263-265`**

```swift
var stableBrowseID: String {
    id?.value ?? name
}
```

This computed property is not referenced anywhere in the codebase. Dead code — either an incomplete feature or leftover from refactoring.

---

### F. `ForEach` with index identifiers still fragile
**`ArtistDetailView.swift:19`, `AlbumDetailView.swift:19`, `SearchResultsView.swift:63`**

```swift
ForEach(albums.indices, id: \.self) { index in
    BrowseAlbumRow(album: albums[index])
```

Using array indices as `id` breaks SwiftUI identity tracking, causing incorrect animations and potential state loss if results are updated incrementally. The items have stable IDs (e.g., `album.id.value`) — use those instead.

---

## Remaining Unfixed from Previous Audit

| # | Finding | File | Line |
|---|---|---|---|
| 1 | Duplicate `formatDuration` functions | `SearchResultsView.swift:469` / `PreviewViews.swift:270` | |
| 2 | `JSONValue` decodes all integers as `Double` | `JSONValue.swift:17-18` | |
| 3 | Inconsistent Qobuz URL host checking (`parse` vs `isQobuzURL`) | `QobuzURLParser.swift:85` vs `:191` | |
| 4 | `TrackPreviewInfo.year` defaults to `0` | `QobuzModels.swift:431` | |
| 5 | `hasPythonTruthyValue` extension lives in `QobuzAPI.swift` | `QobuzAPI.swift:280` | |
| 6 | Fragile tqdm progress regex (`.*?` between capture groups) | `OrpheusRunner.swift:241` | |
| 7 | `max` used for track/album counters — can't track resets | `OrpheusRunner.swift:354, 366, 390, 401` | |
| 8 | `stripLocalCredentials` overwrites non-object codec_conversions | `JSONValue.swift:126` | |
| 9 | `QobuzTracksContainer` / `QobuzSearchItems` silently skip unparseable items | `QobuzModels.swift:182-186, 320-324` | |

---

## Summary

| Category | Count |
|---|---|
| Verified fixed | 11 |
| New issues | 6 (1 medium, 5 low) |
| Remaining unfixed from v1 | 9 (all low) |

### Top priorities for next round:

1. **Fix `cancelPreflight` race** (A) — can soft-lock downloads for the session
2. **Fix `DownloadOutputResolver` cutoff** (B) — currently broken for large multi-album downloads
3. **Fix `DownloadOutputResolver` concurrency** (C) — wrong Finder target for simultaneous completions
4. **Remove dead `NSLock`** (D) — code cleanup
5. **Fix ForEach identifiers** (F) — SwiftUI correctness

The remaining 9 low-severity items from v1 are all cosmetic or defensive — no user-facing bugs.
