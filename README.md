# Signalbird Sunucu Ajanı

Sunucunuzu Signalbird'e bağlayan tek dosyalık ajan. Linux için bir kabuk
betiği, Windows için bir PowerShell betiği. Başka hiçbir şey kurmanız
gerekmez.

Kaynağı açıktır, çünkü sunucunuzda çalışan bir yazılımın ne yaptığını
okuyabilmeniz gerekir.

yazar: ahmet selim çil | ahmet@pariette.com

---

## Ne yapar

* Sunucu durumunu okur: CPU, bellek, disk, çalışma süresi, servisler,
  dinlenen portlar, en çok kaynak kullanan süreçler.
* Socket.io sunucunuzun durumunu okur (yalnız localhost adresinden).
* Veritabanınızın durumunu okur: bağlantı sayısı, yanıt süresi, boyut.
* Log dosyalarınızdaki yeni satırları Signalbird Telsiz sistemine gönderir.
* Beklenen sinyalleri iletir. Örnek: "veritabanı yedeği alındı". Sinyal
  gelmezse Signalbird alarm verir.

## Ne yapmaz

* **Sunucunuzda hiçbir şeyi değiştirmez.** Servis başlatmaz, dosya silmez,
  ayar değiştirmez, paket kurmaz.
* **Signalbird bu ajana komut gönderemez.** Panelden gelen şey komut değil
  ayardır: hangi ölçüm açık, hangi aralıkla, hangi dosya okunacak.
  Çalıştırılan komutların tam listesi [PROTOCOL.md](PROTOCOL.md) §7.
* **Kendini güncellemez.** Yeni sürüm çıktığında haber verir, güncelleme
  kararı sizindir. Kendini güncelleyen bir ajan, uzaktan kod çalıştırmanın
  kibar hâlidir.
* **Veritabanı parolanızı Signalbird'e göndermez.** O bilgi yalnız
  sunucunuzdaki ayar dosyasında durur.

---

## Kurulum

### Ubuntu / Debian ve diğer systemd dağıtımları

```bash
curl -fsSL https://raw.githubusercontent.com/Pariette-Inc/agent.signalbird/main/signalbird-agent.sh -o signalbird-agent.sh
sudo bash signalbird-agent.sh install --token=sba_live_xxxxxxxx
```

Gereksinimler: `curl` ve (`python3` veya `jq`). Ubuntu sunucularında ikisi de
kuruludur.

İzin verilen log kökünü kurulumda genişletebilirsiniz:

```bash
sudo bash signalbird-agent.sh install --token=sba_live_xxx --allow=/var/log,/srv/uygulama/storage/logs
```

### Windows Server

Yönetici PowerShell penceresinde:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/Pariette-Inc/agent.signalbird/main/signalbird-agent.ps1 -OutFile signalbird-agent.ps1
.\signalbird-agent.ps1 install -Token sba_live_xxxxxxxx
```

Anahtarı Signalbird panelinden **Sunucular** ekranında sunucu kaydını açarken
alırsınız. Anahtar bir kez gösterilir.

---

## Günlük kullanım

| Komut | Ne yapar |
| --- | --- |
| `signalbird-agent status` | Yerel ayarı ve bağlantıyı gösterir |
| `signalbird-agent once` | Tek tur ölçüm ve log gönderir |
| `signalbird-agent signal db-backup ok "2.4 GB"` | Beklenen sinyali iletir |
| `signalbird-agent signal db-backup fail "disk doldu"` | Başarısızlığı bildirir, alarm anında çalar |
| `signalbird-agent uninstall` | Servisi kaldırır, ayar dosyasını bırakır |

Windows'ta aynı komutlar `.\signalbird-agent.ps1 <komut>` biçiminde çalışır.

### Yedekleme sinyali örneği

Yedekleme betiğinizin sonuna tek satır eklemeniz yeterli:

```bash
#!/bin/bash
if mysqldump --all-databases | gzip > /var/backups/db.sql.gz; then
    signalbird-agent signal db-backup ok "$(du -h /var/backups/db.sql.gz | cut -f1)"
else
    signalbird-agent signal db-backup fail "mysqldump hata verdi"
fi
```

Panelde "her saat başı beklenir, 5 dakika tolerans" dediyseniz: 14:00 ile
14:05 arasında sinyal gelmezse alarm çalar. `fail` gelirse beklenmez, alarm
anında çalar.

Betiğinize dokunmak istemiyorsanız dosya tabanlı sinyal de vardır: panelde
yedek dosyasının yolunu ve tazelik süresini verirsiniz, ajan dosyanın değişim
zamanına bakar.

---

## Yerel ayar dosyası

Linux: `/etc/signalbird/agent.conf`
Windows: `C:\ProgramData\Signalbird\agent.conf`

Bu dosya sunucunuzdan dışarı çıkmaz. Panelden okunabilecek log yollarını
sınırlayan `allow_paths` ve veritabanı bağlantı bilgileri buradadır. Panelden
seçilen bir log yolu, bu listedeki köklerin altında değilse okunmaz.

Ayrıntılı şema: [PROTOCOL.md](PROTOCOL.md) §5.

---

## Sürüm bildirimi

Bu dosyalarda yapılan her değişiklik yeni bir sürüm numarası alır. Signalbird,
eski sürümü çalıştıran sunucuların sahiplerine panelden ve bildirimle haber
verir. Ajan kendini güncellemez, güncelleme kararı size aittir.

Güncellemek için dosyayı yeniden indirip `install` komutunu tekrar
çalıştırmanız yeterlidir. Ayar dosyanız korunur.

Sürüm geçmişi: [CHANGELOG.md](CHANGELOG.md)

---

## Sorun giderme

| Belirti | Bakılacak yer |
| --- | --- |
| Panelde sunucu görünmüyor | `signalbird-agent status` çıktısı, anahtar doğru mu |
| Log akmıyor | Yolun `allow_paths` altında olduğundan emin olun, `agent.log` dosyasına bakın |
| Veritabanı `ok:false` | Yerel ayardaki `db_*` satırları, kullanıcının salt okuma yetkisi |
| Servis çalışmıyor | Linux: `systemctl status signalbird-agent`, Windows: `Get-Service SignalbirdAgent` |

Ajanın kendi günlüğü Linux'ta `/var/log/signalbird-agent.log`, Windows'ta
`C:\ProgramData\Signalbird\agent.log` dosyasındadır.
