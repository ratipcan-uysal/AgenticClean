import Foundation

/// Explicit app preference. Unknown diagnostics retain their source text, never a guessed translation.
enum L10n {
  static var isEnglish: Bool { UserDefaults.standard.string(forKey: "cleanerLanguage") == "en" }
  static var locale: Locale { Locale(identifier: isEnglish ? "en" : "tr") }
  static func text(_ turkish: String, _ english: String) -> String {
    isEnglish ? english : turkish
  }
  static func core(_ value: String) -> String {
    if isEnglish {
      if value == "Codex · Araç çalıştırıcısı" { return "Codex · Tool runner" }
      if value == "Codex araç yardımcısı · Node.js" { return "Codex tool helper · Node.js" }
      if value == "Codex uygulama paketindeki araç altyapısı. Bu klasörde çalışması, projenin sunucusu olduğunu göstermez. Hangi sohbetin kullandığı ve hâlâ gerekli olup olmadığı doğrulanamadı. Beklerken de çalışma ortamını bellekte tutabilir." {
        return "Tool infrastructure bundled with Codex. Working in this folder does not establish that it is the project's server. Its chat ownership and continued necessity are unverified. It can retain its runtime in memory while waiting."
      }
    }
    if value == "Cleaner veya temel sistem süreci" {
      return text("AgenticClean veya temel sistem süreci", "AgenticClean or an essential system process")
    }
    guard isEnglish else { return value }
    return englishCore(value)
  }
  static func eventName(_ value: String) -> String {
    guard isEnglish else { return value }
    guard let pid = value.range(of: " · PID ", options: .backwards) else { return core(value) }
    let name = String(value[..<pid.lowerBound])
    var start = name.startIndex
    while let separator = name.range(of: " · ", range: start..<name.endIndex) {
      let title = String(name[separator.upperBound...])
      let translated = core(title)
      if translated != title {
        return String(name[..<separator.upperBound]) + translated + String(value[pid.lowerBound...])
      }
      start = separator.upperBound
    }
    return core(name) + String(value[pid.lowerBound...])
  }

  /// Pure translation boundary for the existing Turkish core, kept out of process decisions.
  static func englishCore(_ value: String) -> String {
    if value
      == "Bu AI oturumu paylaşılan bir yerel AI servisinin üst süreci; ayrı inceleyip durdur."
    {
      return
        "This AI session is a parent of a potentially shared local AI service; inspect and stop it separately."
    }
    if value == "Yerel AI servisi başka projelerle paylaşılabilir; ayrı inceleyip durdur." {
      return "A local AI service may be shared with other projects; inspect and stop it separately."
    }
    if let translated = coreStrings[value] { return translated }
    for template in templates
    where value.hasPrefix(template.prefix) && value.hasSuffix(template.suffix) {
      let start = value.index(value.startIndex, offsetBy: template.prefix.count)
      let end = value.index(value.endIndex, offsetBy: -template.suffix.count)
      guard start <= end else { continue }
      return template.englishPrefix + String(value[start..<end]) + template.englishSuffix
    }
    // Project evidence is assembled from a known source sentence and fixed suffixes.
    let evidenceSuffixes = [
      (
        " Proje işaretçisi bulundu. Sohbet kimliği bilinmiyor.",
        " A project marker was found. Chat identity is unknown."
      ),
      (
        " Proje işaretçisi bulunamadı; yalnızca klasör adı gösteriliyor. Sohbet kimliği bilinmiyor.",
        " No project marker was found; only the folder is known. Chat identity is unknown."
      ),
    ]
    for (suffix, translated) in evidenceSuffixes where value.hasSuffix(suffix) {
      let source = String(value.dropLast(suffix.count))
      let translatedSource = englishCore(source)
      if translatedSource != source { return translatedSource + translated }
    }
    return value
  }
  private struct Template {
    let prefix: String
    let suffix: String
    let englishPrefix: String
    let englishSuffix: String
  }
  private static let templates: [Template] = [
    .init(
      prefix: "", suffix: " · AI kodlama oturumu", englishPrefix: "",
      englishSuffix: " · AI coding session"),
    .init(prefix: "Üst uygulama: ", suffix: "", englishPrefix: "Parent app: ", englishSuffix: ""),
    .init(
      prefix: "",
      suffix:
        ", bu sürecin üst süreç zincirinde bulundu. Hangi sohbetin veya görevin kullandığı bilinmiyor.",
      englishPrefix: "",
      englishSuffix:
        " was found in this process’s parent chain. The chat or task using it is unknown."),
    .init(
      prefix: "Üst süreç zincirindeki uygulama veya süreç: ",
      suffix: ". Bu bilgi bir proje veya sohbet eşleştirmesi değildir.",
      englishPrefix: "App or process in the parent chain: ",
      englishSuffix: ". This does not establish project or chat ownership."),
    .init(
      prefix: "Durdurursan devam eden ",
      suffix:
        " AI kodlama oturumu ve araç çağrıları kesilir. Otomatik kaydedilmemiş çalışma kaybolabilir; oturumu yeniden başlatman gerekebilir.",
      englishPrefix: "Stopping interrupts the active ",
      englishSuffix:
        " AI coding session and tool calls. Unsaved work may be lost; you may need to restart the session."
    ),
    .init(
      prefix: "Üst süreç PID ",
      suffix: " çalışma klasöründen çıkarıldı; bu sürece ait kesin proje bilgisi değildir.",
      englishPrefix: "Inferred from the working directory of parent PID ",
      englishSuffix: "; this is not confirmed project ownership for this process."),
    .init(
      prefix: "Komut başarısız (", suffix: "", englishPrefix: "Command failed (", englishSuffix: ""),
  ]
  private static let coreStrings: [String: String] = [
    "Önce durdurmak istediğin yardımcıyı seç.": "First select a helper to stop.",
    "Ölçüm duraklatıldı; devam ettir.": "Monitoring is paused; resume it first.",
    "Tarama başarısız; listeyi yeniden tara.": "Scanning failed; scan the list again.",
    "Liste hazırlanıyor; tamamlanmasını bekle.": "The list is being prepared; wait for it to finish.",
    "Ölçüm güncel değil; listeyi yenile.": "The measurement is out of date; refresh the list.",
    "Bu proje için işlem sürüyor; sonucu bekle.": "An operation is in progress for this project; wait for its result.",
    "Bu işlem zaten gönderildi; güncel listeyi yeniden incele.": "This operation was already submitted; review the current list again.",
    "Durdurmaya uygun süreç yok.": "No eligible processes.",
    "Bazı kullanıcı süreçleri okunamadı; AI oturumunun kapsamı doğrulanamıyor":
      "Some user processes could not be read; the scope of this AI session cannot be verified",
    "Bazı kullanıcı süreçleri okunamadı; AI oturumunun tüm alt işleri doğrulanamadığı için durdurulmadı.":
      "Some user processes could not be read. The AI session was not stopped because all its child jobs could not be verified.",
    "AI oturumunun proje kökü değişti veya doğrulanamadı; durdurulmadı.":
      "The AI session’s project root changed or could not be verified; it was not stopped.",
    "AI oturumunun bir alt işinin çalışma klasörü veya kullanıcısı doğrulanamadı; durdurulmadı.":
      "A child job’s working directory or user could not be verified; the AI session was not stopped.",
    "AI oturumunun başka projeye bağlı veya projesi bilinmeyen alt işi var; durdurulmadı.":
      "The AI session has a child job in another or unknown project; it was not stopped.",
    "İlk ölçüm bekleniyor": "Waiting for first measurement",
    "Sabit (wired)": "Wired",
    "AI oturumunu durdurmak için onaylanan proje kökü gerekli.":
      "A confirmed project root is required to stop this AI session.",
    "Proje kökü onaydan sonra değişti veya okunamadı; durdurulmadı.":
      "The project root changed or could not be read after confirmation; the process was not stopped.",
    "Cleaner veya temel sistem süreci": "AgenticClean or an essential system process",
    "Başka kullanıcıya veya sisteme ait": "Belongs to another user or the system",
    "macOS / geliştirici altyapısı": "macOS / developer infrastructure",
    "Aktif ajan uygulaması veya yönetilen yardımcı süreç":
      "Active agent app or a managed helper process",
    "Ajan uygulaması veya yönetilen yardımcı süreç; etkinliği doğrulanmadı":
      "Agent app or managed helper; activity has not been verified",
    "Codex yardımcı süreci; ayrı seçim ve onay gerekli":
      "Codex helper process; separate selection and approval required",
    "Hangi Codex sohbetinin kullandığı bilinmiyor. Durdurursan bağlı araç çağrıları ve devam eden işler kesilebilir; yeniden bağlantı gerekebilir.":
      "Its Codex chat ownership is unknown. Stopping it may interrupt connected tool calls and ongoing work; reconnection may be needed.",
    "Ajan oturumu; yalnızca onaylı proje işlemiyle kapatılabilir":
      "Agent session; can only be stopped through a confirmed project action",
    "Uygulamayı kendi Çıkış menüsünden kapat": "Use this app’s own Quit menu to close it",
    "Bu süreç türü için kapatma desteklenmiyor": "Stopping is not supported for this process type",
    "Proje bağlantısı doğrudan doğrulanamadı; toplu işleme alınmadı":
      "The project connection could not be verified directly; excluded from the group action",
    "AI oturumu için doğrulanmış proje kökü gerekli; yalnızca klasör bilgisi yeterli değil":
      "An AI session requires a verified project root; a folder alone is insufficient",
    "Bu süreç için zaten kapanma bekleniyor": "A stop request is already pending for this process",
    "Bu AI oturumunun başka projeye bağlı veya proje bağlantısı bilinmeyen alt süreci var":
      "This AI session has a child process connected to another project or with an unknown project",
    "Çalışma klasörü değişti veya okunamadı; durdurulmadı.":
      "The working directory changed or could not be read; the process was not stopped.",
    "Süreç kapanmış veya kimliği değişmiş; durdurulmadı.":
      "The process closed or its identity changed; no stop request was sent.",
    "Süreç kapanmış veya kimliği değişmiş. Listeyi yenile.":
      "The process closed or its identity changed. Refresh the list.",
    "Bu süreç türü desteklenmiyor.": "This process type is not supported.",
    "Bu süreç geliştirme aracı olarak tanınmıyor.":
      "This process is not recognized as a development tool.",
    "Liste veya seçim değişti. Projeyi yeniden seçip güncel listeyi kontrol et.":
      "The list or selection changed. Refresh the project list and review it again.",
    "Süreç veya proje bağlantısı değişti; sinyal gönderilmedi.":
      "The process or its project connection changed; no signal was sent.",
    "Maestro · Mobil test bağlantısı": "Maestro · Mobile testing connection",
    "Java · Görevi belirlenemedi": "Java · Function unknown",
    "Node.js · JavaScript çalışma ortamı": "Node.js · JavaScript runtime",
    "Yerel yapay zekâ sunucusu · llama-server": "Local AI server · llama-server",
    "Ollama · Yerel yapay zekâ": "Ollama · Local AI",
    "iOS simülatörü": "iOS simulator",
    "Python · Betik / servis": "Python · Script / service",
    "Üst uygulama belirlenemedi": "Parent app unknown",
    "Maestro’nun mobil uygulama test araçlarına erişim sağlayan MCP bağlantısı. Java bu aracı çalıştıran altyapıdır.":
      "MCP connection providing access to Maestro’s mobile app testing tools. Java is the runtime hosting this tool.",
    "Java ile çalışan bir araç. Hangi uygulama veya görevi yürüttüğü belirlenemedi; Java adı tek başına yeterli değil.":
      "A tool running on Java. Its app or task could not be identified; the Java name alone is insufficient.",
    "JavaScript çalıştıran süreç. Bir geliştirme sunucusu, araç bağlantısı veya betik olabilir; tam görevi belirlenemedi.":
      "A process running JavaScript. It may be a development server, tool connection, or script; its exact function is unknown.",
    "Bilgisayarda yapay zekâ modeli çalıştırmak için kullanılan süreç. Hangi isteğe hizmet ettiği bilinmiyor.":
      "A process used to run an AI model locally. The request it serves is unknown.",
    "Bu sürecin özel görevi belirlenemedi. Çalışma klasörü ve üst uygulama, neye bağlı olduğunu anlamana yardımcı olabilir.":
      "The specific task of this process is unknown. Its working directory and parent app can help identify its connection.",
    "Üst süreç bağlantısı okunamadı.": "The parent-process connection could not be read.",
    "Durdurursan bağlı oturumun Maestro mobil test araçları kesilebilir. Yeniden bağlantı gerekebilir.":
      "Stopping may interrupt Maestro testing tools in the connected session. Reconnection may be required.",
    "Durdurursan bu sunucuyu kullanan yapay zekâ istekleri kesilebilir.":
      "Stopping may interrupt AI requests using this server.",
    "Durdurursan bu sürece bağlı sunucu, betik veya devam eden iş kesilebilir. Tam etkisi bilinmiyor.":
      "Stopping may interrupt a server, script, or ongoing job using this process. The full impact is unknown.",
    "Bu süreç birden fazla projeye hizmet edebilir. Proje ve sohbet sahipliği bilinmiyor.":
      "This process may serve multiple projects. Its project and chat ownership are unknown.",
    "Sürecin doğrudan çalışma klasöründen bulundu.":
      "Found from this process’s own working directory.",
    "Paylaşılan / proje bilinmiyor": "Shared / unknown project",
    "Proje bilinmiyor": "Unknown project",
    "Proje bağlantısı bulunamadı": "Project connection not found",
    "Masaüstü": "Desktop",
    "1 GiB üzerinde bellek yükü": "Memory footprint exceeds 1 GiB",
    "3 ölçümdür CPU ≥ %25": "CPU at least 25% of one core for 3 measurements",
    "Süreç listesi okunamadı.": "The process list could not be read.",
    "Süreç listesi boş veya erişim engellendi.": "The process list is empty or access was denied.",
    "Süreç bilgileri okunamadı. Uygulamayı normal macOS oturumunda aç.":
      "Process information could not be read. Open the app in a regular macOS session.",
    "Bu kullanıcıya ait süreç listesi doğrulanamadı.":
      "The current user’s process list could not be verified.",
    "Kullanıcı süreç listesi değişti veya tam okunamadı; yeniden tara.":
      "The user process list changed or could not be fully read; scan again.",
    "Yardımcı komut zaman aşımına uğradı. Sonuç doğrulanamadı.":
      "The helper command timed out. Its result could not be verified.",
    "Yardımcı komut iptal edildi.": "The helper command was cancelled.",
    "Yardımcı komut beklenenden fazla çıktı üretti.":
      "The helper command produced too much output.",
    "Yardımcı komutun çıktısı güvenli okunamadı.":
      "The helper command’s output could not be read safely.",
    "Geçersiz simülatör kimliği.": "Invalid simulator identity.",
    "Bellek baskısı kritik": "Memory pressure is critical",
    "Bellek baskısı yüksek": "Memory pressure is high",
    "CPU sürekli yüksek": "CPU usage remains high",
    "Teşhis için yeterli ölçüm yok": "Not enough measurements for a diagnosis",
    "Bu ölçümler nedeni açıklamıyor": "These measurements do not explain the slowdown",
    "Güncel": "Current",
    "Eski ölçüm": "Stale measurement",
    "Kısmi ölçüm": "Partial measurement",
    "Tarama başarısız": "Scan failed",
    "Normal": "Normal",
    "Bilinmiyor": "Unknown",
    "Sıkıştırılmış": "Compressed",
    "Aktif": "Active",
    "İnaktif": "Inactive",
    "Boş": "Free",
    "RAM’de sabit tutulan sayfalar; sistem/sürücü ve uygulama adına ayrılan alanları içerebilir.":
      "Pages pinned in RAM; may include allocations for the system, drivers, and apps.",
    "RAM içinde sıkıştırılan verilerin kapladığı fiziksel alan.":
      "Physical space used by compressed data in RAM.",
    "Aktif bellek sayfaları; tek bir uygulamayı temsil etmez.":
      "Active memory pages; does not represent a single app.",
    "Yakın zamanda kullanılmayan sayfalar; tamamı boş veya önbellek değildir.":
      "Pages not used recently; not all are free or cache.",
    "Şu anda kullanılmayan fiziksel sayfalar.": "Physical pages currently unused.",
  ]
}
