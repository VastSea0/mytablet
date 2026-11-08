# MyTablet

Android tableti, Mac için düşük gecikmeli dokunmatik ekrana çevirir. Piksel birebir bir sanal ekranı USB üzerinden
aktarır ve tablete iPadOS'tan esinlenen bir ana ekran ekler. Mac'in kendi ekranı, imleci ve odağı normal çalışır.

[English](README.md)

Samsung Galaxy Tab A8 (SM-X207) ve macOS 27.2 kullanan M4 MacBook Air üzerinde geliştirildi. Çözünürlük şimdilik
bu tabletin 1920×1200 paneline sabit.

## Çalıştırma

    ./build.sh
    open build/MyTablet.app

Uygulamayı `open` ile başlat, shell'den başlatınca izinler terminale bağlanır ve dokunma çalışmaz.
İlk açılışta **Ekran Kaydı** ve **Erişilebilirlik** izinlerini ver. Tablet uygulaması kendini kurar.

## Hareketler

| Hareket | Sonuç |
| --- | --- |
| Alt kenardan yukarı çekme | Ana ekran (kısa: Dock, çekip bekleme: uygulama değiştirici) |
| Alt kenar boyunca kaydırma | Uygulama değiştirme |
| Sağ üstten aşağı çekme | Kontrol Merkezi |
| Uygulamadayken sol üstten aşağı çekme | Gerçek macOS menü çubuğu (6 saniye) |
| Ana ekranda uzun basma | Düzenleme modu |
| Uygulamayı başka uygulamanın üstüne sürükleme | Klasör oluşturma |
| Üç parmak yukarı / sola / sağa | Uygulama değiştirici / uygulama geçişi |
| Basılı tutup sürükleme | Sürükle-bırak, metin seçimi |

Özellikler, çalışma mantığı ve bilinen sınırlar için [İngilizce README](README.md) dosyasına bak.
