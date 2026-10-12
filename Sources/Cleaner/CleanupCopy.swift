import CleanerCore

@MainActor enum CleanupCopy {
  static func title(_ provider: CleanupProvider) -> String {
    switch provider {
    case .xcode: L10n.text("Xcode derleme çıktıları", "Xcode build outputs")
    case .next: L10n.text("Next.js önbelleği", "Next.js cache")
    case .vite: L10n.text("Vite bağımlılık önbelleği", "Vite dependency cache")
    }
  }
  static func effect(_ provider: CleanupProvider) -> String {
    switch provider {
    case .xcode: L10n.text("Xcode sonraki derlemede yeniden oluşturur; derleme daha uzun sürebilir.", "Xcode recreates these on the next build, which may take longer.")
    case .next: L10n.text("Next.js yeniden oluşturabilir; sonraki açılış veya derleme daha uzun sürebilir.", "Next.js can recreate this cache; the next startup or build may take longer.")
    case .vite: L10n.text("Vite bağımlılıkları yeniden hazırlar; sonraki geliştirme açılışı daha uzun sürebilir.", "Vite prepares dependencies again; the next development startup may take longer.")
    }
  }
  static func notice(_ value: String) -> String {
    let translations = [
      "Supported tool dependency could not be verified.": "Desteklenen araç bağımlılığı doğrulanamadı.",
      "Generated output metadata could not be verified.": "Üretilen çıktı bilgisi doğrulanamadı.",
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
    return L10n.text(translations[value] ?? (value.hasPrefix("Folder could not be read: ") ? "Klasör okunamadı: " + value.dropFirst("Folder could not be read: ".count) : value), value)
  }
}
