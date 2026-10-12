import AppKit
import CleanerCore
import Foundation
import Observation

@MainActor @Observable final class DiskWorkspaceModel {
  var results: [DiskScanResult] = []
  var manualPaths: [String] = []
  var unavailable: [String] = []
  var selectedProject: String?
  var cleanupPlan: CacheCleanupPlan?
  var checkedPaths = Set<String>()
  var selectedArtifacts = Set<UUID>()
  var cleanupResults: [CacheCleanupResult] = []
  var busy = false
  var moving = false
  var cancellationRequested = false
  var progress = ""
  var error: String?
  var capacity: UInt64?
  var available: UInt64?
  var volumeDate: Date?
  var task: Task<Void, Never>?
  let engine = CacheCleanupEngine()
  private let scanner = DiskProjectScanner()
  private var bookmarks: [Data] = []
  private var scopedURLs: [URL] = []
  init() { restoreBookmarks() }
  isolated deinit {
    task?.cancel()
    for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
  }
  var selected: DiskScanResult? { results.first { $0.id == selectedProject } }
  var candidates: [CacheCleanupCandidate] { cleanupPlan?.candidates ?? [] }
  var selectedCandidates: [CacheCleanupCandidate] { candidates.filter { selectedArtifacts.contains($0.id) } }
  var selectedBytes: UInt64 { selectedCandidates.reduce(0) { $0 + $1.bytes } }
  func candidates(for path: String) -> [CacheCleanupCandidate] {
    candidates.filter { $0.projectRoot == path }
  }
  func reviewedBytes(for path: String) -> UInt64? {
    let items = candidates(for: path)
    guard cleanupPlan != nil, checkedPaths.contains(path) || !items.isEmpty else { return nil }
    return items.reduce(0) { $0 + $1.bytes }
  }
  func addProject(replacing oldPath: String? = nil, suggested path: String? = nil) {
    guard !busy && !moving else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.prompt = L10n.text("Proje ekle", "Add project")
    if let path { panel.directoryURL = URL(fileURLWithPath: path) }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
      if let oldPath { removeManual(oldPath) }
      if !manualPaths.contains(url.path) { bookmarks.append(data) }
      UserDefaults.standard.set(bookmarks, forKey: "diskProjectBookmarks")
      restoreBookmarks()
      cleanupPlan = nil; selectedArtifacts = []
    } catch { self.error = error.localizedDescription }
  }
  private func restoreBookmarks() {
    for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
    scopedURLs = []; manualPaths = []; unavailable = []
    bookmarks = UserDefaults.standard.array(forKey: "diskProjectBookmarks") as? [Data] ?? []
    for data in bookmarks {
      var stale = false
      do {
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        if stale || !FileManager.default.fileExists(atPath: url.path) { unavailable.append(url.path) }
        else { manualPaths.append(url.path) }
      } catch { unavailable.append(L10n.text("Kayıtlı konum açılamadı", "Saved location unavailable")) }
    }
  }
  func removeManual(_ path: String) {
    guard !busy && !moving else { return }
    bookmarks.removeAll { data in
      var stale = false
      let resolved = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
      return resolved?.path == path || (resolved == nil && unavailable.contains(path))
    }
    UserDefaults.standard.set(bookmarks, forKey: "diskProjectBookmarks")
    restoreBookmarks()
    results.removeAll { $0.project.path == path }
    if selectedProject == path { selectedProject = nil }
    cleanupPlan = nil; selectedArtifacts = []
  }
  func scan(discovered: [String]) {
    guard !busy && !moving else { return }
    busy = true; cancellationRequested = false; error = nil; selectedArtifacts = []; cleanupResults = []; cleanupPlan = nil; checkedPaths = []
    let initialPaths = Array(Set(discovered + manualPaths)).sorted()
    let previousSelection = selectedProject
    results = []; selectedProject = nil
    task = Task {
      progress = L10n.text("Xcode proje bağlantıları kontrol ediliyor…", "Checking Xcode project links…")
      var xcodePaths: [String] = []
      do { xcodePaths = try await engine.discoveredXcodeProjects() }
      catch is CancellationError {} catch { self.error = error.localizedDescription }
      let paths = Array(Set(manualPaths)).sorted() + Array(Set(initialPaths + xcodePaths).subtracting(manualPaths)).sorted()
      var measured: [DiskScanResult] = []
      await refreshVolume()
      for (index, path) in paths.enumerated() {
        progress = "\(index + 1)/\(paths.count) · " + URL(fileURLWithPath: path).lastPathComponent
        let result: DiskScanResult
        if needsFolderApproval(path) {
          result = DiskScanResult(project: DiskProject(path: path), rootIdentity: nil, date: Date(), state: .inaccessible, bytes: nil, artifacts: [], notice: "approval")
        } else {
          result = await scanner.scan(DiskProject(path: path), excluding: paths)
        }
        measured.append(result)
        results = sort(measured)
        if Task.isCancelled {
          for unscanned in paths.dropFirst(index + 1) {
            measured.append(DiskScanResult(project: DiskProject(path: unscanned), rootIdentity: nil, date: Date(), state: .cancelled, bytes: nil, artifacts: [], notice: "cancelled"))
          }
          results = sort(measured)
          break
        }
      }
      if !Task.isCancelled {
        progress = L10n.text("Çıktıların kimliği ve etkinliği kontrol ediliyor…", "Checking output identity and activity…")
        do {
          let accessible = paths.filter { !needsFolderApproval($0) }
          cleanupPlan = try await engine.scan(projectPaths: accessible)
          checkedPaths = Set(accessible)
        }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
      }
      selectedProject = results.contains { $0.id == previousSelection } ? previousSelection : nil
      busy = false; cancellationRequested = false; progress = ""; task = nil
    }
  }
  // Avoid implicit TCC prompts that can indefinitely block a filesystem syscall.
  // Explicit folder-picker bookmarks grant only the user-selected locations.
  private func needsFolderApproval(_ path: String) -> Bool {
    if manualPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
    let protected: [FileManager.SearchPathDirectory] = [.documentDirectory, .desktopDirectory, .downloadsDirectory]
    return protected.compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first?.path }
      .contains { path == $0 || path.hasPrefix($0 + "/") }
  }
  func cancel() {
    guard busy else { return }
    cancellationRequested = true
    task?.cancel()
  }
  private func sort(_ items: [DiskScanResult]) -> [DiskScanResult] {
    items.sorted {
      if $0.bytes != $1.bytes { return ($0.bytes ?? 0) > ($1.bytes ?? 0) || ($0.bytes != nil && $1.bytes == nil) }
      return $0.project.path < $1.project.path
    }
  }
  func moveSelected() {
    guard let cleanupPlan, !busy, !moving, !selectedArtifacts.isEmpty else { return }
    let ids = selectedArtifacts
    moving = true; error = nil
    task = Task {
      do { cleanupResults = try await engine.moveToTrash(planID: cleanupPlan.id, selectedIDs: ids) }
      catch { self.error = error.localizedDescription }
      selectedArtifacts = []; self.cleanupPlan = nil
      // Re-measure affected roots after a successful move. This is part of the explicit cleanup,
      // not continuous disk scanning. It makes no claim about physically reclaimed space.
      let affected = Set(cleanupResults.filter(\.moved).compactMap { moved in
        cleanupPlan.candidates.first { $0.id == moved.id }.map { candidate in
          candidate.projectRoot
        }
      })
      let roots = results.map { $0.project.path }
      for path in affected {
        let measured = await scanner.scan(DiskProject(path: path), excluding: roots)
        results.removeAll { $0.project.path == path }; results.append(measured)
      }
      results = sort(results)
      await refreshVolume()
      moving = false; task = nil
    }
  }
  func refreshVolume() async {
    let value = await Self.volume()
    capacity = value.0; available = value.1; volumeDate = Date()
  }
  @concurrent private static func volume() async -> (UInt64?, UInt64?) {
    let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
    return (values?.volumeTotalCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil }, values?.volumeAvailableCapacity.flatMap { $0 >= 0 ? UInt64($0) : nil })
  }
}
