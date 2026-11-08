# MyTablet

Samsung Tab A8'i (SM-X207) USB üzerinden MacBook için dokunmatik ikinci ekrana çevirir.
Tabletteki ekran iPadOS gibi davranır, MacBook ekranı olduğu gibi kalır.

## Çalıştırma

    ./build.sh
    open build/MyTablet.app

Uygulamayı `open` ile başlat. Shell'den doğrudan çalıştırınca macOS izinleri terminale bağlar ve dokunma çalışmaz.
İlk açılışta Ekran Kaydı ve Erişilebilirlik izinleri gerekir. Tablet alıcısı otomatik kurulur ve başlatılır.
Çözünürlük ve anlık istatistikler menü çubuğundaki tablet simgesinde.

## Hareketler

| Hareket | Sonuç |
| --- | --- |
| Dokunma / çift dokunma | Tıklama / çift tıklama |
| Dokunup hemen kaydırma | Momentumlu kaydırma |
| Başlık çubuğu veya slider üzerinde kaydırma | Sürükleme |
| 0,22 sn basılı tutup kaydırma | Sürükle-bırak, metin seçimi |
| Uzun basma | Sağ tık |
| İki parmakla dokunma | Sağ tık |
| İki parmak | Kaydırma, pinch ile yakınlaştırma, döndürme |
| Üç parmak yukarı | Uygulama değiştirici |
| Üç parmak sola / sağa | Uygulamalar arası geçiş |
| Alt kenardan kısa yukarı kaydırma | Dock |
| Alt kenardan uzun yukarı kaydırma | Ana ekran |
| Alt kenardan kaydırıp bekleme | Uygulama değiştirici |
| Alt kenar boyunca yana kaydırma | Uygulamalar arası geçiş |
| Uygulama değiştiricide kartı yukarı atma | Pencereyi kapatır |

## Yapı

- `mac/`: Swift menü çubuğu uygulaması. Sanal ekran (`VirtualDisplay`), yakalama (`Capturer`), H.264 (`Encoder`),
  bağlantı ve kredi akışı (`Link`, `Session`), jestler (`GestureEngine`, `Injector`), kabuk (`Shell`, `Windows`, `AppCatalog`, `Keyboard`).
- `android/`: `MainActivity`, SurfaceView + MediaCodec alıcısı ve ham dokunma göndericisi. Gradle gerektirmez.
- `tools/TouchLab.swift`: Sanal ekranda hareket üretir ve alınan her giriş olayını kaydeder.
- `MYTABLET_REPLAY=<dosya>`: Dokunma betiğini jest motoruna oynatır (`Replay.swift`).

## Teknik notlar

- Decoder (`OMX.sprd.h264.decoder`) High profilde kareleri tutuyor, Constrained Baseline'da hemen veriyor. Bu yüzden Baseline kullanılıyor.
- Kullanılan özel API'ler: `CGVirtualDisplay`, gesture CGEvent alanları (110/113/114/132), `_AXUIElementGetWindow`.
  macOS güncellemelerinde değişebilirler.
