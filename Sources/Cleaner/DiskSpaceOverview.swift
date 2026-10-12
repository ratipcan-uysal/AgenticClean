import AppKit
import CleanerCore
import SwiftUI

struct DiskSpaceOverview: View {
  @Bindable var model: DiskWorkspaceModel
  let discovered: [String]
  @State private var confirming = false
  @AppStorage("cleanerLanguage") private var language = "tr"
  private var measuredBytes: UInt64 { model.results.compactMap(\.bytes).reduce(0, +) }
  private var reviewBytes: UInt64 { model.candidates.reduce(0) { $0 + $1.bytes } }
  private var lowSpace: Bool {
    guard let capacity = model.capacity, capacity > 0, let available = model.available else { return false }
    return Double(available) / Double(capacity) < 0.1
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      summary
      HStack(spacing: 10) {
        Button(L10n.text("Projeleri tara", "Scan projects")) { model.scan(discovered: discovered) }
          .buttonStyle(.borderedProminent).disabled(model.busy || model.moving)
        Button(L10n.text("Proje klasörü ekle…", "Add project folder…")) { model.addProject() }
          .disabled(model.busy || model.moving)
        if model.moving {
          ProgressView().controlSize(.small)
          Text(L10n.text("Seçilen çıktılar kontrol ediliyor ve Çöp Sepeti’ne taşınıyor…", "Checking selected outputs and moving them to Trash…")).font(.caption)
        }
        if model.busy {
          ProgressView().controlSize(.small)
          Text(model.cancellationRequested ? L10n.text("İptal isteniyor · macOS erişim penceresi açıksa önce yanıtla", "Cancelling · respond to any open macOS access prompt") : model.progress).font(.caption).lineLimit(2)
          Button(L10n.text("İptal", "Cancel")) { model.cancel() }.disabled(model.cancellationRequested)
        }
        Spacer(minLength: 0)
      }
      if !model.unavailable.isEmpty {
        Label(L10n.text("Erişim gerekiyor: kayıtlı konumu yeniden seç veya listeden çıkar.", "Access needed: select the saved location again or remove it."), systemImage: "folder.badge.questionmark")
          .font(.caption).foregroundStyle(AgenticPalette.warning)
        ForEach(model.unavailable, id: \.self) { path in
          HStack {
            Text(path).font(.caption).lineLimit(1)
            Button(L10n.text("Yeniden seç…", "Choose again…")) { model.addProject(replacing: path) }
            Button(L10n.text("Kaldır", "Remove")) { model.removeManual(path) }
          }
        }
      }
      if let error = model.error { Text(CleanupCopy.notice(error)).font(.callout).foregroundStyle(AgenticPalette.warning) }
      if !model.cleanupResults.isEmpty { resultSummary }
      if let plan = model.cleanupPlan, !plan.notices.isEmpty || !plan.exclusions.isEmpty {
        DisclosureGroup(L10n.text("Doğrulama ayrıntıları · \(plan.skippedCount) çıktı kapsam dışında", "Verification details · \(plan.skippedCount) outputs excluded")) {
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(plan.notices, id: \.self) { Text(CleanupCopy.notice($0)).font(.caption) }
              ForEach(plan.exclusions) { item in
                Text(item.path).font(.caption).textSelection(.enabled)
                Text(CleanupCopy.notice(item.reason)).font(.caption).foregroundStyle(AgenticPalette.warning)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 110)
        }
      }
      if model.results.isEmpty {
        ContentUnavailableView {
          Label(L10n.text("Projelerinin disk alanını incele", "Explore your projects' disk usage"), systemImage: "folder.badge.gearshape")
        } description: {
          Text(L10n.text("Çalışan işlerden bulunan projeleri tara veya kapalı bir projenin klasörünü ekle. Kaynak dosyaları, bağımlılıklar ve çıktılar ayrı gösterilir.", "Scan projects found from running work or add a closed project's folder. See source files, dependencies, and outputs separately."))
        } actions: {
          Text(L10n.text("\(Set(discovered + model.manualPaths).count) proje taramaya hazır", "\(Set(discovered + model.manualPaths).count) projects ready to scan"))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        GeometryReader { geometry in
          if let result = model.selected, geometry.size.width < 900 {
            inspector(result).frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            HSplitView {
              projectList.frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
              if let result = model.selected {
                inspector(result).frame(minWidth: 270, idealWidth: 310, maxWidth: 390, maxHeight: .infinity)
              }
            }
          }
        }
      }
      HStack {
        Text(L10n.text("Mantıksal dosya boyutları · kısmi ölçümler alt sınırdır. Diskte yer açmak RAM’i boşaltmaz.", "Logical file sizes · partial measurements are lower bounds. Freeing disk space does not free RAM."))
          .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
        Spacer()
        Button(L10n.text("Seçilen çıktıları incele…", "Review selected outputs…") + " · " + Format.bytes(model.selectedBytes)) { confirming = true }
          .disabled(model.selectedArtifacts.isEmpty || model.busy || model.moving)
      }
    }.id(language).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
      .task { await model.refreshVolume() }
      .onDisappear { if model.busy { model.cancel() } }
      .sheet(isPresented: $confirming) { confirmation }
      .onExitCommand {
        if model.busy { model.cancel() } else { model.selectedProject = nil }
      }
  }
  private var summary: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Label(L10n.text("Kullanılabilir", "Available") + "  " + Format.bytes(model.available), systemImage: "internaldrive")
          .font(.title2.weight(.semibold))
        Text("/ " + Format.bytes(model.capacity)).foregroundStyle(AgenticPalette.secondaryText)
        Spacer()
        if let date = model.volumeDate { Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(AgenticPalette.secondaryText) }
      }
      if let capacity = model.capacity, capacity > 0, let available = model.available {
        ProgressView(value: Double(capacity - min(available, capacity)), total: Double(capacity))
          .tint(lowSpace ? AgenticPalette.warning : AgenticPalette.accent)
      } else { Text(L10n.text("Disk kapasitesi okunamadı", "Volume capacity unavailable")).font(.caption) }
      if lowSpace { Label(L10n.text("Kullanılabilir alan %10’un altında", "Less than 10% available"), systemImage: "exclamationmark.circle").foregroundStyle(AgenticPalette.warning).font(.caption) }
      HStack(spacing: 30) {
        metric(L10n.text("İncelenen projelerde ölçülen alan", "Measured in scanned projects"), value: model.results.compactMap(\.bytes).isEmpty ? "—" : (model.results.contains { $0.state != .complete } ? "≥ " : "") + Format.bytes(measuredBytes))
        metric(L10n.text("Temizleme için incelenebilir çıktılar", "Outputs available for review"), value: model.cleanupPlan == nil ? "—" : Format.bytes(reviewBytes))
      }
      Text(L10n.text("Kullanıcı klasörünün bulunduğu disk. Çıktı boyutu kesin kazanılacak alan değildir; kullanımda olan çıktılar seçilemez.", "Volume containing your home folder. Output size is not guaranteed recoverable space; outputs in use cannot be selected."))
        .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
    }.padding(18).background(AgenticPalette.surface, in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgenticPalette.border.opacity(0.4)))
  }
  private func metric(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      Text(value).font(.title3.weight(.semibold)).monospacedDigit()
    }
  }
  private var projectList: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        HStack(spacing: 12) {
          Color.clear.frame(width: 18, height: 1)
          Text(L10n.text("Proje", "Project"))
        }.frame(maxWidth: .infinity, alignment: .leading)
        Text(L10n.text("Boyut ↓", "Size ↓")).frame(width: 82, alignment: .trailing)
        Text(L10n.text("Çıktılar", "Outputs")).frame(width: 82, alignment: .trailing)
        Text(L10n.text("Durum", "Status")).frame(width: 90, alignment: .leading)
      }.font(.caption.bold()).foregroundStyle(AgenticPalette.secondaryText).padding(12).background(AgenticPalette.surface)
      List(selection: $model.selectedProject) {
        ForEach(model.results) { result in
          HStack(spacing: 12) {
            Image(systemName: "folder").foregroundStyle(AgenticPalette.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
              Text(result.project.name).fontWeight(.semibold).lineLimit(1).help(result.project.name)
              Text(result.project.path).font(.caption).foregroundStyle(AgenticPalette.secondaryText).lineLimit(1).help(result.project.path)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text((result.bytes != nil && (result.state == .partial || result.state == .cancelled) ? "≥ " : "") + Format.bytes(result.bytes))
              .frame(width: 82, alignment: .trailing).monospacedDigit()
            Text(Format.bytes(model.cleanupPlan == nil ? nil : model.reviewedBytes(for: result.project.path)))
              .frame(width: 82, alignment: .trailing).monospacedDigit()
            Text(stateTitle(result.state)).font(.caption)
              .foregroundStyle(result.state == .complete ? AgenticPalette.secondaryText : AgenticPalette.warning)
              .frame(width: 90, alignment: .leading)
          }.padding(.vertical, 7).tag(result.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(result.project.name)
            .accessibilityValue(Format.bytes(result.bytes) + " · " + stateTitle(result.state) + " · " + result.project.path)
            .accessibilityHint(L10n.text("Dağılımı ve çıktıları incelemek için seç", "Select to inspect breakdown and outputs"))
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        }
      }.listStyle(.plain).scrollContentBackground(.hidden)
    }.background(AgenticPalette.list)
  }
  private func inspector(_ result: DiskScanResult) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(result.project.name).font(.title2.bold())
          Spacer()
          Button { model.selectedProject = nil } label: { Image(systemName: "arrow.left"); Text(L10n.text("Projeler", "Projects")) }.buttonStyle(.borderless)
            .accessibilityLabel(L10n.text("Ayrıntıyı kapat", "Close details"))
        }
        Text(result.project.path).font(.caption).textSelection(.enabled).foregroundStyle(AgenticPalette.secondaryText)
        Button(L10n.text("Finder’da göster", "Show in Finder")) {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.project.path)])
        }.font(.caption)
        Text(stateTitle(result.state)).font(.headline)
        Text(result.date, format: .dateTime.hour().minute()).font(.caption)
        if let notice = result.notice { Text(scanNotice(notice)).font(.caption).foregroundStyle(AgenticPalette.warning) }
        if result.state == .inaccessible {
          Button(L10n.text("Tarama için klasörü seç…", "Select folder to scan…")) {
            model.addProject(replacing: model.manualPaths.contains(result.project.path) ? result.project.path : nil, suggested: result.project.path)
          }.disabled(model.busy || model.moving)
          Text(L10n.text("Klasörü seçtikten sonra projeleri yeniden tara.", "Select the folder, then scan projects again.")).font(.caption)
        }
        Text(L10n.text("Ölçülen dağılım", "Measured breakdown")).font(.headline)
        ForEach(DiskCategory.allCases, id: \.self) { category in
          VStack(alignment: .leading, spacing: 5) {
            HStack { Text(categoryTitle(category)); Spacer(); Text(Format.bytes(result.bytes == nil ? nil : result.bytes(in: category))).monospacedDigit() }
              .font(.callout)
            ResourceMeter(fraction: result.bytes.flatMap { $0 > 0 ? Double(result.bytes(in: category)) / Double($0) : nil }, color: AgenticPalette.accent)
          }
        }
        Text(L10n.text("Dağılım dosya türü ve konumuna göre tahmindir; temizleme izni vermez. APFS klonları ve sıkıştırma fiziksel kullanımın farklı olmasına yol açabilir.", "Breakdown is inferred from file type and location, not cleanup permission. APFS clones and compression can change physical usage."))
          .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
        Divider()
        Text(L10n.text("Üretilen çıktıları incele", "Review generated outputs")).font(.headline)
        let candidates = model.candidates(for: result.project.path)
        if candidates.isEmpty {
          Text(model.busy ? L10n.text("Çıktı doğrulaması bekleniyor", "Waiting for output verification") : L10n.text("Desteklenen çıktı yok. Xcode Build, Next.js cache ve Vite önbelleği doğrulanırsa burada görünür.", "No supported output. Verified Xcode Build, Next.js cache, and Vite cache appear here."))
            .font(.callout).foregroundStyle(AgenticPalette.secondaryText)
        }
        if !candidates.isEmpty && candidates.allSatisfy({ $0.blockedReason != nil }) {
          Label(L10n.text("Çıktılar kullanımda veya doğrulama bekliyor", "Outputs in use or awaiting verification"), systemImage: "lock.shield")
            .font(.callout).foregroundStyle(AgenticPalette.warning)
        }
        ForEach(candidates) { candidate in
          Toggle(isOn: Binding(get: { model.selectedArtifacts.contains(candidate.id) }, set: { if $0 { model.selectedArtifacts.insert(candidate.id) } else { model.selectedArtifacts.remove(candidate.id) } })) {
            VStack(alignment: .leading, spacing: 4) {
              Text(CleanupCopy.title(candidate.provider)).fontWeight(.semibold)
              Text(Format.bytes(candidate.bytes)).monospacedDigit()
            }
          }.disabled(candidate.blockedReason != nil || model.busy || model.moving)
          Text(candidate.path).font(.caption).textSelection(.enabled)
          if let reason = candidate.blockedReason {
            Label(CleanupCopy.notice(reason), systemImage: "lock").font(.caption).foregroundStyle(AgenticPalette.warning)
          } else { Text(CleanupCopy.effect(candidate.provider)).font(.caption).foregroundStyle(AgenticPalette.secondaryText) }
          Divider()
        }
        let exclusions = model.cleanupPlan?.exclusions.filter { $0.path.hasPrefix(result.project.path + "/") } ?? []
        ForEach(exclusions) { exclusion in
          Text(exclusion.path).font(.caption).textSelection(.enabled)
          Text(CleanupCopy.notice(exclusion.reason)).font(.caption).foregroundStyle(AgenticPalette.warning)
        }
        if model.manualPaths.contains(result.project.path) {
          Button(L10n.text("İzlenen konumlardan kaldır", "Remove from saved locations")) { model.removeManual(result.project.path) }
            .disabled(model.busy || model.moving)
        }
      }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }.background(AgenticPalette.surface)
  }
  private var resultSummary: some View {
    DisclosureGroup(L10n.text("\(model.cleanupResults.filter(\.moved).count) klasör Çöp Sepeti’ne taşındı · sonuçları göster", "\(model.cleanupResults.filter(\.moved).count) folders moved to Trash · show results")) {
      ScrollView {
        ForEach(model.cleanupResults) { result in
          VStack(alignment: .leading, spacing: 5) {
            Text(result.path).font(.caption).textSelection(.enabled)
            Text(result.moved ? L10n.text("Çöp Sepeti’ne taşındı", "Moved to Trash") : CleanupCopy.notice(result.error ?? ""))
              .font(.caption).foregroundStyle(result.moved ? AgenticPalette.accent : AgenticPalette.warning)
            if let path = result.trashPath {
              Button(L10n.text("Finder’da göster", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
          }.padding(.vertical, 5)
        }
      }.frame(maxHeight: 140)
    }
  }
  private var confirmation: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.text("Seçili çıktıları Çöp Sepeti’ne taşı?", "Move selected outputs to Trash?")).font(.title2.bold())
      Text(L10n.text("\(model.selectedCandidates.count) klasör · \(Format.bytes(model.selectedBytes)). Proje etkinliği ve dosyalar tekrar doğrulanacak.", "\(model.selectedCandidates.count) folders · \(Format.bytes(model.selectedBytes)). Project activity and files will be checked again."))
      ScrollView {
        ForEach(model.selectedCandidates) { candidate in
          VStack(alignment: .leading, spacing: 6) {
            Text(CleanupCopy.title(candidate.provider)).font(.headline)
            Text(candidate.path).font(.callout).textSelection(.enabled)
            Text(Format.bytes(candidate.bytes)).monospacedDigit()
            Text(CleanupCopy.effect(candidate.provider)).foregroundStyle(AgenticPalette.secondaryText)
          }.padding(.vertical, 10)
          Divider()
        }
      }
      Text(L10n.text("Çöp Sepeti otomatik boşaltılmaz. Finder → Çöp Sepeti → Geri Koy ile geri alabilirsin. Taşıma RAM’i boşaltmaz; fiziksel alan kazancı farklı olabilir.", "Trash is not emptied automatically. Restore with Finder → Trash → Put Back. Moving files does not free RAM; physical space recovered may differ."))
        .font(.caption).foregroundStyle(AgenticPalette.secondaryText)
      HStack {
        Button(L10n.text("Vazgeç", "Cancel")) { confirming = false }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(L10n.text("Çöp Sepeti’ne taşı", "Move to Trash"), role: .destructive) { confirming = false; model.moveSelected() }
          .disabled(model.busy || model.moving || model.selectedArtifacts.isEmpty)
      }
    }.padding(24).frame(width: 600, height: 500).preferredColorScheme(.dark)
      .background(AgenticPalette.canvas).foregroundStyle(AgenticPalette.text).tint(AgenticPalette.accent)
  }
  private func stateTitle(_ state: DiskScanState) -> String {
    switch state {
    case .complete: L10n.text("Tam ölçüm", "Complete")
    case .partial: L10n.text("Kısmi ölçüm", "Partial")
    case .inaccessible: L10n.text("Erişim gerekiyor", "Access needed")
    case .cancelled: L10n.text("Tarama iptal edildi", "Scan cancelled")
    }
  }
  private func categoryTitle(_ category: DiskCategory) -> String {
    switch category {
    case .source: L10n.text("Kaynak dosyaları", "Source files")
    case .dependencies: L10n.text("Bağımlılıklar", "Dependencies")
    case .outputs: L10n.text("Üretilen çıktılar", "Generated outputs")
    case .other: L10n.text("Diğer dosyalar", "Other files")
    }
  }
  private func scanNotice(_ value: String) -> String {
    switch value {
    case "approval": L10n.text("Bu korumalı konumu taramak için klasör seçicide projeyi seç. Diğer projelerin taraması devam eder.", "Select this project in the folder picker before scanning this protected location. Other projects can still be scanned.")
    case "limit": L10n.text("Tarama sınırına ulaşıldı; ölçülen boyut alt sınırdır.", "Scan limit reached; measured size is a lower bound.")
    case "cancelled": L10n.text("Tamamlanmayan ölçümler sıfır sayılmaz. Yeniden tara.", "Incomplete measurements are not zero. Scan again.")
    case "excluded": L10n.text("AI araçlarına ait özel veriler tarama dışında bırakıldı.", "Private AI tool data was excluded.")
    case "links": L10n.text("Sembolik bağlantı hedefleri taranmadı.", "Symbolic link targets were not scanned.")
    default: L10n.text("Bazı dosyalar okunamadı veya tarama sırasında değişti. Boyut alt sınırdır.", "Some files were unreadable or changed during scanning. Size is a lower bound.")
    }
  }
}
