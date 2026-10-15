# AgenticClean

> **Alpha — v0.7.6-alpha.1.** Erken test kullanıcıları için Apple Silicon (M serisi) ZIP indirmesi mevcuttur; Developer ID ile imzalanmış ve Apple tarafından notarize edilmiştir. Genel kullanıma hazır veya bütün Mac’lerde doğrulanmış bir ürün değildir.
>
> **Destek:** macOS kaynak izleme, kanıta dayalı proje bağlantıları, onaylı manuel durdurma, yerel AI servislerini inceleme ve proje disk ölçümü ve doğrulanmış Xcode/Next.js/Vite çıktıları için Çöp Sepeti akışı.
>
> **Sınırlar:** Proje bağlantısı sohbet sahipliği değildir. GPU ve disk gecikmesi ölçülmez; kimlik doğrulamalı model API’leri ve llama.cpp router model çıkarma desteklenmez. Bağımsız Mac kurulumu, VoiceOver ve hedef kullanıcı çalışması bekliyor. [Alpha durumu](docs/ALPHA.md).

Mac’inde çalışan işleri gör: bağımsız yerel AI sunucuları, geliştirme ortamları, uygulamalar ve projeler. CPU ve bellek kullanımını incele; etkisini gözden geçirerek durdur veya doğrulanmış derleme çıktılarını Çöp Kutusu’na taşı.

Ücretsiz, açık kaynak, yerel macOS menü çubuğu uygulaması. [English](README.en.md) · [MIT lisansı](LICENSE)

## İndir ve kur

[Alpha indirme sayfasından](https://github.com/ratipcan-uysal/AgenticClean/releases/tag/v0.7.6-alpha.1) `AgenticClean-0.7.6-arm64.zip` dosyasını indir, ZIP’i aç ve `AgenticClean.app` dosyasını Uygulamalar klasörüne taşı. Uygulamayı aç; menü çubuğundan erişebilirsin. macOS 14+ hedeflenir; Intel paketi sunulmaz. İkinci fiziksel Mac üzerinde kurulum doğrulaması henüz yapılmadı. `.cmd` veya terminal betiği gerekmez.

## Kullanım

1. **Tara:** CPU, bellek baskısı ve uygulama listesini güncelle.
2. **İncele:** Genel Bakış’tan çalışan işi seç; Projeler sekmesinde tam klasör yoluyla bağlantıları incele. Bağımsız AI sunucuları uygulama ağacını açmadan görünür. Node/Java adı tek başına görevi kanıtlamaz.
3. **Onayla:** Projenin **Durdur…** düğmesi kapatılacak ve açık kalacak süreçleri nedenleriyle gösterir. AI oturumu listedeyse devam eden iş kesilir. Paylaşılan veya bağlantısı bilinmeyen süreçler dahil edilmez.
4. **Sonucu gör:** Kapandı, hâlâ çalışıyor, doğrulanamadı ve başarısız sonuçları ayrı gösterilir. Yeni eşleşen süreçler ve okunabilen önce/sonra bellek değerleri ayrıca sunulur; otomatik hızlanma iddiası yapılmaz.

**Listeyi inceleme:** Ölçümler güncellenirken satır sırası, açık gruplar ve seçim sabit kalır. Yeni işler sayaçta bekler; **Yeniden sırala** bunları ekler, kayıp satırları kaldırır ve güncel değerlere göre sıralar. Bellek/CPU/süre seçimini veya arama/filtreyi değiştirmek de listeyi yeniden kurar. Kayıp satırda kapanış yalnız kimlik kontrolüyle doğrulanır; eski ölçümler canlı toplamda kullanılmaz.

**Disk alanı:** Projelerin mantıksal dosya boyutlarını tek çalışma alanında ölç, kaynak/bağımlılık/çıktı dağılımını incele; kapalı projeleri klasör seçerek ekle. Temizleme yalnızca doğrulanmış Xcode `DerivedData/<proje>/Build`, Next.js `.next/cache` ve Vite `node_modules/.vite` çıktılarında sunulur. Etkinlik, kimlik ve değişiklik kontrollerinden geçen çıktıları seçip onayladıktan sonra Çöp Sepeti’ne taşıyabilirsin. Bu, tüm disk analizi veya RAM temizliği değildir. AgenticClean Çöp Sepeti’ni boşaltmaz. [Tam kapsam ve korumalar](docs/CACHE-SCOPE.md).

Codex, Claude Code ve Cursor için süreç/proje inceleme desteklenir; bu araçların sohbet, ayar, kimlik bilgisi veya doğrulanmamış önbellek klasörleri temizlenmez. SwiftPM `.build` içindeki değişmiş bağımlılık kaynakları da temizlik kapsamına alınmaz.

**Codex yardımcıları:** Süreç ayrıntısından veya projeden ayrı incele. Yardımcılar başlangıçta seçilmez; ikinci onay yalnız seçilen PID’leri kapsar. Engellenen işlemler nedenini gösterir. İşlem geçmişi yalnız bu oturumda, son 200 tamamlanan ayrıntı ve 50 proje özetiyle bellekte tutulur; devam eden işlemler korunur ve diske geçmiş yazılmaz.

**Simülatörler:** Açık cihazları kapatma incelemesi yanında, **Disk alanı** görünümü tüm cihazları boyut, sürüm ve bilinen son kullanımlarıyla listeler. Kapalı cihazlar başlangıçta seçilmez. **İçeriği sıfırla…** cihazı koruyarak uygulama/veri/ayarlarını, **Cihazı sil…** cihazın kendisini kalıcı kaldırır; Çöp Sepeti’nden geri alınamaz. Her cihaz için yeniden kimlik/durum kontrolü ve ayrı sonuç vardır; başka bir oturumun gelecekteki kullanım niyeti doğrulanamaz. Boyutlar ortak runtime alanını içermez ve kesin alan kazanımı değildir. Disk Alanı ekranındaki kart aynı incelemeyi açar. Pencere kapansa da işlem sürer; iptal veya uygulamadan çıkış, başlatılan cihazı tamamlayıp kalanları atlar.

**Disk ölçümünü yenileme:** Simülatör silme veya sıfırlama öncesinde ve sonrasında kullanıcı diskinin kullanılabilir alanı yeniden okunur; ana kart ve işlem sonuçları aynı ölçümü kullanır. **Yenile** yalnız disk ölçümünü günceller. Son işlem için önce/sonra alanı ve pozitif, sıfır veya negatif net değişim gösterilir. Bu fark diğer uygulamaların yazmalarını ve APFS etkilerini de kapsar; silinen cihazların kesin alan kazancı değildir. Ölçüm okunamazsa bilinmiyor olarak kalır.

**Grafikler:** Genel Bakış’ta CPU ve bellek baskısının küçük grafikleri bulunur. Ayrıntılı sistem geçmişi ve uygulama/proje geçmişi ayrı açılır. Ana ekran küçük pencerede listeye öncelik verir. Uygulama/proje geçmişi son 30 dakikayı, en az 15 saniye aralıkla CPU ve bellekte ilk 20 grubu tutar. Kısmi kullanım kesikli çizgidir; toplam daha yüksek olabilir. Hiç ölçülmeyen veya tutulmayan değerler grafikte boşluktur, sıfır değildir. Geçmiş yalnızca bellekte, mevcut oturum boyunca kalır.

## Yerel servisler

- **Ollama / LM Studio:** Seçilen süreçte doğrulanmış loopback dinleyicisinden, açık istek üzerine model envanteri okunur. Model bellekten çıkarma ayrı onay ister; dosyaları silmez ve başka istemcileri etkileyebilir. Bellekte bulunma, aktif üretim veya proje sahipliği kanıtı değildir.
- **llama.cpp:** Bağımsız sunucu görünür. Desteklenen `/slots` API’si anlık etkin istek sayısı sağlar; router model çıkarma bu sürümde desteklenmez.
- **Docker:** Resmî Docker Desktop kurulumu ve standart kullanıcı soketi desteklenir. Konteyner/proje/servis bilgileri açık istekte okunur; yalnızca onaylanan tam konteyner kimliğine SIGTERM gönderilir. Otomatik SIGKILL, volume silme veya prune yoktur.
- **Yerel bağlantılar:** Geliştirme sürecinin loopback TCP portlarını inceleyebilirsin. Portun bulunması HTTP desteğini veya proje sahipliğini kanıtlamaz; tarayıcıda açma kullanıcı eylemidir.

API erişim anahtarları, wildcard/harici dinleyiciler ve özel Docker konumları desteklenmez. Bilinmeyen sürüm/yanıt veri yokmuş gibi gösterilmez. Sağlayıcının bellek değeri süreç footprint’ine eklenmez. Sağlayıcı yanıtlarından yalnızca seçili metadata tutulur; yanıt gövdesi ve sohbet içeriği kaydedilmez.

## Açma ve tercihler

Derleyip yerel kurulum yaptıktan sonra `dist/AgenticClean.app` dosyasını aç. Bu çalışma klasöründeki `AgenticClean Aç.command` yalnızca yerel kısayoldur; herkese açık kaynak arşivine dahil değildir. Paneli kapatmak ölçümü durdurmaz; menü çubuğundaki AgenticClean’den tekrar aç. Tam çıkış için **AgenticClean’den çık**. Ana ekranın altındaki **Ayarlar → Language / Dil** alanından **Türkçe** veya **English** seçilebilir. Değişiklik anında uygulanır; aynı ekranda tarama aralığı da seçilebilir. Dil, tarama aralığı, sıralama ve grafik tercihi korunur; PID/seçim geri yüklenmez.

Liste klavye odaktayken ok tuşlarıyla gezin, sağ/sol ile genişlet/daralt, Enter veya boşlukla dalı aç. Süreç seçilince ayrıntı sağda görünür. Arama/filtreyi değiştirmek işlem seçimini temizler; otomatik tarama sırasında filtre eşiğinin altına inen görünür satır, güncel ölçümleriyle bir sonraki sıralamaya kadar kalır.

## Ölçümler ve sınırlar

- Ana listedeki CPU yüzdesi **tüm işlemci kapasitesine** göredir; sayı ve çubuk aynı ölçeği kullanır. Teknik süreç ayrıntısı bir çekirdek %100 esasını ayrıca belirtir.
- Bellek **footprint** değeridir. Okunamayan footprint yerine RSS geçirilmez; eksik süreç sayısı belirtilir. RSS teknik ayrıntıda ayrıdır. Bellek çubuğu fiziksel RAM’e göre sabittir; arama ölçeği değiştirmez. Footprint toplamı fiziksel RAM dağılımına bire bir eşit değildir.
- Bellek baskısı macOS seviyesidir. Swap hızı iki sayaç arasındaki gerçek süreyle hesaplanır. İlk örnek, uyku/duraklama sonrası başlangıç ve eksik ölçüm bilinmiyor olarak kalır.
- CPU toplam kapasitenin en az %85’inde 15 saniye kalırsa yüksek kullanım bildirilir. Eski veya düşük CPU’lu süreç “gereksiz” sayılmaz.
- Süreç disk okuma/yazma hızı, çekirdek başına CPU, macOS termal seviyesi ve Düşük Güç Modu gösterilir. Disk aktarım hızı disk gecikmesi değildir; termal seviye derece veya kesin hız kaybı değildir. Genel GPU kullanımı, disk gecikmesi ve arayüz donması ölçülmez. “Bu ölçümler nedeni açıklamıyor” geçerli bir sonuçtur.
- Çalışma klasörü proje bağlantısı için kanıttır; sohbet sahipliğini kanıtlamaz. Aynı adlı farklı yollar ve Git worktree’leri ayrı kalır.
- Durdurma yalnızca SIGTERM kullanır. Sinyal gönderilen her süreç, kapanışı doğrulanana veya yaklaşık 15 saniyelik bekleme sınırına ulaşılana kadar kontrol edilir; ön kontroller, sinyal gönderimi ve işletim sistemi yanıtları nedeniyle tüm işlemin süresi daha uzun olabilir. AI oturumu için doğrudan işaretçili proje ve tüm okunabilir alt süreçlerin aynı projeye bağlı olması gerekir. Kullanıcı süreçleri eksik okunursa oturum kapatma engellenir. Sinyal öncesi yeni tarama yapılır; son kontrol ile işletim sistemi sinyali atomik değildir.
- Sistem, başka kullanıcı, masaüstü uygulama ana süreçleri ve paylaşılan yardımcılar korunur. Otomatik veya zorla süreç temizliği yoktur.

Sunucu, telemetri, sohbet veritabanı okuması veya yönetici yetkisi isteyen yardımcı servis yoktur. Dosya temizliği açıkça seçilip onaylanır. Harici hata mesajları geldiği dilde kalabilir. [Güvenlik](SECURITY.md)

## Derleme ve geri dönüş

macOS 14+; Xcode ve Swift 6.2+:

```sh
swift test --jobs 2
./scripts/build.sh
open "$(cat dist/latest-candidate.txt)"
```

Bu **yerel ad hoc imzalı adaydır**, Apple tarafından notarize edilmiş genel dağıtım değildir. Adayı doğruladıktan sonra AgenticClean’den çıkıp `./scripts/install.sh` ve `open dist/AgenticClean.app` kullan. Kurulum eski sürümü `dist/releases/previous-<zaman>.app` olarak saklar. Geri dönüş: AgenticClean’den çık, `./scripts/install.sh <eski/AgenticClean.app>` çalıştır.

İmzalı GitHub dağıtımı, kaynak arşivi, mimari desteği ve ikinci Mac kontrolü: [Yayın adımları](docs/RELEASING.md). [Değişiklikler](CHANGELOG.md). Yerel performans ölçümü: pencere kapalıyken `python3 scripts/profile.py --pid <AgenticClean-PID> --duration 600 --output /tmp/cleaner-profile.json`.

CLI tanıma, adı/yerel kurulumu doğrulanan Codex ve Claude yürütülebilirlerini kapsar; Claude’un sürümlü yerel kurulumu dahildir. Node/npm üzerinden çalışan ve kimliği doğrulanamayan sarmalayıcılar Node.js olarak görünebilir; tahminle AI oturumu kapatma izni verilmez.
