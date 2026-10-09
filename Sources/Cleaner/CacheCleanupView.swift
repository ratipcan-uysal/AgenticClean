import AppKit
import CleanerCore
import SwiftUI

struct CacheCleanupView: View {
  @Environment(\.closeCleanerPanel) private var dismiss
  @Environment(\.setCleanerPanelBusy) private var setPanelBusy
  @State private var engine = CacheCleanupEngine()
  @State private var plan: CacheCleanupPlan?
  @State private var selected: Set<UUID> = []
  @State private var results: [CacheCleanupResult] = []
  @State private var busy = false
  @State private var error: String?
  @State private var confirming = false
  @State private var scanTask: Task<Void, Never>?
  @AppStorage("cleanerLanguage") private var language = "tr"

  private func text(_ tr: String, _ en: String) -> String { language == "en" ? en : tr }
  private var selectedBytes: UInt64 {
    plan?.candidates.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.bytes } ?? 0
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Image(systemName: "externaldrive.badge.checkmark").font(.title).foregroundStyle(.teal)
        VStack(alignment: .leading, spacing: 4) {
          Text(text("Disk alanını gözden geçir", "Review disk space")).font(.title2.bold())
          Text(
            text(
              "Önce incele, sonra seçtiklerini Çöp Sepeti’ne taşı.",
              "Review first, then move selected items to Trash.")
          )
          .foregroundStyle(.secondary)
        }
      }
      Text(
        text(
          "Bu sürüm yalnızca doğrulanmış Xcode derleme çıktılarını tarar. Codex, Claude ve Cursor verileri, sohbetler, kaynak kodu, simülatör verileri ve ayarlar bu temizliğe dahil değildir.",
          "This version scans verified Xcode build outputs only. Codex, Claude and Cursor data, chats, source code, simulator data and settings are outside this cleanup scope."
        )
      ).font(.callout).fixedSize(horizontal: false, vertical: true)
      if confirming { confirmationSummary }
      if !results.isEmpty {
        resultList
      } else if let plan {
        if plan.candidates.isEmpty {
          ContentUnavailableView(
            text("Uygun derleme çıktısı bulunamadı", "No eligible build outputs found"),
            systemImage: "checkmark.shield",
            description: Text(
              text(
                "Bu, tüm diskin temiz olduğu anlamına gelmez. Özel Xcode konumları taranmaz.",
                "This does not mean your whole disk is clean. Custom Xcode locations are not scanned."
              )))
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
              ForEach(plan.candidates) { candidate in candidateRow(candidate) }
            }.padding(12)
          }.background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
        ForEach(plan.notices, id: \.self) { notice in
          Text(localizedNotice(notice)).font(.caption).foregroundStyle(.secondary)
        }
      } else if busy {
        Spacer()
        ProgressView(text("Derleme çıktıları ölçülüyor…", "Measuring build outputs…"))
          .frame(maxWidth: .infinity)
        Spacer()
      } else {
        Spacer()
      }
      if let error {
        Text(localizedNotice(error)).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
      }
      Text(
        text(
          "Disk alanı, Çöp Sepeti’ni Finder’dan boşalttığında geri kazanılır. RAM temizlenmez. Gerektiğinde Finder → Çöp Sepeti → Geri Koy ile geri alabilirsin.",
          "Disk space is reclaimed after you empty Trash in Finder. This does not free RAM. To restore items, use Finder → Trash → Put Back."
        )
      ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      controls
    }
    .padding(24).frame(width: 650, height: 640)
    .task { startScan() }
    .onDisappear { scanTask?.cancel() }
    .onChange(of: busy, initial: true) { _, value in setPanelBusy(value) }
    .onExitCommand { if !busy { dismiss() } }
  }

  private var confirmationSummary: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text("Seçili klasörleri Çöp Sepeti’ne taşı?", "Move selected folders to Trash?"))
        .font(.headline)
      Text(
        text(
          "\(selected.count) klasör · \(Format.bytes(selectedBytes)). Aşağıdaki işaretli klasörler taşınacak. Xcode bu çıktıları sonraki derlemede yeniden oluşturur; derleme daha uzun sürebilir. Çalışan projeler ve değişen dosyalar tekrar kontrol edilir. Çöp Sepeti otomatik boşaltılmaz.",
          "\(selected.count) folders · \(Format.bytes(selectedBytes)). The checked folders below will be moved. Xcode recreates these outputs on the next build, which may take longer. Active projects and changed files are checked again. Trash is not emptied automatically."
        )
      ).font(.callout).fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
  }

  private var controls: some View {
    HStack {
      Button(text("Kapat", "Close")) { if !busy { dismiss() } }
        .disabled(busy)
      if !confirming {
        Button(text("Yeniden tara", "Scan again")) { startScan() }.disabled(busy)
      }
      Spacer()
      if busy { ProgressView().controlSize(.small) }
      if results.isEmpty {
        if confirming {
          Button(text("Seçime dön", "Back to selection")) { confirming = false }
            .disabled(busy)
          Button(text("Çöp Sepeti’ne taşı", "Move to Trash"), role: .destructive) {
            performCleanup()
          }.buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty)
        } else {
          Button(text("Seçimi incele", "Review selection") + " · " + Format.bytes(selectedBytes)) {
            confirming = true
          }.buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty)
        }
      }
    }
  }

  private func candidateRow(_ candidate: CacheCleanupCandidate) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        isOn: Binding(
          get: { selected.contains(candidate.id) },
          set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } }
        )
      ) {
        HStack {
          Text(candidate.name).font(.headline)
          Spacer()
          Text(Format.bytes(candidate.bytes)).monospacedDigit()
        }
      }.disabled(candidate.blockedReason != nil || busy || confirming)
      Text(candidate.projectPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      Text(candidate.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
      Text(
        text(
          "Xcode derleme çıktıları · \(candidate.fileCount) öğe · boyut tahmini",
          "Xcode build outputs · \(candidate.fileCount) items · estimated size")
      )
      .font(.caption).foregroundStyle(.secondary)
      if let blocked = candidate.blockedReason {
        Label(localizedNotice(blocked), systemImage: "lock").font(.caption).foregroundStyle(.orange)
      } else {
        Text(text("Sonraki derleme daha uzun sürebilir.", "The next build may take longer."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Divider()
    }
  }

  private var resultList: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        text(
          "\(results.filter(\.moved).count) klasör Çöp Sepeti’ne taşındı · \(results.filter { !$0.moved }.count) taşınamadı",
          "\(results.filter(\.moved).count) folders moved to Trash · \(results.filter { !$0.moved }.count) not moved"
        )
      ).font(.headline)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(results) { result in
            VStack(alignment: .leading, spacing: 5) {
              Label(
                result.name,
                systemImage: result.moved ? "checkmark.circle" : "exclamationmark.circle"
              )
              .foregroundStyle(result.moved ? .green : .orange)
              Text(result.path).font(.caption).textSelection(.enabled)
              if let error = result.error {
                Text(localizedNotice(error)).font(.callout).foregroundStyle(.orange)
              }
              if let path = result.trashPath {
                Text(
                  text("Çöp Sepeti’ne taşındı: ", "Moved to Trash: ") + Format.bytes(result.bytes)
                ).font(.caption)
                Button(text("Finder’da göster", "Show in Finder")) {
                  NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
              }
            }
            Divider()
          }
        }
      }
    }
  }

  private func startScan() {
    guard !busy else { return }
    confirming = false
    scanTask?.cancel()
    busy = true
    error = nil
    selected = []
    results = []
    plan = nil
    scanTask = Task {
      do { plan = try await engine.scan() } catch is CancellationError {} catch {
        self.error = error.localizedDescription
      }
      busy = false
    }
  }

  private func performCleanup() {
    guard let plan, !busy, confirming, !selected.isEmpty else { return }
    let ids = selected
    confirming = false
    busy = true
    error = nil
    Task {
      do { results = try await engine.moveToTrash(planID: plan.id, selectedIDs: ids) } catch {
        self.error = error.localizedDescription
        self.plan = nil
      }
      selected = []
      busy = false
    }
  }

  private func localizedNotice(_ value: String) -> String {
    guard language != "en" else { return value }
    let translations = [
      "Trash destination was not returned.": "Çöp Sepeti hedefi alınamadı.",
      "Select items from the current preview.": "Güncel önizlemeden öğe seç.",
      "This item cannot be cleaned.": "Bu öğe temizlenemiyor.",
      "Folder is outside the supported cleanup scope.":
        "Klasör desteklenen temizleme kapsamı dışında.",
      "Xcode's generated build-folder marker could not be verified.":
        "Xcode derleme klasörü işaretçisi doğrulanamadı.",
      "Project metadata is unsupported.": "Proje bilgisi desteklenen biçimde değil.",
      "Project identity could not be verified.": "Proje kimliği doğrulanamadı.",
      "Folder exceeds the bounded scan limit.": "Klasör tarama sınırını aşıyor.",
      "Folder includes another owner's files or a mounted volume.":
        "Klasör başka kullanıcıya ait dosyalar veya bağlı bir disk içeriyor.",
      "Folder includes an unsupported file type.": "Klasör desteklenmeyen bir dosya türü içeriyor.",
      "Folder size cannot be represented safely.": "Klasör boyutu güvenilir biçimde hesaplanamadı.",
      "Folder changed while being measured.": "Klasör ölçüm sırasında değişti.",
      "Only the first 200 DerivedData folders were checked.":
        "Yalnızca ilk 200 DerivedData klasörü kontrol edildi.",
      "The scan limit was reached. Unmeasured folders were excluded.":
        "Tarama sınırına ulaşıldı. Ölçülmeyen klasörler dışarıda bırakıldı.",
      "Some folders were excluded because their identity, generated-file marker or full size could not be verified.":
        "Kimliği, derleme işaretçisi veya toplam boyutu doğrulanamayan klasörler dışarıda bırakıldı.",
      "Some of your processes could not be checked. Cleanup is unavailable until activity can be verified.":
        "Bazı süreçlerin kontrol edilemedi. Etkinlik doğrulanana kadar temizleme yapılamaz.",
      "Quit Xcode and finish running builds before cleaning build outputs.":
        "Derleme çıktılarını temizlemeden önce Xcode’u kapat ve devam eden derlemelerin bitmesini bekle.",
      "A program is running from this build folder. Close it and scan again.":
        "Bu derleme klasöründen çalışan bir program var. Kapatıp yeniden tara.",
      "This project has an active process or terminal. Close it and scan again.":
        "Bu projede açık süreç veya terminal var. Kapatıp yeniden tara.",
      "This folder changed in the last minute. Wait and scan again.":
        "Bu klasör son bir dakikada değişti. Bekleyip yeniden tara.",
      "Preview expired. Scan again before confirming.":
        "Önizleme süresi doldu. Onaylamadan önce yeniden tara.",
      "Folder contents changed after preview. Nothing was moved; scan again.":
        "Önizlemeden sonra klasör değişti. Hiçbir şey taşınmadı; yeniden tara.",
      "Folder identity changed. Scan again.": "Klasörün kimliği değişti. Yeniden tara.",
      "Project metadata changed. Scan again.": "Proje bilgisi değişti. Yeniden tara.",
      "Symbolic links and non-directory ancestors are excluded.":
        "Sembolik bağlantılar ve klasör olmayan üst yollar kapsam dışıdır.",
    ]
    if let translated = translations[value] { return translated }
    let prefix = "Folder could not be read: "
    if value.hasPrefix(prefix), value.hasSuffix(".") {
      return "Klasör okunamadı: " + value.dropFirst(prefix.count)
    }
    return value
  }
}
