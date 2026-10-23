<#
.SYNOPSIS
    Rolls Steam Geometry Dash back to 2.2081 and installs Geode plus a mod list.

.DESCRIPTION
    Geode targets GD 2.2081, so it breaks whenever Steam updates the game
    (2.209 and 2.2091 in October 2026). This script:
      1. backs up your saves,
      2. gets 2.2081 from your own Steam account (download_depot in the Steam console),
      3. checks the files really are 2.2081 and copies them over your install,
      4. installs the official Geode loader and the mods listed below,
      5. makes Steam's manifest read-only so it stops re-updating the game.
    No game files are included or uploaded anywhere.

.PARAMETER DryRun
    Downloads and checks everything, shows what would change, changes nothing.

.PARAMETER Unlock
    Undoes the update lock so Steam can update Geometry Dash again.

.PARAMETER NoMods
    Installs Geode only, without the mod list.

.PARAMETER NoLock
    Leaves Steam's manifest writable (Steam will update the game on its next patch).

.PARAMETER SteamPath
    Your Steam folder, if it isn't found automatically.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Unlock,
    [switch]$NoMods,
    [switch]$NoLock,
    [string]$SteamPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$AppId = 322170
$DepotId = 322171
$Manifest = '3816559102876907245'
$TargetVersion = '2.2081'
$TargetStamp = 1768959392

$GeodeVersion = 'v5.11.2'
$GeodeZipUrl = "https://github.com/geode-sdk/geode/releases/download/$GeodeVersion/geode-$GeodeVersion-win.zip"
$GeodeZipSha256 = '193d4d9003dd020c989eae5c0e5345aa5b501f2a3ea467ebdd83b72a0c6539cf'
$GeodeFiles = @('Geode.dll', 'XInput1_4.dll', 'GeodeUpdater.exe', 'Geode.pdb')

# Exact versions known to work on 2.2081 with Geode v5.11.x. Downloaded from the
# Geode index and checked against the hash it publishes.
$Mods = [ordered]@{
    'geode.node-ids'           = '1.23.3'
    'cvolton.level-id-api'     = '2.0.0'
    'cvolton.betterinfo'       = '4.4.7'
    'cvolton.misc_bugfixes'    = '1.11.0'
    'dankmeme.globed2'         = '2.1.4'
    'eclipse.eclipse-menu'     = '1.9.4'
    'fleym.nongd'              = '3.6.2'
    'hiimjustin000.more_icons' = '2.1.3'
}

# PE header timestamps of GeometryDash.exe; Geode identifies the game the same way.
$KnownBuilds = @{
    '1768823161' = '2.2080'
    '1768959392' = '2.2081'
    '1791899187' = '2.209'
    '1792203143' = '2.2091'
}

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "   $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "   $Text" }
function Write-Would([string]$Text) { Write-Host "   [dry run] would $Text" -ForegroundColor Yellow }

# Throws instead of exiting: run as a one-liner, exit would close the user's window.
function Stop-WithError([string]$Text) {
    throw $Text
}

function Get-PeTimestamp([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4096
        [void]$fs.Read($buf, 0, $buf.Length)
        $pe = [BitConverter]::ToInt32($buf, 0x3C)
        return [BitConverter]::ToUInt32($buf, $pe + 8)
    } finally {
        $fs.Dispose()
    }
}

function Get-BuildName([uint32]$Stamp) {
    $name = $KnownBuilds["$Stamp"]
    if ($name) { return $name }
    return "unknown build ($Stamp)"
}

function Get-SteamPath {
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($prop in 'SteamPath', 'InstallPath') {
            $value = $item.$prop
            if ($value -and (Test-Path $value)) { return (Resolve-Path $value).Path }
        }
    }
    return $null
}

function Find-GdInstall([string]$SteamPath) {
    $libraries = @($SteamPath)
    $vdf = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $libraries += $m.Groups[1].Value.Replace('\\', '\')
        }
    }
    foreach ($lib in ($libraries | Select-Object -Unique)) {
        $acf = Join-Path $lib "steamapps\appmanifest_$AppId.acf"
        if (-not (Test-Path $acf)) { continue }
        $installDir = 'Geometry Dash'
        $m = [regex]::Match((Get-Content $acf -Raw), '"installdir"\s+"([^"]+)"')
        if ($m.Success) { $installDir = $m.Groups[1].Value }
        $dir = Join-Path $lib "steamapps\common\$installDir"
        if (Test-Path (Join-Path $dir 'GeometryDash.exe')) {
            return [pscustomobject]@{ Dir = $dir; Acf = $acf }
        }
    }
    return $null
}

function Get-FolderBytes([string]$Path) {
    $sum = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($sum) { return [int64]$sum }
    return [int64]0
}

function Save-Download([string]$Url, [string]$OutFile, [string]$Sha256) {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    $actual = (Get-FileHash $OutFile -Algorithm SHA256).Hash
    if ($actual -ne $Sha256.ToUpper()) {
        Remove-Item $OutFile -Force
        Stop-WithError "Download from $Url failed its hash check (got $actual). Nothing was installed from it."
    }
}

function Wait-ForDepot([string]$DepotDir) {
    $command = "download_depot $AppId $DepotId $Manifest"
    $exe = Join-Path $DepotDir 'GeometryDash.exe'
    if (Test-Path $exe) { return }

    try { Set-Clipboard -Value $command } catch { }
    Write-Note 'Steam has to download 2.2081 with your own account. Opening the Steam console now.'
    Write-Note 'In the Steam window, click the text box at the bottom of the Console page,'
    Write-Note 'paste (Ctrl+V; the command is already copied) and press Enter:'
    Write-Host "`n      $command`n" -ForegroundColor White
    Write-Note 'If the Console page does not open, press Win+R and run: steam://open/console'
    Write-Note 'Waiting for the download (about 300 MB). Press Ctrl+C to stop waiting.'
    Start-Process "steam://open/console"

    $last = [int64]-1
    $stableSince = $null
    while ($true) {
        Start-Sleep -Seconds 3
        if (-not (Test-Path $exe)) { continue }
        $bytes = Get-FolderBytes $DepotDir
        if ($bytes -ne $last) {
            $last = $bytes
            $stableSince = Get-Date
            Write-Host ("`r   downloaded {0:N0} MB   " -f ($bytes / 1MB)) -NoNewline
            continue
        }
        if ($bytes -gt 250MB -and ((Get-Date) - $stableSince).TotalSeconds -ge 15) {
            Write-Host ''
            return
        }
    }
}

function Invoke-Rollback {
    Write-Host 'Geode rollback: Geometry Dash 2.2081 + Geode' -ForegroundColor Cyan
    if ($DryRun) { Write-Host 'Dry run: everything is downloaded and checked, nothing is changed.' -ForegroundColor Yellow }

    Write-Step 'Finding Geometry Dash'
    $steam = $SteamPath
    if (-not $steam) { $steam = Get-SteamPath }
    if (-not $steam -or -not (Test-Path $steam)) { Stop-WithError 'Steam was not found. Pass your Steam folder with -SteamPath.' }
    $gd = Find-GdInstall $steam
    if (-not $gd) { Stop-WithError 'Geometry Dash is not installed in any Steam library. Install it from Steam first.' }
    $gdExe = Join-Path $gd.Dir 'GeometryDash.exe'
    $currentStamp = Get-PeTimestamp $gdExe
    Write-Ok "Found $($gd.Dir)"
    Write-Ok "Installed version: $(Get-BuildName $currentStamp)"

    if ($Unlock) {
        Write-Step 'Letting Steam update Geometry Dash again'
        if ($DryRun) {
            Write-Would "make $($gd.Acf) writable"
        } else {
            (Get-Item $gd.Acf).IsReadOnly = $false
            Write-Ok 'Steam manifest is writable again.'
        }
        Write-Note 'To get the latest version now: Steam > Geometry Dash > Properties > Installed Files > Verify integrity.'
        Write-Note 'Geode only works on the new version once Geode itself supports it.'
        return
    }

    if (Get-Process -Name GeometryDash -ErrorAction SilentlyContinue) {
        if ($DryRun) {
            Write-Note 'Geometry Dash is running; a real run would ask you to close it.'
        } else {
            Write-Host "`n   Close Geometry Dash, then press Enter." -ForegroundColor Yellow
            [void](Read-Host)
            if (Get-Process -Name GeometryDash -ErrorAction SilentlyContinue) { Stop-WithError 'Geometry Dash is still running.' }
        }
    }

    Write-Step 'Backing up your saves'
    $backup = Join-Path $env:USERPROFILE ("gd-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $saveDir = Join-Path $env:LOCALAPPDATA 'GeometryDash'
    $saves = @(Get-ChildItem (Join-Path $saveDir '*.dat') -ErrorAction SilentlyContinue)
    if ($DryRun) {
        Write-Would "copy $($saves.Count) save files to $backup\saves"
    } else {
        New-Item -ItemType Directory -Force -Path (Join-Path $backup 'saves') | Out-Null
        foreach ($f in $saves) { Copy-Item $f.FullName (Join-Path $backup 'saves') }
        Copy-Item $gd.Acf $backup
        Write-Ok "$($saves.Count) save files copied to $backup\saves"
    }

    Write-Step "Getting Geometry Dash $TargetVersion"
    if ($currentStamp -eq $TargetStamp) {
        Write-Ok "Already on $TargetVersion, nothing to download."
    } else {
        $depotDir = Join-Path $steam "steamapps\content\app_$AppId\depot_$DepotId"
        $depotExe = Join-Path $depotDir 'GeometryDash.exe'
        if ($DryRun) {
            if (Test-Path $depotExe) {
                Write-Ok "Steam download found: $(Get-BuildName (Get-PeTimestamp $depotExe))"
            } else {
                Write-Note "Not downloaded yet ($depotDir)."
                Write-Would "open the Steam console and wait for: download_depot $AppId $DepotId $Manifest"
            }
            Write-Would "copy $depotDir over $($gd.Dir)"
        } else {
            Wait-ForDepot $depotDir
            $depotStamp = Get-PeTimestamp $depotExe
            if ($depotStamp -ne $TargetStamp) {
                Stop-WithError "Steam's download is $(Get-BuildName $depotStamp), not $TargetVersion. Delete $depotDir and run this again."
            }
            Write-Ok "Steam download checked: $TargetVersion"

            $oldFiles = Join-Path $backup ("game-" + (Get-BuildName $currentStamp))
            New-Item -ItemType Directory -Force -Path $oldFiles | Out-Null
            Get-ChildItem $gd.Dir -File | Where-Object { $_.Extension -in '.exe', '.dll' } | Copy-Item -Destination $oldFiles

            & robocopy $depotDir $gd.Dir /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { Stop-WithError "Copying the game files failed (robocopy code $LASTEXITCODE)." }
            $currentStamp = Get-PeTimestamp $gdExe
            if ($currentStamp -ne $TargetStamp) { Stop-WithError "The copy did not take: the game is still $(Get-BuildName $currentStamp)." }
            Write-Ok "Geometry Dash is now $TargetVersion (old files kept in $oldFiles)"
        }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("geode-rollback-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-Step "Installing Geode $GeodeVersion"
        $zip = Join-Path $tmp 'geode.zip'
        Save-Download $GeodeZipUrl $zip $GeodeZipSha256
        Expand-Archive $zip -DestinationPath (Join-Path $tmp 'geode')
        Write-Ok 'Downloaded from the official geode-sdk release, hash checked.'
        if ($DryRun) {
            Write-Would "copy $($GeodeFiles -join ', ') into $($gd.Dir)"
        } else {
            foreach ($f in $GeodeFiles) { Copy-Item (Join-Path $tmp "geode\$f") $gd.Dir -Force }
            Write-Ok 'Geode loader installed. Its resources download on first launch.'
        }

        if (-not $NoMods) {
            Write-Step 'Installing mods'
            $modsDir = Join-Path $gd.Dir 'geode\mods'
            if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $modsDir | Out-Null }
            foreach ($id in $Mods.Keys) {
                $version = $Mods[$id]
                $target = Join-Path $modsDir "$id.geode"
                if (Test-Path $target) {
                    Write-Note "$id already installed, left as is."
                    continue
                }
                $info = (Invoke-RestMethod "https://api.geode-sdk.org/v1/mods/$id/versions/$version").payload
                $file = Join-Path $tmp "$id.geode"
                Save-Download $info.download_link $file $info.hash
                if ($DryRun) {
                    Write-Would "install $id $version (downloaded and hash checked)"
                } else {
                    Move-Item $file $target -Force
                    Write-Ok "$id $version"
                }
            }
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $NoLock) {
        Write-Step 'Stopping Steam from re-updating the game'
        if ($DryRun) {
            Write-Would "make $($gd.Acf) read-only"
        } else {
            (Get-Item $gd.Acf).IsReadOnly = $true
            Write-Ok 'Steam manifest is read-only. Run this script with -Unlock to allow updates again.'
        }
    }

    Write-Host "`nDone." -ForegroundColor Green
    if ($DryRun) {
        Write-Note 'That was a dry run. Run it again without -DryRun to install.'
    } else {
        Write-Note 'Start Geometry Dash from Steam as usual. The first start takes a little longer while Geode sets up.'
        Write-Note "Your saves are backed up in $backup"
    }
}

try {
    Invoke-Rollback
} catch {
    Write-Host "`n$($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception -is [UnauthorizedAccessException]) {
        Write-Host 'Windows blocked a file change. Run PowerShell as administrator and try again.' -ForegroundColor Red
    }
}
