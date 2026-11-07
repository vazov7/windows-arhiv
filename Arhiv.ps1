# Arhiv.ps1 - дневен архив на папки (GSOL.bg)
# Настройките (кои папки, къде, колко архива) са в nastroiki.txt до този файл.
# ТУК НИЩО НЕ СЕ ПИПА.
#
#   Arhiv.ps1               - работи във фона: на всеки 10 мин. проверява дали е време за архив
#   Arhiv.ps1 -Sega         - прави архив на всички папки веднага (за проба)
#   Arhiv.ps1 -Instalirai   - пуска се заедно с Windows + стартира веднага
#   Arhiv.ps1 -Premahni     - спира и маха автоматичното пускане (архивите остават)

param([switch]$Sega, [switch]$Instalirai, [switch]$Premahni)

$ErrorActionPreference = 'Stop'
$Papka   = $PSScriptRoot
$CfgFile = Join-Path $Papka 'nastroiki.txt'
$LogFile = Join-Path $Papka 'arhiv_log.txt'
$PrimerenPat = 'ТУК_НАПИШИ'
$ProverkaMin = 10
$ZapasMB = 200          # минимум свободно място над размера на папката
$Interactive = $Sega -or $Instalirai -or $Premahni

# уникално име според мястото на скрипта (може да има няколко копия)
$md5 = [Security.Cryptography.MD5]::Create()
$hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($PSCommandPath.ToLowerInvariant()))).Replace('-', '').Substring(0, 12)
$ImeMutex = 'GSOL_Arhiv_' + $hash

# Повтарящо се съобщение (на всеки 10 мин.) се пише само веднъж - отделно за всяка папка
$script:posledno = @{}
function Log([string]$t, [switch]$Vednuzh, [string]$Kluch = '-') {
    if ($Vednuzh) {
        if ($script:posledno.ContainsKey($Kluch) -and $script:posledno[$Kluch] -eq $t) { return }
        $script:posledno[$Kluch] = $t
    }
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $t
    if ($Interactive) { Write-Host $line }
    try {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        if ((Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
            $last = Get-Content -LiteralPath $LogFile -Encoding UTF8 -Tail 2000
            Set-Content -LiteralPath $LogFile -Value $last -Encoding UTF8
        }
    } catch {}
}
function Log-Ok([string]$Kluch) { $script:posledno.Remove($Kluch) }

function Normalize([string]$p) {
    $p = [IO.Path]::GetFullPath($p)
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\', '/') }   # "D:\" остава "D:\"
    return $p
}

function Read-Cfg {
    if (-not (Test-Path -LiteralPath $CfgFile)) { throw "Липсва файлът с настройки: $CfgFile" }
    $b = [IO.File]::ReadAllBytes($CfgFile)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) {
        $text = [Text.Encoding]::Unicode.GetString($b)          # Notepad "Unicode"
    } else {
        try   { $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($b) }   # UTF-8 (с или без BOM)
        catch { try { $text = [Text.Encoding]::GetEncoding(1251).GetString($b) } catch { $text = [Text.Encoding]::Default.GetString($b) } }   # стар Notepad - ANSI (кирилица)
    }
    $text = $text.TrimStart([char]0xFEFF)

    $c = @{ CEL = ''; MAKS_ARHIVI = '50'; CHASA_MEZHDU = '24'; PROPUSNI = '' }
    $izvori = New-Object System.Collections.ArrayList
    foreach ($ln in ($text -split "`r?`n")) {
        $ln = $ln.Trim()
        if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
        $i = $ln.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $ln.Substring(0, $i).Trim().ToUpperInvariant()
        $v = $ln.Substring($i + 1).Trim().Trim('"', "'", ' ')
        if ($k -eq 'IZVOR') { if ($v -ne '' -and $v -notlike "*$PrimerenPat*") { [void]$izvori.Add($v) } }
        elseif ($c.ContainsKey($k)) { $c[$k] = $v }
    }
    if ($izvori.Count -eq 0) { throw "Не е написана нито една папка за архивиране (IZVOR=...) в $CfgFile" }
    if ($c.CEL -eq '')       { throw "Не е написано къде да се пазят архивите (CEL=...) в $CfgFile" }
    $n = 0; if (-not [int]::TryParse($c.MAKS_ARHIVI, [ref]$n) -or $n -lt 1)  { throw "MAKS_ARHIVI трябва да е цяло число от 1 нагоре (сега: '$($c.MAKS_ARHIVI)')" }
    $c.MAKS = $n
    $h = 0; if (-not [int]::TryParse($c.CHASA_MEZHDU, [ref]$h) -or $h -lt 1) { throw "CHASA_MEZHDU трябва да е цяло число от 1 нагоре (сега: '$($c.CHASA_MEZHDU)')" }
    $c.CHASA = $h
    $c.CEL = Normalize $c.CEL
    $c.PROP = @($c.PROPUSNI -split ';' | ForEach-Object { $_.Trim().Trim('\', '/') } | Where-Object { $_ -ne '' })

    $sep = [IO.Path]::DirectorySeparatorChar
    $ce = $c.CEL.TrimEnd('\', '/') + $sep
    $lst = New-Object System.Collections.ArrayList
    $imena = @{}
    foreach ($raw in $izvori) {
        $iz = Normalize $raw
        if ($lst | Where-Object { $_.Izvor -eq $iz }) { continue }   # една папка, написана два пъти
        if ($ce.StartsWith($iz.TrimEnd('\', '/') + $sep, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Папката за архивите ($($c.CEL)) е ВЪТРЕ в $iz - така всеки архив ще съдържа предишните. Сложи CEL на друго място."
        }
        $ime = Split-Path $iz -Leaf
        if (-not $ime -or $ime -match '[:\\/]') { $ime = 'Disk' }
        $ime = $ime -replace '[<>:"/\\|?*]', '_'
        $baza = $ime; $nr = 2
        while ($imena.ContainsKey($ime.ToLowerInvariant())) { $ime = "${baza}_$nr"; $nr++ }
        $imena[$ime.ToLowerInvariant()] = 1
        [void]$lst.Add(@{
            Izvor = $iz
            Ime   = $ime
            Cel   = (Join-Path $c.CEL $ime)
            Re    = '^' + [regex]::Escape($ime) + '_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\.zip$'   # трием САМО такива имена
        })
    }
    $c.IZVORI = $lst
    return $c
}

function Get-Arhivi($s) {
    if (-not (Test-Path -LiteralPath $s.Cel -PathType Container)) { return @() }
    $re = $s.Re
    return @(Get-ChildItem -LiteralPath $s.Cel -File | Where-Object { $_.Name -match $re } | Sort-Object Name)
}

function Get-Vreme($s, $f) {
    $m = [regex]::Match($f.Name, $s.Re)
    return [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd_HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
}

function Propusni([string]$rel, $pats) {
    foreach ($p in $pats) {
        if ($rel -like $p -or $rel -like "$p\*" -or $rel -like "$p/*") { return $true }
        foreach ($seg in ($rel -split '[\\/]')) { if ($seg -like $p) { return $true } }
    }
    return $false
}

function Make-Arhiv($c, $s) {
    $izvor = $s.Izvor; $cel = $s.Cel; $K = $s.Ime
    if (-not (Test-Path -LiteralPath $izvor -PathType Container)) {
        Log "[$K] НЕ Е НАПРАВЕН: папката я няма: $izvor (изключен диск? грешен път?). Пробвам пак след $ProverkaMin мин." -Vednuzh -Kluch $K
        return $false
    }
    if (-not (Test-Path -LiteralPath $cel -PathType Container)) {
        try { New-Item -ItemType Directory -Path $cel -Force | Out-Null }
        catch { Log "[$K] НЕ Е НАПРАВЕН: не мога да създам папката за архивите: $cel ($($_.Exception.Message))." -Vednuzh -Kluch $K; return $false }
    }

    $vsichki = @(Get-ChildItem -LiteralPath $izvor -Recurse -File -Force -ErrorAction SilentlyContinue)
    $files = New-Object System.Collections.ArrayList
    $izkl = 0
    foreach ($f in $vsichki) {
        $rel = $f.FullName.Substring($izvor.Length).TrimStart('\', '/')
        if ($c.PROP.Count -gt 0 -and (Propusni $rel $c.PROP)) { $izkl++; continue }
        [void]$files.Add($f)
    }
    if ($files.Count -eq 0) {
        Log "[$K] НЕ Е НАПРАВЕН: папката $izvor е празна (или няма достъп) - не правя празен архив, за да не изместя добрите стари." -Vednuzh -Kluch $K
        return $false
    }

    # място на диска: поне колкото папката + запас
    $obshto = [long](($files | Measure-Object -Property Length -Sum).Sum)
    try {
        $disk = New-Object IO.DriveInfo -ArgumentList ([IO.Path]::GetPathRoot($cel))
        $nuzhno = $obshto + $ZapasMB * 1MB
        if ($disk.AvailableFreeSpace -lt $nuzhno) {
            Log "[$K] НЕ Е НАПРАВЕН: няма място на $($disk.Name) - свободни $([math]::Round($disk.AvailableFreeSpace/1GB,1)) GB, трябват около $([math]::Round($nuzhno/1GB,1)) GB. Намали MAKS_ARHIVI или освободи място." -Vednuzh -Kluch $K
            return $false
        }
    } catch {}

    # остатъци от прекъснат архив (спрян ток, изключен компютър)
    Get-ChildItem -LiteralPath $cel -File -Filter "$($s.Ime)_*.zip.part" -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force } catch {}
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $final = Join-Path $cel ($s.Ime + '_' + $stamp + '.zip')
    $part  = $final + '.part'
    $root  = $s.Ime

    Add-Type -AssemblyName System.IO.Compression
    $ok = 0; $skip = 0
    $fs = $null; $zip = $null
    try {
        $fs  = [IO.File]::Open($part, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        foreach ($f in $files) {
            $src = $null
            try { $src = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) }
            catch {
                $skip++
                if ($skip -le 20) { Log "[$K]   пропуснат (зает от програма или без достъп): $($f.FullName)" }
                continue
            }
            try {
                $rel = $f.FullName.Substring($izvor.Length).TrimStart('\', '/') -replace '\\', '/'
                $e = $zip.CreateEntry("$root/$rel", [IO.Compression.CompressionLevel]::Optimal)
                try { $e.LastWriteTime = $f.LastWriteTime } catch {}
                $es = $e.Open()
                try { $src.CopyTo($es) } finally { $es.Dispose() }
                $ok++
            } finally { $src.Dispose() }
        }
        $zip.Dispose(); $zip = $null
        $fs.Dispose();  $fs = $null
    } catch {
        if ($zip) { try { $zip.Dispose() } catch {} }
        if ($fs)  { try { $fs.Dispose() } catch {} }
        try { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue } catch {}
        Log "[$K] НЕ Е НАПРАВЕН: грешка при писане на архива ($($_.Exception.Message)). Пробвам пак след $ProverkaMin мин." -Vednuzh -Kluch $K
        return $false
    }

    if ($ok -eq 0) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Log "[$K] НЕ Е НАПРАВЕН: нито един файл не можа да се прочете от $izvor." -Vednuzh -Kluch $K
        return $false
    }

    Move-Item -LiteralPath $part -Destination $final
    Log-Ok $K
    $mb = [math]::Round((Get-Item -LiteralPath $final).Length / 1MB, 1)
    $msg = "[$K] ГОТОВ: $(Split-Path $final -Leaf) - $ok файла, $mb MB"
    if ($izkl -gt 0) { $msg += ", изключени по PROPUSNI $izkl" }
    if ($skip -gt 0) { $msg += ", ПРОПУСНАТИ $skip (заети от програма/без достъп)" }
    Log $msg

    # само най-новите MAKS архива остават
    $all = @(Get-Arhivi $s)
    $izlishni = $all.Count - $c.MAKS
    if ($izlishni -gt 0) {
        $all | Select-Object -First $izlishni | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force; Log "[$K]   изтрит стар архив: $($_.Name)" }
            catch { Log "[$K]   не можах да изтрия $($_.Name): $($_.Exception.Message)" }
        }
    }
    return $true
}

function Lock-Rabota {
    $m = New-Object Threading.Mutex -ArgumentList $false, ($ImeMutex + '_rabota')
    try { [void]$m.WaitOne() } catch {}   # изоставен mutex (убит процес) пак ни го дава
    return $m
}

# Проверка: време ли е за всяка папка? Ако да - прави архив. (под заключване, за да не тръгнат два наведнъж)
function Proveri-I-Arhiviray([switch]$Vinagi) {
    $m = Lock-Rabota
    try {
        $c = Read-Cfg
        Log-Ok 'cfg'
        foreach ($s in $c.IZVORI) {
            try {
                $arh = @(Get-Arhivi $s)
                $vreme = $true
                if (-not $Vinagi -and $arh.Count -gt 0) {
                    $posleden = Get-Vreme $s $arh[-1]
                    $vreme = ((Get-Date) - $posleden).TotalHours -ge $c.CHASA
                }
                if ($vreme) { [void](Make-Arhiv $c $s) }
            } catch {
                Log "[$($s.Ime)] ГРЕШКА: $($_.Exception.Message)" -Vednuzh -Kluch $s.Ime
            }
        }
    } catch {
        Log "ГРЕШКА: $($_.Exception.Message)" -Vednuzh -Kluch 'cfg'
    } finally {
        $m.ReleaseMutex(); $m.Dispose()
    }
}

function Get-MoiProcesi {
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return @() }
    return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($PSCommandPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

$startup = [Environment]::GetFolderPath('Startup')
if (-not $startup) { $startup = $Papka }   # само за проба извън Windows
$lnk = Join-Path $startup ('GSOL Arhiv - ' + (Split-Path $Papka -Leaf) + '.lnk')
$psExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
$fonArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""

# ---------- -Sega: архив веднага ----------
if ($Sega) {
    Log "Ръчен архив (2_ARHIVIRAI_SEGA)..."
    Proveri-I-Arhiviray -Vinagi
    exit
}

# ---------- -Premahni ----------
if ($Premahni) {
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Log "Махнато от автоматичното пускане: $lnk" }
    else { Log "Не беше в автоматичното пускане." }
    foreach ($p in (Get-MoiProcesi)) { try { Stop-Process -Id $p.ProcessId -Force; Log "Спрян работещ архиватор (процес $($p.ProcessId))." } catch {} }
    Log "Готово. Архивите НЕ са пипнати."
    exit
}

# ---------- -Instalirai ----------
if ($Instalirai) {
    try { $c = Read-Cfg } catch { Log "СПИРАМ: $($_.Exception.Message)"; Log "Отвори nastroiki.txt, оправи го и пусни 1_INSTALIRAI пак."; exit 1 }
    $ima = 0
    foreach ($s in $c.IZVORI) {
        if (Test-Path -LiteralPath $s.Izvor -PathType Container) { $ima++; Log "Папка за архив : $($s.Izvor)  ->  $($s.Cel)" }
        else { Log "ВНИМАНИЕ: папката я няма: $($s.Izvor) - провери пътя в nastroiki.txt (другите ще се архивират)." }
    }
    if ($ima -eq 0) {
        Log "СПИРАМ: нито една от папките не съществува. Провери пътищата в nastroiki.txt и пусни 1_INSTALIRAI пак."
        exit 1
    }
    Log "Пази последните: $($c.MAKS) архива за всяка папка, нов на всеки $($c.CHASA) часа"
    if ($c.PROP.Count -gt 0) { Log "Изключени      : $($c.PROP -join '; ')" }
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $psExe
    $sc.Arguments = $fonArgs
    $sc.WorkingDirectory = $Papka
    $sc.WindowStyle = 7
    $sc.Save()
    Log "Добавено в автоматичното пускане с Windows: $lnk"
    foreach ($p in (Get-MoiProcesi)) { try { Stop-Process -Id $p.ProcessId -Force } catch {} }   # стара версия да не остане
    Start-Process -FilePath $psExe -ArgumentList $fonArgs -WindowStyle Hidden
    Log "Пуснат във фона. Първата проверка е след 2 минути - ако няма архив от последните $($c.CHASA) часа, прави веднага."
    exit
}

# ---------- фонов режим (при пускане на Windows) ----------
$edinstven = New-Object Threading.Mutex -ArgumentList $false, ($ImeMutex + '_cikal')
$imam = $false
try { $imam = $edinstven.WaitOne(0) } catch { $imam = $true }
if (-not $imam) { exit }   # вече работи друг - не пускаме втори

Log "Старт във фона (проверка на всеки $ProverkaMin мин.)."
Start-Sleep -Seconds 120   # Windows да се успокои, мрежовите дискове да се вържат
while ($true) {
    Proveri-I-Arhiviray
    Start-Sleep -Seconds ($ProverkaMin * 60)
}
