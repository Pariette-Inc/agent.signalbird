# Signalbird Agent Protokolü

> yazar: ahmet selim çil | ahmet@pariette.com
> protokol sürümü: 1
> ajan sürümü: bkz. `VERSION`

Bu belge, sunucuda çalışan ajan (`signalbird-agent.sh` ve `signalbird-agent.ps1`)
ile Signalbird arasındaki sözleşmeyi tanımlar. İki ajan dosyası ayrı dillerde
yazılmıştır ama **aynı** sözleşmeye uyar. Birinde bir alan değişiyorsa diğerinde
de değişmek zorundadır, yoksa panel iki farklı sunucuyu iki farklı şekilde görür.

---

## 1. Temel ilkeler

Bu ilkeler tartışmaya kapalıdır. Ajan müşterinin sunucusunda çalışır ve
kaynağı herkese açıktır, çünkü kimsenin "acaba içinde ne var" diye sorması
gerekmemelidir.

1. **Ajan komut çalıştırmaz.** Signalbird ajana "şunu çalıştır" diyemez.
   Panelden gelen şey komut değil, ayardır: hangi ölçüm açık, hangi aralıkla,
   hangi dosya okunacak. Ne çalıştırılacağına her zaman ajanın kendi kaynağı
   karar verir. Ajanın çalıştırdığı komutların tam listesi bu belgenin §7
   bölümündedir.
2. **Ajan yalnız okur.** Servis başlatmaz, dosya silmez, yapılandırma
   değiştirmez, paket kurmaz.
3. **Dosya erişimi sunucuda sınırlanır.** Panelden bir log yolu seçilebilir
   ama bu yol, sunucudaki yerel ayarda (`allow_paths`) izin verilen köklerin
   altında değilse okunmaz. Signalbird hesabı ele geçse bile yeni bir dosya
   okutulamaz.
4. **Kimlik bilgileri sunucuda kalır.** Veritabanı kullanıcı adı ve parolası
   yalnız yerel ayar dosyasında durur, Signalbird'e hiç gönderilmez ve
   panelden yönetilemez.
5. **Tek dosya.** Müşteri tek bir dosya indirir, çalıştırır ve iş biter.
   Ek paket, ek kütüphane, ek depo yoktur.

---

## 2. Kimlik doğrulama

Her istek tek bir ajan anahtarı taşır:

```
Authorization: Bearer sba_live_XXXXXXXXXXXXXXXXXXXXXXXX
Content-Type: application/json
Accept: application/json
User-Agent: signalbird-agent/1.0.0 (linux)
```

`Accept` başlığı zorunludur ve unutulması sessiz bir hataya yol açar: Laravel,
JSON istemediğini söyleyen bir istemciye doğrulama hatasını 422 yerine 302
yönlendirme olarak döner. Ajan o zaman "ne oldu" sorusuna cevap veremez.

Anahtar panelde sunucu kaydı açılırken üretilir, bir kez gösterilir ve
sunucudaki yerel ayar dosyasına yazılır. Anahtar yalnız bu belgedeki uçlara
erişir: takımın diğer verilerine (kişi listesi, kampanya, fatura) erişemez.

Anahtar sızarsa yapılabilecek en kötü şey, sahte ölçüm ve sahte log
göndermektir. Bu yüzden panelden anahtar tazeleme (rotate) vardır ve eski
anahtar o anda ölür.

---

## 3. Uçlar

Taban adres yerel ayardaki `api_base` değeridir (varsayılan
`https://api.signalbird.app/api`).

### 3.1 `POST /v1/agent/hello`

Ajan açılışta bir kez, sonra her `config_refresh_seconds` sürede bir çağırır.
Hem "buradayım" der hem ayarını alır.

İstek:

```json
{
  "version": "1.0.0",
  "protocol": 1,
  "hostname": "web-01",
  "os": "linux",
  "os_version": "Ubuntu 24.04.1 LTS",
  "arch": "x86_64",
  "boot_time": "2026-08-28T04:12:00Z",
  "started_at": "2026-08-30T09:00:00Z"
}
```

Yanıt:

```json
{
  "ok": true,
  "agent": { "id": 12, "name": "web-01", "team": "Penyu" },
  "server_time": "2026-08-30T09:00:01Z",
  "config": { "...": "bkz. §4" },
  "release": {
    "version": "1.1.0",
    "is_outdated": true,
    "notes_url": "https://signalbird.app/agent/changelog",
    "download_url": "https://raw.githubusercontent.com/Pariette-Inc/agent.signalbird/main/signalbird-agent.sh",
    "sha256": "…"
  }
}
```

`release.is_outdated` doğruysa ajan bunu kendi kaydına yazar ve bir kez
uyarır. **Ajan kendini güncellemez.** Kendini güncelleyen bir ajan, uzaktan
kod çalıştırmanın kibar hâlidir. Güncelleme kararı müşteriye aittir,
Signalbird yalnız haber verir.

### 3.2 `GET /v1/agent/config`

`hello` ile aynı ayarı döner, gövde göndermeden. Ajan yeniden başlatıldığında
ve ayar tazelemesinde kullanılır.

### 3.3 `POST /v1/agent/metrics`

Ölçüm gönderimi. `interval_seconds` aralığıyla çağrılır.

```json
{
  "collected_at": "2026-08-30T09:01:00Z",
  "metrics": {
    "uptime_seconds": 183600,
    "load": { "1m": 0.42, "5m": 0.51, "15m": 0.48 },
    "cpu_percent": 12.4,
    "memory": { "total_mb": 7960, "used_mb": 3120, "percent": 39.2 },
    "swap":   { "total_mb": 2048, "used_mb": 0, "percent": 0 },
    "disks": [
      { "mount": "/", "total_gb": 78.2, "used_gb": 41.9, "percent": 53.6, "inode_percent": 11 }
    ],
    "services": [
      { "name": "nginx", "state": "running" },
      { "name": "mysql", "state": "running" }
    ],
    "ports": [ { "port": 443, "process": "nginx" } ],
    "processes": [ { "name": "php-fpm", "cpu": 8.1, "memory_mb": 240 } ],
    "socket": { "ok": true, "clients": 184, "rooms": 22, "events_per_second": 41.5 },
    "database": {
      "ok": true, "driver": "mysql", "response_ms": 3,
      "connections": 24, "max_connections": 151,
      "slow_queries": 0, "uptime_seconds": 900000, "size_mb": 2410
    }
  }
}
```

Kapalı toplayıcının anahtarı gövdede **hiç bulunmaz**. `null` göndermek ile
göndermemek aynı şey değildir: panel "ölçüm yok" ile "ölçüm sıfır" ayrımını
buradan yapar.

### 3.4 `POST /v1/agent/logs`

Sunucudaki log dosyalarından okunan yeni satırlar. Signalbird bunları Telsiz
sistemine yazar. Tek istekte en çok 100 kayıt, kayıt başına 4000 karakter.

Alan sınırları sunucudaki doğrulamayla aynıdır ve ajan **kırparak** gönderir:
`message` en çok 4000, `source` en çok 120 karakter. Sınırı aşan bir satır 422
döndürür; konum ilerlemeseydi aynı satır sonsuza kadar tekrar denenirdi.

```json
{
  "events": [
    {
      "channel": "sunucu",
      "level": "error",
      "message": "2026/08/30 09:00:12 [error] 1234#0: *5 connect() failed",
      "source": "web-01:/var/log/nginx/error.log",
      "context": { "path": "/var/log/nginx/error.log", "line": 8123 }
    }
  ]
}
```

Yanıt, Telsiz toplu giriş ucundaki gibi satır satırdır: kota tam ortada
dolabilir, ajan hangi kaydın düştüğünü bilmelidir.

### 3.5 `POST /v1/agent/signal`

Beklenen sinyal. "Yedeği aldım" senaryosunun ta kendisi.

```json
{ "key": "db-backup", "status": "ok", "message": "42 tablo, 2.4 GB, 51 sn" }
```

`status` yalnız `ok` veya `fail` olabilir.

- `ok`: beklenen slot karşılandı.
- `fail`: iş çalıştı ama başarısız oldu. Signalbird pencereyi beklemez,
  alarmı **anında** çalar. Sessizlik yalnız "sunucu tamamen öldü" hâlini
  yakalar, başarısızlığı ise sunucu kendisi söyler.

Sinyalin ne zaman beklendiğine Signalbird karar verir (takvim çapası panelde
tanımlıdır), ajan yalnız "oldu" der. Ajan kendi saatine göre karar verseydi,
saati kaymış bir sunucu sessizce alarmsız kalırdı.

---

## 4. Ayar şeması (panelden gelir)

```json
{
  "config_version": 7,
  "interval_seconds": 60,
  "config_refresh_seconds": 300,
  "collectors": {
    "system": true,
    "disks": true,
    "services": ["nginx", "mysql", "redis"],
    "ports": true,
    "processes": 5,
    "socket": { "enabled": true, "url": "http://127.0.0.1:3000/metrics" },
    "database": { "enabled": true }
  },
  "logs": [
    {
      "channel": "sunucu",
      "path": "/var/log/nginx/error.log",
      "level": "error",
      "match": "\\[error\\]|\\[crit\\]",
      "max_lines": 200
    }
  ],
  "signals": [
    { "key": "db-backup", "mode": "manual" },
    { "key": "dump-file", "mode": "file", "path": "/var/backups/db.sql.gz", "max_age_minutes": 70 }
  ]
}
```

Alan açıklamaları:

| Alan | Anlamı |
| --- | --- |
| `config_version` | Her kaydetmede artar. Ajan bunu loglar, panelde "ayar ulaştı mı" böyle görülür. |
| `interval_seconds` | Ölçüm gönderim aralığı. Alt sınır 30, üst sınır 3600. |
| `config_refresh_seconds` | Ayar tazeleme aralığı. Alt sınır 60. |
| `collectors.services` | İzlenecek servis adları. Boş dizi verilirse servis toplanmaz. |
| `collectors.processes` | Kaç sürecin listeleneceği (CPU'ya göre ilk N). 0 kapatır. |
| `collectors.socket.url` | Yalnız `127.0.0.1` veya `localhost` adresleri kabul edilir. Ajan dışarıya istek atmaz. |
| `collectors.database.enabled` | Açıksa bağlantı bilgisi **yerel ayardan** okunur, panelden değil. |
| `logs[].path` | Yerel `allow_paths` altında olmalıdır, değilse okunmaz ve panele "reddedildi" bilgisi düşer. |
| `logs[].match` | Yalnız eşleşen satırlar gönderilir. Boşsa hepsi gönderilir. |
| `logs[].max_lines` | Bir turda bir dosyadan gönderilecek en çok satır. Log patlamasında ajan kendini boğmaz. |
| `signals[].mode` | `manual`: sinyali müşterinin kendi betiği `signalbird-agent signal <key>` ile atar. `file`: ajan dosyanın değişim zamanına bakar, `max_age_minutes` içinde tazeyse sinyali kendisi atar. |

---

## 5. Yerel ayar dosyası (sunucuda kalır)

Linux: `/etc/signalbird/agent.conf`
Windows: `C:\ProgramData\Signalbird\agent.conf`

```ini
# Signalbird ajan yerel ayarı. Bu dosya sunucudan dışarı çıkmaz.
token=sba_live_XXXXXXXXXXXXXXXXXXXX
api_base=https://api.signalbird.app/api

# Panelden seçilen log yolları YALNIZ bu köklerin altındaysa okunur.
allow_paths=/var/log

# Veritabanı izleme açıksa kullanılır. Panelde görünmez, panele gönderilmez.
db_driver=mysql
db_host=127.0.0.1
db_port=3306
db_user=signalbird_ro
db_pass=...
db_name=penyu
```

Veritabanı kullanıcısının **salt okunur** olması beklenir. Ajan yalnız durum
sorgusu çalıştırır (§7), ama en küçük yetki ilkesi burada da geçerlidir.

---

## 6. Durum dosyası

Linux: `/var/lib/signalbird/state`
Windows: `C:\ProgramData\Signalbird\state`

Log dosyalarının okunma noktası (offset) ve dosya kimliği burada tutulur.
Dosya döndüğünde (logrotate) boyut küçüldüğü için ajan başa döner, aynı
satırları ikinci kez göndermez.

---

## 7. Ajanın çalıştırdığı komutların tam listesi

Denetim kolaylığı için burada toplu hâlde durur. Bu listede olmayan hiçbir
komut çalışmaz.

**Linux**

| Komut | Ne için |
| --- | --- |
| `uptime`, `cat /proc/uptime`, `cat /proc/loadavg` | Çalışma süresi ve yük |
| `cat /proc/stat`, `cat /proc/meminfo` | CPU ve bellek |
| `df -P`, `df -Pi` | Disk ve inode doluluğu |
| `systemctl is-active <servis>` | Servis durumu |
| `ss -ltnp` | Dinlenen portlar |
| `ps -eo comm,pcpu,rss --sort=-pcpu` | En çok CPU kullanan süreçler |
| `curl` (yalnız localhost ve Signalbird API'si) | Socket ölçümü ve gönderim |
| `mysql -e "SHOW GLOBAL STATUS"` / `psql -c` | Veritabanı durumu |
| `tail -c +<offset>` | Log okuma |
| `systemctl` (yalnız kurulum sırasında, kendi servisi için) | Kurulum |

**Windows**

| Komut | Ne için |
| --- | --- |
| `Get-CimInstance Win32_OperatingSystem` | Çalışma süresi, bellek |
| `Get-CimInstance Win32_Processor` | CPU |
| `Get-CimInstance Win32_LogicalDisk` | Disk |
| `Get-Service <ad>` | Servis durumu |
| `Get-NetTCPConnection -State Listen` | Portlar |
| `Get-Process` | Süreçler |
| `Invoke-RestMethod` (yalnız localhost ve Signalbird API'si) | Socket ölçümü ve gönderim |
| `Get-Content -Tail` | Log okuma |
| `New-Service` / `sc.exe` (yalnız kurulum sırasında) | Kurulum |

---

## 8. Sürüm bildirimi

Ajan dosyasında yapılan **her** değişiklik yeni bir sürüm numarası alır ve
Signalbird tarafında yayınlanır. Yayınlandığı anda:

1. Eski sürümü bildiren her ajanın kaydına "güncelleme var" işareti düşer.
2. Sunucunun bağlı olduğu takıma bildirim gider (sürüm başına bir kez, her
   turda tekrar tekrar değil).
3. Panelde sunucu satırında sürüm rozeti sararır.

Bu, hatırlanması gereken bir görev değil, mekanizmadır: sürüm kaydı
girilmeden değişiklik yayınlanmış sayılmaz.

Sürüm numarası `VERSION` dosyasında ve iki ajan dosyasının başındaki
`SB_AGENT_VERSION` değişkeninde **aynı** olmak zorundadır.

---

## 9. Hata durumunda davranış

| Durum | Ajanın davranışı |
| --- | --- |
| Signalbird'e ulaşılamıyor | Ölçümü atar, log noktasını **ilerletmez**, bir sonraki turda dener. Kuyruk diske yazılmaz: eski ölçümün değeri yoktur, eski logun vardır ve o zaten dosyada durur. |
| Sunucu 5xx döndü | Ağ hatasıyla aynı: konum durur, tekrar denenir. |
| Sunucu 4xx döndü (429 hariç) | Log konumu **yine de ilerletilir** ve durum yerel günlüğe yazılır. Sunucunun kabul etmeyeceği bir kaydı sonsuza kadar tekrar göndermek, tek bozuk satır yüzünden tüm log akışını durdurmak olurdu. |
| 429 (kota/hız sınırı) | Konum durur: kayıt geçerli, yalnız zamanı değil. |
| Anahtar geçersiz (401) | Döngü durur, yerel loga tek satır hata yazar. Sonsuz döngüde 401 üretmez. |
| Ayar çekilemedi | En son bilinen ayarla devam eder. İlk açılışta ayar yoksa yalnız `hello` dener. |
| Log yolu izinli değil | O yolu atlar, panele bir kez bildirir, diğer yollara devam eder. |
| Veritabanına bağlanılamıyor | `database.ok=false` gönderir. Ajan ölmez, panel sorunu görür. |
