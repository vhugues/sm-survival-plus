<#
    Install-ThisMod.ps1

    Installs the mod sitting next to this script into the Scrap Mechanic Mod Manager.

    FOR MOD AUTHORS
    ---------------
    This file is FREE TO USE. Copy it and "Install this mod.bat" into your own mod's
    zip and your mod installs itself - no instructions, no folder hunting, no asking
    people to find where the Mod Manager went. You do not need permission and you do
    not need to credit anyone.

    It makes no assumptions about your mod. It installs whatever folder is beside it
    that contains a mod.lua, so it works unchanged in any mod.

    HOW IT FINDS THE MOD MANAGER
    ---------------------------
    The Mod Manager's installer records where it put itself:

        HKCU\Software\spawn7224\ScrapMechanicModManager\InstallPath   (per-user)
        HKLM\Software\spawn7224\ScrapMechanicModManager\InstallPath   (admin install)

    Read that, and Add-Mod.ps1 is in its tools folder. Nothing here is specific to a
    particular version, so a mod shipping this will keep working as the manager moves.

    If the Mod Manager is not installed, this says so and points at it, rather than
    failing with something the player cannot act on.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

function Say([string]$text, [string]$colour = "Gray") { Write-Host $text -ForegroundColor $colour }

function Stop-With([string]$message) {
    Write-Host ""
    Say $message "Red"
    Write-Host ""
    Write-Host "Press any key to close..."
    [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

Write-Host ""
Say "Scrap Mechanic - mod installer" "Cyan"
Write-Host ""

#------------------------------------------------------------------------------
# 1. Which folder here is the mod?
#
# Identified by mod.lua rather than by name, so this file needs no editing to be
# reused - drop it in any mod's zip and it finds that mod.
#------------------------------------------------------------------------------
$modFolder = $null

if (Test-Path (Join-Path $scriptDir "mod.lua")) {
    # The script is inside the mod folder itself.
    $modFolder = $scriptDir
} else {
    $candidates = @(Get-ChildItem $scriptDir -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.FullName "mod.lua") })
    if ($candidates.Count -eq 1) {
        $modFolder = $candidates[0].FullName
    } elseif ($candidates.Count -gt 1) {
        Stop-With ("This folder contains {0} mods, so it is not clear which to install:`r`n  {1}" -f `
            $candidates.Count, (($candidates | ForEach-Object { $_.Name }) -join "`r`n  "))
    }
}

if (-not $modFolder) {
    Stop-With "No mod was found next to this file.`r`n`r`nExtract the whole zip first, keeping its folders, then run this again."
}

Say ("  Mod:  " + (Split-Path $modFolder -Leaf))

#------------------------------------------------------------------------------
# 2. Where is the Mod Manager?
#------------------------------------------------------------------------------
$managerPath = $null
foreach ($hive in @("HKCU:", "HKLM:")) {
    $key = "$hive\Software\spawn7224\ScrapMechanicModManager"
    try {
        $value = (Get-ItemProperty -Path $key -Name "InstallPath" -ErrorAction Stop).InstallPath
        if ($value -and (Test-Path $value)) { $managerPath = $value; break }
    } catch { }
}

# Fall back to the usual places, so a manager installed before InstallPath was
# recorded - or copied to another machine by hand - is still found.
if (-not $managerPath) {
    foreach ($guess in @(
        (Join-Path $env:LOCALAPPDATA "Programs\Scrap Mechanic Mod Manager"),
        "C:\Program Files\Scrap Mechanic Mod Manager",
        "C:\Program Files (x86)\Scrap Mechanic Mod Manager"
    )) {
        if (Test-Path (Join-Path $guess "tools\Add-Mod.ps1")) { $managerPath = $guess; break }
    }
}

if (-not $managerPath) {
    Stop-With @"
The Scrap Mechanic Mod Manager is not installed on this computer.

This mod runs inside it, so install that first:
  https://www.nexusmods.com/scrapmechanic/mods/37

Then run this again.
"@
}

$addMod = Join-Path $managerPath "tools\Add-Mod.ps1"
if (-not (Test-Path $addMod)) {
    Stop-With "Found the Mod Manager at:`r`n  $managerPath`r`n`r`nbut its tools\Add-Mod.ps1 is missing. Reinstalling the Mod Manager should fix that."
}

Say ("  Into: " + $managerPath)
Write-Host ""

#------------------------------------------------------------------------------
# 3. Hand it over
#
# Add-Mod does the real work: it copies the mod in, regenerates what needs
# regenerating, and patches the game. Deliberately not reimplemented here - one copy
# of that logic, maintained in one place.
#------------------------------------------------------------------------------
if (Get-Process -Name "ScrapMechanic" -ErrorAction SilentlyContinue) {
    Stop-With "Scrap Mechanic is running.`r`n`r`nClose the game completely, then run this again."
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $addMod $modFolder
$code = $LASTEXITCODE

Write-Host ""
if ($code -eq 0) {
    Say "Done. Start the game and type /mods in chat." "Green"
} else {
    Say "The mod was not installed. The messages above say why." "Red"
}
Write-Host ""
Write-Host "Press any key to close..."
[void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
exit $code
