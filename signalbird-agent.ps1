<#
    Signalbird sunucu ajanı (Windows)
    yazar: ahmet selim çil | ahmet@pariette.com
    kaynak: https://github.com/Pariette-Inc/agent.signalbird
    sözleşme: PROTOCOL.md

    NE YAPAR
      Sunucunun durumunu okur (CPU, bellek, disk, servis, port, süreç, socket,
      veritabanı), log dosyalarını takip eder ve Signalbird'e gönderir.
      Beklenen sinyalleri (örnek: "yedeği aldım") iletir.

    NE YAPMAZ
      Sunucuda hiçbir şeyi değiştirmez. Signalbird bu ajana komut gönderemez.
      Panelden gelen şey komut değil ayardır. Çalıştırılan komutların tam
      listesi PROTOCOL.md §7 bölümündedir.

    KURULUM (yönetici PowerShell)
      .\signalbird-agent.ps1 install -Token sba_live_xxx

    ELLE ÇALIŞTIRMA
      .\signalbird-agent.ps1 once
      .\signalbird-agent.ps1 signal db-backup ok "yedek bitti"
      .\signalbird-agent.ps1 status

    Bu dosya Linux ajanı (signalbird-agent.sh) ile AYNI protokolü konuşur.
    Birinde bir alan değişiyorsa diğerinde de değişmek zorundadır.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'help',
    [Parameter(Position = 1)][string]$Arg1 = '',
    [Parameter(Position = 2)][string]$Arg2 = '',
    [Parameter(Position = 3)][string]$Arg3 = '',
    [string]$Token = '',
    [string]$Api = 'https://api.signalbird.app/api',
    [string]$Allow = 'C:\inetpub\logs,C:\logs'
)

$ErrorActionPreference = 'Continue'

# ─────────────────────────────────────────────────────────────────────────────
#  Sabitler
# ─────────────────────────────────────────────────────────────────────────────

# Sürüm. PROTOCOL.md §8: VERSION dosyası ve Linux ajanı ile AYNI olmak
# zorundadır. Değiştiren kişi üçünü birden değiştirir.
$script:AgentVersion = '1.0.0'
$script:Protocol     = 1

$script:BaseDir   = Join-Path $env:ProgramData 'Signalbird'
$script:ConfPath  = Join-Path $script:BaseDir 'agent.conf'
$script:StatePath = Join-Path $script:BaseDir 'state'
$script:CachePath = Join-Path $script:BaseDir 'config.json'
$script:LogPath   = Join-Path $script:BaseDir 'agent.log'
$script:BinPath   = Join-Path $script:BaseDir 'signalbird-agent.ps1'
$script:ServiceName = 'SignalbirdAgent'

# Ayar çekilemediğinde kullanılan değerler.
$script:Interval      = 60
$script:ConfigRefresh = 300

$script:Conf   = @{}
$script:Config = $null

# ─────────────────────────────────────────────────────────────────────────────
#  Yardımcılar
# ─────────────────────────────────────────────────────────────────────────────

function Get-SbNow { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

# Yerel günlük. Sunucunun kendi diskine yazar, Signalbird'e gitmez: ajan
# Signalbird'e ulaşamadığında sorunun izini burada bırakması gerekir.
function Write-SbLog {
    param([string]$Level, [string]$Message)
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Path $script:BaseDir -Force | Out-Null }
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

function Stop-SbWithError {
    param([string]$Message)
    Write-SbLog 'hata' $Message
    exit 1
}

function Test-SbAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ─────────────────────────────────────────────────────────────────────────────
#  Yerel ayar
# ─────────────────────────────────────────────────────────────────────────────

function Read-SbConf {
    if (-not (Test-Path $script:ConfPath)) {
        Stop-SbWithError "Ayar dosyası yok: $($script:ConfPath) (önce install çalıştırın)"
    }

    $conf = @{}
    foreach ($line in Get-Content $script:ConfPath -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $idx = $trimmed.IndexOf('=')
        if ($idx -lt 1) { continue }
        # Değerde eşittir işareti olabilir (parola), yalnız ilk eşittir bölücüdür.
        $key = $trimmed.Substring(0, $idx).Trim()
        $val = $trimmed.Substring($idx + 1).Trim()
        $conf[$key] = $val
    }

    if (-not $conf.ContainsKey('token') -or [string]::IsNullOrWhiteSpace($conf['token'])) {
        Stop-SbWithError 'Ayar dosyasında token yok'
    }
    if (-not $conf.ContainsKey('api_base') -or [string]::IsNullOrWhiteSpace($conf['api_base'])) {
        $conf['api_base'] = 'https://api.signalbird.app/api'
    }
    if (-not $conf.ContainsKey('allow_paths')) { $conf['allow_paths'] = 'C:\inetpub\logs,C:\logs' }

    $script:Conf = $conf
}

# ─────────────────────────────────────────────────────────────────────────────
#  HTTP
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-SbApi {
    param([string]$Path, [object]$Body = $null, [string]$Method = 'POST')

    $headers = @{
        'Authorization' = "Bearer $($script:Conf['token'])"
        'User-Agent'    = "signalbird-agent/$($script:AgentVersion) (windows)"
    }

    $uri = "$($script:Conf['api_base'])$Path"

    try {
        if ($Method -eq 'GET') {
            return Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -TimeoutSec 20
        }
        # Türkçe karakterlerin bozulmaması için gövde UTF-8 baytlarına çevrilir:
        # Invoke-RestMethod varsayılanı Windows'ta ANSI'ye düşebiliyor.
        $json  = $Body | ConvertTo-Json -Depth 12 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        return Invoke-RestMethod -Uri $uri -Method POST -Headers $headers `
            -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 20
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        $script:LastHttpCode = $code
        if ($code -eq 401 -or $code -eq 403) {
            Stop-SbWithError "Anahtar reddedildi (HTTP $code). Panelden anahtarı yenileyin."
        }
        return $null
    }
    finally { }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Ayar çekme (panelden)
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-SbHello {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue

    $body = @{
        version    = $script:AgentVersion
        protocol   = $script:Protocol
        hostname   = $env:COMPUTERNAME
        os         = 'windows'
        os_version = if ($os) { $os.Caption } else { 'Windows' }
        arch       = $env:PROCESSOR_ARCHITECTURE
        boot_time  = if ($os) { $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { Get-SbNow }
        started_at = Get-SbNow
    }

    $resp = Invoke-SbApi -Path '/v1/agent/hello' -Body $body

    if ($null -eq $resp) {
        Write-SbLog 'uyari' 'hello başarısız, son bilinen ayarla devam'
        Import-SbCachedConfig
        return $false
    }

    if ($resp.config) {
        $script:Config = $resp.config
        try {
            if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Path $script:BaseDir -Force | Out-Null }
            ($resp.config | ConvertTo-Json -Depth 12) | Set-Content -Path $script:CachePath -Encoding UTF8
        } catch { }
    } else {
        Import-SbCachedConfig
    }

    Set-SbIntervals

    # Sürüm uyarısı. Ajan kendini GÜNCELLEMEZ: kendini güncelleyen bir ajan,
    # uzaktan kod çalıştırmanın kibar hâlidir. Yalnız haber verir.
    if ($resp.release -and $resp.release.is_outdated -eq $true) {
        Write-SbLog 'bilgi' ("Yeni ajan sürümü var: {0} (kurulu: {1}). Güncelleme kararı sizindir." -f $resp.release.version, $script:AgentVersion)
    }

    return $true
}

function Import-SbCachedConfig {
    if (Test-Path $script:CachePath) {
        try {
            $script:Config = Get-Content $script:CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            Set-SbIntervals
        } catch { }
    }
}

function Set-SbIntervals {
    if ($null -eq $script:Config) { return }
    $i = 60; $r = 300
    if ($script:Config.interval_seconds)       { $i = [int]$script:Config.interval_seconds }
    if ($script:Config.config_refresh_seconds) { $r = [int]$script:Config.config_refresh_seconds }
    if ($i -lt 30)   { $i = 30 }
    if ($i -gt 3600) { $i = 3600 }
    if ($r -lt 60)   { $r = 60 }
    $script:Interval = $i
    $script:ConfigRefresh = $r
}

function Get-SbConfigValue {
    param([string]$Path, $Default = $null)
    if ($null -eq $script:Config) { return $Default }
    $cur = $script:Config
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$part]
        if ($null -eq $prop) { return $Default }
        $cur = $prop.Value
    }
    if ($null -eq $cur) { return $Default }
    return $cur
}

# ─────────────────────────────────────────────────────────────────────────────
#  Toplayıcılar
#
#  Hepsi tek kural altında çalışır: yalnız okur. Kapalı toplayıcının anahtarı
#  gövdede HİÇ bulunmaz (PROTOCOL.md §3.3): "ölçüm yok" ile "ölçüm sıfır"
#  farklı şeylerdir.
# ─────────────────────────────────────────────────────────────────────────────

function Get-SbSystemMetrics {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $metrics = @{}

    if ($os) {
        $uptime = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
        $totalMb = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
        $freeMb  = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
        $usedMb  = $totalMb - $freeMb

        $metrics['uptime_seconds'] = $uptime
        $metrics['memory'] = @{
            total_mb = $totalMb
            used_mb  = $usedMb
            percent  = if ($totalMb -gt 0) { [math]::Round(($usedMb / $totalMb) * 100, 1) } else { 0 }
        }

        # Windows'ta takas alanı sayfa dosyasıdır.
        $swapTotal = [math]::Round(($os.TotalVirtualMemorySize - $os.TotalVisibleMemorySize) / 1KB, 0)
        $swapFree  = [math]::Round(($os.FreeVirtualMemory - $os.FreePhysicalMemory) / 1KB, 0)
        if ($swapTotal -lt 0) { $swapTotal = 0 }
        if ($swapFree  -lt 0) { $swapFree  = 0 }
        $swapUsed = $swapTotal - $swapFree
        $metrics['swap'] = @{
            total_mb = $swapTotal
            used_mb  = $swapUsed
            percent  = if ($swapTotal -gt 0) { [math]::Round(($swapUsed / $swapTotal) * 100, 1) } else { 0 }
        }
    }

    $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue |
        Measure-Object -Property LoadPercentage -Average
    $metrics['cpu_percent'] = if ($cpu -and $null -ne $cpu.Average) { [math]::Round($cpu.Average, 1) } else { 0 }

    # Windows'ta Unix anlamında yük ortalaması yoktur. Panelde boş göstermek
    # yerine CPU yüzdesini üç pencereye de yazmak yanıltıcı olurdu, o yüzden
    # `load` alanı Windows'ta HİÇ gönderilmez.

    return $metrics
}

function Get-SbDisks {
    $disks = @()
    # DriveType 3 = yerel sabit disk. Ağ sürücüsü ve CD panelde "disk doldu"
    # alarmı üretip kimseyi ilgilendirmezdi.
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
        $total = [double]$_.Size
        $free  = [double]$_.FreeSpace
        if ($total -le 0) { return }
        $used = $total - $free
        $disks += @{
            device   = $_.DeviceID
            mount    = $_.DeviceID
            total_gb = [math]::Round($total / 1GB, 1)
            used_gb  = [math]::Round($used / 1GB, 1)
            percent  = [math]::Round(($used / $total) * 100, 1)
            # Windows'ta inode kavramı yok, sözleşmeyi bozmamak için 0 gider.
            inode_percent = 0
        }
    }
    return $disks
}

function Get-SbServices {
    param([string[]]$Names)
    $result = @()
    foreach ($name in $Names) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        $state = 'unknown'
        if ($svc) {
            switch ($svc.Status) {
                'Running' { $state = 'running' }
                'Stopped' { $state = 'stopped' }
                default   { $state = $svc.Status.ToString().ToLower() }
            }
        }
        $result += @{ name = $name; state = $state }
    }
    return $result
}

function Get-SbPorts {
    $ports = @()
    try {
        Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty LocalPort -Unique |
            Sort-Object | Select-Object -First 50 | ForEach-Object {
                $ports += @{ port = [int]$_ }
            }
    } catch { }
    return $ports
}

function Get-SbProcesses {
    param([int]$Limit)
    $result = @()
    Get-Process -ErrorAction SilentlyContinue |
        Sort-Object -Property CPU -Descending |
        Select-Object -First $Limit | ForEach-Object {
            $result += @{
                name      = $_.ProcessName
                cpu       = if ($_.CPU) { [math]::Round($_.CPU, 1) } else { 0 }
                memory_mb = [math]::Round($_.WorkingSet64 / 1MB, 0)
            }
        }
    return $result
}

# Socket.io ölçümü. Adres YALNIZ localhost olabilir: ajan, panelden verilen
# rastgele bir adrese istek atan bir tarayıcıya dönüşmemeli. Aksi hâlde
# Signalbird hesabını ele geçiren biri, müşterinin sunucusunu iç ağı taramak
# için kullanabilirdi.
function Get-SbSocket {
    param([string]$Url)

    if ($Url -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\]):\d+') {
        Write-SbLog 'uyari' "socket adresi localhost değil, atlandı: $Url"
        return $null
    }

    try {
        $resp = Invoke-RestMethod -Uri $Url -Method GET -TimeoutSec 5
    } catch {
        return @{ ok = $false }
    }

    $clients = 0
    if ($resp.clients)     { $clients = [int]$resp.clients }
    elseif ($resp.connections) { $clients = [int]$resp.connections }

    return @{
        ok = $true
        clients = $clients
        rooms = if ($resp.rooms) { [int]$resp.rooms } else { 0 }
        events_per_second = if ($resp.events_per_second) { [double]$resp.events_per_second } else { 0 }
    }
}

# Veritabanı ölçümü. Bağlantı bilgisi YALNIZ yerel ayardan okunur, panelden
# değil (PROTOCOL.md §1.4). Panel yalnız "izle" veya "izleme" der.
function Get-SbDatabase {
    $driver = $script:Conf['db_driver']
    if ([string]::IsNullOrWhiteSpace($driver)) {
        return @{ ok = $false; error = 'yerel ayarda db_driver yok' }
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()

    switch ($driver) {
        { $_ -in 'mssql', 'sqlserver' } {
            try {
                $conn = New-Object System.Data.SqlClient.SqlConnection
                $host_ = if ($script:Conf['db_host']) { $script:Conf['db_host'] } else { '127.0.0.1' }
                $db    = if ($script:Conf['db_name']) { $script:Conf['db_name'] } else { 'master' }
                $conn.ConnectionString = "Server=$host_;Database=$db;User Id=$($script:Conf['db_user']);Password=$($script:Conf['db_pass']);Connect Timeout=5"
                $conn.Open()

                $cmd = $conn.CreateCommand()
                $cmd.CommandText = "SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1"
                $connections = [int]$cmd.ExecuteScalar()

                $cmd.CommandText = "SELECT CAST(SUM(size) * 8.0 / 1024 AS DECIMAL(10,1)) FROM sys.database_files"
                $sizeMb = [double]$cmd.ExecuteScalar()

                $conn.Close()
                $sw.Stop()

                return @{
                    ok = $true; driver = 'mssql'
                    response_ms = [int]$sw.ElapsedMilliseconds
                    connections = $connections
                    size_mb = $sizeMb
                }
            } catch {
                return @{ ok = $false; driver = 'mssql'; error = 'baglanti kurulamadi' }
            }
        }
        { $_ -in 'mysql', 'mariadb' } {
            # Windows'ta mysql.exe yolda değilse ölçüm yapılmaz. Ajan bunun
            # için paket kurmaz.
            $mysql = Get-Command mysql.exe -ErrorAction SilentlyContinue
            if (-not $mysql) { return @{ ok = $false; driver = 'mysql'; error = 'mysql istemcisi yok' } }
            try {
                # Parola komut satırına yazılmaz, ortam değişkeninden okunur.
                $env:MYSQL_PWD = $script:Conf['db_pass']
                $out = & mysql.exe -h $script:Conf['db_host'] -P $script:Conf['db_port'] `
                    -u $script:Conf['db_user'] --connect-timeout=5 -N -B `
                    -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Slow_queries','Uptime');" 2>$null
                $sw.Stop()
                Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue

                if (-not $out) { return @{ ok = $false; driver = 'mysql'; error = 'baglanti kurulamadi' } }

                $map = @{}
                foreach ($line in $out) {
                    $parts = $line -split "`t"
                    if ($parts.Count -ge 2) { $map[$parts[0]] = $parts[1] }
                }
                return @{
                    ok = $true; driver = 'mysql'
                    response_ms = [int]$sw.ElapsedMilliseconds
                    connections = [int]($map['Threads_connected'])
                    slow_queries = [int]($map['Slow_queries'])
                    uptime_seconds = [int]($map['Uptime'])
                }
            } catch {
                Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
                return @{ ok = $false; driver = 'mysql'; error = 'baglanti kurulamadi' }
            }
        }
        default { return @{ ok = $false; error = 'bilinmeyen sürücü' } }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Ölçüm turu
# ─────────────────────────────────────────────────────────────────────────────

function Send-SbMetrics {
    $metrics = Get-SbSystemMetrics

    if ((Get-SbConfigValue 'collectors.disks' $true) -eq $true) {
        $metrics['disks'] = @(Get-SbDisks)
    }

    $services = Get-SbConfigValue 'collectors.services' @()
    if ($services -and $services.Count -gt 0) {
        $metrics['services'] = @(Get-SbServices -Names $services)
    }

    if ((Get-SbConfigValue 'collectors.ports' $false) -eq $true) {
        $metrics['ports'] = @(Get-SbPorts)
    }

    $procLimit = [int](Get-SbConfigValue 'collectors.processes' 0)
    if ($procLimit -gt 0) {
        if ($procLimit -gt 20) { $procLimit = 20 }
        $metrics['processes'] = @(Get-SbProcesses -Limit $procLimit)
    }

    if ((Get-SbConfigValue 'collectors.socket.enabled' $false) -eq $true) {
        $url = Get-SbConfigValue 'collectors.socket.url' ''
        if ($url) {
            $socket = Get-SbSocket -Url $url
            if ($null -ne $socket) { $metrics['socket'] = $socket }
        }
    }

    if ((Get-SbConfigValue 'collectors.database.enabled' $false) -eq $true) {
        $metrics['database'] = Get-SbDatabase
    }

    $resp = Invoke-SbApi -Path '/v1/agent/metrics' -Body @{
        collected_at = Get-SbNow
        metrics      = $metrics
    }

    if ($null -eq $resp) { Write-SbLog 'uyari' 'ölçüm gönderilemedi' }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Log takibi
#
#  Her dosya için en son okunan bayt konumu durum dosyasında tutulur. Dosya
#  döndüğünde boyut küçülür, ajan başa döner. Gönderim başarısız olursa konum
#  İLERLETİLMEZ: aynı satırlar bir sonraki turda tekrar denenir.
# ─────────────────────────────────────────────────────────────────────────────

function Get-SbState {
    $state = @{}
    if (Test-Path $script:StatePath) {
        foreach ($line in Get-Content $script:StatePath -Encoding UTF8) {
            $idx = $line.IndexOf('=')
            if ($idx -lt 1) { continue }
            $state[$line.Substring(0, $idx)] = $line.Substring($idx + 1)
        }
    }
    return $state
}

function Save-SbState {
    param([hashtable]$State)
    if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Path $script:BaseDir -Force | Out-Null }
    $lines = foreach ($k in $State.Keys) { "$k=$($State[$k])" }
    Set-Content -Path $script:StatePath -Value $lines -Encoding UTF8
}

# Panelden gelen yolun yerel izin listesinde olup olmadığına bakar.
# PROTOCOL.md §1.3: Signalbird hesabı ele geçse bile yeni bir dosya okutulamaz.
function Test-SbPathAllowed {
    param([string]$Path)
    try {
        $full = [IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }
    foreach ($root in ($script:Conf['allow_paths'] -split ',')) {
        $r = $root.Trim().TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        if ($full -eq $r -or $full.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Send-SbLogs {
    $specs = Get-SbConfigValue 'logs' @()
    if (-not $specs -or $specs.Count -eq 0) { return }

    $state = Get-SbState
    $pending = @{}
    $events = @()

    foreach ($spec in $specs) {
        $path = $spec.path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        if (-not (Test-SbPathAllowed -Path $path)) {
            Write-SbLog 'uyari' "log yolu izinli değil, atlandı: $path (izinli kökler: $($script:Conf['allow_paths']))"
            continue
        }
        if (-not (Test-Path $path)) { continue }

        $channel  = if ($spec.channel) { $spec.channel } else { 'sunucu' }
        $level    = if ($spec.level)   { $spec.level }   else { 'error' }
        $match    = $spec.match
        $maxLines = if ($spec.max_lines) { [int]$spec.max_lines } else { 200 }
        if ($maxLines -gt 500) { $maxLines = 500 }

        $key = 'log:' + ($path -replace '[\\:/]', '_')
        $offset = 0
        if ($state.ContainsKey($key)) { [void][int]::TryParse($state[$key], [ref]$offset) }

        $size = (Get-Item $path -ErrorAction SilentlyContinue).Length
        if ($null -eq $size) { continue }

        # Dosya döndüyse (küçüldüyse) baştan başlanır.
        if ($size -lt $offset) { $offset = 0 }

        # İlk kurulumda geçmiş log baştan sona gönderilmez: müşteri ajanı
        # kurar kurmaz aylık kotasını bir yıllık IIS loguna yakardı.
        if ($offset -eq 0 -and $size -gt 0) {
            $state[$key] = $size
            continue
        }
        if ($size -le $offset) { continue }

        try {
            $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            [void]$stream.Seek($offset, 'Begin')
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
            $chunk = $reader.ReadToEnd()
            $reader.Close()
            $stream.Close()
        } catch {
            Write-SbLog 'uyari' "log okunamadı: $path"
            continue
        }

        $lines = $chunk -split "`r?`n" | Select-Object -First $maxLines
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($match -and ($line -notmatch $match)) { continue }
            if ($events.Count -ge 100) { break }
            $events += @{
                channel = $channel
                level   = $level
                message = if ($line.Length -gt 4000) { $line.Substring(0, 4000) } else { $line }
                source  = "$env:COMPUTERNAME:$path"
                context = @{ path = $path }
            }
        }

        $pending[$key] = $size
    }

    if ($events.Count -eq 0) {
        Save-SbState -State $state
        return
    }

    $resp = Invoke-SbApi -Path '/v1/agent/logs' -Body @{ events = $events }

    if ($null -ne $resp) {
        foreach ($k in $pending.Keys) { $state[$k] = $pending[$k] }
        Write-SbLog 'bilgi' "$($events.Count) log satırı gönderildi"
    } else {
        Write-SbLog 'uyari' 'log gönderilemedi, konum ilerletilmedi'
    }

    Save-SbState -State $state
}

# ─────────────────────────────────────────────────────────────────────────────
#  Sinyaller
#
#  Sinyalin ne zaman beklendiğine SIGNALBIRD karar verir, ajan yalnız "oldu"
#  der. Ajan kendi saatine göre karar verseydi, saati kaymış bir sunucu
#  sessizce alarmsız kalırdı.
# ─────────────────────────────────────────────────────────────────────────────

function Send-SbSignal {
    param([string]$Key, [string]$Status = 'ok', [string]$Message = '')

    if ($Status -ne 'ok' -and $Status -ne 'fail') { $Status = 'ok' }

    $resp = Invoke-SbApi -Path '/v1/agent/signal' -Body @{
        key = $Key; status = $Status; message = $Message
    }

    if ($null -ne $resp) {
        Write-SbLog 'bilgi' "sinyal iletildi: $Key ($Status)"
        return $true
    }
    Write-SbLog 'uyari' "sinyal iletilemedi: $Key"
    return $false
}

# `mode: file` olan sinyaller: ajan dosyanın değişim zamanına bakar. Yedek
# dosyası tazeyse sinyal gider, bayatsa GİTMEZ. Bayat dosya için "oldu" demek,
# alarmı sessizce kapatmak olurdu.
function Test-SbFileSignals {
    $specs = Get-SbConfigValue 'signals' @()
    if (-not $specs -or $specs.Count -eq 0) { return }

    foreach ($spec in $specs) {
        if ($spec.mode -ne 'file') { continue }
        $key = $spec.key
        $path = $spec.path
        if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($path)) { continue }
        $maxAge = if ($spec.max_age_minutes) { [int]$spec.max_age_minutes } else { 70 }

        $item = Get-Item $path -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            Send-SbSignal -Key $key -Status 'fail' -Message "dosya yok: $path" | Out-Null
            continue
        }

        $ageMin = [int]((Get-Date) - $item.LastWriteTime).TotalMinutes
        if ($ageMin -le $maxAge) {
            $sizeMb = [math]::Round($item.Length / 1MB, 1)
            Send-SbSignal -Key $key -Status 'ok' -Message "dosya $ageMin dakika önce güncellendi ($sizeMb MB)" | Out-Null
        }
        # Bayatsa hiçbir şey gönderilmez: beklenen pencere Signalbird
        # tarafında kapanır ve alarm oradan çalar.
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Komutlar
# ─────────────────────────────────────────────────────────────────────────────

function Install-SbAgent {
    if (-not (Test-SbAdmin)) { Stop-SbWithError 'Kurulum yönetici yetkisi gerektirir' }
    if ([string]::IsNullOrWhiteSpace($Token)) { Stop-SbWithError 'Anahtar gerekli: -Token sba_live_...' }

    if (-not (Test-Path $script:BaseDir)) { New-Item -ItemType Directory -Path $script:BaseDir -Force | Out-Null }

    if (Test-Path $script:ConfPath) {
        # Mevcut ayar korunur, yalnız anahtar ve adres güncellenir: veritabanı
        # bilgilerini yeniden yazdırmanın anlamı yok.
        $kept = Get-Content $script:ConfPath -Encoding UTF8 |
            Where-Object { $_ -notmatch '^\s*(token|api_base)\s*=' }
        $kept + @("token=$Token", "api_base=$Api") | Set-Content -Path $script:ConfPath -Encoding UTF8
    } else {
        @(
            '# Signalbird ajan yerel ayarı. Bu dosya sunucudan dışarı çıkmaz.',
            '# Belgeler: https://github.com/Pariette-Inc/agent.signalbird',
            '',
            "token=$Token",
            "api_base=$Api",
            '',
            '# Panelden seçilen log yolları YALNIZ bu köklerin altındaysa okunur.',
            "allow_paths=$Allow",
            '',
            '# Veritabanı izleme açıksa kullanılır. Panele GÖNDERİLMEZ.',
            '#db_driver=mssql',
            '#db_host=127.0.0.1',
            '#db_port=1433',
            '#db_user=signalbird_ro',
            '#db_pass=',
            '#db_name='
        ) | Set-Content -Path $script:ConfPath -Encoding UTF8
    }

    # Ayar dosyası anahtar ve veritabanı parolası tutar: yalnız yöneticiler
    # ve SYSTEM okuyabilsin diye devralınan izinler kaldırılır.
    try {
        $acl = Get-Acl $script:ConfPath
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
        foreach ($who in 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM') {
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                $who, 'FullControl', 'Allow')))
        }
        Set-Acl -Path $script:ConfPath -AclObject $acl
    } catch {
        Write-SbLog 'uyari' 'ayar dosyasının izinleri sıkılaştırılamadı'
    }

    # Dosyanın kendisi ProgramData'ya kopyalanır: müşteri indirdiği dosyayı
    # silse bile servis çalışmaya devam etsin.
    Copy-Item -Path $PSCommandPath -Destination $script:BinPath -Force

    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }
    $binPath = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$($script:BinPath)`" run"

    $existing = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        & sc.exe config $script:ServiceName binPath= $binPath start= auto | Out-Null
    } else {
        & sc.exe create $script:ServiceName binPath= $binPath start= auto DisplayName= 'Signalbird sunucu ajanı' | Out-Null
        & sc.exe description $script:ServiceName 'Signalbird icin salt okunur sunucu izleme ajani' | Out-Null
    }
    & sc.exe start $script:ServiceName | Out-Null

    Write-SbLog 'bilgi' 'Kurulum tamam'
    Write-Host ''
    Write-Host 'Kurulum tamam.'
    Write-Host "  Ayar dosyası : $($script:ConfPath)"
    Write-Host "  Servis       : Get-Service $($script:ServiceName)"
    Write-Host "  Günlük       : $($script:LogPath)"
    Write-Host "  Sinyal örneği: powershell -File `"$($script:BinPath)`" signal db-backup ok"
    Write-Host ''
}

function Uninstall-SbAgent {
    if (-not (Test-SbAdmin)) { Stop-SbWithError 'Kaldırma yönetici yetkisi gerektirir' }
    & sc.exe stop $script:ServiceName | Out-Null
    & sc.exe delete $script:ServiceName | Out-Null
    # Ayar ve durum dosyaları BIRAKILIR: yeniden kurulumda anahtar ve log
    # konumları kaybolmasın.
    Write-Host "Servis kaldırıldı. Ayar dosyası duruyor: $($script:ConfPath)"
}

function Invoke-SbCycle {
    Send-SbLogs
    Test-SbFileSignals
    Send-SbMetrics
}

function Start-SbLoop {
    Read-SbConf
    Write-SbLog 'bilgi' "ajan başladı (sürüm $($script:AgentVersion))"
    [void](Invoke-SbHello)

    $lastRefresh = Get-Date

    while ($true) {
        Invoke-SbCycle

        if (((Get-Date) - $lastRefresh).TotalSeconds -ge $script:ConfigRefresh) {
            [void](Invoke-SbHello)
            $lastRefresh = Get-Date
        }

        Start-Sleep -Seconds $script:Interval
    }
}

function Show-SbStatus {
    Read-SbConf
    Write-Host "Signalbird ajanı $($script:AgentVersion)"
    Write-Host "  API        : $($script:Conf['api_base'])"
    Write-Host "  Anahtar    : $($script:Conf['token'].Substring(0, [Math]::Min(16, $script:Conf['token'].Length)))…"
    Write-Host "  İzinli yol : $($script:Conf['allow_paths'])"
    if (Test-Path $script:CachePath) {
        Import-SbCachedConfig
        Write-Host "  Ayar sürümü: $(Get-SbConfigValue 'config_version' '?')"
    } else {
        Write-Host '  Ayar sürümü: henüz çekilmedi'
    }
    $svc = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
    Write-Host "  Servis     : $(if ($svc) { $svc.Status } else { 'kurulu değil' })"
    Write-Host ''
    Write-Host 'Bağlantı deneniyor...'
    if (Invoke-SbHello) { Write-Host 'Bağlantı tamam.' }
}

function Show-SbUsage {
@"
Signalbird sunucu ajanı $($script:AgentVersion)
yazar: ahmet selim çil | ahmet@pariette.com

Kullanım:
  .\signalbird-agent.ps1 install -Token sba_live_xxx [-Api URL] [-Allow C:\logs]
  .\signalbird-agent.ps1 run                    sürekli çalışır (servis bunu kullanır)
  .\signalbird-agent.ps1 once                   tek tur ölçüm ve log gönderir
  .\signalbird-agent.ps1 signal <anahtar> [ok|fail] [mesaj]
  .\signalbird-agent.ps1 status                 yerel durumu ve bağlantıyı gösterir
  .\signalbird-agent.ps1 uninstall              servisi kaldırır
  .\signalbird-agent.ps1 version

Bu ajan sunucuda hiçbir şeyi değiştirmez ve Signalbird'den komut almaz.
Ayrıntı: https://github.com/Pariette-Inc/agent.signalbird
"@ | Write-Host
}

# ─────────────────────────────────────────────────────────────────────────────
#  Giriş
# ─────────────────────────────────────────────────────────────────────────────

switch ($Command.ToLower()) {
    'install'   { Install-SbAgent }
    'uninstall' { Uninstall-SbAgent }
    'run'       { Start-SbLoop }
    'once'      { Read-SbConf; [void](Invoke-SbHello); Invoke-SbCycle; Write-Host 'Tek tur tamamlandı.' }
    'status'    { Show-SbStatus }
    'signal'    {
        if ([string]::IsNullOrWhiteSpace($Arg1)) {
            Stop-SbWithError 'Sinyal anahtarı gerekli: signal db-backup ok'
        }
        Read-SbConf
        $st = if ($Arg2) { $Arg2 } else { 'ok' }
        [void](Send-SbSignal -Key $Arg1 -Status $st -Message $Arg3)
    }
    'version'   { Write-Host $script:AgentVersion }
    default     { Show-SbUsage }
}
