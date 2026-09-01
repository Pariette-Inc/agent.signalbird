# Sürüm geçmişi

Bu dosyadaki her satır, Signalbird tarafında bir sürüm kaydına karşılık gelir.
Sürüm kaydı girilmeden değişiklik yayınlanmış sayılmaz (PROTOCOL.md §8):
yayınlandığı anda eski sürümü çalıştıran her sunucunun sahibine bildirim gider.

## 1.0.1 (1 Eylül 2026)

Varsayılan API adresi düzeltildi.

- Ajanlar var olmayan `https://api.signalbird.app/api` adresini varsayılan
  alıyordu; gerçek uç `https://live.signalbird.io/api`. Şirket alan adı
  `signalbird.io`, `signalbird.app` diye bir uç hiç olmadı.
- 1.0.0 kurulumları bu adresi yerel ayar dosyasına (`agent.conf`,
  `api_base=`) yazdığı ve dosyadaki değer varsayılanı ezdiği için, yalnız
  betiği güncellemek yetmiyordu. Ayar dosyasında `signalbird.app` geçen bir
  `api_base` artık göz ardı ediliyor, günlüğe uyarı düşüyor ve yeni
  varsayılan kullanılıyor. Değeri dosyada da kalıcı düzeltmek için
  `signalbird-agent config` çalıştırın.
- PROTOCOL.md'deki taban adres, örnek ayar dosyası ve `notes_url`
  (`https://signalbird.io/agent/changelog`) güncellendi.

## 1.0.0 (30 Ağustos 2026)

İlk sürüm.

- Linux (`signalbird-agent.sh`) ve Windows (`signalbird-agent.ps1`) ajanları.
- Ölçümler: çalışma süresi, yük, CPU, bellek, takas, disk, inode, servis
  durumu, dinlenen portlar, en çok CPU kullanan süreçler.
- Socket.io ölçümü (yalnız localhost adresinden).
- Veritabanı ölçümü: MySQL/MariaDB, PostgreSQL (Linux), SQL Server ve
  MySQL (Windows).
- Log takibi: bayt konumu korunur, dosya döndüğünde başa dönülür, gönderim
  başarısız olursa konum ilerletilmez.
- Sinyaller: elle (`signal` komutu) ve dosya tazeliğine bakan otomatik biçim.
- Panelden ayar çekme, sürüm uyarısı, systemd ve Windows servis kurulumu.

Yayın öncesi canlı denemede düzeltilenler:

- HTTP durum kodu artık dosyada tutuluyor. Değişkende tutulduğunda komut
  ikamesi (`resp="$(sb_post …)"`) alt kabukta çalıştığı için kod ana kabuğa
  dönmüyordu: başarılı her istek "başarısız" sayılıyordu.
- `Accept: application/json` başlığı eklendi. Yokken doğrulama hatası 422
  yerine 302 yönlendirme olarak dönüyordu.
- Log alanları sunucunun sınırlarına göre kırpılıyor (`source` 120,
  `message` 4000) ve 4xx yanıtında konum yine de ilerliyor: tek uzun yol
  bütün log akışını sonsuza kadar tıkıyordu.
