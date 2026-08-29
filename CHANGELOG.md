# Sürüm geçmişi

Bu dosyadaki her satır, Signalbird tarafında bir sürüm kaydına karşılık gelir.
Sürüm kaydı girilmeden değişiklik yayınlanmış sayılmaz (PROTOCOL.md §8):
yayınlandığı anda eski sürümü çalıştıran her sunucunun sahibine bildirim gider.

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
