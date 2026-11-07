# Arhiv.ps1 - дневен архив на папка (GSOL.bg)
# Настройките (коя папка, къде, колко архива) са в nastroiki.txt до този файл.
# ТУК НИЩО НЕ СЕ ПИПА.
#
#   Arhiv.ps1               - работи във фона: на всеки 10 мин. проверява дали е време за архив
#   Arhiv.ps1 -Sega         - прави един архив веднага (за проба)
#   Arhiv.ps1 -Instalirai   - пуска се заедно с Windows + стартира веднага
#   Arhiv.ps1 -Premahni     - спира и маха автоматичното пускане (архивите остават)

param([switch]$Sega, [switch]$Instalirai, [switch]$Premahni)

$ErrorActionPreference = 'Stop'
$Papka   = $PSScriptRoot
$CfgFile = Join-Path $Papka 'nastroiki.txt'
$LogFile = Join-Path $Papka 'arhiv_log.txt'
$ImeRe   = '^Arhiv_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\.zip$'   # трием САМО файлове с точно такова име
$PrimerenPat = 'ТУК_НАПИШИ'
$ProverkaMin = 10
$Interactive = $Sega -or $Instalirai -or $Premahni

# уникално име според мястото на скрипта (може да има няколко копия за няколко папки)
$md5 = [Security.Cryptography.MD5]::Create()
$hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($PSCommandPath.ToLowerInvariant()))).Replace('-', '').Substring(0, 12)
$ImeMutex = 'GSOL_Arhiv_' + $hash

$script:posledno = ''
function Log([string]$t, [switch]$Vednuzh) {
    if ($Vednuzh) { if ($script:posledno -eq $t) { return }; $script:posledno = $t } else { $script:posledno = '' }
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

    $c = @{ IZVOR = ''; CEL = ''; MAKS_ARHIVI = '50'; CHASA_MEZHDU = '24' }
    foreach ($ln in ($text -split "`r?`n")) {
        $ln = $ln.Trim()
        if ($ln -eq '' -or $ln.StartsWith('#')) { continue }
        $i = $ln.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $ln.Substring(0, $i).Trim().ToUpperInvariant()
        $v = $ln.Substring($i + 1).Trim().Trim('"', "'", ' ')
        if ($c.ContainsKey($k)) { $c[$k] = $v }
    }
    if ($c.IZVOR -eq '' -or $c.IZVOR -like "*$PrimerenPat*") { throw "Не е написана папката за архивиране (IZVOR=...) в $CfgFile" }
    if ($c.CEL -eq '')   { throw "Не е написано къде да се пазят архивите (CEL=...) в $CfgFile" }
    $n = 0; if (-not [int]::TryParse($c.MAKS_ARHIVI, [ref]$n) -or $n -lt 1)  { throw "MAKS_ARHIVI трябва да е цяло число от 1 нагоре (сега: '$($c.MAKS_ARHIVI)')" }
    $c.MAKS = $n
    $h = 0; if (-not [int]::TryParse($c.CHASA_MEZHDU, [ref]$h) -or $h -lt 1) { throw "CHASA_MEZHDU трябва да е цяло число от 1 нагоре (сега: '$($c.CHASA_MEZHDU)')" }
    $c.CHASA = $h
    $c.IZVOR = Normalize $c.IZVOR
    $c.CEL   = Normalize $c.CEL
    $sep = [IO.Path]::DirectorySeparatorChar
    $iz = $c.IZVOR.TrimEnd('\', '/') + $sep
    $ce = $c.CEL.TrimEnd('\', '/') + $sep
    if ($ce.StartsWith($iz, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Папката за архивите ($($c.CEL)) е ВЪТРЕ в папката, която се архивира - така всеки архив ще съдържа предишните. Сложи CEL на друго място."
    }
    return $c
}

function Get-Arhivi([string]$cel) {
    if (-not (Test-Path -LiteralPath $cel -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $cel -File | Where-Object { $_.Name -match $ImeRe } | Sort-Object Name)
}

function Get-Vreme($f) {
    $m = [regex]::Match($f.Name, $ImeRe)
    return [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd_HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture)
}

function Make-Arhiv($c) {
    $izvor = $c.IZVOR; $cel = $c.CEL
    if (-not (Test-Path -LiteralPath $izvor -PathType Container)) {
        Log "НЕ Е НАПРАВЕН: папката за архивиране я няма: $izvor (изключен диск? грешен път?). Пробвам пак след $ProverkaMin мин." -Vednuzh
        return $false
    }
    if (-not (Test-Path -LiteralPath $cel -PathType Container)) {
        try { New-Item -ItemType Directory -Path $cel -Force | Out-Null }
        catch { Log "НЕ Е НАПРАВЕН: не мога да създам папката за архивите: $cel ($($_.Exception.Message)). Пробвам пак след $ProverkaMin мин." -Vednuzh; return $false }
    }

    $files = @(Get-ChildItem -LiteralPath $izvor -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Log "НЕ Е НАПРАВЕН: папката $izvor е празна (или няма достъп) - не правя празен архив, за да не изместя добрите стари." -Vednuzh
        return $false
    }

    # остатъци от прекъснат архив (спрян ток, изключен компютър)
    Get-ChildItem -LiteralPath $cel -File -Filter 'Arhiv_*.zip.part' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force } catch {}
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $final = Join-Path $cel ('Arhiv_' + $stamp + '.zip')
    $part  = $final + '.part'
    $root  = Split-Path $izvor -Leaf
    if (-not $root -or $root -match '[:\\/]') { $root = 'Arhiv' }

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
                if ($skip -le 20) { Log "  пропуснат (зает или без достъп): $($f.FullName)" }
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
        Log "НЕ Е НАПРАВЕН: грешка при писане на архива ($($_.Exception.Message)). Свършило място? Изключен диск? Пробвам пак след $ProverkaMin мин." -Vednuzh
        return $false
    }

    if ($ok -eq 0) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Log "НЕ Е НАПРАВЕН: нито един файл не можа да се прочете от $izvor." -Vednuzh
        return $false
    }

    Move-Item -LiteralPath $part -Destination $final
    $mb = [math]::Round((Get-Item -LiteralPath $final).Length / 1MB, 1)
    $msg = "ГОТОВ: $(Split-Path $final -Leaf) - $ok файла, $mb MB"
    if ($skip -gt 0) { $msg += ", ПРОПУСНАТИ $skip (заети/без достъп)" }
    Log $msg

    # само най-новите MAKS архива остават
    $all = @(Get-Arhivi $cel)
    $izlishni = $all.Count - $c.MAKS
    if ($izlishni -gt 0) {
        $all | Select-Object -First $izlishni | ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force; Log "  изтрит стар архив: $($_.Name)" }
            catch { Log "  не можах да изтрия $($_.Name): $($_.Exception.Message)" }
        }
    }
    return $true
}

function Lock-Rabota {
    $m = New-Object Threading.Mutex -ArgumentList $false, ($ImeMutex + '_rabota')
    try { [void]$m.WaitOne() } catch {}   # изоставен mutex (убит процес) пак ни го дава
    return $m
}

# Проверка: време ли е? Ако да - прави архив. (под заключване, за да не тръгнат два наведнъж)
function Proveri-I-Arhiviray([switch]$Vinagi) {
    $m = Lock-Rabota
    try {
        $c = Read-Cfg
        $arh = @(Get-Arhivi $c.CEL)
        $vreme = $true
        if (-not $Vinagi -and $arh.Count -gt 0) {
            $posleden = Get-Vreme $arh[-1]
            $vreme = ((Get-Date) - $posleden).TotalHours -ge $c.CHASA
        }
        if ($vreme) { [void](Make-Arhiv $c) }
    } catch {
        Log "ГРЕШКА: $($_.Exception.Message)" -Vednuzh
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

# ---------- -Sega: един архив веднага ----------
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
    if (-not (Test-Path -LiteralPath $c.IZVOR -PathType Container)) {
        Log "СПИРАМ: папката за архивиране я няма: $($c.IZVOR)"
        Log "Провери пътя в nastroiki.txt (копирай го от адресната лента на папката) и пусни 1_INSTALIRAI пак."
        exit 1
    }
    Log "Папка за архив : $($c.IZVOR)"
    Log "Архивите отиват: $($c.CEL)"
    Log "Пази последните: $($c.MAKS) архива, нов на всеки $($c.CHASA) часа"
    if ([IO.Path]::GetPathRoot($c.IZVOR) -eq [IO.Path]::GetPathRoot($c.CEL)) {
        Log "ВНИМАНИЕ: архивите са на същия диск - пазят от изтрит/развален файл, но НЕ от развален диск. По-добре е друг диск."
    }
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $psExe
    $s.Arguments = $fonArgs
    $s.WorkingDirectory = $Papka
    $s.WindowStyle = 7
    $s.Save()
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
