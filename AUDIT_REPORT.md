# OrpheusUI Code Audit Report

## Critical Bugs

### 1. `prepareRuntime` skips credentials stripping on first launch
**`RuntimeLocator.swift:75-77`**

```swift
guard !fileManager.fileExists(atPath: settingsURL.path) else {
    return  // returns immediately if settings.json already exists
}
```

If the template was already copied but `prepareRuntime` is called again (e.g., after app restart on a new machine), neither the copy nor the credential stripping runs. The settings file may contain stale credentials from a previous user or build.

Additionally, on **line 81-82**, the old runtime folder is deleted unconditionally before `copyRuntimeTemplate`:
```swift
if fileManager.fileExists(atPath: runtimeProjectURL.path) {
    try fileManager.removeItem(at: runtimeProjectURL)
}
try copyRuntimeTemplate(from: template, to: runtimeProjectURL)
```
If the copy fails partway through (disk full, permissions), the old working runtime is gone with no recovery path.

---

### 2. Race condition in `OrpheusRunner.cancel()` with `onTermination`
**`OrpheusRunner.swift:133-135, 220-225`**

```swift
continuation.onTermination = { [weak self] _ in
    self?.cancel()
}
```

`markFinished()` sets `finished = true` then `process = nil`. Between these two statements, `cancel()` called from another thread could snapshot `finished = true` and return early, leaving `process` non-nil but unreachable — a leaked Process.

The `terminationHandler` and `onTermination` callbacks may interleave: `terminationHandler` calls `markFinished()` → `process = nil`, then `onTermination` calls `cancel()` which captures `mainProcess = nil` and does nothing. This is benign but fragile.

---

### 3. `AsyncThrowingStream` continuation yielded from `FileHandle.readabilityHandler`
**`OrpheusRunner.swift:104-109`**

```swift
let handleData: (Data) -> Void = { [weak self] data in
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
    self?.appendOutput(text)
    for event in parser.events(from: text) {
        continuation.yield(event)  // called on FileHandle's background thread
    }
}
```

`readabilityHandler` fires on an arbitrary background thread managed by Foundation. `AsyncThrowingStream.Continuation.yield()` is not documented as thread-safe and is not `Sendable`. Should dispatch to a known serial context.

---

### 4. `RunnerOutputParser` uses `NSLock` — thread safety on concurrent queue
**`OrpheusRunner.swift:322-323`**

```swift
private final class RunnerOutputParser {
    private let lock = NSLock()
```

Combined with issue #3, if the readability handler fires on multiple threads for stdout and stderr simultaneously, both call `parser.events(from:)` which locks. `NSLock` blocks the calling thread, which can cause priority inversions with Swift concurrency's cooperative thread pool. Migrate to `OSAllocatedUnfairLock` or an actor.

---

## High-Severity Issues

### 5. `revealInFinder` shows the download root, not the specific file
**`MainViewModel.swift:680-687`**

```swift
func revealInFinder(id: UUID) {
    guard let item = downloads.first(where: { $0.id == id }),
          case .completed = item.status else { return }
    let root = runtime.resolvedDownloadURL(from: settings?.downloadPath ?? "")
    NSWorkspace.shared.activateFileViewerSelecting([root])
}
```

This always selects the **download root directory**, ignoring the specific item being downloaded. The user clicks "Show in Finder" expecting to see the album/track they just downloaded, but instead only sees the top-level downloads folder. The path should be constructed from the item's URL (e.g., `root.appendingPathComponent(albumName)`).

---

### 6. `DownloadPreflightError` is `private` — blocks unit testing
**`MainViewModel.swift:1725`**

```swift
private enum DownloadPreflightError: LocalizedError { ... }
```

The error type used throughout the preflight pipeline is `private`, making it inaccessible from test targets. Tests can use the `FakeQobuzService` mock but cannot catch or verify specific `DownloadPreflightError` cases.

**Fix:** Change to `internal` or `package`.

---

### 7. `isPreflighting` can get stuck `true` forever
**`MainViewModel.swift:916-949`**

```swift
isPreflighting = true
queueNotice = ...
Task { [weak self] in
    guard let self else { return }
    do {
        try await verifyRemoteAvailability(for: context)
    } catch {
        isPreflighting = false
        presentPreflightFailure(error.localizedDescription)
        return
    }
    isPreflighting = false
    // ...
}
```

If the `Task` is cancelled externally (e.g., view dismissed, app backgrounded) while `verifyRemoteAvailability` is running, the `catch` block may not set `isPreflighting = false` because cancellation throws `CancellationError` which is caught by the `catch` — but the `catch` does set `isPreflighting = false`. However, if `self` is deallocated before the task completes, neither branch runs and `isPreflighting` stays `true`, permanently blocking all future downloads until app restart.

**Fix:** Use a `defer { isPreflighting = false }` or reset in `catch` regardless of self validity.

```swift
Task { [weak self] in
    defer { self?.isPreflighting = false }
    // ...
}
```

---

### 8. Stale `qobuzAPI` reference during preflight
**`MainViewModel.swift:921-948`**

```swift
Task { [weak self] in
    guard let self else { return }
    try await verifyRemoteAvailability(for: context)
    // ...
}
```

`verifyRemoteAvailability` captures `qobuzAPI` from `self`, but if the user opens Settings and changes credentials during the preflight, the preflight uses the **old** API instance. This can lead to confusing "invalid credentials" errors when the user just entered valid ones, or worse, the preflight succeeds with old credentials and the download uses new ones.

---

## Medium-Severity Issues

### 9. `loadSettings()` called from `onAppear` — no error recovery
**`ContentView.swift:30`**

```swift
.onAppear { vm.loadSettings() }
```

If `loadSettings()` fails during `prepareRuntime()` (e.g., missing bundle template, permission denied), `settings` remains `nil` forever. The user sees an error preview but has no way to retry. They must restart the app. There's no retry button or automatic recovery.

---

### 10. `cancelActiveDownload` may mark completed downloads as cancelled
**`MainViewModel.swift:1280-1289`**

```swift
private func cancelActiveDownload() {
    activeDownloadTask?.cancel()
    if let activeDownloadID {
        runners[activeDownloadID]?.cancel()
    }
    if let activeDownloadID, let activeQueueID {
        markCancelled(downloadID: activeDownloadID, queueID: activeQueueID)
    }
}
```

`activeDownloadTask?.cancel()` cooperatively cancels the task. But the `for try await event in stream` loop in `runQueuedDownload` may have already finished (stream completed, status set to `.completed`) before `cancel()` is called. Then `markCancelled` overwrites the `.completed` status with `.cancelled` — giving the user a false "cancelled" status for a download that actually succeeded.

**Fix:** Check if the download is already finished before marking cancelled:
```swift
if let activeDownloadID, let activeQueueID,
   let download = downloads.first(where: { $0.id == activeDownloadID }),
   case .downloading = download.status {
    markCancelled(downloadID: activeDownloadID, queueID: activeQueueID)
}
```

---

### 11. `clearQueue` logic has edge cases with active downloads
**`MainViewModel.swift:565-578`**

```swift
let selectedWasRemoved = selectedQueueID.map { selected in
    queuedLinks.contains { $0.id == selected && !$0.state.isActive }
} ?? false
queuedLinks.removeAll { !$0.state.isActive }
```

If the selected item is `.downloading` (active), `selectedWasRemoved` is `false`, and the item is not removed. The notification says "Cleared finished and waiting queue rows" but if there were no such rows, the user sees this message with no visible change. The message should reflect what actually happened.

---

### 12. `QobuzLinkExtractor` URL regex misses trailing quotes
**`QobuzURLParser.swift:136, 178-183`**

```swift
guard let regex = try? NSRegularExpression(pattern: #"(https?://[^\s<>"']+)"#) ...
```

The regex excludes `"` and `'` from the URL match, so `https://open.qobuz.com/album/123"` becomes `https://open.qobuz.com/album/123` — correct. But `cleanCandidate` only strips `.,;:!?)]}`, not `"` or `'`. So with a URL like `https://open.qobuz.com/album/123".`, the regex match would be `https://open.qobuz.com/album/123` (the `"` excluded), but then `cleanCandidate` strips the trailing `.` — fine. However, if the regex matched without stripping the quote, it would appear in the candidate and cause a parse failure. This is mostly fine in practice but the list of stripping characters should match the regex exclusions for consistency.

---

### 13. `QobuzTracksContainer` custom decoder silently drops unparseable tracks
**`QobuzModels.swift:182-186`**

```swift
if let track = try? tracks.decode(QobuzTrackRef.self) {
    decoded.append(track)
} else {
    _ = try? tracks.decode(JSONValue.self)  // skip silently
}
```

If a track fails to decode (e.g., missing `id` field due to API change), it's silently discarded. The user sees fewer tracks than expected with no error or warning. This defensive coding could mask real API breaking changes.

---

### 14. `ForEach` with index-based identifiers in browse views
**`SearchResultsView.swift:63`, `ArtistDetailView.swift:19`, `AlbumDetailView.swift:19`**

```swift
ForEach(albums.indices, id: \.self) { index in
    BrowseAlbumRow(album: albums[index])
```

Using array indices as `id` makes SwiftUI identity unstable — if items are removed or the array is replaced, diffing may produce incorrect animations or state retention issues. Since browse results are replaced wholesale, this is unlikely to cause visible bugs in practice but violates SwiftUI best practices. Items with stable IDs should use those instead.

---

### 15. `applyPreviewSummary` doesn't set `coverURL` for playlists/collections
**`MainViewModel.swift:899-902`**

```swift
case .loadedCollection(let info):
    queuedLinks[index].title = info.title
    queuedLinks[index].subtitle = info.subtitle
    // coverURL never set
```

All other cases set `coverURL`. Playlist items in the queue will always show the fallback icon even if the API returns cover art. Not a bug per se (playlists don't have standard covers in the Qobuz API), but inconsistent.

---

### 16. `OrpheusRunner.parseProgress` regex uses fragile `.*?` between capture groups
**`OrpheusRunner.swift:232`**

```swift
let pattern = #"([0-9]+(?:\.[0-9]+)?)%.*?([0-9]+(?:\.[0-9]+)?\s*(?:[KMGTPE]?i?B|[KMGTPE]?B|B)?)/([0-9]+(?:\.[0-9]+)?\s*(?:[KMGTPE]?i?B|[KMGTPE]?B|B)?).*?([0-9]+(?:\.[0-9]+)?\s*(?:[KMGTPE]?i?B|[KMGTPE]?B|B)/s)"#
```

The `.*?` non-greedy matches between groups will match *anything*, including other numbers. If tqdm output format changes (e.g., adds a new percentage field), this could silently capture wrong values. Use more specific separators or anchor on known tqdm output patterns.

---

## Low-Severity / Code Quality Issues

### 17. Duplicate `formatDuration` functions
**`SearchResultsView.swift:469-473` and `PreviewViews.swift:270-278`**

`formatBrowseDuration` formats as `m:ss`, while `formatDuration` formats as `h:mm:ss` (for hours). These should be consolidated into a single parameterized utility function.

---

### 18. `JSONValue` decoder converts all integers to `Double`
**`JSONValue.swift:17-18`**

```swift
} else if let value = try? container.decode(Double.self) {
    self = .number(value)
```

Integer `42` becomes `Double(42.0)`, which when re-encoded writes `42.0` instead of `42`. This causes minor JSON formatting diffs and could break downstream consumers that expect integer values. Since this is only used for OrpheusDL settings, the Python JSON parser handles both, so risk is minimal.

---

### 19. Inconsistent Qobuz URL host validation
**`QobuzURLParser.swift:85`** — `parse()` accepts `open.qobuz.com`, `play.qobuz.com`, `www.qobuz.com`.  
**`QobuzURLParser.swift:191`** — `isQobuzURL()` accepts `qobuz.com` or `*.qobuz.com`.

URLs like `api.qobuz.com` would be marked invalid by `parse()` but `isQobuzURL()` would count them as Qobuz URLs. This means they show up as "invalid Qobuz URLs" in link extraction, which is confusing when they look like Qobuz URLs to the user.

---

### 20. `TrackPreviewInfo.year` defaults to 0
**`QobuzModels.swift:414`**

```swift
year = Int((album.releaseDateOriginal ?? "").prefix(4)) ?? 0
```

The views handle `info.year > 0` to suppress display, but the property itself returning `0` for an unknown year is semantically misleading. Should be `Int?` (optional).

---

### 21. `JSONValue.hasPythonTruthyValue` defined in `QobuzAPI.swift` instead of `JSONValue.swift`
**`QobuzAPI.swift:280-296`**

The `hasPythonTruthyValue` extension on `JSONValue` lives in `QobuzAPI.swift` rather than `JSONValue.swift` or its own file. This is a discoverability issue — the property appears to be missing when reading `JSONValue.swift`.

---

### 22. `max` used on `completedTracks`/`completedAlbums` may skip updates
**`OrpheusRunner.swift:354, 366, 390, 401`**

```swift
completedTracks = max(completedTracks, marker.current - 1)
```

Using `max` means the counter can only increase. If tqdm output restarts or resets (e.g., retry logic in orpheus), the parser cannot track the reset. In normal operation this is fine, but it could produce stale "3/5 tracks" progress after a retry restarts the count.

---

### 23. `SettingsDocument.stripLocalCredentials` resets codec conversions to empty object
**`JSONValue.swift:125-127`**

```swift
if disableConversions {
    setValue(.object([:]), at: ["global", "advanced", "codec_conversions"])
}
```

If the user had a non-object JSON type at `codec_conversions`, this silently overwrites it with an empty object. While `setValue` correctly creates intermediate nodes, the user's prior configuration (e.g., a string label) is lost without warning.

---

### 24. `max` on `SeenIDs` / `canonicalURLs` — deduplication uses canonical URL only
**`QobuzURLParser.swift:161-164`**

```swift
guard !seen.contains(canonical) else {
    result.duplicateCount += 1
    continue
}
seen.insert(canonical)
```

Deduplication is based solely on the canonical URL (e.g., `https://open.qobuz.com/album/123`). Two different Qobuz URLs that resolve to the same canonical URL are correctly deduplicated, but URLs for the same album from different regional domains (e.g., `www.qobuz.com/de-de/album/123` vs `open.qobuz.com/album/123`) are also deduplicated correctly. No bug here, but the de-duplication strategy should be documented.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 4 |
| High | 4 |
| Medium | 8 |
| Low | 8 |

### Top Priorities to Fix (ordered by impact)

1. **`revealInFinder`** shows root folder instead of downloaded content — user-facing broken feature
2. **`isPreflighting`** can get stuck `true` — blocks all future downloads until restart
3. **Race condition** in `OrpheusRunner.cancel()` — potential Process leak
4. **No error recovery** after `loadSettings` failure — user stuck, must restart app
5. **`cancelActiveDownload`** marks completed downloads as cancelled — confusing UX
6. **Stale `qobuzAPI` reference** during preflight — credentials change during preflight causes confusion
7. **`DownloadPreflightError` is `private`** — blocks proper unit testing
8. **`AsyncThrowingStream` thread safety** — continuation called from arbitrary threads
