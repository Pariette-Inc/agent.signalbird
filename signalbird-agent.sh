#!/usr/bin/env bash
#
# Signalbird sunucu ajanı (Linux)
# yazar: ahmet selim çil | ahmet@pariette.com
# kaynak: https://github.com/Pariette-Inc/agent.signalbird
# lisans ve sözleşme: PROTOCOL.md
#
# NE YAPAR
#   Sunucunun durumunu okur (yük, bellek, disk, servis, port, süreç, socket,
#   veritabanı), hata loglarını takip eder ve Signalbird'e gönderir. Beklenen
#   sinyalleri (örnek: "yedeği aldım") iletir.
#
# NE YAPMAZ
#   Sunucuda hiçbir şeyi değiştirmez. Signalbird bu ajana komut gönderemez.
#   Panelden gelen şey komut değil ayardır: hangi ölçüm açık, hangi aralıkla,
#   hangi dosya okunacak. Çalıştırılan komutların tam listesi PROTOCOL.md §7.
#
# KURULUM
#   sudo bash signalbird-agent.sh install --token=sba_live_xxx
#
# ELLE ÇALIŞTIRMA
#   signalbird-agent once                      tek tur ölçüm gönderir
#   signalbird-agent signal db-backup ok       beklenen sinyali iletir
#   signalbird-agent status                    yerel durumu yazar
#
set -u

# Boru hattındaki bir hata sessizce yutulmasın. `set -e` bilerek YOK: ajan
# tek bir toplayıcı patladı diye ölmemeli, o ölçümü atlayıp devam etmeli.
set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  Sabitler
# ─────────────────────────────────────────────────────────────────────────────

# Sürüm. PROTOCOL.md §8: bu değer VERSION dosyasıyla ve PowerShell ajanıyla
# AYNI olmak zorundadır. Değiştiren kişi üçünü birden değiştirir.
SB_AGENT_VERSION="1.0.1"

# Protokol sürümü. Sunucu tarafı gövdeyi buna göre yorumlar.
SB_PROTOCOL=1

SB_CONF="/etc/signalbird/agent.conf"
SB_STATE_DIR="/var/lib/signalbird"
SB_STATE="${SB_STATE_DIR}/state"
SB_CONFIG_CACHE="${SB_STATE_DIR}/config.json"
SB_LOG="/var/log/signalbird-agent.log"
SB_SERVICE="/etc/systemd/system/signalbird-agent.service"
SB_BIN="/usr/local/bin/signalbird-agent"

SB_DEFAULT_API="https://live.signalbird.io/api"
SB_DEFAULT_ALLOW="/var/log"

# Ayar çekilemediğinde kullanılan değerler.
SB_INTERVAL=60
SB_CONFIG_REFRESH=300

# Yerel ayardan doldurulur.
SB_TOKEN=""
SB_API=""
SB_ALLOW_PATHS=""
SB_DB_DRIVER=""
SB_DB_HOST=""
SB_DB_PORT=""
SB_DB_USER=""
SB_DB_PASS=""
SB_DB_NAME=""

# JSON okuma aracı: python3 ya da jq. Ubuntu sunucularında python3 zaten
# kuruludur; ikisi de yoksa kurulum en baştan reddedilir. Kendi JSON
# ayrıştırıcımızı yazmak, ilk çok satırlı log mesajında sessizce bozulurdu.
SB_JSON=""

# ─────────────────────────────────────────────────────────────────────────────
#  Yardımcılar
# ─────────────────────────────────────────────────────────────────────────────

sb_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Yerel günlük. Sunucunun kendi diskine yazar, Signalbird'e gitmez: ajan
# Signalbird'e ulaşamadığında sorunun izini burada bırakması gerekir.
sb_log() {
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
    if [ -w "$(dirname "$SB_LOG")" ] || [ -w "$SB_LOG" ]; then
        printf '%s\n' "$line" >> "$SB_LOG" 2>/dev/null
    fi
    # Servis olarak çalışırken stderr journald'a düşer, elle çalışırken ekrana.
    printf '%s\n' "$line" >&2
}

sb_die() { sb_log "hata" "$1"; exit 1; }

# JSON dize kaçışı. Gövdeyi elle kuruyoruz, çünkü python3'ü her satır için
# çağırmak bir log turunu yüzlerce süreç açmaya çevirirdi.
sb_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//	/\\t}"
    s="${s//$'\r'/}"
    s="${s//$'\n'/\\n}"
    # Görünmez kontrol karakterleri JSON'da yasaktır, temizlenir.
    printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

# JSON okuma. `sb_json_get <json> <yol> [varsayılan]`
# Yol noktalıdır: collectors.socket.url gibi. Dizi indeksi desteklenmez;
# diziler sb_json_list ile alınır.
sb_json_get() {
    local json="$1" path="$2" fallback="${3:-}"
    local out=""
    if [ "$SB_JSON" = "python3" ]; then
        out="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
cur = data
for part in sys.argv[1].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(1)
if isinstance(cur, bool):
    print("true" if cur else "false")
elif cur is None:
    sys.exit(1)
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, ensure_ascii=False))
else:
    print(cur)
' "$path" 2>/dev/null)"
    else
        out="$(printf '%s' "$json" | jq -r --arg p "$path" '
            getpath($p | split(".")) // empty
            | if type == "object" or type == "array" then tojson else . end
        ' 2>/dev/null)"
    fi
    if [ -z "$out" ]; then printf '%s' "$fallback"; else printf '%s' "$out"; fi
}

# JSON dizisini satır satır verir. Nesne dizisiyse her satır bir JSON nesnesi
# olur, satır içindeki alanlar yine sb_json_get ile okunur.
sb_json_list() {
    local json="$1" path="$2"
    if [ "$SB_JSON" = "python3" ]; then
        printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
cur = data
for part in sys.argv[1].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(0)
if not isinstance(cur, list):
    sys.exit(0)
for item in cur:
    print(json.dumps(item, ensure_ascii=False) if isinstance(item, (dict, list)) else item)
' "$path" 2>/dev/null
    else
        printf '%s' "$json" | jq -r --arg p "$path" '
            (getpath($p | split(".")) // [])[]
            | if type == "object" or type == "array" then tojson else . end
        ' 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Yerel ayar
# ─────────────────────────────────────────────────────────────────────────────

sb_load_conf() {
    [ -f "$SB_CONF" ] || sb_die "Ayar dosyası yok: $SB_CONF (önce install çalıştırın)"

    # Ayar dosyası `source` EDİLMEZ. Edilseydi dosyaya bir satır yazabilen
    # herkes root olurdu; oysa dosya yalnız anahtar tutuyor.
    local key value
    while IFS='=' read -r key value; do
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        [ -z "$key" ] && continue
        case "$key" in \#*) continue ;; esac
        # Değerdeki baştaki ve sondaki boşluklar atılır, içerideki korunur
        # (parolada boşluk olabilir).
        value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$key" in
            token)       SB_TOKEN="$value" ;;
            api_base)    SB_API="$value" ;;
            allow_paths) SB_ALLOW_PATHS="$value" ;;
            db_driver)   SB_DB_DRIVER="$value" ;;
            db_host)     SB_DB_HOST="$value" ;;
            db_port)     SB_DB_PORT="$value" ;;
            db_user)     SB_DB_USER="$value" ;;
            db_pass)     SB_DB_PASS="$value" ;;
            db_name)     SB_DB_NAME="$value" ;;
        esac
    done < "$SB_CONF"

    [ -n "$SB_TOKEN" ] || sb_die "Ayar dosyasında token yok"
    # 1.0.0 ile kurulan ajanların ayar dosyasında var olmayan bir adres
    # (api.signalbird.app) yazılı kaldı. Dosyadaki değer varsayılanı ezdiği
    # için yalnız betiği güncellemek yetmiyor; o adres burada göz ardı edilir.
    case "$SB_API" in
        *signalbird.app*)
            sb_log "uyari" "Ayar dosyasındaki api_base geçersiz ($SB_API), $SB_DEFAULT_API kullanılıyor. Kalıcı düzeltme: signalbird-agent config"
            SB_API=""
            ;;
    esac
    [ -n "$SB_API" ] || SB_API="$SB_DEFAULT_API"
    [ -n "$SB_ALLOW_PATHS" ] || SB_ALLOW_PATHS="$SB_DEFAULT_ALLOW"

    if command -v python3 >/dev/null 2>&1; then
        SB_JSON="python3"
    elif command -v jq >/dev/null 2>&1; then
        SB_JSON="jq"
    else
        sb_die "python3 veya jq gerekli (JSON okumak için)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  HTTP
# ─────────────────────────────────────────────────────────────────────────────

# `sb_post <yol> <gövde>` — yanıt gövdesini basar, HTTP kodunu DOSYAYA yazar.
# Ağ hatası kodu 000 olur.
#
# Kod neden değişkende değil dosyada tutuluyor: bu fonksiyon çoğu yerde
# `resp="$(sb_post …)"` biçiminde, yani KOMUT İKAMESİ içinde çağrılıyor. Komut
# ikamesi alt kabukta çalışır ve orada yapılan değişken ataması ana kabuğa
# dönmez; kodu bir değişkene yazdığımızda çağıran taraf her zaman eski değeri
# (0) okuyordu ve başarılı istekler "başarısız" sayılıyordu.
sb_http_file() {
    printf '%s' "${SB_STATE_DIR}/.http_code"
}

sb_http_code() {
    cat "$(sb_http_file)" 2>/dev/null || printf '000'
}

sb_set_http_code() {
    mkdir -p "$SB_STATE_DIR" 2>/dev/null
    printf '%s' "${1:-000}" > "$(sb_http_file)" 2>/dev/null
}

sb_post() {
    local path="$1" body="$2" out code
    out="$(printf '%s' "$body" | curl -sS -m 20 -w '\n%{http_code}' \
        -X POST "${SB_API}${path}" \
        -H "Authorization: Bearer ${SB_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "User-Agent: signalbird-agent/${SB_AGENT_VERSION} (linux)" \
        --data-binary @- 2>/dev/null)"
    code="$(printf '%s' "$out" | tail -n1)"
    sb_set_http_code "${code:-000}"
    printf '%s' "$out" | sed '$d'
}

sb_get() {
    local path="$1" out code
    out="$(curl -sS -m 20 -w '\n%{http_code}' \
        "${SB_API}${path}" \
        -H "Authorization: Bearer ${SB_TOKEN}" \
        -H "Accept: application/json" \
        -H "User-Agent: signalbird-agent/${SB_AGENT_VERSION} (linux)" 2>/dev/null)"
    code="$(printf '%s' "$out" | tail -n1)"
    sb_set_http_code "${code:-000}"
    printf '%s' "$out" | sed '$d'
}

# ─────────────────────────────────────────────────────────────────────────────
#  Ayar çekme (panelden)
# ─────────────────────────────────────────────────────────────────────────────

SB_CONFIG=""

sb_hello() {
    local body resp
    body="$(cat <<JSON
{"version":"${SB_AGENT_VERSION}","protocol":${SB_PROTOCOL},"hostname":"$(sb_json_escape "$(hostname)")","os":"linux","os_version":"$(sb_json_escape "$(sb_os_version)")","arch":"$(sb_json_escape "$(uname -m)")","boot_time":"$(sb_boot_time)","started_at":"$(sb_now)"}
JSON
)"
    resp="$(sb_post "/v1/agent/hello" "$body")"

    local code
    code="$(sb_http_code)"

    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
        sb_die "Anahtar reddedildi (HTTP $code). Panelden anahtarı yenileyin."
    fi

    if [ "$code" != "200" ]; then
        sb_log "uyari" "hello başarısız (HTTP $code), son bilinen ayarla devam"
        sb_load_cached_config
        return 1
    fi

    SB_CONFIG="$(sb_json_get "$resp" "config" "")"
    if [ -n "$SB_CONFIG" ]; then
        mkdir -p "$SB_STATE_DIR" 2>/dev/null
        printf '%s' "$SB_CONFIG" > "$SB_CONFIG_CACHE"
    else
        sb_load_cached_config
    fi

    sb_apply_intervals

    # Sürüm uyarısı. Ajan kendini GÜNCELLEMEZ: kendini güncelleyen bir ajan,
    # uzaktan kod çalıştırmanın kibar hâlidir. Yalnız haber verir.
    local outdated newv
    outdated="$(sb_json_get "$resp" "release.is_outdated" "false")"
    newv="$(sb_json_get "$resp" "release.version" "")"
    if [ "$outdated" = "true" ] && [ -n "$newv" ]; then
        sb_log "bilgi" "Yeni ajan sürümü var: ${newv} (kurulu: ${SB_AGENT_VERSION}). Güncelleme kararı sizindir."
    fi

    return 0
}

sb_load_cached_config() {
    if [ -f "$SB_CONFIG_CACHE" ]; then
        SB_CONFIG="$(cat "$SB_CONFIG_CACHE")"
        sb_apply_intervals
    fi
}

sb_apply_intervals() {
    local i r
    i="$(sb_json_get "$SB_CONFIG" "interval_seconds" "60")"
    r="$(sb_json_get "$SB_CONFIG" "config_refresh_seconds" "300")"
    case "$i" in ''|*[!0-9]*) i=60 ;; esac
    case "$r" in ''|*[!0-9]*) r=300 ;; esac
    [ "$i" -lt 30 ] && i=30
    [ "$i" -gt 3600 ] && i=3600
    [ "$r" -lt 60 ] && r=60
    SB_INTERVAL="$i"
    SB_CONFIG_REFRESH="$r"
}

sb_os_version() {
    if [ -r /etc/os-release ]; then
        # PRETTY_NAME satırı tırnaklı gelir, tırnaklar atılır.
        grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'
    else
        uname -sr
    fi
}

sb_boot_time() {
    local up
    up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)"
    case "$up" in ''|*[!0-9]*) sb_now; return ;; esac
    date -u -d "@$(( $(date +%s) - up ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || sb_now
}

# ─────────────────────────────────────────────────────────────────────────────
#  Toplayıcılar
#
#  Hepsi tek kural altında çalışır: yalnız okur, çıktısını JSON parçası olarak
#  basar, hata hâlinde boş basar. Kapalı toplayıcının anahtarı gövdede HİÇ
#  bulunmaz (PROTOCOL.md §3.3): "ölçüm yok" ile "ölçüm sıfır" farklı şeylerdir.
# ─────────────────────────────────────────────────────────────────────────────

sb_collect_system() {
    local uptime load1 load5 load15 cpu mem_total mem_avail mem_used mem_pct
    local swap_total swap_free swap_used swap_pct

    uptime="$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)"
    case "$uptime" in ''|*[!0-9]*) uptime=0 ;; esac

    read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || { load1=0; load5=0; load15=0; }

    cpu="$(sb_cpu_percent)"

    mem_total="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    mem_avail="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    swap_total="$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    swap_free="$(awk '/^SwapFree:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
    : "${mem_total:=0}" ; : "${mem_avail:=0}" ; : "${swap_total:=0}" ; : "${swap_free:=0}"

    mem_used=$(( mem_total - mem_avail ))
    mem_pct=0
    [ "$mem_total" -gt 0 ] && mem_pct="$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.1f", (u/t)*100}')"

    swap_used=$(( swap_total - swap_free ))
    swap_pct=0
    [ "$swap_total" -gt 0 ] && swap_pct="$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{printf "%.1f", (u/t)*100}')"

    printf '"uptime_seconds":%s,"load":{"1m":%s,"5m":%s,"15m":%s},"cpu_percent":%s,' \
        "$uptime" "$load1" "$load5" "$load15" "$cpu"
    printf '"memory":{"total_mb":%s,"used_mb":%s,"percent":%s},' "$mem_total" "$mem_used" "$mem_pct"
    printf '"swap":{"total_mb":%s,"used_mb":%s,"percent":%s}' "$swap_total" "$swap_used" "$swap_pct"
}

# CPU yüzdesi iki /proc/stat okuması arasındaki farktan hesaplanır. Tek okuma,
# makine açıldığından beri geçen sürenin ortalamasını verirdi ki o da anlık
# yükü hiç göstermez.
sb_cpu_percent() {
    local a b idle_a total_a idle_b total_b
    a="$(grep -m1 '^cpu ' /proc/stat 2>/dev/null)"
    [ -z "$a" ] && { printf '0'; return; }
    sleep 1
    b="$(grep -m1 '^cpu ' /proc/stat 2>/dev/null)"
    idle_a="$(printf '%s' "$a" | awk '{print $5+$6}')"
    total_a="$(printf '%s' "$a" | awk '{s=0; for(i=2;i<=NF;i++) s+=$i; print s}')"
    idle_b="$(printf '%s' "$b" | awk '{print $5+$6}')"
    total_b="$(printf '%s' "$b" | awk '{s=0; for(i=2;i<=NF;i++) s+=$i; print s}')"
    awk -v ia="$idle_a" -v ta="$total_a" -v ib="$idle_b" -v tb="$total_b" \
        'BEGIN{d=tb-ta; if(d<=0){print 0} else {printf "%.1f", (1-((ib-ia)/d))*100}}'
}

sb_collect_disks() {
    local first=1
    printf '"disks":['
    # Yalnız gerçek yerel dosya sistemleri. tmpfs, overlay ve ağ bağlantıları
    # panelde "disk doldu" alarmı üretip kimseyi ilgilendirmezdi.
    df -P -x tmpfs -x devtmpfs -x overlay -x squashfs -x nfs -x nfs4 -x cifs 2>/dev/null \
        | awk 'NR>1 {print $1, $2, $3, $6}' | while read -r dev total used mount; do
        local ipct total_gb used_gb pct
        ipct="$(df -Pi "$mount" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
        case "$ipct" in ''|*[!0-9]*) ipct=0 ;; esac
        total_gb="$(awk -v k="$total" 'BEGIN{printf "%.1f", k/1048576}')"
        used_gb="$(awk -v k="$used" 'BEGIN{printf "%.1f", k/1048576}')"
        pct="$(awk -v u="$used" -v t="$total" 'BEGIN{if(t<=0){print 0}else{printf "%.1f",(u/t)*100}}')"
        [ "$first" -eq 0 ] && printf ','
        first=0
        printf '{"device":"%s","mount":"%s","total_gb":%s,"used_gb":%s,"percent":%s,"inode_percent":%s}' \
            "$(sb_json_escape "$dev")" "$(sb_json_escape "$mount")" "$total_gb" "$used_gb" "$pct" "$ipct"
    done
    printf ']'
}

# Servis durumu. `systemctl is-active` yalnız OKUR, servise dokunmaz.
sb_collect_services() {
    local names="$1" first=1 state
    printf '"services":['
    printf '%s\n' "$names" | while IFS= read -r name; do
        [ -z "$name" ] && continue
        if command -v systemctl >/dev/null 2>&1; then
            state="$(systemctl is-active "$name" 2>/dev/null)"
        else
            state="unknown"
        fi
        case "$state" in
            active)   state="running" ;;
            inactive) state="stopped" ;;
            failed)   state="failed" ;;
            "")       state="unknown" ;;
        esac
        [ "$first" -eq 0 ] && printf ','
        first=0
        printf '{"name":"%s","state":"%s"}' "$(sb_json_escape "$name")" "$state"
    done
    printf ']'
}

sb_collect_ports() {
    local first=1
    printf '"ports":['
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' \
            | grep -E '^[0-9]+$' | sort -n -u | head -50 | while read -r port; do
            [ "$first" -eq 0 ] && printf ','
            first=0
            printf '{"port":%s}' "$port"
        done
    fi
    printf ']'
}

sb_collect_processes() {
    local limit="$1" first=1
    printf '"processes":['
    ps -eo comm=,pcpu=,rss= --sort=-pcpu 2>/dev/null | head -n "$limit" | while read -r name cpu rss; do
        [ -z "$name" ] && continue
        [ "$first" -eq 0 ] && printf ','
        first=0
        printf '{"name":"%s","cpu":%s,"memory_mb":%s}' \
            "$(sb_json_escape "$name")" "${cpu:-0}" "$(( ${rss:-0} / 1024 ))"
    done
    printf ']'
}

# Socket.io ölçümü. Adres YALNIZ localhost olabilir: ajan, panelden verilen
# rastgele bir adrese istek atan bir tarayıcıya dönüşmemeli. Aksi hâlde
# Signalbird hesabını ele geçiren biri, müşterinin sunucusunu iç ağı taramak
# için kullanabilirdi.
sb_collect_socket() {
    local url="$1" resp ok clients rooms eps
    case "$url" in
        http://127.0.0.1:*|http://localhost:*|http://[::1]:*) ;;
        *) sb_log "uyari" "socket adresi localhost değil, atlandı: $url"; return ;;
    esac
    resp="$(curl -sS -m 5 "$url" 2>/dev/null)"
    if [ -z "$resp" ]; then
        printf '"socket":{"ok":false}'
        return
    fi
    clients="$(sb_json_get "$resp" "clients" "$(sb_json_get "$resp" "connections" "0")")"
    rooms="$(sb_json_get "$resp" "rooms" "0")"
    eps="$(sb_json_get "$resp" "events_per_second" "0")"
    case "$clients" in ''|*[!0-9]*) clients=0 ;; esac
    case "$rooms" in ''|*[!0-9]*) rooms=0 ;; esac
    case "$eps" in ''|*[!0-9.]*) eps=0 ;; esac
    printf '"socket":{"ok":true,"clients":%s,"rooms":%s,"events_per_second":%s}' "$clients" "$rooms" "$eps"
}

# Veritabanı ölçümü. Bağlantı bilgisi YALNIZ yerel ayardan okunur, panelden
# değil (PROTOCOL.md §1.4). Panel yalnız "izle" veya "izleme" der.
sb_collect_database() {
    local start end ms

    [ -n "$SB_DB_DRIVER" ] || { printf '"database":{"ok":false,"error":"yerel ayarda db_driver yok"}'; return; }

    start="$(date +%s%N)"

    case "$SB_DB_DRIVER" in
        mysql|mariadb) sb_db_mysql "$start" ;;
        pgsql|postgres|postgresql) sb_db_pgsql "$start" ;;
        *) printf '"database":{"ok":false,"error":"bilinmeyen sürücü"}' ;;
    esac
}

sb_db_mysql() {
    local start="$1" out conn maxconn slow up size end ms
    command -v mysql >/dev/null 2>&1 || { printf '"database":{"ok":false,"error":"mysql istemcisi yok"}'; return; }

    # Parola komut satırına YAZILMAZ: `ps` çıktısında herkes görürdü.
    # MYSQL_PWD ortam değişkeni yalnız bu çağrı için tanımlanır.
    out="$(MYSQL_PWD="$SB_DB_PASS" mysql -h "${SB_DB_HOST:-127.0.0.1}" -P "${SB_DB_PORT:-3306}" \
        -u "$SB_DB_USER" --connect-timeout=5 -N -B \
        -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Slow_queries','Uptime'); SHOW GLOBAL VARIABLES LIKE 'max_connections';" 2>/dev/null)"

    end="$(date +%s%N)"
    ms=$(( (end - start) / 1000000 ))

    if [ -z "$out" ]; then
        printf '"database":{"ok":false,"driver":"mysql","error":"baglanti kurulamadi"}'
        return
    fi

    conn="$(printf '%s' "$out" | awk '$1=="Threads_connected"{print $2}')"
    slow="$(printf '%s' "$out" | awk '$1=="Slow_queries"{print $2}')"
    up="$(printf '%s' "$out" | awk '$1=="Uptime"{print $2}')"
    maxconn="$(printf '%s' "$out" | awk '$1=="max_connections"{print $2}')"
    : "${conn:=0}" ; : "${slow:=0}" ; : "${up:=0}" ; : "${maxconn:=0}"

    size=0
    if [ -n "$SB_DB_NAME" ]; then
        size="$(MYSQL_PWD="$SB_DB_PASS" mysql -h "${SB_DB_HOST:-127.0.0.1}" -P "${SB_DB_PORT:-3306}" \
            -u "$SB_DB_USER" --connect-timeout=5 -N -B \
            -e "SELECT ROUND(SUM(data_length+index_length)/1048576,1) FROM information_schema.tables WHERE table_schema='${SB_DB_NAME}';" 2>/dev/null)"
        case "$size" in ''|NULL|*[!0-9.]*) size=0 ;; esac
    fi

    printf '"database":{"ok":true,"driver":"mysql","response_ms":%s,"connections":%s,"max_connections":%s,"slow_queries":%s,"uptime_seconds":%s,"size_mb":%s}' \
        "$ms" "$conn" "$maxconn" "$slow" "$up" "$size"
}

sb_db_pgsql() {
    local start="$1" conn maxconn size end ms
    command -v psql >/dev/null 2>&1 || { printf '"database":{"ok":false,"error":"psql istemcisi yok"}'; return; }

    export PGPASSWORD="$SB_DB_PASS"
    conn="$(psql -h "${SB_DB_HOST:-127.0.0.1}" -p "${SB_DB_PORT:-5432}" -U "$SB_DB_USER" \
        -d "${SB_DB_NAME:-postgres}" -tAc "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null)"
    maxconn="$(psql -h "${SB_DB_HOST:-127.0.0.1}" -p "${SB_DB_PORT:-5432}" -U "$SB_DB_USER" \
        -d "${SB_DB_NAME:-postgres}" -tAc "SHOW max_connections;" 2>/dev/null)"
    size="$(psql -h "${SB_DB_HOST:-127.0.0.1}" -p "${SB_DB_PORT:-5432}" -U "$SB_DB_USER" \
        -d "${SB_DB_NAME:-postgres}" -tAc "SELECT ROUND(pg_database_size(current_database())/1048576.0,1);" 2>/dev/null)"
    unset PGPASSWORD

    end="$(date +%s%N)"
    ms=$(( (end - start) / 1000000 ))

    if [ -z "$conn" ]; then
        printf '"database":{"ok":false,"driver":"pgsql","error":"baglanti kurulamadi"}'
        return
    fi

    : "${maxconn:=0}" ; : "${size:=0}"
    printf '"database":{"ok":true,"driver":"pgsql","response_ms":%s,"connections":%s,"max_connections":%s,"size_mb":%s}' \
        "$ms" "$conn" "$maxconn" "$size"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Ölçüm turu
# ─────────────────────────────────────────────────────────────────────────────

sb_send_metrics() {
    local body parts svc_names proc_limit socket_url

    parts="$(sb_collect_system)"

    if [ "$(sb_json_get "$SB_CONFIG" "collectors.disks" "true")" = "true" ]; then
        parts="${parts},$(sb_collect_disks)"
    fi

    svc_names="$(sb_json_list "$SB_CONFIG" "collectors.services")"
    if [ -n "$svc_names" ]; then
        parts="${parts},$(sb_collect_services "$svc_names")"
    fi

    if [ "$(sb_json_get "$SB_CONFIG" "collectors.ports" "false")" = "true" ]; then
        parts="${parts},$(sb_collect_ports)"
    fi

    proc_limit="$(sb_json_get "$SB_CONFIG" "collectors.processes" "0")"
    case "$proc_limit" in ''|*[!0-9]*) proc_limit=0 ;; esac
    if [ "$proc_limit" -gt 0 ]; then
        [ "$proc_limit" -gt 20 ] && proc_limit=20
        parts="${parts},$(sb_collect_processes "$proc_limit")"
    fi

    if [ "$(sb_json_get "$SB_CONFIG" "collectors.socket.enabled" "false")" = "true" ]; then
        socket_url="$(sb_json_get "$SB_CONFIG" "collectors.socket.url" "")"
        [ -n "$socket_url" ] && parts="${parts},$(sb_collect_socket "$socket_url")"
    fi

    if [ "$(sb_json_get "$SB_CONFIG" "collectors.database.enabled" "false")" = "true" ]; then
        parts="${parts},$(sb_collect_database)"
    fi

    body="{\"collected_at\":\"$(sb_now)\",\"metrics\":{${parts}}}"

    sb_post "/v1/agent/metrics" "$body" >/dev/null

    local code
    code="$(sb_http_code)"

    if [ "$code" != "200" ] && [ "$code" != "202" ]; then
        sb_log "uyari" "ölçüm gönderilemedi (HTTP $code)"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
#  Log takibi
#
#  Her dosya için en son okunan bayt konumu durum dosyasında tutulur. Dosya
#  döndüğünde (logrotate) boyut küçülür, ajan başa döner. Gönderim başarısız
#  olursa konum İLERLETİLMEZ: aynı satırlar bir sonraki turda tekrar denenir.
# ─────────────────────────────────────────────────────────────────────────────

sb_state_get() {
    local key="$1"
    [ -f "$SB_STATE" ] || { printf '0'; return; }
    grep -m1 "^${key}=" "$SB_STATE" 2>/dev/null | cut -d= -f2- || printf '0'
}

sb_state_set() {
    local key="$1" value="$2" tmp
    mkdir -p "$SB_STATE_DIR" 2>/dev/null
    tmp="${SB_STATE}.tmp.$$"
    if [ -f "$SB_STATE" ]; then
        grep -v "^${key}=" "$SB_STATE" 2>/dev/null > "$tmp"
    else
        : > "$tmp"
    fi
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$SB_STATE"
}

# Panelden gelen yolun yerel izin listesinde olup olmadığına bakar.
# PROTOCOL.md §1.3: Signalbird hesabı ele geçse bile yeni bir dosya okutulamaz.
sb_path_allowed() {
    local path="$1" root real
    # Sembolik bağ ile izinli klasörün dışına çıkılmasın diye gerçek yol alınır.
    real="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
    case "$real" in *..*) return 1 ;; esac
    local IFS=','
    for root in $SB_ALLOW_PATHS; do
        root="$(printf '%s' "$root" | sed -e 's/^[[:space:]]*//' -e 's#/*$##')"
        [ -z "$root" ] && continue
        case "$real" in "$root"/*|"$root") return 0 ;; esac
    done
    return 1
}

# Gönderimi tamamlanan dosyaların okuma konumunu ilerletir.
sb_advance_pending() {
    [ -f "${SB_STATE_DIR}/.pending.$$" ] || return 0

    while IFS='|' read -r k v; do
        [ -n "$k" ] && sb_state_set "$k" "$v"
    done < "${SB_STATE_DIR}/.pending.$$"
}

sb_ship_logs() {
    local specs spec path channel level match max_lines
    local key offset size chunk events count first
    specs="$(sb_json_list "$SB_CONFIG" "logs")"
    [ -z "$specs" ] && return 0

    mkdir -p "$SB_STATE_DIR" 2>/dev/null
    rm -f "${SB_STATE_DIR}/.pending.$$" 2>/dev/null

    events=""
    count=0
    first=1

    while IFS= read -r spec; do
        [ -z "$spec" ] && continue
        path="$(sb_json_get "$spec" "path" "")"
        channel="$(sb_json_get "$spec" "channel" "sunucu")"
        level="$(sb_json_get "$spec" "level" "error")"
        match="$(sb_json_get "$spec" "match" "")"
        max_lines="$(sb_json_get "$spec" "max_lines" "200")"
        case "$max_lines" in ''|*[!0-9]*) max_lines=200 ;; esac
        [ "$max_lines" -gt 500 ] && max_lines=500

        [ -n "$path" ] || continue

        if ! sb_path_allowed "$path"; then
            sb_log "uyari" "log yolu izinli değil, atlandı: $path (izinli kökler: $SB_ALLOW_PATHS)"
            continue
        fi

        [ -r "$path" ] || { sb_log "uyari" "log okunamıyor: $path"; continue; }

        key="log:$(printf '%s' "$path" | tr '/' '_')"
        offset="$(sb_state_get "$key")"
        case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
        size="$(wc -c < "$path" 2>/dev/null | tr -d ' ')"
        case "$size" in ''|*[!0-9]*) size=0 ;; esac

        # Dosya döndüyse (küçüldüyse) baştan başlanır.
        [ "$size" -lt "$offset" ] && offset=0

        # İlk kurulumda geçmiş log baştan sona gönderilmez: müşteri ajanı
        # kurar kurmaz aylık kotasını bir yıllık nginx loguna yakardı.
        if [ "$offset" -eq 0 ] && [ "$size" -gt 0 ]; then
            sb_state_set "$key" "$size"
            continue
        fi

        [ "$size" -le "$offset" ] && continue

        chunk="$(tail -c "+$((offset + 1))" "$path" 2>/dev/null | head -n "$max_lines")"
        [ -z "$chunk" ] && continue

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            if [ -n "$match" ]; then
                printf '%s' "$line" | grep -Eq "$match" || continue
            fi
            [ "$count" -ge 100 ] && break
            [ "$first" -eq 0 ] && events="${events},"
            first=0

            # Alan sınırları sunucudaki doğrulamayla aynı olmalı (source 120,
            # message 4000). Aşan bir satır 422 döndürür ve konum ilerlemediği
            # için AYNI satır sonsuza kadar tekrar denenir: tek uzun yol, tüm
            # log akışını durdururdu.
            local src msg
            src="$(printf '%s' "$(hostname):${path}" | tail -c 110)"
            msg="$(printf '%s' "$line" | cut -c1-3900)"

            events="${events}{\"channel\":\"$(sb_json_escape "$channel")\",\"level\":\"$(sb_json_escape "$level")\",\"message\":\"$(sb_json_escape "$msg")\",\"source\":\"$(sb_json_escape "$src")\",\"context\":{\"path\":\"$(sb_json_escape "$(printf '%s' "$path" | tail -c 200)")\"}}"
            count=$((count + 1))
        done <<EOF
$chunk
EOF

        # Konum, gönderim başarılı olursa ilerletilir. Burada geçici olarak
        # saklanır, gönderim sonucunu aşağıda görürüz.
        printf '%s|%s\n' "$key" "$size" >> "${SB_STATE_DIR}/.pending.$$"
    done <<EOF
$specs
EOF

    if [ "$count" -eq 0 ]; then
        rm -f "${SB_STATE_DIR}/.pending.$$" 2>/dev/null
        return 0
    fi

    sb_post "/v1/agent/logs" "{\"events\":[${events}]}" >/dev/null

    local code
    code="$(sb_http_code)"

    # 2xx: gönderildi. 4xx (429 hariç): sunucu bu kaydı KABUL ETMEYECEK, tekrar
    # denemek akışı sonsuza kadar tıkar — konum yine ilerletilir ve durum
    # günlüğe yazılır. Ağ hatası ve 5xx'te konum DURUR, bir sonraki turda
    # aynı satırlar yeniden denenir.
    if [ "$code" = "200" ] || [ "$code" = "202" ]; then
        sb_advance_pending
        sb_log "bilgi" "${count} log satırı gönderildi"
    elif [ "$code" -ge 400 ] 2>/dev/null && [ "$code" -lt 500 ] 2>/dev/null && [ "$code" != "429" ]; then
        sb_advance_pending
        sb_log "uyari" "log reddedildi (HTTP ${code}), ${count} satır atlandı"
    else
        sb_log "uyari" "log gönderilemedi (HTTP ${code}), konum ilerletilmedi"
    fi

    rm -f "${SB_STATE_DIR}/.pending.$$" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
#  Sinyaller
#
#  Sinyalin ne zaman beklendiğine SIGNALBIRD karar verir, ajan yalnız "oldu"
#  der. Ajan kendi saatine göre karar verseydi, saati kaymış bir sunucu
#  sessizce alarmsız kalırdı.
# ─────────────────────────────────────────────────────────────────────────────

sb_send_signal() {
    local key="$1" status="${2:-ok}" message="${3:-}"
    case "$status" in ok|fail) ;; *) status="ok" ;; esac
    sb_post "/v1/agent/signal" \
        "{\"key\":\"$(sb_json_escape "$key")\",\"status\":\"${status}\",\"message\":\"$(sb_json_escape "$message")\"}" >/dev/null
    local code
    code="$(sb_http_code)"

    if [ "$code" = "200" ] || [ "$code" = "202" ]; then
        sb_log "bilgi" "sinyal iletildi: ${key} (${status})"
        return 0
    fi
    sb_log "uyari" "sinyal iletilemedi: ${key} (HTTP $code)"
    return 1
}

# `mode: file` olan sinyaller: ajan dosyanın değişim zamanına bakar. Yedek
# dosyası tazeyse sinyal gider, bayatsa GİTMEZ. Bayat dosya için "oldu" demek,
# alarmı sessizce kapatmak olurdu.
sb_check_file_signals() {
    local specs spec key mode path max_age mtime age
    specs="$(sb_json_list "$SB_CONFIG" "signals")"
    [ -z "$specs" ] && return 0

    while IFS= read -r spec; do
        [ -z "$spec" ] && continue
        mode="$(sb_json_get "$spec" "mode" "manual")"
        [ "$mode" = "file" ] || continue

        key="$(sb_json_get "$spec" "key" "")"
        path="$(sb_json_get "$spec" "path" "")"
        max_age="$(sb_json_get "$spec" "max_age_minutes" "70")"
        case "$max_age" in ''|*[!0-9]*) max_age=70 ;; esac
        [ -n "$key" ] && [ -n "$path" ] || continue

        if [ ! -f "$path" ]; then
            sb_send_signal "$key" "fail" "dosya yok: ${path}"
            continue
        fi

        mtime="$(stat -c %Y "$path" 2>/dev/null)"
        case "$mtime" in ''|*[!0-9]*) continue ;; esac
        age=$(( ( $(date +%s) - mtime ) / 60 ))

        if [ "$age" -le "$max_age" ]; then
            sb_send_signal "$key" "ok" "dosya ${age} dakika önce güncellendi ($(du -h "$path" 2>/dev/null | cut -f1))"
        fi
        # Bayatsa hiçbir şey gönderilmez: beklenen pencere Signalbird
        # tarafında kapanır ve alarm oradan çalar.
    done <<EOF
$specs
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
#  Komutlar
# ─────────────────────────────────────────────────────────────────────────────

sb_cmd_install() {
    local token="" api="$SB_DEFAULT_API" allow="$SB_DEFAULT_ALLOW" arg

    for arg in "$@"; do
        case "$arg" in
            --token=*) token="${arg#*=}" ;;
            --api=*)   api="${arg#*=}" ;;
            --allow=*) allow="${arg#*=}" ;;
        esac
    done

    [ "$(id -u)" -eq 0 ] || sb_die "Kurulum root gerektirir: sudo bash $0 install --token=..."
    [ -n "$token" ] || sb_die "Anahtar gerekli: --token=sba_live_..."
    command -v curl >/dev/null 2>&1 || sb_die "curl gerekli"
    command -v python3 >/dev/null 2>&1 || command -v jq >/dev/null 2>&1 \
        || sb_die "python3 veya jq gerekli (JSON okumak için)"

    mkdir -p /etc/signalbird "$SB_STATE_DIR"

    # Ayar dosyası anahtar ve veritabanı parolası tutar: yalnız root okur.
    if [ -f "$SB_CONF" ]; then
        sb_log "bilgi" "Mevcut ayar korunuyor, yalnız anahtar güncelleniyor: $SB_CONF"
        local tmp="${SB_CONF}.tmp"
        grep -v '^token=' "$SB_CONF" | grep -v '^api_base=' > "$tmp"
        printf 'token=%s\napi_base=%s\n' "$token" "$api" >> "$tmp"
        mv "$tmp" "$SB_CONF"
    else
        cat > "$SB_CONF" <<CONF
# Signalbird ajan yerel ayarı. Bu dosya sunucudan dışarı çıkmaz.
# Belgeler: https://github.com/Pariette-Inc/agent.signalbird

token=${token}
api_base=${api}

# Panelden seçilen log yolları YALNIZ bu köklerin altındaysa okunur.
# Virgülle çoğaltılır: /var/log,/srv/uygulama/storage/logs
allow_paths=${allow}

# Veritabanı izleme açıksa kullanılır. Panele GÖNDERİLMEZ, panelde GÖRÜNMEZ.
# Salt okunur bir kullanıcı verin.
#db_driver=mysql
#db_host=127.0.0.1
#db_port=3306
#db_user=signalbird_ro
#db_pass=
#db_name=
CONF
    fi
    chmod 600 "$SB_CONF"

    # Dosyanın kendisi /usr/local/bin'e kopyalanır: müşteri indirdiği dosyayı
    # silse bile servis çalışmaya devam etsin.
    cp -f "$0" "$SB_BIN"
    chmod 755 "$SB_BIN"

    cat > "$SB_SERVICE" <<UNIT
[Unit]
Description=Signalbird sunucu ajanı
Documentation=https://github.com/Pariette-Inc/agent.signalbird
After=network-online.target

[Service]
Type=simple
ExecStart=${SB_BIN} run
Restart=always
RestartSec=15
# Ajan yalnız okur. Yazabildiği tek yer kendi durum klasörü ve kendi günlüğü.
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=${SB_STATE_DIR} /var/log

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable --now signalbird-agent >/dev/null 2>&1

    sb_log "bilgi" "Kurulum tamam. Durum: systemctl status signalbird-agent"
    printf '\nKurulum tamam.\n\n'
    printf '  Ayar dosyası : %s\n' "$SB_CONF"
    printf '  Servis       : systemctl status signalbird-agent\n'
    printf '  Günlük       : %s\n' "$SB_LOG"
    printf '  Sinyal örneği: %s signal db-backup ok "yedek bitti"\n\n' "$SB_BIN"
}

sb_cmd_uninstall() {
    [ "$(id -u)" -eq 0 ] || sb_die "Kaldırma root gerektirir"
    systemctl disable --now signalbird-agent >/dev/null 2>&1
    rm -f "$SB_SERVICE"
    systemctl daemon-reload
    rm -f "$SB_BIN"
    # Ayar ve durum dosyaları BIRAKILIR: yeniden kurulumda anahtar ve log
    # konumları kaybolmasın. Tamamen silmek isteyen elle siler.
    printf 'Servis kaldırıldı. Ayar dosyası duruyor: %s\n' "$SB_CONF"
}

# Tek tur: ayar tazele, ölçüm gönder, log gönder, dosya sinyallerine bak.
sb_cycle() {
    sb_ship_logs
    sb_check_file_signals
    sb_send_metrics
}

sb_cmd_run() {
    sb_load_conf
    sb_log "bilgi" "ajan başladı (sürüm ${SB_AGENT_VERSION})"
    sb_hello || true

    local last_refresh
    last_refresh="$(date +%s)"

    while true; do
        sb_cycle

        if [ $(( $(date +%s) - last_refresh )) -ge "$SB_CONFIG_REFRESH" ]; then
            sb_hello || true
            last_refresh="$(date +%s)"
        fi

        sleep "$SB_INTERVAL"
    done
}

sb_cmd_once() {
    sb_load_conf
    sb_hello || true
    sb_cycle
    printf 'Tek tur tamamlandı.\n'
}

sb_cmd_status() {
    sb_load_conf
    printf 'Signalbird ajanı %s\n' "$SB_AGENT_VERSION"
    printf '  API        : %s\n' "$SB_API"
    printf '  Anahtar    : %s…\n' "$(printf '%s' "$SB_TOKEN" | cut -c1-16)"
    printf '  İzinli yol : %s\n' "$SB_ALLOW_PATHS"
    printf '  JSON aracı : %s\n' "$SB_JSON"
    if [ -f "$SB_CONFIG_CACHE" ]; then
        printf '  Ayar sürümü: %s\n' "$(sb_json_get "$(cat "$SB_CONFIG_CACHE")" "config_version" "?")"
    else
        printf '  Ayar sürümü: henüz çekilmedi\n'
    fi
    if command -v systemctl >/dev/null 2>&1; then
        printf '  Servis     : %s\n' "$(systemctl is-active signalbird-agent 2>/dev/null)"
    fi
    printf '\nBağlantı deneniyor...\n'
    sb_hello && printf 'Bağlantı tamam.\n'
}

sb_usage() {
    cat <<USAGE
Signalbird sunucu ajanı ${SB_AGENT_VERSION}
yazar: ahmet selim çil | ahmet@pariette.com

Kullanım:
  signalbird-agent install --token=sba_live_xxx [--api=URL] [--allow=/var/log]
  signalbird-agent run                     sürekli çalışır (servis bunu kullanır)
  signalbird-agent once                    tek tur ölçüm ve log gönderir
  signalbird-agent signal <anahtar> [ok|fail] [mesaj]
  signalbird-agent status                  yerel durumu ve bağlantıyı gösterir
  signalbird-agent uninstall               servisi kaldırır
  signalbird-agent version

Bu ajan sunucuda hiçbir şeyi değiştirmez ve Signalbird'den komut almaz.
Ayrıntı: https://github.com/Pariette-Inc/agent.signalbird
USAGE
}

# ─────────────────────────────────────────────────────────────────────────────
#  Giriş
# ─────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
    install)   shift; sb_cmd_install "$@" ;;
    uninstall) sb_cmd_uninstall ;;
    run)       sb_cmd_run ;;
    once)      sb_cmd_once ;;
    status)    sb_cmd_status ;;
    signal)
        shift
        [ -n "${1:-}" ] || sb_die "Sinyal anahtarı gerekli: signalbird-agent signal db-backup ok"
        sb_load_conf
        sb_send_signal "$1" "${2:-ok}" "${3:-}"
        ;;
    version|--version|-v) printf '%s\n' "$SB_AGENT_VERSION" ;;
    ""|help|--help|-h) sb_usage ;;
    *) sb_usage; exit 1 ;;
esac
