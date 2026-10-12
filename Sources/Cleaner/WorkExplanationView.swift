import CleanerCore
import SwiftUI

struct WorkExplanationView: View {
  let row: ProcessRow
  private var role: WorkRole { WorkRole.identify(row) }
  private var purpose: String {
    if row.sample.isBundledCodexHelper { return L10n.core(row.explanation) }
    return switch role {
    case .localAI: L10n.text("Mac’inde AI modelleri çalıştırır; birden fazla proje kullanıyor olabilir.", "Runs AI models on your Mac; multiple projects may use it.")
    case .simulator: L10n.text("Bir cihazı taklit ederek uygulamanı denemeni sağlar.", "Emulates a device so you can test your app.")
    case .agent: L10n.text("AI kodlama oturumu; yanıt üretebilir ve araç çalıştırabilir.", "An AI coding session that can generate responses and run tools.")
    case .testBridge: L10n.text("AI aracını Maestro mobil test araçlarına bağlar.", "Connects your AI tool to Maestro mobile testing tools.")
    case .build: L10n.text("Kod derleme aracı. Şu anda derleme yaptığını yalnızca adına bakarak doğrulayamıyoruz.", "A code build tool. Its name alone does not establish that a build is active.")
    case .runtime: L10n.text("Kod çalıştıran altyapı. Sunucu mu, betik mi olduğunu henüz doğrulamadık; portlarını aşağıdan inceleyebilirsin.", "A code runtime. We have not verified whether it is a server or script; inspect its ports below.")
    case .sharedHelper: L10n.text("Uygulamanın yardımcı bileşeni. Birden fazla pencere veya projeye hizmet edebilir.", "An application helper. It may serve multiple windows or projects.")
    case .unknown: L10n.core(row.explanation)
    }
  }
  private var restart: String {
    switch role {
    case .localAI: L10n.text("Kullandığın model uygulamasından veya sunucuyu başlattığın terminalden yeniden başlat; modelin yüklenmesi zaman alabilir.", "Restart from the model app or the terminal that started the server; loading the model may take time.")
    case .simulator: L10n.text("Xcode veya Simulator’dan cihazı yeniden aç. Devam eden test yeniden başlatılmalıdır.", "Reopen the device in Xcode or Simulator. An interrupted test must be restarted.")
    case .agent, .testBridge: L10n.text("Başlattığın AI uygulamasında oturumu veya araç bağlantısını yeniden aç; kesilen iş otomatik tamamlanmaz.", "Reopen the session or tool connection in the originating AI app; interrupted work will not finish automatically.")
    case .build: L10n.text("Editöründen veya terminalinden derlemeyi yeniden çalıştır.", "Run the build again from your editor or terminal.")
    case .runtime: L10n.text("Projeyi açıp kullandığın çalıştırma komutunu yeniden başlat. Komutu bilmiyorsak tahmin etmiyoruz.", "Open the project and rerun its original start command. We do not guess an unknown command.")
    default: L10n.text("İlgili uygulamayı yeniden açman gerekebilir; tam yeniden başlatma yolu doğrulanmadı.", "You may need to reopen the parent application; the exact restart path is unverified.")
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.text("Ne için çalışıyor?", "What does it do?")).font(.headline)
      Text(purpose)
      Text(L10n.text("Kapatırsan", "If you stop it")).font(.subheadline.bold())
      Text(role == .simulator
        ? L10n.text("Cihazdaki uygulama ve testler kesilebilir. Cihaz kapatmak için Simülatörler ekranını kullan.", "Apps and tests on the device may stop. Use Simulators to shut down a device.")
        : L10n.core(row.stopImpact))
      DisclosureGroup(L10n.text("Nasıl yeniden başlatırım?", "How do I restart it?")) {
        Text(restart).font(.caption).padding(.top, 4)
      }
      Text(L10n.text("Açık olması, boşta veya gereksiz olduğu anlamına gelmez.", "Being open does not mean idle or unnecessary."))
        .font(.caption).foregroundStyle(.secondary)
    }.font(.callout)
  }
}

struct PressureEpisodesView: View {
  let model: Dashboard
  private var episodes: [PressureEpisode] {
    PressureEpisode.collect(points: model.history.points, frames: model.groupHistory.frames)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(L10n.text("Yavaşlama anlarını incele", "Review pressure periods")).font(.title2.bold())
      Text(L10n.text("Son 30 dakika · yalnızca bu oturum. Aynı anda yüksek tüketim, yavaşlamanın nedenini tek başına kanıtlamaz.", "Last 30 minutes · this session only. High usage at the same time does not prove the cause of a slowdown."))
        .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if episodes.isEmpty {
            Text(L10n.text("Bu kayıtta yüksek bellek baskısı veya en az 15 saniye süren %85+ CPU dönemi bulunmadı. Bu, hiç yavaşlama olmadığı anlamına gelmez; GPU ve disk gecikmesi ölçülmüyor.", "No high memory pressure or 15-second period of 85%+ CPU was found in this record. This does not rule out a slowdown; GPU and disk latency are not measured."))
          }
          ForEach(episodes) { episode in
            VStack(alignment: .leading, spacing: 6) {
              Text(episode.kind == .memory ? L10n.text("Bellek baskısı", "Memory pressure") : L10n.text("Sürekli yüksek CPU", "Sustained high CPU")).font(.headline)
              Text(episode.start.formatted(date: .omitted, time: .standard) + " – " + episode.end.formatted(date: .omitted, time: .standard))
              if let date = episode.evidenceDate {
                Text(L10n.text("\(date.formatted(date: .omitted, time: .standard)) ölçümünde öne çıkan uygulamalar:", "Leading apps at the \(date.formatted(date: .omitted, time: .standard)) reading:")).font(.caption)
              }
              ForEach(episode.applications) { group in
                Text("\(group.name) · \(Format.bytes(group.memory)) · CPU \(Format.cpu(group.cpu.map { $0 / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) }))")
                if !group.membershipComplete || group.missingCPUCount > 0 || group.missingMemoryCount > 0 {
                  Text(L10n.text("Kısmi ölçüm; gerçek toplam daha yüksek olabilir.", "Partial reading; the actual total may be higher.")).font(.caption).foregroundStyle(.secondary)
                }
              }
              if episode.applications.isEmpty { Text(L10n.text("Bu aralık için uygulama ölçümü yok.", "No application reading is available for this period.")).font(.caption) }
              Divider()
            }
          }
        }
      }
    }.padding(24).frame(width: 680, height: 520)
  }
}
