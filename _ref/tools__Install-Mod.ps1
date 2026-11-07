<#
    Install-Mod.ps1

    Installs (or removes) the Foliage Eraser + Mod Manager into Scrap Mechanic.

    Vanilla Survival cannot load Steam Workshop mods -- the survival menu has no
    mod UI at all -- so this works by patching the game's own Lua and JSON files.
    They ship as plain readable text and are meant to be moddable.

    Everything it touches is backed up first, and -Uninstall puts the originals
    straight back.

    IMPORTANT: a Steam update, or "Verify integrity of game files", replaces the
    patched files with fresh ones. Just re-run this script afterwards.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\tools\Install-Mod.ps1
        powershell -ExecutionPolicy Bypass -File .\tools\Install-Mod.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    # Left empty on purpose: the game is found automatically, and passing a path
    # is only needed for an install Steam does not know about.
    [string]$GamePath = "",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$projectRoot = Resolve-Path (Join-Path $scriptDir "..")
$srcDir      = Join-Path $projectRoot "src"
$backupRoot  = Join-Path $projectRoot "backups"

. (Join-Path $scriptDir "Find-Game.ps1")
$GamePath = Resolve-ScrapMechanic $GamePath

# Patching files the game has open ends with a half-written install, so stop
# before touching anything rather than after.
if (Get-Process -Name "ScrapMechanic" -ErrorAction SilentlyContinue) {
    throw "Scrap Mechanic is running. Close the game completely, then run this again."
}

$TOOL_UUID = "cf77fe7e-0dae-4beb-bbc9-07e31a470000"

# Marker comments let us find and remove our own edits without guessing.
$MARK_BEGIN = "-- [FoliageEraserMod] BEGIN - added by Install-Mod.ps1"
$MARK_END   = "-- [FoliageEraserMod] END"
$JSON_MARK  = "FoliageEraserMod"

$survival = Join-Path $GamePath "Survival"

# --- files we copy in (source -> destination, relative to Survival) -----------
#
# Only the framework's own GUI files are listed here. Anything belonging to a
# particular mod comes from that mod's assets.json, so each mod can be
# distributed as a self-contained folder.
$copyFiles = @(
    @{ src = "Gui\ModMenu.layout"; dst = "Gui\Layouts\ModMenu.layout" }
)

# The player's Steam Workshop creations.
#
# Runs BEFORE the framework sweep below, for the same reason the plant list does:
# the sweep copies whatever .lua files exist at that moment, so a registry
# generated afterwards would not be installed until the NEXT run.
#
# Failure here is not fatal. Somebody with no Workshop subscriptions, or a Steam
# layout this cannot make sense of, should still get a working mod menu - they
# simply get no WORKSHOP button.
if (-not $Uninstall) {
    $bpGen = Join-Path $scriptDir "Generate-BlueprintList.ps1"
    if (Test-Path $bpGen) {
        try { & $bpGen -GamePath $GamePath }
        catch { Write-Host "  Workshop scan skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }

    # Workshop PART PACKS. Rewrites each pack's shapesets so their asset paths
    # resolve outside Creative; the junction that makes those paths real is made
    # further down, once the game folder is being written to.
    $ppGen = Join-Path $scriptDir "Generate-PartPackList.ps1"
    if (Test-Path $ppGen) {
        try { & $ppGen -GamePath $GamePath }
        catch { Write-Host "  part pack scan skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    }
}

# Framework and plugin folders are discovered rather than listed, so dropping a
# new mod folder into src\Mods\ is all it takes to install it.
foreach ($f in Get-ChildItem (Join-Path $srcDir "Framework") -Filter *.lua -File -ErrorAction SilentlyContinue) {
    $copyFiles += @{ src = "Framework\$($f.Name)"; dst = "Scripts\game\ModFramework\$($f.Name)" }
}

# The creations themselves. Copied as data rather than swept with the .lua files
# above, and kept in their own folder so uninstall can remove the lot without
# touching anything else.
foreach ($f in Get-ChildItem (Join-Path $srcDir "Framework\Blueprints") -Filter *.blueprint -File -ErrorAction SilentlyContinue) {
    $copyFiles += @{ src = "Framework\Blueprints\$($f.Name)"; dst = "Scripts\game\ModFramework\Blueprints\$($f.Name)" }
}

# The Foliage Eraser's plant list is scraped from the player's own game files, so
# it is generated rather than shipped: it keeps the download free of data lifted
# out of the game, and it stays correct across game updates that add or rename
# plants.
#
# This MUST happen before the .lua sweep below. It used to run later, which
# worked on a machine where the file already existed and silently failed on every
# clean install -- the sweep found no FoliageAssets.lua to copy, so the mod
# installed without its plant list. Only a from-zip test on a clean game caught
# it.
$assetList = Join-Path $srcDir "Mods\FoliageEraser\FoliageAssets.lua"
if (-not $Uninstall -and (Test-Path (Join-Path $srcDir "Mods\FoliageEraser")) -and -not (Test-Path $assetList)) {
    $gen = Join-Path $scriptDir "Generate-FoliageList.ps1"
    if (-not (Test-Path $gen)) { throw "Missing $assetList and $gen - cannot build the plant list." }
    Write-Host "Building the plant list from your game files (first run only)..."
    & $gen -GamePath $GamePath
    if (-not (Test-Path $assetList)) { throw "Generate-FoliageList.ps1 did not produce $assetList" }
    Write-Host ""
}

# --- the Data root: Creative and Custom Games ---------------------------------
#
# A second, parallel install. Creative loads its scripts from Data\ and resolves
# $GAME_DATA rather than $SURVIVAL_DATA, so the framework is copied there too
# with its paths rewritten (see Convert-ToDataPaths below).
$dataDir       = Join-Path $GamePath "Data"
$dataCopyFiles = @(
    @{ src = "Gui\ModMenu.layout"; dst = "Gui\Layouts\ModMenu.layout" }
)
foreach ($f in Get-ChildItem (Join-Path $srcDir "Framework") -Filter *.lua -File -ErrorAction SilentlyContinue) {
    $dataCopyFiles += @{ src = "Framework\$($f.Name)"; dst = "Scripts\game\ModFramework\$($f.Name)"; rewrite = $true }
}

# Which game modes does this mod declare? $null means "all of them".
function Get-ModModes([string]$modLuaPath) {
    $t = [System.IO.File]::ReadAllText($modLuaPath)
    $m = [regex]::Match($t, 'modes\s*=\s*\{([^}]*)\}')
    if (-not $m.Success) { return $null }
    $modes = @()
    foreach ($q in [regex]::Matches($m.Groups[1].Value, '"([^"]+)"')) { $modes += $q.Groups[1].Value }
    return $modes
}

function Test-ModWantsMode($modes, [string]$mode) {
    if ($null -eq $modes) { return $true }
    return ($modes -contains $mode)
}

$pluginNames     = @()
$script:toolProxies = @()
$dataPluginNames = @()
foreach ($dir in Get-ChildItem (Join-Path $srcDir "Mods") -Directory -ErrorAction SilentlyContinue) {
    if (-not (Test-Path (Join-Path $dir.FullName "mod.lua"))) {
        Write-Warning "Skipping src\Mods\$($dir.Name): no mod.lua"
        continue
    }

    $modes = Get-ModModes (Join-Path $dir.FullName "mod.lua")

    # A mod's non-Lua assets are listed in its own assets.json, read once here and
    # handed to whichever game roots the mod applies to.
    #
    # Comments are stripped first: the game's own json files use // freely, so ours
    # match that style, and ConvertFrom-Json rejects it.
    $modAssets = @()
    $manifest = Join-Path $dir.FullName "assets.json"
    if (Test-Path $manifest) {
        $raw  = [regex]::Replace([System.IO.File]::ReadAllText($manifest), '(?m)^\s*//.*$', '')
        $spec = $raw | ConvertFrom-Json
        foreach ($entry in @($spec.files)) {
            if ($null -eq $entry) { continue }
            $modAssets += @{
                src = "Mods\$($dir.Name)\$($entry.src.Replace('/','\'))"
                dst = $entry.dst.Replace('/', '\')
            }
        }

        # A tool mod may declare a DROP PROXY: the part that stands in for the
        # tool when it is dropped on the ground. The game never renders a
        # dropped tool itself - util.lua's ToolItems maps tool uuid -> part
        # uuid, and every vanilla tool has such a part. Collected here, patched
        # into util.lua further down.
        if ($spec.toolProxy -and $spec.toolProxy.tool -and $spec.toolProxy.part) {
            $script:toolProxies += @{
                tool = $spec.toolProxy.tool
                part = $spec.toolProxy.part
                name = $dir.Name
            }
        }
    }

    if (Test-ModWantsMode $modes "creative") {
        $dataPluginNames += $dir.Name
        foreach ($f in Get-ChildItem $dir.FullName -Filter *.lua -File) {
            $dataCopyFiles += @{ src = "Mods\$($dir.Name)\$($f.Name)"; dst = "Scripts\game\Mods\$($dir.Name)\$($f.Name)"; rewrite = $true }
        }

        # Assets go to Creative too, so a mod that adds a PART can be tested in a
        # throwaway Creative world before it is trusted with a Survival base.
        #
        # Only text assets get their $SURVIVAL_DATA paths rewritten to $GAME_DATA.
        # A .tga is BINARY: putting one through the text rewriter would corrupt it,
        # and the corruption would only show up as a broken texture in game.
        foreach ($a in $modAssets) {
            $isText = $a.dst -match '\.(shapeset|rend|json|lua)$'
            $dataCopyFiles += @{ src = $a.src; dst = $a.dst; rewrite = $isText }
        }
    }

    if (-not (Test-ModWantsMode $modes "survival")) { continue }

    $pluginNames += $dir.Name
    foreach ($f in Get-ChildItem $dir.FullName -Filter *.lua -File) {
        $copyFiles += @{ src = "Mods\$($dir.Name)\$($f.Name)"; dst = "Scripts\game\Mods\$($dir.Name)\$($f.Name)" }
    }

    foreach ($a in $modAssets) {
        $copyFiles += @{ src = $a.src; dst = $a.dst }
    }
}

# --- files we patch in place -------------------------------------------------
#
# Creative and Custom Games both run CreativeGame.lua, so one patch covers both.
$dataPatchTargets = @(
    "Scripts\game\CreativeGame.lua",
    "Objects\Database\shapesets.json"
)

$patchTargets = @(
    "Tools\ToolSets\tools.json",
    "Gui\Language\English\inventoryDescriptions.json",
    # Craftbot recipes. Listed statically rather than discovered from the mods,
    # because this list drives the pristine backup and that has to happen before
    # anything is read. A mod adding a recipe to a DIFFERENT craftbot list must
    # add that file here too, or its edit would go unbacked-up.
    "CraftingRecipes\craftbot\craftbot_core.json",
    # The INDEX of recipe sets, set name -> file path. Each Workshop parts pack is
    # given its own set so it can be switched off again, and every set has to be
    # named here or it is never loaded.
    "CraftingRecipes\craftbot\craftbot.json",
    # Where a Craftbot decides which sets to show. Patched to register the pack sets
    # and to skip any whose pack is switched off in the current world - that skip is
    # what makes an in-game on/off switch possible, since the grid is rebuilt from
    # this list every time a Craftbot is opened.
    "Scripts\game\interactables\Crafter.lua",
    # Recipes are invisible until unlocked, so a modded recipe needs its uuid in
    # this file's DefaultUnlockedItems as well as in a recipe list.
    "Scripts\game\managers\RecipeManager.lua",
    "Objects\Database\shapesets.json",
    # A part's rotationSet names the orientations it may be placed in, and a Workshop
    # pack can DEFINE ITS OWN. Survival ships this file containing an empty array,
    # so pack definitions go here - see the rotation set step further down for why
    # attachment points depended on it.
    "Objects\Database\rotationsets.json",
    "Scripts\terrain\terrain_overworld.lua",
    # Tool drop proxies (ToolItems table) - see step 3c2.
    "Scripts\util.lua",
    "Scripts\game\SurvivalGame.lua",
    "Scripts\game\SurvivalPlayer.lua",
    "Scripts\game\worlds\Overworld.lua"
)

function Read-TextFile([string]$path) {
    return [System.IO.File]::ReadAllText($path)
}

function Replace-First([string]$text, [string]$pattern, [string]$replacement) {
    # NOTE: [regex]::Replace(input, pattern, replacement, N) does NOT mean
    # "replace N times" -- the static overload takes RegexOptions there, so a 4th
    # argument of 1 silently means IgnoreCase and every match gets replaced.
    # The count overload only exists on the instance method, hence this helper.
    $re = New-Object System.Text.RegularExpressions.Regex($pattern)
    return $re.Replace($text, $replacement, 1)
}

# Creative resolves $GAME_DATA, not $SURVIVAL_DATA. The framework and any
# mode-agnostic mod are authored once and rewritten on the way into Data\,
# rather than kept as two copies that drift apart.
function Convert-ToDataPaths([string]$text) {
    return $text.Replace('$SURVIVAL_DATA', '$GAME_DATA')
}

function Write-TextFile([string]$path, [string]$content) {
    # Refuse to write a lone CR (one not part of a CRLF).
    #
    # This exists because of a real outage: a backtick-quoted word inside one of
    # the Lua here-strings below was read as a PowerShell escape, so `r put a raw
    # carriage return into SurvivalGame.lua. Lua treats it as a newline, which
    # split a comment in half and turned its tail into code:
    #
    #     -- ... the mod supplies a <CR>un function in its
    #
    # giving "'=' expected near 'function'". SurvivalGame then failed to compile
    # and Survival worlds would not load at all -- while Creative, patched from
    # here-strings with no backticks in them, was completely fine.
    if ([regex]::IsMatch($content, "\r(?!\n)")) {
        throw "Refusing to write $path - it contains a stray carriage return. A backtick escape in a here-string is the usual cause."
    }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-PristineBackupPath([string]$relative, [string]$root = "Survival") {
    # One pristine copy of each vanilla file, taken the first time we ever touch
    # it. Later installs must not overwrite it with an already-patched version.
    return Join-Path (Join-Path (Join-Path $backupRoot "pristine") $root) $relative
}

function Backup-Pristine([string]$relative, [string]$root = "Survival") {
    $full   = Join-Path (Join-Path $GamePath $root) $relative
    $backup = Get-PristineBackupPath $relative $root
    if (-not (Test-Path $backup)) {
        $dir = Split-Path -Parent $backup
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Copy-Item $full $backup
        Write-Host "  backed up  $root\$relative"
    }
}

# Vanilla files we replace outright (as opposed to text-patch), with the same
# pristine-backup treatment as everything else.
#
# IconMapSurvival is THE source of inventory/hotbar grid icons: a 4096x4096
# atlas of 96x96 frames indexed by item uuid. Without an entry here an item
# simply draws nothing, which is why the eraser's slot was blank.
# Data\Gui\ToolIconMap was a red herring - it holds only 6 creative tools and no
# survival tool at all, not even the Sledgehammer.
# Creative keeps its own icon atlas, so a part needs an entry in BOTH or it has
# no icon in whichever mode was missed. Both are generated by Make-Icon.ps1, so
# these are copied AFTER it runs rather than with the ordinary file copies.
$dataReplaceFiles = @(
    @{ src = "Gui\IconMap.png"; dst = "Gui\IconMap.png" },
    @{ src = "Gui\IconMap.xml"; dst = "Gui\IconMap.xml" }
)

$survivalReplaceFiles = @(
    @{ src = "Gui\IconMapSurvival.png"; dst = "Gui\IconMapSurvival.png" },
    @{ src = "Gui\IconMapSurvival.xml"; dst = "Gui\IconMapSurvival.xml" }
)

#------------------------------------------------------------------------------
# Uninstall
#------------------------------------------------------------------------------
if ($Uninstall) {
    Write-Host "Removing the Foliage Eraser mod..." -ForegroundColor Cyan

    # Workshop part pack mounts.
    #
    # Delete() on the junction itself, NEVER Remove-Item -Recurse: a recursive
    # delete can follow a junction and destroy the ORIGINAL Workshop content,
    # which would silently wipe out another creator's pack from the player's Steam
    # download. Delete() removes only the link.
    #
    # The rewritten shapesets themselves are copied files and are removed by the
    # normal copy-file cleanup, since they live under Objects\Database\ShapeSets.
    $mountRootDir = Join-Path $GamePath "Survival\WorkshopMods"
    if (Test-Path $mountRootDir) {
        foreach ($link in @(Get-ChildItem $mountRootDir -Force -ErrorAction SilentlyContinue)) {
            try {
                (Get-Item $link.FullName -Force).Delete()
                Write-Host "  unmounted  Survival\WorkshopMods\$($link.Name)"
            } catch {
                Write-Warning "  could not remove the mount $($link.FullName) - delete it by hand"
            }
        }
        if (@(Get-ChildItem $mountRootDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $mountRootDir -Force -ErrorAction SilentlyContinue
        }
    }

    # Scratch blueprint copies the placer wrote into the game's own
    # LocalBlueprints folder. They are ours, so uninstalling takes them with it
    # rather than leaving litter behind in a vanilla install.
    $localBlueprintsDir = Join-Path $GamePath "Survival\LocalBlueprints"
    if (Test-Path $localBlueprintsDir) {
        $leftovers = @(Get-ChildItem (Join-Path $localBlueprintsDir "modmanager_*.blueprint") -ErrorAction SilentlyContinue)
        foreach ($f in $leftovers) {
            Remove-Item $f.FullName -Force
            Write-Host "  removed    Survival\LocalBlueprints\$($f.Name)"
        }
    }

    foreach ($relative in $patchTargets) {
        $backup = Get-PristineBackupPath $relative
        $full   = Join-Path $survival $relative
        if (Test-Path $backup) {
            Copy-Item $backup $full -Force
            Write-Host "  restored   $relative"
        } else {
            Write-Warning "  no backup for $relative - use Steam > Verify integrity of game files"
        }
    }

    foreach ($relative in $dataPatchTargets) {
        $backup = Get-PristineBackupPath $relative "Data"
        $full   = Join-Path $dataDir $relative
        if (Test-Path $backup) {
            Copy-Item $backup $full -Force
            Write-Host "  restored   Data\$relative"
        } elseif (Test-Path $full) {
            Write-Warning "  no backup for Data\$relative - use Steam > Verify integrity of game files"
        }
    }

    foreach ($entry in $dataCopyFiles) {
        $full = Join-Path $dataDir $entry.dst
        if (Test-Path $full) {
            Remove-Item $full -Force
            Write-Host "  removed    Data\$($entry.dst)"
        }
    }
    foreach ($extra in @("Scripts\game\ModFramework\ModRegistry.lua")) {
        $full = Join-Path $dataDir $extra
        if (Test-Path $full) { Remove-Item $full -Force; Write-Host "  removed    Data\$extra" }
    }

    foreach ($entry in $dataReplaceFiles) {
        $backup = Get-PristineBackupPath $entry.dst "Data"
        $full   = Join-Path (Join-Path $GamePath "Data") $entry.dst
        if (Test-Path $backup) {
            Copy-Item $backup $full -Force
            Write-Host "  restored   Data\$($entry.dst)"
        } else {
            Write-Warning "  no backup for Data\$($entry.dst)"
        }
    }

    foreach ($entry in $survivalReplaceFiles) {
        $backup = Get-PristineBackupPath $entry.dst "Survival"
        $full   = Join-Path $survival $entry.dst
        if (Test-Path $backup) {
            Copy-Item $backup $full -Force
            Write-Host "  restored   $($entry.dst)"
        } else {
            Write-Warning "  no backup for $($entry.dst)"
        }
    }

    foreach ($entry in $copyFiles) {
        $full = Join-Path $survival $entry.dst
        if (Test-Path $full) {
            Remove-Item $full -Force
            Write-Host "  removed    $($entry.dst)"
        }
    }

    # Tidy up the folders those files lived in, derived from what was actually
    # installed rather than a hardcoded list -- a hardcoded one only ever named
    # FoliageEraser, so every other mod left an empty directory behind.
    #
    # Deepest first, so Mods\SomeMod empties before Mods is considered.
    $dirs = @()
    foreach ($entry in $copyFiles) {
        $dir = Split-Path -Parent $entry.dst
        while (-not [string]::IsNullOrWhiteSpace($dir)) {
            $dirs += $dir
            $dir = Split-Path -Parent $dir
        }
    }
    $dirs += @("Scripts\game\Mods", "Scripts\game\ModFramework")

    # Folders that belong to the game. They can legitimately end up empty once
    # our files are gone -- Survival\Renderables holds nothing else -- but they
    # are not ours to delete. An uninstall should leave no trace of the mod and
    # no dent in the game either.
    $vanillaDirs = @(
        "Gui", "Gui\Layouts", "Gui\JsonGuis", "Gui\Language",
        "Renderables", "Scripts", "Scripts\game", "Scripts\terrain",
        "Character", "Character\Char_Tools", "Tools", "Tools\ToolSets"
    )

    foreach ($entry in $dataCopyFiles) {
        $dir = Split-Path -Parent $entry.dst
        while (-not [string]::IsNullOrWhiteSpace($dir)) { $dirs += $dir; $dir = Split-Path -Parent $dir }
    }

    foreach ($folder in ($dirs | Select-Object -Unique | Sort-Object { ($_ -split '\\').Count } -Descending)) {
        if ($vanillaDirs -contains $folder) { continue }
        foreach ($root in @($survival, $dataDir)) {
            $full = Join-Path $root $folder
            if ((Test-Path $full) -and -not (Get-ChildItem $full -Force)) {
                Remove-Item $full -Force
                Write-Host "  removed    $(Split-Path $root -Leaf)\$folder\"
            }
        }
    }

    # FILES WE CREATE THAT NOTHING ELSE REMOVES.
    #
    # Restoring a pristine backup only undoes an EDIT to a vanilla file. These three
    # are files the installer ADDS, so nothing above knows about them, and a test
    # uninstall found all three still sitting in the game folder afterwards:
    #
    #   craftbot_mmpack_*.json      one recipe set per Workshop parts pack
    #   ModManagerPackDefaults.json written by the Asset Pack Installer
    #   ModFramework\ModRegistry.lua generated at install, so the folder never emptied
    #                                and the empty-folder sweep above skipped it
    #
    # This matters more than it looks: the Windows uninstaller calls this script and
    # then deletes its own files, so anything missed here stays in the game forever
    # with nothing left that knows how to remove it.
    $addedFiles = @(
        (Join-Path $survival "ModManagerPackDefaults.json")
    )
    $addedFiles += @(Get-ChildItem (Join-Path $survival "CraftingRecipes\craftbot\craftbot_mmpack_*.json") -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })

    foreach ($f in $addedFiles) {
        if (Test-Path $f) {
            Remove-Item $f -Force
            Write-Host "  removed    $($f.Replace($survival, 'Survival'))"
        }
    }

    foreach ($root in @($survival, $dataDir)) {
        $fw = Join-Path $root "Scripts\game\ModFramework"
        if (Test-Path $fw) {
            Remove-Item $fw -Recurse -Force
            Write-Host "  removed    $(Split-Path $root -Leaf)\Scripts\game\ModFramework\"
        }
    }

    Write-Host ""
    Write-Host "Done. The game is back to vanilla." -ForegroundColor Green
    Write-Host "Plants you already erased stay erased in the save, because that list lives" -ForegroundColor Yellow
    Write-Host "in the world file rather than in the mod." -ForegroundColor Yellow
    return
}

#------------------------------------------------------------------------------
# Install
#------------------------------------------------------------------------------
Write-Host "Installing the Foliage Eraser mod into:" -ForegroundColor Cyan
Write-Host "  $GamePath"
Write-Host ""

# The one copy of the player's worlds from before any of this existed.
#
# Taken here, before a single game file is touched, and only once - -IfMissing
# means this can be called unconditionally on every install and re-install. If
# they have never played, there is nothing to copy and it says so; the next run
# picks it up.
#
# Called as a child process rather than dot-sourced on purpose. Save-Backups.ps1
# has its own param block, and dot-sourcing would drop $Mod, $Id, $Kind, $Reason
# and $Keep into this script's scope.
#
# Never fatal. A save backup failing is a reason to warn, not a reason to refuse
# to install a mod.
if (-not $Uninstall) {
    try {
        $baselineReason = if ($pluginNames.Count -eq 0 -and $dataPluginNames.Count -eq 0) {
            "Before any mods - your original unmodded worlds"
        } else {
            "First save backup (some mods were already installed)"
        }
        & (Join-Path $scriptDir "Save-Backups.ps1") -Action New -Kind baseline -Reason $baselineReason -IfMissing
    } catch {
        Write-Warning "Could not take the baseline save backup: $($_.Exception.Message)"
    }
    Write-Host ""
}

Write-Host "Step 1/3  Backing up the files we are about to change"
foreach ($relative in $dataPatchTargets) { Backup-Pristine $relative "Data" }
foreach ($relative in $patchTargets) { Backup-Pristine $relative }

# Has something ELSE modified a file we patch?
#
# Every patch is applied to the pristine backup, never to whatever is on disk --
# that is what makes re-running safe and stops edits stacking up. The cost is
# that another mod's changes to the same file are silently discarded.
#
# Scrap Mechanic Survival mods work by replacing game files (there is a Vortex
# extension devoted to deploying exactly that kind of mod), so two mods wanting
# SurvivalGame.lua is a realistic collision, not a hypothetical one. Say so
# rather than quietly winning.

# Fingerprints that mean "this file was changed by us". The comment marker
# covers the Lua patches, but tools.json is JSON and carries no comment -- it is
# recognised by the tool uuids we add. Without those, a normal reinstall
# reported our own tools.json edit as somebody else's work.
$ourSignatures = @($JSON_MARK)
foreach ($name in $pluginNames) {
    $itemJson = Join-Path $srcDir "Mods\$name\item.json"
    if (Test-Path $itemJson) {
        $m = [regex]::Match([System.IO.File]::ReadAllText($itemJson), '"uuid"\s*:\s*"([^"]+)"')
        if ($m.Success) { $ourSignatures += $m.Groups[1].Value }
    }
}

# A part shapeset is registered in shapesets.json by PATH, not by uuid, so the uuid
# signatures above would fail to recognise our own edit to that one file and the
# SECOND install would abort, convinced somebody else had modified it.
foreach ($f in $copyFiles) {
    if ($f.dst -like "*.shapeset") {
        $ourSignatures += [System.IO.Path]::GetFileName($f.dst)
    }
}

# Part pack recipe sets, for the same reason as the shapesets above.
#
# Our craftbot.json edit adds index entries named craftbot_mmpack_<pack uuid>, and
# not one of the signatures above appears anywhere in that file. So every install
# after the first saw craftbot.json differing from pristine, failed to recognise
# the change as ours, and warned that ANOTHER MOD had edited it - on a file we had
# written ourselves minutes earlier.
#
# A prefix rather than the full names because the pack list is not worked out until
# much later in this script, and a false "another mod is fighting you" warning on
# every single install is worse than matching slightly broadly. Nothing but this
# installer writes that prefix.
$ourSignatures += "craftbot_mmpack_"

function Test-ForeignEdit([string]$relative, [string]$root) {
    $backup = Get-PristineBackupPath $relative $root
    $full   = Join-Path (Join-Path $GamePath $root) $relative
    if (-not (Test-Path $backup) -or -not (Test-Path $full)) { return $false }

    $current = Read-TextFile $full
    if ($current -eq (Read-TextFile $backup)) { return $false }   # untouched

    foreach ($sig in $ourSignatures) {
        if ($current.Contains($sig)) { return $false }            # ours already
    }
    return $true
}

$foreign = @()
foreach ($relative in $patchTargets)     { if (Test-ForeignEdit $relative "Survival") { $foreign += "Survival\$relative" } }
foreach ($relative in $dataPatchTargets) { if (Test-ForeignEdit $relative "Data")     { $foreign += "Data\$relative" } }

if ($foreign.Count -gt 0) {
    Write-Host ""
    Write-Warning "Another mod appears to have edited files this installer also patches:"
    foreach ($f in $foreign) { Write-Host "    $f" -ForegroundColor Yellow }
    Write-Host "  Patching restores each file from the untouched backup first, so those" -ForegroundColor Yellow
    Write-Host "  other changes will be lost. If you want both, install the other mod" -ForegroundColor Yellow
    Write-Host "  first and re-run this afterwards - or check whether it does the same" -ForegroundColor Yellow
    Write-Host "  job as one of these mods." -ForegroundColor Yellow
    Write-Host ""
}
foreach ($entry in $dataReplaceFiles) { Backup-Pristine $entry.dst "Data" }
foreach ($entry in $survivalReplaceFiles) { Backup-Pristine $entry.dst "Survival" }

# Files earlier versions installed and this one does not. Once a file leaves
# $copyFiles the uninstaller no longer knows about it, so upgrading would leave
# it behind for ever. Anything retired belongs on this list.
$legacyFiles = @(
    "Gui\JsonGuis\ModButton.gui",                      # HUD MODS button, removed:
    "Scripts\game\ModFramework\ModHudButton.lua"       # see the note in the SurvivalPlayer patch
)
foreach ($relative in $legacyFiles) {
    foreach ($root in @($survival, $dataDir)) {
        $full = Join-Path $root $relative
        if (Test-Path $full) {
            Remove-Item $full -Force
            Write-Host "  removed    $(Split-Path $root -Leaf)\$relative  (no longer used)"
        }
    }
}

# Mods that have been REMOVED since the last run.
#
# A mod's scripts live in a folder of their own, Scripts\game\Mods\<ModName>\,
# and $copyFiles only ever describes what is being installed NOW. Take a mod out
# of src\Mods and nothing above would mention it again - so its folder would sit
# in the game forever, orphaned.
#
# Nothing LOADS it: every file that could reference the mod is rebuilt from the
# pristine copy on each run, so its registration has already gone. But leaving it
# there makes "is this mod installed?" a question with two different answers,
# which is exactly the confusion the Mod Installer window is meant to end.
#
# Swept by folder NAME against the lists built during discovery, so it covers a
# mod that was deleted, renamed, or that stopped declaring a mode it used to
# want. Scripts\game\Mods does not exist in a vanilla install - it is created
# here - so everything in it is ours to remove. Verified against the pristine
# backup before this was written.
#
# NOT swept: a removed mod's non-Lua assets - meshes, textures - because they go
# to scattered game paths listed in that mod's own assets.json, which is gone by
# the time we notice the mod is. They are inert once shapesets.json is rebuilt
# from pristine, so this costs disk space and nothing else.
if (-not $Uninstall) {
    $modFolderSweeps = @(
        @{ root = $survival; keep = $pluginNames;     label = "Survival"; files = $copyFiles },
        @{ root = $dataDir;  keep = $dataPluginNames; label = "Data";     files = $dataCopyFiles }
    )
    foreach ($sweep in $modFolderSweeps) {
        if ([string]::IsNullOrWhiteSpace($sweep.root)) { continue }
        $modsRoot = Join-Path $sweep.root "Scripts\game\Mods"
        if (-not (Test-Path $modsRoot)) { continue }

        # Everything this install is about to write into Scripts\game\Mods, so
        # anything already there and NOT in the list is left over from before.
        $expected = @{}
        foreach ($entry in $sweep.files) {
            if ($entry.dst -like "Scripts\game\Mods\*") { $expected[$entry.dst.ToLower()] = $true }
        }

        foreach ($modFolder in Get-ChildItem $modsRoot -Directory -ErrorAction SilentlyContinue) {

            # A mod that has been removed entirely - folder and all.
            if ($sweep.keep -notcontains $modFolder.Name) {
                Remove-Item $modFolder.FullName -Recurse -Force
                Write-Host "  removed    $($sweep.label)\Scripts\game\Mods\$($modFolder.Name)  (mod no longer installed)"
                continue
            }

            # A mod that is STILL installed but has been UPDATED, where the new
            # version dropped a file the old one shipped.
            #
            # Copying only ever adds and overwrites, so a renamed or deleted script
            # stayed in the game forever. Installing v2 of a mod over v1 left v1's
            # files sitting alongside v2's, which is exactly the situation somebody
            # updating a mod is in, and it is silent.
            foreach ($f in Get-ChildItem $modFolder.FullName -File -Recurse -ErrorAction SilentlyContinue) {
                $relative = $f.FullName.Substring($sweep.root.Length).TrimStart('\')
                if ($expected.ContainsKey($relative.ToLower())) { continue }
                Remove-Item $f.FullName -Force
                Write-Host "  removed    $($sweep.label)\$relative  (left over from an older version)"
            }
        }
    }
}

Write-Host ""
Write-Host "Step 2/3  Copying the mod's own files in"
foreach ($entry in $copyFiles) {
    $from = Join-Path $srcDir $entry.src
    $to   = Join-Path $survival $entry.dst
    if (-not (Test-Path $from)) { throw "Missing source file: $from" }
    $dir = Split-Path -Parent $to
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item $from $to -Force
    Write-Host "  copied     $($entry.dst)"
}

# Files for the Data root: Creative and Custom Games. Text files are rewritten
# on the way in, because Creative resolves $GAME_DATA where Survival resolves
# $SURVIVAL_DATA.
foreach ($entry in $dataCopyFiles) {
    $from = Join-Path $srcDir $entry.src
    $to   = Join-Path $dataDir $entry.dst
    if (-not (Test-Path $from)) { throw "Missing source file: $from" }
    $dir = Split-Path -Parent $to
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    if ($entry.rewrite) {
        Write-TextFile $to (Convert-ToDataPaths (Read-TextFile $from))
    } else {
        Copy-Item $from $to -Force
    }
    Write-Host "  copied     Data\$($entry.dst)"
}

# The registry: Lua cannot enumerate directories, so the list of installed
# plugins is generated here from whatever folders exist in src\Mods\. That is
# what lets the mod manager pick up a new mod without any code changes.
#
# One registry per game mode. Each states its own mode, which is how the manager
# knows where it is running without any sm.game.getMode() to ask.
function Write-ModRegistry([string]$path, [string]$mode, [string]$prefix, $plugins) {
    $registry = New-Object System.Text.StringBuilder
    [void]$registry.AppendLine("-- ModRegistry.lua")
    [void]$registry.AppendLine("--")
    [void]$registry.AppendLine("-- GENERATED by tools\Install-Mod.ps1 - do not edit by hand.")
    [void]$registry.AppendLine("-- Lists every installed plugin that applies to the '$mode' game mode.")
    [void]$registry.AppendLine("-- Add a folder to src\Mods\ containing a mod.lua and re-run the")
    [void]$registry.AppendLine("-- installer; it will appear here and in the menu.")
    [void]$registry.AppendLine("--")
    [void]$registry.AppendLine("-- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    [void]$registry.AppendLine("")
    [void]$registry.AppendLine("dofile( `"$prefix/Scripts/game/ModFramework/ModManager.lua`" )")
    [void]$registry.AppendLine("ModManager.SetMode( `"$mode`" )")
    [void]$registry.AppendLine("")
    foreach ($name in $plugins) {
        [void]$registry.AppendLine("dofile( `"$prefix/Scripts/game/Mods/$name/mod.lua`" )")
    }
    Write-TextFile $path $registry.ToString()
}

# -- Purge the ENGINE'S compiled cache for every asset we copy ------------------
# The engine caches compiled meshes/textures (Cache\*_<hash>.mco/.tco/.dco) and
# does not reliably re-validate a changed source: a 20 Aug session served a
# STALE ani_mapper_position while rebuilding the idle clips beside it, and the
# tool posed from yesterday's numbers. Deleting the cache entries whose stem
# matches a copied asset's basename forces a clean rebuild - the engine
# recreates them on next launch, cost is a one-time hitch per changed file.
$gameRoot = Split-Path $survival -Parent
$cacheDir = Join-Path $gameRoot "Cache"
if (Test-Path $cacheDir) {
    $stems = @{}
    foreach ($entry in $copyFiles) {
        if ($entry.dst -match '\.(dae|tga|rend)$') {
            $stems[[System.IO.Path]::GetFileNameWithoutExtension($entry.dst)] = $true
        }
    }
    $purged = 0
    if ($stems.Count -gt 0) {
        foreach ($cf in Get-ChildItem $cacheDir -Recurse -File -ErrorAction SilentlyContinue) {
            if ($cf.Name -match '^(.+)_[0-9A-Fa-f]{16}\.(mco|tco|dco)$' -and $stems.ContainsKey($Matches[1])) {
                try { Remove-Item -LiteralPath $cf.FullName -Force -Confirm:$false -ErrorAction Stop; $purged++ } catch {}
            }
        }
    }
    if ($purged -gt 0) {
        Write-Host "  purged     $purged stale engine cache entr$(if ($purged -eq 1) { 'y' } else { 'ies' }) for copied assets"
    }
}

Write-ModRegistry (Join-Path $survival "Scripts\game\ModFramework\ModRegistry.lua") `
    "survival" "`$SURVIVAL_DATA" $pluginNames
Write-Host "  generated  Scripts\game\ModFramework\ModRegistry.lua  ($($pluginNames.Count) plugin(s): $($pluginNames -join ', '))"

Write-ModRegistry (Join-Path $dataDir "Scripts\game\ModFramework\ModRegistry.lua") `
    "creative" "`$GAME_DATA" $dataPluginNames
Write-Host "  generated  Data\Scripts\game\ModFramework\ModRegistry.lua  ($($dataPluginNames.Count) plugin(s): $($dataPluginNames -join ', '))"

# The survival item icon atlas, carrying our custom icons.
#
# This is BUILT HERE rather than shipped. IconMapSurvival.png is a 12 MB piece of
# Axolot Games' own artwork, and a patched copy of it is a derivative of their
# art -- not something to put in a public download. Make-Icon.ps1 instead reads
# the player's own atlas and paints our 96x96 icons into free frames, so nothing
# of theirs ever leaves their machine.
# Workshop pack icons are NOT drawn here any more. The engine loads each pack from
# its own folder when a world asks for it, and brings the pack's own icon atlas with
# it - so compositing them into IconMapSurvival was duplicating work the game already
# does, and burning finite atlas frames to do it. Only our own mods' icons are drawn.
& (Join-Path $scriptDir "Make-Icon.ps1") -GamePath $GamePath
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "Make-Icon.ps1 failed" }

# A MISSING ATLAS IS NORMAL WITH NO MODS INSTALLED.
#
# Make-Icon only writes one when something declares an icon to draw. Installing the
# Mod Manager on its own - which is exactly what the Windows installer does, since
# mods are separate downloads - leaves nothing to draw and no atlas to copy.
#
# This used to throw, which aborted the install AFTER the framework had been copied
# but BEFORE any game file was patched: every file present, and `/mods` doing
# nothing, with no error the player ever saw. Found by testing the installer on a
# clean game rather than on the author's, where a mod is always present.
$skippedAtlas = 0

foreach ($entry in $survivalReplaceFiles) {
    $from = Join-Path $srcDir $entry.src
    $to   = Join-Path $survival $entry.dst
    if (-not (Test-Path $from)) { $skippedAtlas++; continue }
    Copy-Item $from $to -Force
    Write-Host "  copied     $($entry.dst)  (custom icons)"
}

foreach ($entry in $dataReplaceFiles) {
    $from = Join-Path $srcDir $entry.src
    $to   = Join-Path $dataDir $entry.dst
    if (-not (Test-Path $from)) { $skippedAtlas++; continue }
    Copy-Item $from $to -Force
    Write-Host "  copied     Data\$($entry.dst)  (custom icons)"
}

if ($skippedAtlas -gt 0) {
    Write-Host "  icons      none to draw - no installed mod declares one"
}

Write-Host ""
Write-Host "Step 3/3  Patching the game's own files"

# Always patch from the pristine copy, so re-running is safe and never stacks
# two copies of the same edit.

# -- 3a. Register the tool -----------------------------------------------------
$rel  = "Tools\ToolSets\tools.json"
$text = Read-TextFile (Get-PristineBackupPath $rel)

# Each plugin supplies its own toolset entry as tool.json, so adding a mod with a
# tool needs no changes here.
#
# Field notes, read out of the game executable's toolset schema:
#   previewRenderable / previewRotation / previewColor / previewPose /
#   previewHidden / previewDither / previewShake / previewUvFrame
# There is no separate "icon" field for the detail panel - that IS this preview
# render. The inventory GRID icon comes from IconMapSurvival instead.
# Add no custom keys: the game's JSON schema is strict.
$toolEntries = ""
$toolCount   = 0

# Give Survival the CREATIVE lift.
#
# The two lifts are the same item with different brains. Creative's is uuid
# 5cc12f03 running class "Lift" from Data\Scripts\game\Lift.lua, which has
# selection, client_onForceTool and import. Survival's is uuid 8f190ce2 running
# "SurvivalLift" - 49 lines that only track the carrying state.
#
# The LOAD CREATION window that assembles a blueprint properly - joints, wiring,
# suspension and all - belongs to the Creative lift. It is engine-side, so Lua
# cannot open it, and no amount of createPart can reproduce what it does:
# bearings and springs are JOINTS, and createPart refuses them outright with
# "expected the uuid of a part".
#
# So rather than rebuild what the engine already does, hand Survival the tool
# that has it. Registered as an extra tool rather than replacing the Survival
# lift, so the vanilla one still works exactly as before.
$creativeLift = @"
		{
			"previewRenderable" : "`$GAME_DATA/Character/Char_Tools/char_lift_preview.rend",
			"previewRotation" :
			[
				1, 0, 0,
				0, 0, -1,
				0, 1, 0
			],
			"script" :
			{
				"class" : "Lift",
				"file" : "`$GAME_DATA/Scripts/game/Lift.lua"
			},
			"uuid" : "5cc12f03-275e-4c8e-b013-79fc0f913e1b"
		},
"@
$toolEntries += $creativeLift + "`r`n"
$toolCount++
Write-Host "  tool       Creative Lift (for loading creations in Survival)"

foreach ($name in $pluginNames) {
    $toolJson = Join-Path $srcDir "Mods\$name\tool.json"
    # A mod with no tool.json is perfectly normal - a mod does not have to give
    # the player an item. Count only the ones that actually registered something,
    # or the summary claims a tool for every installed mod.
    if (-not (Test-Path $toolJson)) { continue }
    $body = (Read-TextFile $toolJson).Trim()
    # indent to match the surrounding file, and add the trailing comma
    $indented = ($body -split "`r?`n" | ForEach-Object { "`t`t$_" }) -join "`r`n"
    $toolEntries += "$indented,`r`n"
    $toolCount++
    Write-Host "  tool       $name"
}

if ($toolEntries -ne "") {
    if ($text -notmatch '"toolList"\s*:\s*\r?\n?\s*\[') {
        throw "Could not find toolList in $rel - the game format may have changed."
    }
    $text = Replace-First $text '("toolList"\s*:\s*\r?\n?\s*\[)' "`$1`r`n$toolEntries"
    Write-TextFile (Join-Path $survival $rel) $text
    Write-Host "  patched    $rel  (registered $toolCount tool(s))"
}

# -- 3b. Give the tool a name in the inventory ---------------------------------
$rel  = "Gui\Language\English\inventoryDescriptions.json"
$text = Read-TextFile (Get-PristineBackupPath $rel)

# Item names and descriptions also come from each plugin, as item.json.
$descEntries = ""
foreach ($name in $pluginNames) {
    $itemJson = Join-Path $srcDir "Mods\$name\item.json"
    if (-not (Test-Path $itemJson)) { continue }
    $item = (Read-TextFile $itemJson) | ConvertFrom-Json
    $descEntries += @"
	"$($item.uuid)": {
		"description": "$($item.description)",
		"title": "$($item.title)",
		"upperCaseTitle": "$($item.upperCaseTitle)"
	},

"@
}

# Workshop part pack names.
#
# Survival reads item names from THIS file, not from the shapeset, so a pack's
# parts are nameless here - and a nameless item does not appear in the Craftbot at
# all. Recipes installed and unlocked but nothing visible in the list was exactly
# that: our own Chest Sorter shows up because it ships a title, and the pack parts
# did not have one.
if ($descEntries -ne "") {
    # This file opens with a "// this file is generated by..." comment, so the
    # real opening brace is not at position 0. Match the first brace on its own line.
    if ($text -notmatch '(?m)^\{') { throw "Could not find the opening brace in $rel" }
    $text = Replace-First $text '(?m)^\{' "{`r`n$descEntries"
    Write-TextFile (Join-Path $survival $rel) $text
    Write-Host "  patched    $rel  (item names)"
}

# -- 3b1z. Clear out the OLD Workshop-pack registration --------------------------
#
# Earlier versions of this installer forced Workshop packs into Survival globally:
# rewritten `wsmod_*.shapeset` copies, directory junctions under
# Survival\WorkshopMods, and entries in shapesets.json. None of that is needed - the
# engine loads each pack itself, per world, from the world's own save.
#
# Anyone upgrading has those files sitting in their game, and leaving them would keep
# every pack loaded in every world, which is exactly the behaviour being replaced. So
# they are removed on every install.
#
# The junction is deleted with Delete(), NEVER Remove-Item -Recurse: a recursive
# delete can follow the link and destroy the author's actual Workshop download.
if (-not $Uninstall) {
    $legacy = @(Get-ChildItem (Join-Path $survival "Objects\Database\ShapeSets\wsmod_*.shapeset") -ErrorAction SilentlyContinue)
    foreach ($f in $legacy) {
        Remove-Item $f.FullName -Force
        Write-Host "  removed    Objects\Database\ShapeSets\$($f.Name)  (superseded)"
    }

    $legacyMounts = Join-Path $survival "WorkshopMods"
    if (Test-Path $legacyMounts) {
        foreach ($link in @(Get-ChildItem $legacyMounts -Force -ErrorAction SilentlyContinue)) {
            try {
                (Get-Item $link.FullName -Force).Delete()
                Write-Host "  unmounted  Survival\WorkshopMods\$($link.Name)  (superseded)"
            } catch {
                Write-Warning "  could not remove the mount $($link.FullName) - delete it by hand"
            }
        }
        if (@(Get-ChildItem $legacyMounts -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $legacyMounts -Force -ErrorAction SilentlyContinue
        }
    }

    # Rotation sets were merged into Survival's own file so pack parts could be
    # oriented correctly. The engine supplies each pack's rotation sets itself now,
    # so ours are restored to stock - otherwise an upgrading player keeps definitions
    # for parts that are no longer registered this way.
    #
    # It stays in $patchTargets so the pristine copy is still taken and uninstall
    # still restores it; this just puts it back on the way IN as well.
    $rotRel = "Objects\Database\rotationsets.json"
    $rotPristine = Get-PristineBackupPath $rotRel
    if (Test-Path $rotPristine) {
        $rotLive = Join-Path $survival $rotRel
        if ((Test-Path $rotLive) -and
            ((Read-TextFile $rotLive) -ne (Read-TextFile $rotPristine))) {
            Copy-Item $rotPristine $rotLive -Force
            Write-Host "  restored   $rotRel  (pack rotation sets no longer needed)"
        }
    }

    # The old state files went with the global on/off switch, which no longer exists.
    foreach ($stale in @("PartPacksEnabled.json", "PartPackState.lua")) {
        $sp = Join-Path $survival "Scripts\game\ModFramework\$stale"
        if (Test-Path $sp) {
            Remove-Item $sp -Force
            Write-Host "  removed    Scripts\game\ModFramework\$stale  (superseded)"
        }
    }
}

# -- 3b2. Register any part shapesets a mod ships -------------------------------
#
# This is what lets a mod add a PLACEABLE PART rather than just a tool.
#
# shapesets.json is a plain list of paths, so a mod ships its own .shapeset file
# and the only registration needed is adding that path to the list. Nothing in any
# of the game's own shapesets is touched, which keeps the addition separable and
# makes uninstall a matter of restoring one file.
$rel = "Objects\Database\shapesets.json"
$shapesetDsts = @($copyFiles |
    Where-Object { $_.dst -like "Objects\Database\ShapeSets\*.shapeset" } |
    ForEach-Object { $_.dst })

if (-not $Uninstall -and $shapesetDsts.Count -gt 0) {
    $text = Read-TextFile (Get-PristineBackupPath $rel)

    $setEntries = ""
    foreach ($d in $shapesetDsts) {
        # Single-quoted, or PowerShell would expand $SURVIVAL_DATA as a variable.
        $asPath = '$SURVIVAL_DATA/' + ($d -replace '\\', '/')
        $setEntries += "`t`t`"$asPath`",`r`n"
        Write-Host "  shapeset   $d"
    }

    if ($text -notmatch '"shapeSetList"\s*:\s*\r?\n?\s*\[') {
        throw "Could not find shapeSetList in $rel - the game format may have changed."
    }
    $text = Replace-First $text '("shapeSetList"\s*:\s*\r?\n?\s*\[)' "`$1`r`n$setEntries"
    Write-TextFile (Join-Path $survival $rel) $text
    Write-Host "  patched    $rel  (registered $($shapesetDsts.Count) part shapeset(s))"
}




# -- 3b3. Register any Craftbot recipes a mod ships ------------------------------
#
# This is what makes a part CRAFTABLE in Survival rather than handed out. Each
# recipe list is a plain JSON array, so a mod's recipe is appended and no vanilla
# recipe is edited - same shape of change as the shapeset registration above, and
# uninstall stays a single file restore.
#
# Clear out every part pack recipe set before writing any.
#
# These are files we ADD rather than vanilla files we patch, so restoring the
# pristine backups does not remove them - nothing else would ever delete one. They
# are rewritten from scratch each install, so sweeping first also handles a pack the
# author has since unsubscribed from: its set file goes, and with it the recipes for
# parts that no longer exist.
#
# Runs on uninstall too, which is the only thing that removes them for good.
$staleSets = @(Get-ChildItem (Join-Path $survival "CraftingRecipes\craftbot\craftbot_mmpack_*.json") -ErrorAction SilentlyContinue)
foreach ($f in $staleSets) {
    Remove-Item $f.FullName -Force
}
if ($staleSets.Count -gt 0) {
    Write-Host "  removed    $($staleSets.Count) old part pack recipe set(s)"
}

# Survival only. There is no Data\CraftingRecipes: Creative has nothing to craft
# with and simply gives the part out, which is the behaviour we want anyway.
if (-not $Uninstall) {
    $recipesByFile = @{}
    $unlockUuids = @()

    foreach ($name in $pluginNames) {
        $recipePath = Join-Path $srcDir "Mods\$name\recipe.json"
        if (-not (Test-Path $recipePath)) { continue }

        # Comments stripped first, same as assets.json: the game's own json uses
        # // freely so ours match that style, and ConvertFrom-Json rejects it.
        $raw  = [regex]::Replace((Read-TextFile $recipePath), '(?m)^\s*//.*$', '')
        $spec = $raw | ConvertFrom-Json
        $file = if ([string]::IsNullOrWhiteSpace($spec.file)) { "craftbot_core.json" } else { $spec.file }
        if (-not $recipesByFile.ContainsKey($file)) { $recipesByFile[$file] = @() }
        foreach ($recipe in @($spec.recipes)) {
            $recipesByFile[$file] += @{ mod = $name; recipe = $recipe }
            if ($spec.unlockedByDefault) { $unlockUuids += $recipe.itemId }
        }
    }

    # Workshop part packs, whose recipes Generate-PartPackList.ps1 DERIVED from
    # each part's own material and size.
    #
    # Joining the same queue as our own mods on purpose: registration, unlocking and
    # uninstall are already solved above, and a part pack's recipe file is written in
    # exactly that shape so none of it needs duplicating.
    #
    # Derived rather than authored because it has to scale. There are thousands of
    # Workshop packs and nobody can cost up every part of every one by hand - which
    # was the objection that produced this design.
    # EVERY pack's recipes are installed, with nothing gated.
    #
    # EACH PACK GETS ITS OWN RECIPE SET, and that is the whole point.
    #
    # These used to be merged into the vanilla craftbot_core.json, which made a pack
    # impossible to separate again. A Craftbot builds its grid in Lua, per set, every
    # time it is opened - Crafter.cl_updateRecipeGrid loops `self.crafter.recipeSets`
    # and adds each set's file. So a pack that owns a SET can be switched off simply
    # by skipping that set, per world, live, with no file rewriting and nothing for
    # the engine's by-path cache to get wrong.
    #
    # That is what makes an in-game on/off switch possible at all. Whether a pack's
    # parts EXIST is still a property of the world's save and cannot be changed from
    # in game; whether they can be OBTAINED is decided here, and that is ours.
    $packSets = @()
    foreach ($dir in Get-ChildItem (Join-Path $srcDir "Framework\PartPacks") -Directory -ErrorAction SilentlyContinue) {
        $recipePath = Join-Path $dir.FullName "recipe.json"
        if (-not (Test-Path $recipePath)) { continue }

        try {
            $spec = [regex]::Replace((Read-TextFile $recipePath), '(?m)^\s*//.*$', '') | ConvertFrom-Json
        } catch {
            Write-Host "  part pack $($dir.Name): recipe.json will not parse - parts stay uncraftable" -ForegroundColor DarkYellow
            continue
        }

        $recipes = @($spec.recipes) | Where-Object { $_ -ne $null }
        if ($recipes.Count -eq 0) { continue }

        # The set name carries the pack id, so Crafter.lua can recover it with a
        # single string.match and needs no lookup table shipped alongside.
        $packSets += @{
            id      = $dir.Name
            setName = "craftbot_mmpack_$($dir.Name)"
            recipes = $recipes
        }

        foreach ($recipe in $recipes) {
            if ($spec.unlockedByDefault) { $unlockUuids += $recipe.itemId }
        }
        Write-Host "  recipes    $($recipes.Count) derived for part pack $($dir.Name)"
    }

    # -- unlock them ----------------------------------------------------------
    #
    # Without this the recipe is loaded and never shown. RecipeManager's
    # cl_isUnlocked returns true only for recipes switched off globally, items in
    # DefaultUnlockedItems, or uuids the SAVE has unlocked - and a modded recipe
    # is none of those. Inserting at the head of the table rather than the tail
    # so the patch does not depend on what the last vanilla entry happens to be.
    if ($unlockUuids.Count -gt 0) {
        $rel  = "Scripts\game\managers\RecipeManager.lua"
        $text = Read-TextFile (Get-PristineBackupPath $rel)

        $unlockEntries = "$MARK_BEGIN`r`n"
        foreach ($uuid in $unlockUuids) {
            $unlockEntries += "`tsm.uuid.new( `"$uuid`" ),`r`n"
        }
        $unlockEntries += "$MARK_END`r`n"

        if ($text -notmatch 'local DefaultUnlockedItems\s*=\s*\{') {
            throw "Could not find DefaultUnlockedItems in $rel - the game format may have changed."
        }
        $text = Replace-First $text '(local DefaultUnlockedItems\s*=\s*\{)' "`$1`r`n$unlockEntries"
        Write-TextFile (Join-Path $survival $rel) $text
        Write-Host "  patched    $rel  (unlocked $($unlockUuids.Count) recipe(s))"
    }

    foreach ($file in $recipesByFile.Keys) {
        $rel  = "CraftingRecipes\craftbot\$file"
        $text = Read-TextFile (Get-PristineBackupPath $rel)

        $entries = ""
        foreach ($item in $recipesByFile[$file]) {
            # Re-serialised rather than pasted through, so a malformed recipe.json
            # fails here with a JSON error instead of quietly corrupting a recipe
            # list the Craftbot then refuses to load.
            $json = $item.recipe | ConvertTo-Json -Depth 6 -Compress
            $entries += "`t$json,`r`n"
            # Part packs are counted once above instead. A pack can contribute
            # hundreds of recipes and listing each would bury the rest of the
            # install output.
            if (-not $item.quiet) { Write-Host "  recipe     $($item.mod) -> $file" }
        }

        # The file opens with a "// this file is generated" comment, so the real
        # opening bracket is not at position 0. Match the first one on its own line.
        if ($text -notmatch '(?m)^\[') {
            throw "Could not find the opening bracket in $rel - the game format may have changed."
        }
        $text = Replace-First $text '(?m)^\[' "[`r`n$entries"
        Write-TextFile (Join-Path $survival $rel) $text
        Write-Host "  patched    $rel  (registered $($recipesByFile[$file].Count) recipe(s))"
    }

    # -- part pack recipe sets -------------------------------------------------
    #
    # Three pieces, in order:
    #   1. one recipe file per pack        - a plain JSON array, written whole
    #   2. craftbot.json                   - the INDEX, set name -> file path
    #   3. Crafter.lua CraftbotRecipeSets  - the list a Craftbot actually walks
    #
    # A set registered in the index but missing from CraftbotRecipeSets is loaded and
    # never shown, so all three are needed.
    if ($packSets.Count -gt 0) {

        # 1. the files. Written whole rather than spliced into a vanilla file, which
        #    is why these need no pristine backup: uninstall just deletes them.
        foreach ($pack in $packSets) {
            $lines = @()
            foreach ($recipe in $pack.recipes) {
                $lines += "`t" + ($recipe | ConvertTo-Json -Depth 6 -Compress)
            }
            $body = "// written by Install-Mod.ps1 - one recipe set per Workshop parts pack`r`n[`r`n"
            $body += ($lines -join ",`r`n")
            $body += "`r`n]`r`n"

            $setRel = "CraftingRecipes\craftbot\$($pack.setName).json"
            Write-TextFile (Join-Path $survival $setRel) $body
        }
        Write-Host "  wrote      $($packSets.Count) part pack recipe set(s)"

        # 2. the index. Keys are quoted strings, so a pack id with hyphens is fine.
        $rel  = "CraftingRecipes\craftbot\craftbot.json"
        $text = Read-TextFile (Get-PristineBackupPath $rel)

        $indexEntries = ""
        foreach ($pack in $packSets) {
            $indexEntries += "`t`"$($pack.setName)`": `"`$SURVIVAL_DATA/CraftingRecipes/craftbot/$($pack.setName).json`",`r`n"
        }

        if ($text -notmatch '(?m)^\{') {
            throw "Could not find the opening brace in $rel - the game format may have changed."
        }
        $text = Replace-First $text '(?m)^\{' "{`r`n$indexEntries"
        Write-TextFile (Join-Path $survival $rel) $text
        Write-Host "  patched    $rel  (indexed $($packSets.Count) set(s))"

        # 3. Crafter.lua - register the sets, and teach both loops to skip a set whose
        #    pack is switched off in THIS WORLD.
        #
        #    Two loops matter and both must be filtered:
        #      cl_updateRecipeGrid  - what the player SEES
        #      the loop near it     - what the player may actually CRAFT
        #    Filtering only the first would hide a part while leaving it craftable by
        #    index, which is worse than not filtering at all.
        $rel  = "Scripts\game\interactables\Crafter.lua"
        $text = Read-TextFile (Get-PristineBackupPath $rel)

        $setEntries = "$MARK_BEGIN`r`n"
        foreach ($pack in $packSets) {
            $setEntries += "`t{ name = `"$($pack.setName)`" },`r`n"
        }
        $setEntries += "$MARK_END`r`n"

        # APPENDED, not inserted at the head.
        #
        # A Craftbot fills its grid in set order, so sets added at the front push every
        # vanilla part down the list - the player opens a Craftbot and finds modded
        # parts where the wood blocks used to be. Modded content goes after the
        # vanilla content, which is where a player expects to find it.
        #
        # Lua allows a trailing comma in a table constructor, so the last vanilla entry
        # simply gains one rather than the entries needing to know which is last.
        if ($text -notmatch 'local CraftbotRecipeSets\s*=\s*\{') {
            throw "Could not find CraftbotRecipeSets in $rel - the game format may have changed."
        }
        if ($text -notmatch '(?s)(local CraftbotRecipeSets\s*=\s*\{.*?)\r?\n\}') {
            throw "Could not find the end of CraftbotRecipeSets in $rel - the game format may have changed."
        }
        $text = Replace-First $text '(?s)(local CraftbotRecipeSets\s*=\s*\{.*?)\r?\n\}' "`$1,`r`n$setEntries}"

        # PartPacks is loaded here explicitly. Crafter.lua is its own script with its
        # own environment, and this filter runs CLIENT side, so it cannot rely on the
        # copy ModManager.lua loads on the server. pcall'd because a machine with no
        # subscriptions has no PartPacks.lua at all.
        $crafterHelper = @"
$MARK_BEGIN
pcall( dofile, "`$SURVIVAL_DATA/Scripts/game/ModFramework/PartPacks.lua" )

--- Is this recipe set allowed in the world the player is standing in?
--
-- Vanilla sets always are. A pack's set is named craftbot_mmpack_<packId>, so the
-- pack id comes straight back out of the name and no lookup table is needed.
--
-- Fails OPEN on purpose: if anything is missing or errors, the set is shown. A bug
-- here would otherwise make parts silently uncraftable, which reads to a player as
-- lost progress rather than as a mod fault.
function ModManagerRecipeSetEnabled( setName )
	local packId = string.match( tostring( setName ), "^craftbot_mmpack_(.+)`$" )
	if packId == nil then return true end

	local ok, enabled = pcall( function()
		return PartPacks.Cl_IsEnabled( packId )
	end )
	if not ok or enabled == nil then return true end
	return enabled ~= false
end

--- The crafter's recipe sets, minus any switched off in this world.
--
-- Filtering the LIST rather than guarding inside each loop is deliberate. The two
-- loops that walk these sets have different bodies - one fills the grid, the other
-- resolves a recipe by index - and wrapping either body in an `if` means finding
-- the matching `end` in someone else's code. Swapping what is iterated needs no
-- `end` at all, applies to both loops identically, and cannot unbalance the file.
--
-- The two must agree: filtering only what is DISPLAYED would leave a hidden part
-- still craftable by index, which is worse than not filtering at all.
function ModManagerEnabledSets( sets )
	if sets == nil then return {} end

	local out = {}
	for _, recipeSet in ipairs( sets ) do
		if ModManagerRecipeSetEnabled( recipeSet.name ) then
			out[#out + 1] = recipeSet
		end
	end
	return out
end

--- A value that changes whenever a pack is switched on or off.
--
-- A Craftbot only rebuilds its grid when RecipeManager's unlocked-recipes revision
-- changes. Switching a pack does not change that, so without this the parts stop
-- being craftable but carry on being DISPLAYED - which is exactly how the first
-- version of this behaved when tested.
function ModManagerPackRevision()
	local ok, rev = pcall( function()
		return PartPacks.Cl_Revision()
	end )
	if not ok or rev == nil then return "" end
	return rev
end
$MARK_END
"@

        if ($text -notmatch '(?m)^local CraftbotRecipeSets') {
            throw "Could not find the head of Crafter.lua to insert the pack filter."
        }
        $text = Replace-First $text '(?m)^local CraftbotRecipeSets' "$crafterHelper`r`nlocal CraftbotRecipeSets"

        # One token swapped, in both loops. No loop body is touched, so nothing here
        # depends on what those bodies happen to contain.
        $loopOld = 'ipairs( self.crafter.recipeSets )'
        $loopNew = 'ipairs( ModManagerEnabledSets( self.crafter.recipeSets ) )'

        $loopCount = ([regex]::Matches($text, [regex]::Escape($loopOld))).Count
        if ($loopCount -lt 2) {
            throw "Expected at least 2 recipe-set loops in $rel, found $loopCount - the game format may have changed."
        }
        $text = $text.Replace($loopOld, $loopNew)

        # Make the Craftbot NOTICE a toggle.
        #
        # Found by testing: filtering the set list alone stopped parts being crafted
        # but left them on screen. A Craftbot rebuilds its grid only when
        # RecipeManager's unlocked-recipes revision changes, and a pack toggle does
        # not change that, so the grid it was already showing simply stayed.
        #
        # Two edits: remember our revision when the grid is built, and treat a change
        # in it as another reason to rebuild.
        $revStore    = 'self.cl.unlockedRecipesRevision = RecipeManager.Cl_GetUnlockedRevision()'
        $revStoreNew = $revStore + "`r`n`tself.cl.mmPackRevision = ModManagerPackRevision()"
        if ($text -notmatch [regex]::Escape($revStore)) {
            throw "Could not find the recipe revision assignment in $rel - the game format may have changed."
        }
        $text = $text.Replace($revStore, $revStoreNew)

        $revTest    = 'self.cl.unlockedRecipesRevision ~= RecipeManager.Cl_GetUnlockedRevision()'
        $revTestNew = '( ' + $revTest + ' or self.cl.mmPackRevision ~= ModManagerPackRevision() )'
        if ($text -notmatch [regex]::Escape($revTest)) {
            throw "Could not find the recipe revision check in $rel - the game format may have changed."
        }
        $text = $text.Replace($revTest, $revTestNew)

        Write-TextFile (Join-Path $survival $rel) $text
        Write-Host "  patched    $rel  (registered $($packSets.Count) set(s))"
    }
}

# -- 3c. Terrain filter --------------------------------------------------------
$rel  = "Scripts\terrain\terrain_overworld.lua"
$text = Read-TextFile (Get-PristineBackupPath $rel)

# ONLY WHEN THE FOLIAGE ERASER IS ACTUALLY INSTALLED.
#
# This used to be unconditional, and that shipped a world-breaking bug. The
# Mod Manager download carries an EMPTY src\Mods folder (mods are separate
# downloads), so installing it on its own still patched this file to dofile a
# FoliageEraserTerrain.lua that was not there. The hook sits inside
# GetAssetsForCell, which returns a cell's terrain assets AND its prefab
# assets - THE STRUCTURES - so the nil error took every structure in the world
# down with it. Reported 30 Aug 2026 by a player running the Mod Manager on its
# own: Steam's verify put the structures back and broke the Mod Manager, and
# reinstalling took the structures away again. That loop is the signature.
#
# The else branch still WRITES: $text is the pristine copy, so removing the mod
# and re-running restores the vanilla file rather than leaving an old patch in
# place. Same reason every other step patches from pristine.
if ($pluginNames -notcontains "FoliageEraser") {
    Write-TextFile (Join-Path $survival $rel) $text
    Write-Host "  left alone $rel  (no Foliage Eraser installed)"
} else {

$terrainDofile = @"
$MARK_BEGIN
-- pcall, NOT a bare dofile. If this file is ever missing or broken, a bare
-- dofile takes the whole terrain script down with it - and GetAssetsForCell
-- below is what returns a cell's STRUCTURES. A user with only the Mod Manager
-- installed lost every structure in their world exactly that way (30 Aug 2026).
pcall( dofile, "`$SURVIVAL_DATA/Scripts/game/Mods/FoliageEraser/FoliageEraserTerrain.lua" )
$MARK_END
"@

# Put our dofile after the file's existing dofile block.
# Note: this file uses the bare `dofile "path"` form, without parentheses.
if ($text -match '(?m)^dofile\s+"[^"]*"\r?\n') {
    $lastDofile = ([regex]::Matches($text, '(?m)^dofile\s+"[^"]*"\r?\n') | Select-Object -Last 1)
    $insertAt = $lastDofile.Index + $lastDofile.Length
    $text = $text.Substring(0, $insertAt) + $terrainDofile + "`r`n" + $text.Substring($insertAt)
} else {
    $text = $terrainDofile + "`r`n" + $text
}

$filterBlock = @"
$MARK_BEGIN
		-- Drop any plant the player erased with the Foliage Eraser.
		-- asset.pos is cell-local X/Y plus world Z at this point, so the world
		-- position is cellX/cellY * CELL_SIZE + the local offset.
		-- NEVER let a missing Foliage Eraser reach the calls below: this runs
		-- inside GetAssetsForCell, and an error here means the function never
		-- returns its asset list - so every structure in the cell vanishes.
		if FoliageEraserTerrain ~= nil then
			local eraserSpots = FoliageEraserTerrain.GetSpots( tileStorage )
			FoliageEraserTerrain.NoteCell( cellX, cellY, eraserSpots )
			if eraserSpots then
				local eraserRemoved = false
				for i = 1, #assets, 1 do
					local eraserAsset = assets[i]
					if eraserAsset and eraserAsset.pos then
						local ex = cellX * CELL_SIZE + eraserAsset.pos.x
						local ey = cellY * CELL_SIZE + eraserAsset.pos.y
						if FoliageEraserTerrain.ShouldErase( tostring( eraserAsset.uuid ), ex, ey, eraserAsset.pos.z, eraserSpots ) then
							assets[i] = false
							eraserRemoved = true
						end
					end
				end
				if eraserRemoved then
					removeFromArray( assets, function( value ) return value == false end )
				end
			end
		end
$MARK_END

"@

# -- 3c2. Ground grass ----------------------------------------------------------
# GetClutterIdxAt returns which clutter (grass) type to draw at a point, or -1
# for none. x/y here are in half-metre units, hence the * 0.5 to get world
# coordinates. Returning -1 inside an erased spot clears the grass there.
$clutterAnchor = '(?m)^(function GetClutterIdxAt\( x, y \)\r?\n)'
if ($text -notmatch $clutterAnchor) { throw "Could not find GetClutterIdxAt in $rel" }
$clutterBlock = @"
`$1$MARK_BEGIN
	if FoliageEraserTerrain ~= nil and FoliageEraserTerrain.ClutterCleared( x * 0.5, y * 0.5 ) then
		return -1
	end
$MARK_END

"@
$text = Replace-First $text $clutterAnchor $clutterBlock

$anchor = '(?m)^\t\t-- if the cell is in the graphical padding area'
if ($text -notmatch $anchor) {
    throw "Could not find the insert point in $rel - the game format may have changed."
}
$text = Replace-First $text $anchor ($filterBlock + "`t`t-- if the cell is in the graphical padding area")
Write-TextFile (Join-Path $survival $rel) $text
Write-Host "  patched    $rel  (the actual plant removal)"

}   # end of the "is the Foliage Eraser installed" guard

# -- 3c2. tool drop proxies ----------------------------------------------------
#
# util.lua's ToolItems table decides what a dropped TOOL looks like on the
# ground: tool uuid -> proxy part uuid. Vanilla tools each have an obj_tool_*
# part; a modded tool without an entry drops an INVISIBLE pickup, which is how
# this surfaced. Each mod may declare one in assets.json as "toolProxy".
if (@($script:toolProxies).Count -gt 0) {
    $rel  = "Scripts\util.lua"
    $text = Read-TextFile (Get-PristineBackupPath $rel)
    $anchor = '["ed185725-ea12-43fc-9cd7-4295d0dbf88b"] = obj_tool_sledgehammer, --Creative sledgehammer'
    $lines = $anchor
    foreach ($p in $script:toolProxies) {
        $lines += "`n`t[`"$($p.tool)`"] = sm.uuid.new( `"$($p.part)`" ), -- $($p.name) drop proxy (mod)"
    }
    # Escaped: Replace-First is REGEX-based and this anchor is full of [ and ".
    $text = Replace-First $text ([regex]::Escape($anchor)) $lines
    if ($text -notmatch [regex]::Escape($script:toolProxies[0].part)) {
        throw "Tool proxy patch found no anchor in $rel - the game format may have changed."
    }
    Write-TextFile (Join-Path $survival $rel) $text
    Write-Host "  patched    $rel  ($(@($script:toolProxies).Count) tool drop proxy(ies))"
}

# -- 3d. /eraser chat command --------------------------------------------------
$rel  = "Scripts\game\SurvivalGame.lua"
$text = Read-TextFile (Get-PristineBackupPath $rel)

$bindBlock = @"
$MARK_BEGIN
	sm.game.bindChatCommand( "/eraser", {}, "cl_onChatCommand", "Give the Foliage Eraser tool" )
	sm.game.bindChatCommand( "/mods", {}, "cl_onChatCommand", "Open the mod manager" )
	sm.game.bindChatCommand( "/mapname", { { "string", "name", false }, { "string", "word2", true }, { "string", "word3", true }, { "string", "word4", true } }, "cl_onChatCommand", "Name the next map marker (Map Viewer)" )
$MARK_END
"@

$bindAnchor = '(?m)^\tlocal addCheats = g_survivalDev'
if ($text -notmatch $bindAnchor) { throw "Could not find bindChatCommands anchor in $rel" }
$text = Replace-First $text $bindAnchor ($bindBlock + "`r`n`tlocal addCheats = g_survivalDev")

$handleBlock = @"
$MARK_BEGIN
	if params[1] == "/eraser" then
		self.network:sendToServer( "sv_giveItem", { player = sm.localPlayer.getPlayer(), item = sm.uuid.new( "$TOOL_UUID" ), quantity = 1 } )
		return
	end
	if params[1] == "/mods" then
		local ok, err = pcall( function() ModMenuGui.Open( self ) end )
		if not ok then
			sm.log.error( "[FoliageEraser] mod menu failed: " .. tostring( err ) )
		end
		return
	end
	if params[1] == "/mapname" then
		-- Map Viewer: the GUI cannot read typed text back (no getText exists), so
		-- the name for the next marker comes in through chat instead.
		local words = {}
		for i = 2, #params do
			if params[i] ~= nil then words[#words + 1] = tostring( params[i] ) end
		end
		g_mapViewerPendingName = table.concat( words, " " )
		sm.gui.displayAlertText( "Next map marker: " .. g_mapViewerPendingName, 4 )
		return
	end
$MARK_END
"@

$handleAnchor = '(?m)^function SurvivalGame\.cl_onChatCommand\( self, params \)\r?\n'
if ($text -notmatch $handleAnchor) { throw "Could not find cl_onChatCommand in $rel" }
$text = Replace-First $text $handleAnchor ("function SurvivalGame.cl_onChatCommand( self, params )`r`n" + $handleBlock + "`r`n")

# The game script needs the framework loaded, and it owns the menu's callbacks:
# Scrap Mechanic dispatches GUI callbacks to whichever script created the GUI.
$gameDofile = @"
$MARK_BEGIN
dofile( "`$SURVIVAL_DATA/Scripts/game/ModFramework/ModManager.lua" )
dofile( "`$SURVIVAL_DATA/Scripts/game/ModFramework/ModMenuGui.lua" )
dofile( "`$SURVIVAL_DATA/Scripts/game/ModFramework/ModRegistry.lua" )
$MARK_END
"@

$lastGameDofile = ([regex]::Matches($text, '(?m)^dofile\([^\r\n]*\)\r?\n') | Select-Object -Last 1)
if ($lastGameDofile -eq $null) { throw "Could not find the dofile block in $rel" }
$at = $lastGameDofile.Index + $lastGameDofile.Length
$text = $text.Substring(0, $at) + $gameDofile + "`r`n" + $text.Substring($at)

$gameCallbacks = @"

$MARK_BEGIN
-- Mod manager menu, opened with /mods. Lives on SurvivalGame rather than on the
-- tool because the engine sends GUI callbacks to the script that created the GUI,
-- and this way the menu works without the tool equipped.
function SurvivalGame.cl_modMenuButton( self, buttonName )
	ModMenuGui.OnButton( self, buttonName )
end

function SurvivalGame.cl_modMenuClosed( self )
	ModMenuGui.OnClose( self )
end

-- Outcome of a blueprint placement, on its way to the player.
--
-- Placement is asynchronous: Blueprints.Sv_Place sends a world event and returns
-- immediately, so its own return value is a promise, not a result. Only the world
-- script knows whether the creation landed, came in frozen, or hit something and
-- was undone - and a world script cannot talk to a client directly.
--
-- sm.event.sendToGame is the game's own world-to-game channel (EffectManager,
-- SurvivalPlayer and quest_util all use it), and client_showMessage is vanilla,
-- calling sm.gui.chatMessage. So this is a two-line relay between two existing
-- mechanisms rather than new plumbing.
function SurvivalGame.sv_e_blueprintResult( self, params )
	if params ~= nil and params.message ~= nil then
		self.network:sendToClients( "client_showMessage", tostring( params.message ) )
	end
end

-- Record what was just placed, so the menu's UNDO button can remove it.
--
-- Blueprints.placed lives in the game script's environment, but the creation is
-- built in the world script, which cannot write to it. Same relay as the result
-- message, in the other direction.
--
-- Memory only, by design: a creation the player has since built onto, driven away
-- or filled with loot is not something to silently delete a session later.
function SurvivalGame.sv_e_blueprintPlaced( self, params )
	if params == nil or params.player == nil or params.body == nil then return end
	local ok, err = pcall( function()
		-- Pushes onto a per-player stack, so UNDO walks back through the whole
		-- session newest-first rather than only ever removing one creation.
		Blueprints.Sv_RecordPlacement( params.player, params.body )
	end )
	if not ok then
		sm.log.error( "[Blueprints] could not record the placement for undo: " .. tostring( err ) )
	end
end

function SurvivalGame.cl_modMenuRefresh( self, params )
	ModMenuGui.Refresh( self, params )
end

function SurvivalGame.sv_setModOption( self, params, player )
	-- Shared with the tool's copy, so the /mods menu and the tool's right-click
	-- menu always behave identically.
	local ok, err = pcall( function()
		ModManager.Sv_ApplyChange( params )
	end )
	if not ok then
		sm.log.error( "[FoliageEraser] ApplyModOption failed: " .. tostring( err ) )
	end

	-- Disabling a mod removes its tool, so make sure the player knows the menu
	-- is still reachable without it. Otherwise turning a mod off looks like it
	-- locks you out of turning it back on.
	local message = nil
	if params.key == "__enabled" and params.value ~= true then
		message = "Mod disabled and its tool removed.\nType /mods in chat to turn it back on."
	end
	self.network:sendToClient( player, "cl_modMenuRefresh", { message = message } )
end

-- Every mod menu action button arrives here, whichever mod owns it.
--
-- This used to be one hardcoded handler per action -- sv_restore, sv_undoLast --
-- injected by the installer, which meant only mods shipped with the installer
-- could have working buttons. A third-party mod had no way to add one without
-- editing the installer itself. Now the mod supplies a run function in its
-- action and nothing here needs to know it exists.
--
-- NOTE TO ANYONE EDITING THE HERE-STRINGS IN THIS FILE: backtick is
-- PowerShell's escape character. Writing a backtick-quoted word here put a raw
-- carriage return into SurvivalGame.lua, which split a comment in half and left
-- the tail as live code -- Survival then failed to load at all. Keep backticks
-- out of the Lua text.
function SurvivalGame.sv_modAction( self, params, player )
	local message = ModManager.Sv_RunAction( params.modId, params.actionKey, player )
	self.network:sendToClient( player, "cl_modMenuRefresh", { message = message } )
end

-- Delete beacon marker records by shape id, on request from the Height Adjuster.
--
-- The ids were read off a creation before it was rebuilt at a new height, so
-- this needs no guesswork about which shapes are still alive.
function SurvivalGame.sv_e_heightAdjusterRetireBeacons( self, params )
	if HeightAdjusterServer == nil then
		sm.log.error( "[HeightAdjuster] retire event arrived, but HeightAdjusterServer is nil here" )
		return
	end

	local ok, removed = pcall( HeightAdjusterServer.RetireBeaconIds, params.ids )
	sm.log.error( "[HeightAdjuster] retire by id: ok=" .. tostring( ok )
		.. " removed=" .. tostring( removed ) )
end

-- Sweep dead beacon markers on request.
--
-- This has to live here rather than in the mod: g_beaconManager only exists in
-- this environment, and a tool script runs in its own. The Height Adjuster fires
-- sv_e_heightAdjusterSweepBeacons after a move for exactly that reason.
--
-- All logging here uses sm.log.error even for ordinary progress. The game log
-- contains no INFO lines at all, not even from vanilla, so sm.log.info goes
-- nowhere -- an earlier attempt to trace this bug produced an empty log.
function SurvivalGame.sv_e_heightAdjusterSweepBeacons( self, params )
	if HeightAdjusterServer == nil then
		sm.log.error( "[HeightAdjuster] sweep event arrived, but HeightAdjusterServer is nil here" )
		return
	end

	local ok, err = pcall( HeightAdjusterServer.PurgeCondemned )
	if not ok then
		sm.log.error( "[HeightAdjuster] purge failed: " .. tostring( err ) )
	end

	-- Arm the per-tick purge for two seconds. The orphan record has not been
	-- created yet at this point, so the window matters more than this first call.
	if self.sv ~= nil then
		self.sv.haPurgeTicks = 80
	end
end

function SurvivalGame.sv_refreshArea( self, params, player )
	if player == nil or player.character == nil then return end
	local world = player.character:getWorld()
	local _, message = FoliageEraserServer.RefreshArea( world, player.character.worldPosition, 1 )
	self.network:sendToClient( player, "cl_modMenuRefresh", { message = message } )
end
$MARK_END
"@

$text = $text.TrimEnd() + "`r`n" + $gameCallbacks + "`r`n"

# The deferred half of the beacon sweep needs a server tick to count down on.
#
# Literal string search on purpose, no regex: this pipeline collapses doubled
# backslashes, which previously turned a regex anchor's \r\n into a literal
# carriage return and newline and made the match silently impossible.
$tickNeedle = "function SurvivalGame.server_onFixedUpdate( self, timeStep )"
$tickCount  = ([regex]::Matches($text, [regex]::Escape($tickNeedle))).Count
if ($tickCount -ne 1) { throw "Expected exactly 1 server_onFixedUpdate in $rel, found $tickCount" }

$sweepTick = @"
$tickNeedle
	$MARK_BEGIN
	-- Orphaned beacon marker purge, armed by sv_e_heightAdjusterSweepBeacons
	-- after the Height Adjuster rebuilds a creation.
	--
	-- This runs EVERY tick for the length of the window rather than once at the
	-- end of it, because the orphan record does not exist yet when the move
	-- finishes -- the engine registers it a moment later, from the beacon's own
	-- server_onCreate, for a shape that has already been destroyed. Waiting a
	-- fixed delay and looking once left the ghost on the map for the whole delay.
	-- Purging every tick removes it on the tick it appears.
	--
	-- Safe to run this often because the purge only matches ids we destroyed
	-- ourselves; it does not ask sm.exists anything, so it cannot mistake a
	-- freshly imported beacon for a dead one.
	if self.sv ~= nil and self.sv.haPurgeTicks ~= nil then
		self.sv.haPurgeTicks = self.sv.haPurgeTicks - 1

		if HeightAdjusterServer ~= nil then
			local purged = HeightAdjusterServer.PurgeCondemned()
			if purged ~= nil and purged > 0 then
				sm.log.error( "[HeightAdjuster] removed " .. tostring( purged )
					.. " orphaned beacon marker(s)" )
			end
		end

		if self.sv.haPurgeTicks <= 0 then
			self.sv.haPurgeTicks = nil
			if HeightAdjusterServer ~= nil then
				-- Last word: correct any live marker left at a stale position,
				-- then stop condemning ids so the list cannot grow without end.
				HeightAdjusterServer.ResyncBeacons()
				HeightAdjusterServer.ForgetCondemned()
			end
		end
	end
	$MARK_END
"@

$text = $text.Replace($tickNeedle, $sweepTick)

Write-TextFile (Join-Path $survival $rel) $text
Write-Host "  patched    $rel  (/eraser and /mods commands, beacon sweep tick)"

# -- 3e. Put the tool in the player's inventory automatically -------------------
# The chat command turned out not to fire, so this is the reliable route: hand
# the tool over once, the first time the player script initialises.
$rel  = "Scripts\game\SurvivalPlayer.lua"
$text = Read-TextFile (Get-PristineBackupPath $rel)

# This file needs the framework too - it must not depend on SurvivalGame having
# been loaded first.
$playerDofile = @"
$MARK_BEGIN
dofile( "`$SURVIVAL_DATA/Scripts/game/ModFramework/ModManager.lua" )
dofile( "`$SURVIVAL_DATA/Scripts/game/ModFramework/ModMenuGui.lua" )
dofile( "`$SURVIVAL_DATA/Scripts/game/ModFramework/ModRegistry.lua" )
$MARK_END
"@

$lastPlayerDofile = ([regex]::Matches($text, '(?m)^dofile\([^\r\n]*\)\r?\n') | Select-Object -Last 1)
if ($lastPlayerDofile -eq $null) { throw "Could not find the dofile block in $rel" }
$atP = $lastPlayerDofile.Index + $lastPlayerDofile.Length
$text = $text.Substring(0, $atP) + $playerDofile + "`r`n" + $text.Substring($atP)

$giveBlock = @"
$MARK_BEGIN
	-- Every player gets one Foliage Eraser. We check the inventory rather than
	-- keeping a "already given" flag: that way it is impossible to end up with
	-- duplicates, and a replacement appears if the tool is ever lost.
	-- Give or remove the Foliage Eraser to match whether the mod is enabled.
	local eraserOk, eraserErr = pcall( function()
		ModManager.Sv_SyncTools( self.player )
	end )
	if not eraserOk then
		sm.log.error( "[FoliageEraser] SyncTool failed: " .. tostring( eraserErr ) )
	end
$MARK_END
"@

# NOTE: this anchor appears TWICE in SurvivalPlayer.lua (sv_init and a respawn
# reset). Replace-First is what keeps the patch out of the second one.
$giveAnchor = '(?m)^\tself\.sv\.spawnparams = \{\}'
if ($text -notmatch $giveAnchor) { throw "Could not find sv_init anchor in $rel" }
$text = Replace-First $text $giveAnchor ("`tself.sv.spawnparams = {}`r`n" + $giveBlock)

# There is no HUD "MODS" button any more.
#
# It could never open cleanly. Scrap Mechanic shows no mouse cursor during normal
# play, so the only way to click a HUD button was with the backpack already open
# -- and there is no API to close the backpack, so the menu could not be shown
# until the player closed it themselves. sm.gui.hasActiveGui() does not appear to
# count the engine-drawn backpack either (nothing in vanilla calls it), so the
# menu got created straight away and drew underneath the backpack.
#
# /mods needs no cursor and opens instantly, so the button was strictly the worse
# route to the same window. Removed rather than papered over.

# The mod menu's GUI callbacks still live here as well as on SurvivalGame,
# because the engine dispatches them to whichever script created the GUI.
$playerCallbacks = @"

$MARK_BEGIN
function SurvivalPlayer.cl_modMenuButton( self, buttonName )
	ModMenuGui.OnButton( self, buttonName )
end

-- Map Viewer: ESC reaches the map even with no gui open. The engine calls
-- client_onCancel on ESCAPE regardless of the pause menu; the map registers
-- g_mapViewerOnEsc while it is open, and this wrapper forwards the press.
local mapViewer_baseOnCancel = SurvivalPlayer.client_onCancel
function SurvivalPlayer.client_onCancel( self )
	mapViewer_baseOnCancel( self )
	if g_mapViewerOnEsc ~= nil then
		pcall( g_mapViewerOnEsc )
	end
end

function SurvivalPlayer.cl_modMenuClosed( self )
	ModMenuGui.OnClose( self )
end

function SurvivalPlayer.cl_modMenuRefresh( self, params )
	ModMenuGui.Refresh( self, params )
end

function SurvivalPlayer.sv_setModOption( self, params, player )
	local ok, err = pcall( function()
		ModManager.Sv_ApplyChange( params )
	end )
	if not ok then
		sm.log.error( "[FoliageEraser] ApplyModOption failed: " .. tostring( err ) )
	end
	local message = nil
	if params and params.key == "__enabled" and params.value ~= true then
		message = "Mod disabled and its tool removed.\nType /mods in chat to turn it back on."
	end
	self.network:sendToClient( self.player, "cl_modMenuRefresh", { message = message } )
end

-- Generic mod action handler; see the note on SurvivalGame.sv_modAction.
function SurvivalPlayer.sv_modAction( self, params, player )
	local message = ModManager.Sv_RunAction( params.modId, params.actionKey, self.player )
	self.network:sendToClient( self.player, "cl_modMenuRefresh", { message = message } )
end

function SurvivalPlayer.sv_refreshArea( self, params, player )
	if self.player == nil or self.player.character == nil then return end
	local world = self.player.character:getWorld()
	local _, message = FoliageEraserServer.RefreshArea( world, self.player.character.worldPosition, 1 )
	self.network:sendToClient( self.player, "cl_modMenuRefresh", { message = message } )
end
$MARK_END
"@

$text = $text.TrimEnd() + "`r`n" + $playerCallbacks + "`r`n"

# Tick the mod menu once a frame, alongside Survival's own HUD re-render.
#
# Only so a stale action result can time out on its own. ModMenuGui.Refresh runs
# when something is clicked, which is not enough: leave the window open without
# touching it and the last result would sit there looking current for ever.
#
# Plain string search, no regex: a backslash-escaped pattern here got mangled
# into literal tabs and newlines and silently failed to match.
$tickNeedle = "self.cl.oxygenPanelGui:render( OxygenPanelGui.root )"
if (-not $text.Contains($tickNeedle)) { throw "Could not find the HUD render loop in $rel" }
$tickInsert = $tickNeedle + "`r`n" + $MARK_BEGIN + "`r`n`t`t`tModMenuGui.Cl_Tick( self )`r`n" + $MARK_END
$text = $text.Replace($tickNeedle, $tickInsert)

Write-TextFile (Join-Path $survival $rel) $text
Write-Host "  patched    $rel  (auto-give the tool)"

# -- 3e2. The same menu in Creative and Custom Games ---------------------------
#
# Both modes run CreativeGame.lua out of the Data root, so one patch covers them
# and the paths are $GAME_DATA rather than $SURVIVAL_DATA.
#
# Only /mods here -- no HUD button and no auto-given tool. Creative hands you
# everything through its own build menu, and a mod's tool would need a Creative
# icon atlas entry, which is a separate job.
$rel  = "Scripts\game\CreativeGame.lua"
$text = Read-TextFile (Get-PristineBackupPath $rel "Data")

$cBind = @"
$MARK_BEGIN
	sm.game.bindChatCommand( "/mods", {}, "cl_onChatCommand", "Open the mod manager" )
$MARK_END
"@

$cBindAnchor = '(?m)^\tsm\.game\.bindChatCommand\( "/noaggro",'
if ($text -notmatch $cBindAnchor) { throw "Could not find the bindChatCommand block in $rel" }
$text = Replace-First $text $cBindAnchor ($cBind + "`r`n`tsm.game.bindChatCommand( `"/noaggro`",")

$cHandle = @"
$MARK_BEGIN
	if params[1] == "/mods" then
		local ok, err = pcall( function() ModMenuGui.Open( self ) end )
		if not ok then
			sm.log.error( "[ModManager] mod menu failed: " .. tostring( err ) )
		end
		return
	end
$MARK_END
"@

$cHandleAnchor = '(?m)^function CreativeGame\.cl_onChatCommand\( self, params \)\r?\n'
if ($text -notmatch $cHandleAnchor) { throw "Could not find cl_onChatCommand in $rel" }
$text = Replace-First $text $cHandleAnchor ("function CreativeGame.cl_onChatCommand( self, params )`r`n" + $cHandle + "`r`n")

$cDofile = @"
$MARK_BEGIN
dofile( "`$GAME_DATA/Scripts/game/ModFramework/ModManager.lua" )
dofile( "`$GAME_DATA/Scripts/game/ModFramework/ModMenuGui.lua" )
dofile( "`$GAME_DATA/Scripts/game/ModFramework/ModRegistry.lua" )
$MARK_END
"@

$cLastDofile = ([regex]::Matches($text, '(?m)^dofile\([^\r\n]*\)\r?\n') | Select-Object -Last 1)
if ($cLastDofile -eq $null) { throw "Could not find the dofile block in $rel" }
$at = $cLastDofile.Index + $cLastDofile.Length
$text = $text.Substring(0, $at) + $cDofile + "`r`n" + $text.Substring($at)

$cCallbacks = @"

$MARK_BEGIN
-- Mod manager menu in Creative and Custom Games. Same handlers as the Survival
-- side; the engine dispatches GUI callbacks to whichever script created the GUI.
function CreativeGame.cl_modMenuButton( self, buttonName )
	ModMenuGui.OnButton( self, buttonName )
end

function CreativeGame.cl_modMenuClosed( self )
	ModMenuGui.OnClose( self )
end

function CreativeGame.cl_modMenuRefresh( self, params )
	ModMenuGui.Refresh( self, params )
end

function CreativeGame.sv_setModOption( self, params, player )
	local ok, err = pcall( function()
		ModManager.Sv_ApplyChange( params )
	end )
	if not ok then
		sm.log.error( "[ModManager] ApplyModOption failed: " .. tostring( err ) )
	end
	self.network:sendToClient( player, "cl_modMenuRefresh", {} )
end

function CreativeGame.sv_modAction( self, params, player )
	local message = ModManager.Sv_RunAction( params.modId, params.actionKey, player )
	self.network:sendToClient( player, "cl_modMenuRefresh", { message = message } )
end
$MARK_END
"@

# INSERTED BEFORE THE SUBCLASSES, not appended to the end of the file.
#
# This was a real bug and a nasty one to spot. CreativeGame.lua declares
# CreativeFlatGame, ClassicCreativeGame, CreativeCustomGame and
# CreativeTerrainGame as `class( CreativeGame )` partway down, and the game runs
# one of THOSE, never CreativeGame itself. Appending our methods to the end of
# the file defined them after those subclasses already existed, so they never
# picked them up and every button in the Creative mod menu was dead:
#
#   ERROR: attempted to call generic method 'cl_modMenuButton'
#          and failed to set method and/or environment
#
# Closing was broken too, so cl_modMenuClosed never ran, owner.cl_modMenu was
# never cleared, and /mods stayed dead for the rest of the session.
#
# Defining them before the subclasses means they are inherited however the
# engine's class() actually works - it is native, so its semantics cannot be
# read from the scripts, and this does not depend on knowing them.
$cSubclassAnchor = '(?m)^CreativeFlatGame = class\( CreativeGame \)'
if ($text -notmatch $cSubclassAnchor) {
    throw "Could not find the CreativeGame subclasses in Data\$rel - the game format may have changed."
}
$text = Replace-First $text $cSubclassAnchor ($cCallbacks + "`r`nCreativeFlatGame = class( CreativeGame )")

Write-TextFile (Join-Path $dataDir $rel) $text
Write-Host "  patched    Data\$rel  (/mods in Creative and Custom Games)"

# -- 3e2. Register part shapesets for Creative and Custom Games ------------------
#
# The same registration as the Survival root, against Data's own shapesets.json.
# Without this a mod could add a part to Survival but not to Creative, which is
# exactly backwards: Creative is where a part that MOVES ITEMS should be tested,
# because a bug there costs a throwaway world rather than a real base.
$rel = "Objects\Database\shapesets.json"
$dataShapesetDsts = @($dataCopyFiles |
    Where-Object { $_.dst -like "Objects\Database\ShapeSets\*.shapeset" } |
    ForEach-Object { $_.dst })

if (-not $Uninstall -and $dataShapesetDsts.Count -gt 0) {
    $text = Read-TextFile (Get-PristineBackupPath $rel "Data")

    $setEntries = ""
    foreach ($d in $dataShapesetDsts) {
        # Single-quoted, or PowerShell expands $GAME_DATA as a variable.
        $asPath = '$GAME_DATA/' + ($d -replace '\\', '/')
        $setEntries += "`t`t`"$asPath`",`r`n"
    }

    if ($text -notmatch '"shapeSetList"\s*:\s*\r?\n?\s*\[') {
        throw "Could not find shapeSetList in Data\$rel - the game format may have changed."
    }
    $text = Replace-First $text '("shapeSetList"\s*:\s*\r?\n?\s*\[)' "`$1`r`n$setEntries"
    Write-TextFile (Join-Path $dataDir $rel) $text
    Write-Host "  patched    Data\$rel  (registered $($dataShapesetDsts.Count) part shapeset(s))"
}

# -- 3f. Let the world script reload cells --------------------------------------
# sm.world.reloadCell is sandboxed to the world's own script. Called from the
# tool it fails with "Sandbox violation: mismatching scriptTypeID", so the tool
# raises an event and this handler does the actual reload.
$rel  = "Scripts\game\worlds\Overworld.lua"
$text = Read-TextFile (Get-PristineBackupPath $rel)

$worldBlock = @"

$MARK_BEGIN
function Overworld.sv_e_foliageEraserReload( self, params )
	local done, failed, lastErr = 0, 0, nil
	for cellX = params.minCellX, params.maxCellX do
		for cellY = params.minCellY, params.maxCellY do
			local ok, err = pcall( function()
				sm.world.reloadCell( self.world, cellX, cellY )
			end )
			if ok then
				done = done + 1
			else
				failed = failed + 1
				lastErr = err
			end
		end
	end
	-- The server call above succeeds but redraws nothing, because terrain is
	-- rendered on the CLIENT. Ask each client to reload the same cells so the
	-- visible mesh is rebuilt too.
	local sent, sendErr = pcall( function()
		self.network:sendToClients( "cl_e_foliageEraserReload", params )
	end )
	if not sent then
		sm.log.error( "[FoliageEraser] could not notify clients: " .. tostring( sendErr ) )
	end
end

function Overworld.cl_e_foliageEraserReload( self, params )
	local done, failed, lastErr = 0, 0, nil
	for cellX = params.minCellX, params.maxCellX do
		for cellY = params.minCellY, params.maxCellY do
			local ok, err = pcall( function()
				sm.world.reloadCell( self.world, cellX, cellY )
			end )
			if ok then done = done + 1 else failed = failed + 1; lastErr = err end
		end
	end
end

-- Spawn the Map Viewer's camera seat, INSIDE THE WORLD SCRIPT.
--
-- Same reason the foliage reload lives here: sm.shape.createPart is sandboxed
-- to world scripts (every vanilla caller sits in BaseWorld.lua), so the mod
-- menu action raises this event instead of calling it directly. Spawned
-- dynamic, exactly as BaseWorld spawns its chests; the seat script destroys
-- it when the player exits the map. sm.log.error rather than ModManager.Log
-- because the world script never loads the framework - and never print(),
-- which does not reach the log files from these script environments.
function Overworld.sv_e_mapViewerSpawnSeat( self, params )
	sm.log.error( "[ModLog:mapViewer] world spawn request received" )
	local ok, err = pcall( function()
		local pos = params.player.character.worldPosition + sm.vec3.new( 0, 0, 3 )
		local seat = sm.shape.createPart(
			sm.uuid.new( "cafe0001-5ea7-4001-9001-c0ffee000001" ),
			pos, sm.quat.identity(), true )
		sm.event.sendToInteractable( seat.interactable,
			"sv_e_takeControl", { player = params.player } )
	end )
	sm.log.error( "[ModLog:mapViewer] world seat spawn: " ..
		( ok and "OK" or ( "FAILED: " .. tostring( err ) ) ) )
end

-- Load the world cells around the map camera, INSIDE THE WORLD SCRIPT.
--
-- A SLIDING WINDOW of cell HANDLES. The first version used
-- world:loadCell( x, y, player ), which pins cells to the player and never
-- lets go - a long flight loaded hundreds of cells and dragged the game to
-- 13 fps. This one uses loadCellWithHandle + handle:release(), the exact
-- pair SurvivalGame.sv_loadCell/sv_releaseCell use: every new centre first
-- RELEASES everything outside the window, then loads the square around
-- the camera. The RADIUS RIDES WITH THE ZOOM (0.9.89): the seat sends r =
-- half the visible width in cells (clamped 2..8) - a fixed 5x5 was a
-- 320m crisp island that stopped covering the view once the fog fix let
-- players actually see from high up. Close the map and
-- sv_e_mapViewerReleaseCells drops the lot.
function Overworld.sv_e_mapViewerLoadCells( self, params )
	self.mapViewerCells = self.mapViewerCells or {}
	local cx, cy = params.cx, params.cy
	local r = math.min( math.max( tonumber( params.r ) or 2, 2 ), 8 )

	local released = 0
	local freed = {}
	for key, entry in pairs( self.mapViewerCells ) do
		if math.abs( entry.x - cx ) > r + 1 or math.abs( entry.y - cy ) > r + 1 then
			pcall( function() entry.handle:release() end )
			self.mapViewerCells[key] = nil
			released = released + 1
			freed[#freed + 1] = { x = entry.x, y = entry.y }
		end
	end

	local loaded, failed, lastErr = 0, 0, nil
	local fresh = {}
	for dx = -r, r do
		for dy = -r, r do
			local key = ( cx + dx ) .. ":" .. ( cy + dy )
			if self.mapViewerCells[key] == nil then
				local ok, err = pcall( function()
					local handle = self.world:loadCellWithHandle( cx + dx, cy + dy, nil )
					self.mapViewerCells[key] = { x = cx + dx, y = cy + dy, handle = handle }
				end )
				if ok then
					loaded = loaded + 1
					fresh[#fresh + 1] = { x = cx + dx, y = cy + dy }
				else
					failed = failed + 1; lastErr = err
				end
			end
		end
	end

	-- The GROUND is built by each client's own terrain renderer, and cells
	-- loaded from the server get their trees and rocks but no ground mesh
	-- (seen 19 Aug: assets floating on sky). Same wall the foliage eraser
	-- hit, same cure: ask the clients to rebuild those cells' visuals.
	-- RELEASED cells ride along too: releasing a handle leaves the far-
	-- terrain look stripped (dark smudge where the map has been), and the
	-- rebuild is the one lever that can hand those cells back to the
	-- engine's own far renderer.
	for _, cell in ipairs( freed ) do
		fresh[#fresh + 1] = cell
	end
	if #fresh > 0 then
		pcall( function()
			self.network:sendToClients( "cl_e_mapViewerReloadCells", { cells = fresh } )
		end )
	end

	sm.log.error( string.format(
		"[ModLog:mapViewer] cells around (%d,%d): +%d loaded, -%d released, %d failed%s",
		cx, cy, loaded, released, failed,
		failed > 0 and ( " - " .. tostring( lastErr ) ) or "" ) )
end

function Overworld.cl_e_mapViewerReloadCells( self, params )
	local done, failed = 0, 0
	for _, cell in ipairs( params.cells or {} ) do
		local ok = pcall( function()
			sm.world.reloadCell( self.world, cell.x, cell.y )
		end )
		if ok then done = done + 1 else failed = failed + 1 end
	end
	if failed > 0 then
		sm.log.error( "[ModLog:mapViewer] client ground rebuild: " ..
			done .. " ok, " .. failed .. " failed" )
	end
end

function Overworld.sv_e_mapViewerReleaseCells( self )
	local n = 0
	local freed = {}
	for key, entry in pairs( self.mapViewerCells or {} ) do
		pcall( function() entry.handle:release() end )
		n = n + 1
		freed[#freed + 1] = { x = entry.x, y = entry.y }
	end
	self.mapViewerCells = {}
	if #freed > 0 then
		pcall( function()
			self.network:sendToClients( "cl_e_mapViewerReloadCells", { cells = freed } )
		end )
	end
	sm.log.error( "[ModLog:mapViewer] map closed - released all " .. n .. " held cells" )
end

-- Place a Steam Workshop creation, INSIDE THE WORLD SCRIPT.
--
-- This exists because of where it runs, not because of what it does. The obvious
-- home for it is ModManager.Sv_RunAction on SurvivalGame, and that was the first
-- attempt - but SurvivalGame is what the engine calls a "no world script", and
-- from there sm.creation.importFromString returns bodies that are 100% STATIC.
-- Measured, not guessed: "imported 20 bodies: 0 dynamic, 20 static", the same
-- with four, five and six arguments.
--
-- A static creation cannot fall, cannot be pushed by an impulse, and cannot be
-- picked up by sm.player.placeLift - so it just hangs in the air, unusable. The
-- same context also refuses sm.physics.raycast with "Calling world dependent
-- functions in a no world script!", which is the clue that led here.
--
-- The game's own falling debris (WoodHarvestable, StoneHarvestable) imports from
-- world scripts, so the import happens here instead and the result is reported
-- back to the game script.
-- Blueprint axis indices to vectors.
--
-- A creation stores each part's orientation as two signed axis numbers rather
-- than a rotation: 1/2/3 are +X/+Y/+Z and the negatives are the opposite
-- directions. body:createPart wants them as vectors.
local BLUEPRINT_AXES = {
	[1]  = sm.vec3.new(  1,  0,  0 ),
	[-1] = sm.vec3.new( -1,  0,  0 ),
	[2]  = sm.vec3.new(  0,  1,  0 ),
	[-2] = sm.vec3.new(  0, -1,  0 ),
	[3]  = sm.vec3.new(  0,  0,  1 ),
	[-3] = sm.vec3.new(  0,  0, -1 ),
}

local function BlueprintAxis( index, fallback )
	return BLUEPRINT_AXES[index] or fallback
end

-- Build a creation part by part instead of importing it.
--
-- WHY: sm.creation.importFromString/importFromFile on a SAVED BLUEPRINT returns
-- static prefab scaffolding, not a creation - measured as "20 bodies, 0 dynamic"
-- from every context and argument count tried, and asking the engine to export
-- one back out hard-crashes the process. Static means it cannot fall, cannot be
-- lifted and cannot be driven, which is exactly what was seen in game.
--
-- sm.body.createBody takes an explicit DYNAMIC flag, which is the one thing no
-- import route would give us. So the blueprint is read and rebuilt by hand.
--
-- Everything lands in ONE body on purpose. Scrap Mechanic exposes no joint API
-- to Lua - there is no sm.joint anywhere in the game's own scripts - so bearings
-- and suspension cannot be recreated as real joints. One rigid body gives a
-- complete, solid, liftable creation; separate bodies would give the same pile
-- of disconnected parts the import already produced. A car built this way holds
-- together and can be moved, but its steering and suspension will not articulate.
local function BuildCreationFromBlueprint( blueprint, position )
	local body = sm.body.createBody( position, sm.quat.identity(), true )
	if body == nil then return nil, 0 end

	-- Shapes are remembered BY INDEX, in blueprint order, because that is how the
	-- joints refer to them.
	--
	-- Each joint carries childA and childB - indices into the creation's full
	-- child list, counted across every body and starting at 0. On the test car
	-- those run up to 257 against exactly 258 children, which is what confirmed
	-- the base.
	--
	-- Looking the anchor up by POSITION was the earlier attempt and it mostly
	-- failed: a joint sits between two parts, so its own position usually matches
	-- no part at all. Only 5 of 24 happened to line up; the other 19 returned nil
	-- and the engine rightly complained "Shape expected, got nil".
	local shapeByIndex = {}
	local childIndex = 0

	-- Kept as well, purely as a fallback for blueprints that reference a joint
	-- position with no childA.
	local shapeAt = {}
	local function PosKey( p ) return string.format( "%d,%d,%d", p.x, p.y, p.z ) end

	-- Which part types refused, and why. Counting failures told us 8 were missing
	-- but never which 8, so a whole round was spent guessing at them.
	local missing, missingErr = {}, {}

	-- Which children hang off the FAR side of a joint.
	--
	-- A joint connects two shapes. Creating it against side A alone left its
	-- controller with no body on the other end, and the engine died on
	-- "Controller without Body ... Host is null" - a hard Bugsplat, after
	-- reporting 24 of 24 joints placed.
	--
	-- sm.joint has its own createPart and createBlock, so the far-side shape is
	-- meant to be built THROUGH the joint. Those children are therefore skipped
	-- here and created in the joint pass below.
	-- Joints come in two classes, and only one of them crashes.
	--
	-- On the test car: 20 plain bearings (jnt_bearing) carry NO controller, and 4
	-- suspension joints carry one with a stiffnessLevel. The crash is
	-- "Controller without Body ... Host is null" - so the controller-carrying
	-- joints are the suspects, and the 20 plain bearings are what actually hold
	-- the wheels on.
	--
	-- Building the bearings alone should attach the wheels and leave only the
	-- suspension missing, which narrows the remaining work to controllers.
	--
	-- Declared HERE, at the top, because `deferred` below depends on them. An
	-- earlier version declared them down beside the joint loop, where they read
	-- as nil and quietly deferred nothing.
	-- Controller joints (suspension) are SKIPPED, not substituted.
	--
	-- Upgradeable joints - jnt_suspensionoffroad_01, jnt_suspensionsport_01 -
	-- carry a controller holding their stiffness level. The engine creates that
	-- controller itself and then crashes with "Controller without Body ... Host
	-- is null", every time, however the joint is built.
	--
	-- Established three independent ways, not assumed:
	--   1. Enumerating every sm.* namespace at runtime for
	--      controller/host/upgrade/level found nothing that could host one.
	--   2. The official Joint API reference lists no controller, stiffness or
	--      level property at all.
	--   3. The engine rejects a 5th argument outright: "Expected 4 arguments
	--      (got 5)", so there is no richer creation form.
	--
	-- The attachment flow here already matches the documented one - createJoint
	-- then joint:createPart, which creates shapeB on another body - and it still
	-- crashes. The controller is the blocker, not the joint.
	--
	-- Skipped rather than replaced with a bearing: a bearing is not a suspension
	-- and the point is an exact reproduction. Missing is honest; wrong is not.
	local BUILD_PLAIN_JOINTS      = true
	local BUILD_CONTROLLER_JOINTS = true

	-- Suspension is a SPRING, not a bearing.
	--
	-- The game's own shapeset says so: jnt_suspensionoffroad_02 and
	-- jnt_suspensionsport_02 (the two this blueprint uses) carry a
	-- "survivalSpring" block with a length and a stiffnessLimit. The API lists
	-- three joint types - bearing, spring, piston - and springs are driven by
	-- setTargetLength, not by the bearing calls.
	--
	-- setTargetLength does NOT apply: the engine answers "bad argument #1 to
	-- 'getLength' (piston expected, got spring)". Useful anyway - it proves the
	-- joint really is being created as a spring. Springs are passive and have no
	-- length API; only pistons do.
	local INIT_SPRINGS = false

	-- ISOLATION TEST: build the spring but attach NOTHING to its far side.
	--
	-- The API says shapeB "returns nil if no shape attached", so a joint with one
	-- end is legal. If the crash disappears, the fault is in how the far-side
	-- body is made. If it still crashes, the spring itself cannot be created from
	-- Lua and no attachment strategy will help.
	--
	-- The far-side child is NOT deferred while this is on, so it still gets built
	-- on the main body and no part goes missing.
	local SPRING_WITHOUT_FAR_SIDE = true

	-- Suspension is rebuilt AS A PLAIN BEARING.
	--
	-- An upgradeable joint - jnt_suspensionoffroad_01, jnt_suspensionsport_01 -
	-- carries a controller holding its stiffness level, and the ENGINE creates
	-- that controller when the joint is made. Nothing in Lua can give it a host
	-- body: sm.joint exposes getShapeA/getShapeB and the motor calls, but no
	-- controller API at all.
	--
	-- Every step of building one succeeds - anchor found, joint made, far side
	-- built, 24 of 24, 258/258 - and then the engine validates the finished
	-- creation, finds "Controller without Body ... Host is null", and hard
	-- crashes. pcall cannot catch it; the fault is inside the engine.
	--
	-- Structurally a suspension does the same job as a bearing: it connects the
	-- wheel to the chassis and lets it turn. Swapping in a plain bearing keeps
	-- the creation whole and drivable, and costs only the springy travel. A car
	-- that works without suspension beats a car that crashes the game.
	local SUSPENSION_AS_BEARING = false
	local PLAIN_BEARING_UUID    = "4a1b886b-913e-4aad-b5b6-6e41b0db23a6"

	-- Only defer the far side of joints we are actually going to build. A child
	-- deferred for a joint that never gets made would simply go missing.
	local deferred = {}
	for _, joint in ipairs( blueprint.joints or {} ) do
		local hasCtrl = ( joint.controller ~= nil )
		local build = hasCtrl and BUILD_CONTROLLER_JOINTS or
		              ( not hasCtrl ) and BUILD_PLAIN_JOINTS
		-- A spring's far side is not deferred during the isolation test: nothing
		-- will build it through the joint, so it must go on the main body.
		if hasCtrl and SPRING_WITHOUT_FAR_SIDE then build = false end
		if build and joint.childB ~= nil then deferred[joint.childB] = true end
	end

	-- The child DATA by index, so the joint pass can build the far-side shape it
	-- deferred. Indices count across every body, from 0, matching childA/childB.
	local childByIndex = {}
	do
		local i = 0
		for _, bpBody in ipairs( blueprint.bodies or {} ) do
			for _, child in ipairs( bpBody.childs or {} ) do
				childByIndex[i] = child
				i = i + 1
			end
		end
	end

	local placed, failed = 0, 0
	for _, bpBody in ipairs( blueprint.bodies or {} ) do
		for _, child in ipairs( bpBody.childs or {} ) do
			-- Deferred children are built later, through their joint, so the joint
			-- has a body on its far side. Plain if/else rather than goto: this is
			-- Lua 5.1 and goto does not exist here.
			local ok, err = true, nil
			if not deferred[childIndex] then
			ok, err = pcall( function()
				local uuid = sm.uuid.new( child.shapeId )
				local pos  = sm.vec3.new( child.pos.x, child.pos.y, child.pos.z )
				local shape

				-- BLOCKS and PARTS are built by different calls, and a blueprint
				-- tells them apart by one field: a block carries `bounds` (its
				-- size), a part does not.
				--
				-- Getting this wrong is what lost the floor. Every one of the 8
				-- failures was blk_scrapstone being pushed through createPart,
				-- which refuses it with "expected the uuid of a part" - the same
				-- message joints give, which is why it read as one problem
				-- rather than two.
				if child.bounds then
					shape = body:createBlock(
						uuid,
						sm.vec3.new( child.bounds.x, child.bounds.y, child.bounds.z ),
						pos,
						true )
				else
					shape = body:createPart(
						uuid,
						pos,
						BlueprintAxis( child.zaxis, sm.vec3.new( 0, 0, 1 ) ),
						BlueprintAxis( child.xaxis, sm.vec3.new( 1, 0, 0 ) ),
						true )
				end

				-- Remembered for the joints below, which name a POSITION rather
				-- than the shape they attach to. Recorded for every shape, not
				-- just coloured ones - an earlier version tucked this inside the
				-- colour check, so uncoloured parts were invisible to the joints.
				if shape then
					shapeByIndex[childIndex] = shape
					shapeAt[PosKey( child.pos )] = shape
					if child.color then
						pcall( function() shape:setColor( sm.color.new( child.color ) ) end )
					end
				end
			end )
			if ok then
				placed = placed + 1
			else
				failed = failed + 1
				local id = tostring( child.shapeId )
				missing[id] = ( missing[id] or 0 ) + 1
				missingErr[id] = missingErr[id] or tostring( err )
			end
			end

			-- Advanced for EVERY child, deferred or not, so joint indices stay
			-- lined up with the blueprint.
			childIndex = childIndex + 1
		end
	end

	-- Named, not just counted. A uuid can be looked up in the game's shapesets to
	-- see exactly which part is being lost.
	for id, count in pairs( missing ) do
		sm.log.error( string.format( "[Blueprints] MISSING PART %s x%d : %s",
			id, count, missingErr[id] ) )
	end

	-- Then the joints - the bearings, hinges and suspension mounts.
	--
	-- These live in a SEPARATE top-level `joints` array, not inside any body, and
	-- skipping them is what made the first working build fall apart the moment it
	-- was lifted: the chassis held, but every wheel and subassembly dropped off,
	-- because nothing physically connected them.
	--
	-- Each entry is a real part with its own shapeId - three bearing types on the
	-- test car - plus a position and axes for each side. Lua exposes no joint API
	-- (there is no sm.joint anywhere in the game's scripts), so they cannot be
	-- made into articulating joints. Placed as parts they at least fill the gap
	-- and weld the assembly into one solid creation, which lifts and moves in one
	-- piece. Wheels will not spin and steering will not turn.
	-- NOTE: never call getmetatable in here. Scrap Mechanic's Lua sandbox removes
	-- it, and "attempt to call global 'getmetatable' (a nil value)" aborted this
	-- entire function before the joints below were ever reached - which looked
	-- from the outside exactly like the joints failing again.
	--
	-- The API-enumeration probes that lived here have done their job and been
	-- removed: they are what found sm.shape.createJoint, and then proved no
	-- controller API exists anywhere. They only added log noise afterwards.

	-- Then the joints, with sm.shape.createJoint.
	--
	-- createPart refuses these outright ("expected the uuid of a part") because a
	-- bearing is a JOINT, and joints have their own creation call. Nothing in the
	-- game's own scripts calls it, which is why it took so long to find - but the
	-- function is there, alongside sm.joint with setMotorVelocity, setTargetAngle
	-- and the rest.
	--
	-- The signature is not documented anywhere in the game's files, so several
	-- plausible argument orders are tried and the engine's own error message is
	-- kept. Its errors have been precise so far ("expected the uuid of a part"),
	-- so whichever one it dislikes, it will say why.
	-- Upgrades are switched OFF around the joint build, then restored.
	--
	-- Suspension carries a controller only because it is an UPGRADEABLE part -
	-- the controller is where its stiffness level lives. The engine creates that
	-- controller itself, finds no body to host it, and hard crashes with
	-- "Controller without Body ... Host is null".
	--
	-- Lua has no controller API at all: enumerating every namespace for
	-- controller/host/upgrade/level turned up only sm.body.isGhost,
	-- sm.player.getHostPlayer, the lift helpers, and this pair. So this flag is
	-- the only lever there is - with upgrades off, there should be no upgrade
	-- level to store and no controller to host.
	--
	-- Restored immediately afterwards, in both the success and failure paths, so
	-- a placement can never leave the player's world with upgrades disabled.
	local upgradeWas = nil
	if type( sm.game ) == "table" and sm.game.getEnableUpgrade and sm.game.setEnableUpgrade then
		local okGet, val = pcall( sm.game.getEnableUpgrade )
		if okGet then
			upgradeWas = val
			pcall( sm.game.setEnableUpgrade, false )
			sm.log.error( "[Blueprints] upgrades temporarily OFF (was " .. tostring( val ) .. ")" )
		end
	end

	local joints, skipped, jointErr = 0, 0, nil
	for _, joint in ipairs( blueprint.joints or {} ) do
		local hasController = ( joint.controller ~= nil )
		local wanted = ( hasController and BUILD_CONTROLLER_JOINTS ) or
		               ( not hasController and BUILD_PLAIN_JOINTS )
		if not wanted then skipped = skipped + 1 end

		if wanted and joint.shapeId and joint.posA then
			-- A controller-carrying joint is built as a plain bearing instead, so
			-- the engine never creates the controller that it cannot host.
			local useId = joint.shapeId
			if hasController and SUSPENSION_AS_BEARING then
				useId = PLAIN_BEARING_UUID
			end

			local uuid   = sm.uuid.new( useId )
			local posA   = sm.vec3.new( joint.posA.x, joint.posA.y, joint.posA.z )
			local zA     = BlueprintAxis( joint.zaxisA, sm.vec3.new( 0, 0, 1 ) )
			local xA     = BlueprintAxis( joint.xaxisA, sm.vec3.new( 1, 0, 0 ) )
			-- childA names the shape this joint hangs off. Position is only a
			-- fallback for blueprints that omit it.
			local anchor = nil
			if joint.childA ~= nil then anchor = shapeByIndex[joint.childA] end
			if anchor == nil then anchor = shapeAt[PosKey( joint.posA )] end

			-- SHAPE FIRST. The engine said so: "bad argument #1 to '?' (Shape
			-- expected, got userdata)" when the uuid was passed first.
			--
			-- For CONTROLLER joints the far side is built FIRST and handed in, in
			-- case the controller needs both ends known at creation time. Every
			-- signature that only names shapeA has produced a joint whose
			-- controller has no host, and sm.joint exposes getShapeA AND
			-- getShapeB, so a two-shape form is worth probing.
			local farShape = nil
			if hasController and not SPRING_WITHOUT_FAR_SIDE then
				local far = childByIndex[joint.childB]
				if far ~= nil then
					pcall( function()
						local fUuid = sm.uuid.new( far.shapeId )
						local fPos  = sm.vec3.new( far.pos.x, far.pos.y, far.pos.z )
						if far.bounds then
							farShape = body:createBlock( fUuid,
								sm.vec3.new( far.bounds.x, far.bounds.y, far.bounds.z ), fPos, true )
						else
							farShape = body:createPart( fUuid, fPos,
								BlueprintAxis( far.zaxis, sm.vec3.new( 0, 0, 1 ) ),
								BlueprintAxis( far.xaxis, sm.vec3.new( 1, 0, 0 ) ), true )
						end
					end )
					if farShape ~= nil then
						shapeByIndex[joint.childB] = farShape
						placed = placed + 1
					end
					sm.log.error( "[Blueprints] pre-built far side for joint " ..
						tostring( joint.id ) .. " ok=" .. tostring( farShape ~= nil ) )
				end
			end

			local attempts = {}
			if farShape ~= nil then
				attempts = {
					function() return sm.shape.createJoint( anchor, uuid, posA, zA, farShape ) end,
					function() return sm.shape.createJoint( anchor, farShape, uuid, posA, zA ) end,
					function() return sm.shape.createJoint( anchor, uuid, posA, zA, xA, farShape ) end,
					function() return sm.shape.createJoint( anchor, uuid, posA, zA ) end,
				}
			else
				attempts = {
					function() return sm.shape.createJoint( anchor, uuid, posA, zA ) end,
					function() return sm.shape.createJoint( anchor, uuid, posA, zA, xA ) end,
					function() return sm.shape.createJoint( anchor, uuid, posA, zA, true ) end,
					function() return sm.shape.createJoint( anchor, uuid, posA ) end,
				}
			end

			local made = nil
			for _, attempt in ipairs( attempts ) do
				local ok, res = pcall( attempt )
				if ok and res ~= nil then
					made = res
					break
				end
				if not ok and jointErr == nil then jointErr = res end
			end

			-- Suspension joints are logged step by step. They are the ones that
			-- crash, and the log is written live, so even a hard Bugsplat leaves a
			-- trail showing exactly how far it got.
			if hasController then
				sm.log.error( string.format(
					"[Blueprints] SUSPENSION joint id=%s shape=%s anchor=%s made=%s childB=%s",
					tostring( joint.id ), tostring( joint.shapeId ),
					tostring( anchor ~= nil ), tostring( made ~= nil ),
					tostring( joint.childB ) ) )
			end

			-- Initialise a spring the moment it exists, before anything else can
			-- look at it. getLength reads what the engine gave it; feeding that
			-- straight back as the target is a no-op movement but forces the
			-- spring's state to be set up.
			if made ~= nil and hasController and INIT_SPRINGS then
				local okInit, errInit = pcall( function()
					local len = sm.joint.getLength( made )
					sm.joint.setTargetLength( made, len, 1, 1000 )
				end )
				sm.log.error( "[Blueprints]   spring init for joint " ..
					tostring( joint.id ) .. " ok=" .. tostring( okInit ) ..
					( okInit and "" or ( " err=" .. tostring( errInit ) ) ) )
			end

			if made ~= nil then
				joints = joints + 1

				-- Build the FAR SIDE through the joint.
				--
				-- Without this the joint exists but has no shape on its other
				-- end, and the engine hard-crashes with "Controller without Body
				-- ... Host is null" once the creation goes live. sm.joint's own
				-- createPart / createBlock are what attach a shape to a joint.
				-- Skipped for springs during the isolation test, and skipped when
				-- the far side was already pre-built above.
				local far = nil
				if farShape == nil and not ( hasController and SPRING_WITHOUT_FAR_SIDE ) then
					far = childByIndex[joint.childB]
				end
				if far ~= nil then
					local okFar, errFar = pcall( function()
						local uuid = sm.uuid.new( far.shapeId )
						local pos  = sm.vec3.new( far.pos.x, far.pos.y, far.pos.z )
						local shape
						if far.bounds then
							shape = made:createBlock(
								uuid,
								sm.vec3.new( far.bounds.x, far.bounds.y, far.bounds.z ),
								pos, true )
						else
							shape = made:createPart(
								uuid, pos,
								BlueprintAxis( far.zaxis, sm.vec3.new( 0, 0, 1 ) ),
								BlueprintAxis( far.xaxis, sm.vec3.new( 1, 0, 0 ) ),
								true )
						end
						if shape then
							shapeByIndex[joint.childB] = shape
							if far.color then
								pcall( function() shape:setColor( sm.color.new( far.color ) ) end )
							end
						end
					end )
					if okFar then
						placed = placed + 1
						if hasController then
							sm.log.error( "[Blueprints]   far side built OK for joint " .. tostring( joint.id ) )
						end
					else
						failed = failed + 1
						if hasController then
							sm.log.error( "[Blueprints]   FAR SIDE FAILED for joint " ..
								tostring( joint.id ) .. ": " .. tostring( errFar ) )
						end
						if jointErr == nil then jointErr = "far side: " .. tostring( errFar ) end
					end
				end
			end
		end
	end
	-- Put the upgrade setting back exactly as it was, whatever happened above.
	if upgradeWas ~= nil then
		pcall( sm.game.setEnableUpgrade, upgradeWas )
		sm.log.error( "[Blueprints] upgrades restored to " .. tostring( upgradeWas ) )
	end

	if jointErr then
		sm.log.error( "[Blueprints] joint error: " .. tostring( jointErr ) )
	end

	if failed > 0 then
		sm.log.error( string.format( "[Blueprints] %d part(s) could not be placed", failed ) )
	end
	sm.log.error( string.format( "[Blueprints] %d of %d joint(s) placed, %d skipped (controller joints)",
		joints, #( blueprint.joints or {} ), skipped ) )

	-- A MANIFEST of what the blueprint asked for versus what actually exists.
	--
	-- Counting failures was never enough: it said 8 parts were missing without
	-- saying which, so rounds were spent guessing while the floor blocks sat
	-- there unexplained. This lists every part type in the creation with expected
	-- and placed counts, so anything short is named outright.
	local expected, blocks = {}, 0
	for _, bpBody in ipairs( blueprint.bodies or {} ) do
		for _, child in ipairs( bpBody.childs or {} ) do
			local id = tostring( child.shapeId )
			expected[id] = ( expected[id] or 0 ) + 1
			if child.bounds then blocks = blocks + 1 end
		end
	end

	local types, short = 0, 0
	for _, _ in pairs( expected ) do types = types + 1 end
	for id, want in pairs( expected ) do
		local lost = ( missing[id] or 0 )
		if lost > 0 then short = short + 1 end
	end

	sm.log.error( string.format(
		"[Blueprints] MANIFEST: %d part types, %d blocks, %d joints | %d/%d placed, %d type(s) short",
		types, blocks, #( blueprint.joints or {} ),
		placed, placed + failed, short ) )

	return body, placed
end

function Overworld.sv_e_blueprintPlace( self, params )
	-- FIRST: try the game's OWN import, exactly as SurvivalGame.sv_importCreation
	-- does it.
	--
	--   sm.creation.importFromFile( params.world, ".../name.blueprint", params.position )
	--
	-- THREE arguments, with a world, and no rotation. Every earlier attempt here
	-- passed four, or a nil world, or used importFromString - never this exact
	-- form. And the game's matching sv_exportCreation writes its file with
	-- exportToString, which means a .blueprint file IS the export format, not a
	-- lesser one as assumed earlier.
	--
	-- If the engine's own round-trip works, it brings joints, springs, controllers
	-- and wiring with it - everything the hand-built constructor cannot do.
	local imported = nil
	do
		-- EACH BODY'S "type" IS SET BEFORE IMPORTING.
		--
		-- A blueprint body may carry a "type" field, and the game treats it as the
		-- body's physics kind. Proof that it is load-bearing: the game ships the
		-- SAME crystal twice, and CrystalHarvestable.lua:59 picks between them -
		--
		--   local blueprint = position and self.data.blueprint
		--       or self.data.blueprint:gsub( "%.blueprint", "_dyn.blueprint" )
		--
		-- harvestable_crystal_large01.blueprint and its _dyn twin are otherwise
		-- byte-identical: same version, same children, same colours. The only
		-- difference in the whole file is type 2 versus type 0. Nobody keeps two
		-- copies of a file to change a field the engine ignores.
		--
		-- Across the game's 1300-odd blueprint bodies:
		--   type 0  the _dyn crystals (fragments FLY on explosion), and most
		--           GameplayBlueprints                                   moves
		--   type 2  every falling tree and boulder in harvestable_blueprints
		--                                                                moves
		--   type 1  BuilderQuest and BuildQuests build guides, Undergroundstation
		--           and Dungeon scenery                                  FROZEN
		--   absent  831 bodies, including every player-saved creation - and our
		--           Workshop car, which measured 0/20 dynamic
		--
		-- A Steam Workshop creation is player-saved, so it has NO type at all and
		-- the engine falls back to whatever its default is. That is the difference
		-- the world argument was wrongly blamed for: passing nil changed nothing
		-- because the file never said the bodies could move.
		--
		-- ALL THREE VALUES ARE TRIED IN ONE RUN, best first, because each in-game
		-- test costs a launch, a world load and a placement. The first type that
		-- yields a dynamic body wins; a static result is destroyed before the next
		-- attempt so the world is not left with a pile of failed cars.

		-- IS SOMETHING IN THE WAY? Asked BEFORE anything is imported.
		--
		-- The first version of this check imported the creation, measured its real
		-- bounding box, and destroyed it again if it overlapped something. That
		-- measurement was more accurate, and it was still the wrong design: it
		-- dropped 23 dynamic bodies inside a wreck, and the player's game fell to
		-- 3 FPS for over a minute and would not respond. The lag vanished the
		-- instant they left the world, which places it squarely in the world's
		-- physics rather than in this script - the solver was fighting deeply
		-- interpenetrating bodies. destroyCreation was wrapped in a bare pcall, so
		-- "removing" was logged whether or not anything was actually removed.
		--
		-- NEVER SPAWN SOMETHING IN ORDER TO TEST WHETHER IT SHOULD HAVE BEEN
		-- SPAWNED. The measurement is worth less than the damage.
		--
		-- So the footprint is estimated from the blueprint instead. Child positions
		-- are in BLOCK units of a quarter metre, and a block child carries a
		-- "bounds" giving its size in blocks, so the extent is the min-to-max span
		-- of every child scaled by 0.25.
		--
		-- The probe is centred on the target rather than on the creation's true
		-- anchor, because importFromFile's anchor convention is not documented -
		-- the Height Adjuster places, measures and corrects for that same reason.
		-- That makes this approximate, and approximate in the safe direction: it
		-- can refuse a spot that would just about have worked, which is a nuisance,
		-- rather than allow one that locks the game up.
		--
		-- Only FOREIGN BODIES count. Characters are ignored - standing next to
		-- where your creation will appear is not an obstruction - and harvestables
		-- are ignored on purpose, because Survival is full of trees and boulders
		-- and refusing near one would fail almost everywhere. Wrecks, which is what
		-- a car actually landed on the roof of, are bodies.
		local function ObstructionCount()
			local blocked = 0
			pcall( function()
				local bp = sm.json.open( params.path )
				if bp == nil or bp.bodies == nil then return end

				local lo, hi = nil, nil
				for _, body in ipairs( bp.bodies ) do
					for _, child in ipairs( body.childs or {} ) do
						local p = child.pos
						if p ~= nil then
							local x0, y0, z0 = p.x or 0, p.y or 0, p.z or 0
							local sx, sy, sz = 1, 1, 1
							local b = child.bounds
							if b ~= nil then
								sx, sy, sz = b.x or 1, b.y or 1, b.z or 1
							end
							if lo == nil then
								lo = { x = x0, y = y0, z = z0 }
								hi = { x = x0 + sx, y = y0 + sy, z = z0 + sz }
							else
								lo.x = math.min( lo.x, x0 ); hi.x = math.max( hi.x, x0 + sx )
								lo.y = math.min( lo.y, y0 ); hi.y = math.max( hi.y, y0 + sy )
								lo.z = math.min( lo.z, z0 ); hi.z = math.max( hi.z, z0 + sz )
							end
						end
					end
				end
				if lo == nil then return end

				-- Blocks are quarter-metres; halve the span for half-extents. A
				-- floor keeps a very flat creation from producing a zero-thickness
				-- probe, which would contact nothing at all.
				local half = sm.vec3.new(
					math.max( ( hi.x - lo.x ) * 0.125, 0.25 ),
					math.max( ( hi.y - lo.y ) * 0.125, 0.25 ),
					math.max( ( hi.z - lo.z ) * 0.125, 0.25 ) )

				local contacts = sm.physics.getBoxContacts(
					params.position, sm.quat.identity(), half )
				if contacts ~= nil and contacts.bodies ~= nil then
					blocked = #contacts.bodies
				end
			end )
			return blocked
		end

		local inTheWay = ObstructionCount()
		if inTheWay > 0 then
			sm.log.error( string.format(
				"[Blueprints] OBSTRUCTED by %d body/bodies - nothing imported", inTheWay ) )
			sm.event.sendToGame( "sv_e_blueprintResult",
				{ message = "Unable to place due to obstruction - move somewhere clearer and try again" } )
			return
		end

		local function ImportWithType( bodyType )
			local bp = nil
			local okRead = pcall( function() bp = sm.json.open( params.path ) end )
			if not okRead or bp == nil or bp.bodies == nil then
				return nil, "could not read the blueprint"
			end

			for _, body in ipairs( bp.bodies ) do
				body.type = bodyType
			end

			-- ONE PATH PER CREATION PER TYPE. Not tidiness - correctness.
			--
			-- The engine caches blueprint parses BY PATH. With a single shared
			-- scratch filename, selecting the Bipedal Piston Walker spawned the CAR
			-- that had been placed earlier, twice in a row, even though the file on
			-- disk was verified to be the walker. It also made this very loop a lie:
			-- attempts 2 and 3 would re-serve attempt 1's parse.
			--
			-- The bytes for a given creation and type are always identical, so once
			-- each path has its own content the cache is simply right.
			local scratchPath = params.scratch .. "_t" .. tostring( bodyType ) .. ".blueprint"

			local okWrite = pcall( function() sm.json.save( bp, scratchPath ) end )
			if not okWrite then return nil, "could not write the scratch copy" end

			-- Same four-argument call the harvestables use.
			local okImport, imp = pcall( sm.creation.importFromFile,
				nil, scratchPath, params.position, sm.quat.identity() )
			if not okImport or imp == nil or #imp == 0 then
				return nil, tostring( imp )
			end
			return imp, nil
		end

		local function CountDynamic( bodies )
			local n = 0
			for _, b in ipairs( bodies ) do
				local d = false
				pcall( function() d = b:isDynamic() end )
				if d then n = n + 1 end
			end
			return n
		end

		local ok, res = false, nil
		for _, bodyType in ipairs( { 0, 2, 1 } ) do
			local candidate, err = ImportWithType( bodyType )
			if candidate == nil then
				sm.log.error( string.format(
					"[Blueprints] type=%d import failed: %s", bodyType, tostring( err ) ) )
			else
				local n = CountDynamic( candidate )
				sm.log.error( string.format(
					"[Blueprints] type=%d -> %d bodies, %d dynamic", bodyType, #candidate, n ) )
				if n > 0 then
					ok, res = true, candidate
					break
				end
				-- Static. Clear it away rather than leaving it in the world.
				pcall( function() candidate[1]:destroyCreation() end )
			end
		end

		-- No type produced a dynamic body. Fall back to importing the file
		-- untouched, so the player still gets the creation - static, exactly as
		-- before - instead of nothing at all.
		if not ok then
			sm.log.error( "[Blueprints] no body type gave a dynamic result; importing as-is" )
			ok, res = pcall( sm.creation.importFromFile,
				nil, params.path, params.position, sm.quat.identity() )
		end

		if ok and res ~= nil and #res > 0 then
			local dyn = 0
			for _, b in ipairs( res ) do
				local d = false
				pcall( function() d = b:isDynamic() end )
				if d then dyn = dyn + 1 end
			end
			sm.log.error( string.format(
				"[Blueprints] GAME IMPORT worked: %d bodies, %d dynamic", #res, dyn ) )

			-- Let the creation become dynamic.
			--
			-- An imported creation arrives STATIC - welded to the world, frozen
			-- in mid air, refusing the lift. The game controls exactly this with
			-- setConvertibleToDynamic: BuilderGuideLiftPlatform locks a build
			-- with false while a quest is in progress, then releases it with true
			-- when the quest completes.
			--
			-- Applied to every body in the creation, not just the first: a
			-- creation is many bodies joined by joints, and one left locked would
			-- anchor the whole thing.
			-- An imported creation arrives with its permissions OFF, which is why
			-- the lift would not touch it: the Lift tool tests liftable, and
			-- being liftable is what converts a static body to dynamic. Setting
			-- convertible alone was only half of it.
			--
			-- The full set comes from sm.body, listed by dumping the namespace:
			-- setLiftable, setConnectable, setBuildable, setErasable,
			-- setDestructable, setPaintable, setUsable, setConvertibleToDynamic.
			-- All are applied so the creation behaves like anything the player
			-- built themselves - liftable, wirable with the Connect Tool,
			-- paintable, and removable.
			local freed, failedFree = 0, nil
			for _, b in ipairs( res ) do
				local okFree, errFree = pcall( function()
					b:setConvertibleToDynamic( true )
					b:setLiftable( true )
					b:setConnectable( true )
					b:setBuildable( true )
					b:setErasable( true )
					b:setDestructable( true )
					b:setPaintable( true )
					b:setUsable( true )
				end )
				if okFree then freed = freed + 1 elseif failedFree == nil then failedFree = errFree end
			end
			sm.log.error( string.format(
				"[Blueprints] setConvertibleToDynamic on %d/%d bodies%s",
				freed, #res, failedFree and ( " err=" .. tostring( failedFree ) ) or "" ) )

			-- The namespace dumps that used to run here are GONE.
			--
			-- They were searching sm.game and sm.player for a switch that would
			-- turn a static import dynamic. There is no such switch: the answer was
			-- in the blueprint file's body "type", not in the API, and the search
			-- printed two enormous lines into the log on every single placement.
			-- The full listings are recorded in memory.md instead.

			-- Is this ONE creation or 20 loose bodies?
			--
			-- getCreationBodies returns every body joined to this one. If it
			-- reports 20 the creation is properly linked; if it reports 1 the
			-- import produced separate objects that merely look like a car.
			pcall( function()
				local grouped = res[1]:getCreationBodies()
				sm.log.error( string.format(
					"[Blueprints] creation grouping: body 1 belongs to a creation of %d bodies (of %d imported)",
					grouped and #grouped or -1, #res ) )
			end )

			-- The LIFT, but only as a RESCUE for a static import.
			--
			-- A dynamic creation is left alone deliberately: it falls and lands on
			-- the ground by itself, which is what was actually asked for. Putting
			-- it on a lift instead would hold it in the air again.
			--
			-- So this only runs if the import still came back static, where the
			-- lift is the one remaining way to get the thing moving. The vanilla
			-- Lift TOOL refuses a static body because the tool checks isDynamic()
			-- itself, but that is the tool's guard, not the engine's -
			-- sm.player.placeLift is the call underneath it.
			--
			-- liftPos is in quarter-metres (Lift.lua:108, pointWorld * 4 floored),
			-- taken from the creation's own position so the lift appears under it.
			if params.player ~= nil and dyn == 0 then
				local okLift, errLift = pcall( function()
					local aabb = res[1]:getWorldPosition()
					local liftPos = sm.vec3.new(
						math.floor( aabb.x * 4 + 0.5 ),
						math.floor( aabb.y * 4 + 0.5 ),
						math.floor( aabb.z * 4 + 0.5 ) )
					sm.player.placeLift( params.player, res, liftPos, 0, 0 )
				end )
				sm.log.error( "[Blueprints] placeLift ok=" .. tostring( okLift ) ..
					( okLift and "" or ( " err=" .. tostring( errLift ) ) ) )
			end

			-- Report the resulting state, so "still floating" can be told apart
			-- from "liftable but nobody lifted it".
			local st = { dynamic = 0, liftable = 0, convertible = 0, onLift = 0 }
			for _, b in ipairs( res ) do
				pcall( function()
					if b:isDynamic() then st.dynamic = st.dynamic + 1 end
					if b:isLiftable() then st.liftable = st.liftable + 1 end
					if b:isConvertibleToDynamic() then st.convertible = st.convertible + 1 end
					if b:isOnLift() then st.onLift = st.onLift + 1 end
				end )
			end
			sm.log.error( string.format(
				"[Blueprints] AFTER: %d/%d dynamic, %d liftable, %d convertible, %d on lift",
				st.dynamic, #res, st.liftable, st.convertible, st.onLift ) )

			-- Tell the player it landed.
			--
			-- Sv_Place cannot report this: it returns the moment the world event is
			-- sent, long before the import has happened, so its "placed in front of
			-- you" is a promise rather than a result. This is the real outcome.
			-- Hand the creation back so UNDO can reach it.
			--
			-- This was missing, and it mattered: Blueprints.lastPlaced was only ever
			-- set by the old in-game-script route, so for every creation placed
			-- through this handler the UNDO button silently did nothing. The one time
			-- a placement genuinely needed undoing - a walker wedged inside a wreck,
			-- dragging the world to 3 FPS - there was no way to remove it from the
			-- menu at all.
			if params.player ~= nil then
				sm.event.sendToGame( "sv_e_blueprintPlaced",
					{ player = params.player, body = res[1] } )
			end

			local placedName = tostring( params.name or "The creation" )
			if dyn > 0 then
				sm.event.sendToGame( "sv_e_blueprintResult",
					{ message = placedName .. " placed - it will drop and settle" } )
			else
				sm.event.sendToGame( "sv_e_blueprintResult",
					{ message = placedName .. " placed, but it came in frozen - tell Claude" } )
			end

			imported = res
		else
			sm.log.error( "[Blueprints] game import failed: " .. tostring( res ) )
			sm.event.sendToGame( "sv_e_blueprintResult",
				{ message = "That creation could not be placed" } )
		end
	end

	if imported ~= nil then return end

	-- Read the creation. sm.json.open parses the blueprint file straight into a
	-- table, which is all the constructor needs.
	local read, blueprint = pcall( sm.json.open, params.path )
	if not read or type( blueprint ) ~= "table" or blueprint.bodies == nil then
		sm.log.error( "[Blueprints] could not read " .. tostring( params.path ) )
		return
	end

	local built, placed = BuildCreationFromBlueprint( blueprint, params.position )
	if built == nil then
		sm.log.error( "[Blueprints] createBody returned nothing" )
		return
	end

	local isDyn = false
	pcall( function() isDyn = built:isDynamic() end )
	sm.log.error( string.format(
		"[Blueprints] BUILT %d parts, dynamic=%s", placed, tostring( isDyn ) ) )

	-- DO NOT call sm.creation.exportToString on a creation from here.
	--
	-- It hard-crashed the engine ("Bugsplat!" in sv_e_blueprintPlace) when it was
	-- tried on imported bodies, and pcall does NOT protect against it because the
	-- fault is inside the engine rather than a Lua error.
end
$MARK_END
"@

# Appending is safe: this file just defines functions on the Overworld class.
$text = $text.TrimEnd() + "`r`n" + $worldBlock + "`r`n"

Write-TextFile (Join-Path $survival $rel) $text
Write-Host "  patched    $rel  (cell reload handler)"

# -- 4. Invalidate the content cache -------------------------------------------
# Scrap Mechanic compiles the content databases into $CACHE_DATA/Bundle/*.cbo and
# reuses them. Observed 2026-08-09: core_data.cbo was NOT rebuilt after the game
# files changed, so patched content silently had no effect. Clearing it forces a
# rebuild on next launch.
#
# ONLY core_data.cbo. Clearing the whole folder caused a real regression: the
# game regenerates a bundle only when it next needs it, and customization_data.cbo
# was never regenerated, which made the player character invisible everywhere
# including the character editor. Our patches only ever affect tools.json and
# inventoryDescriptions.json, both of which live in core_data.cbo.
Write-Host ""
Write-Host "Step 4/4  Clearing the content cache so the game picks up the changes"

# Scratch blueprint copies written by the blueprint placer.
#
# The world script rewrites each Workshop creation before importing it (it sets
# every body's physics "type") and saves the result beside the game's own
# LocalBlueprints. The paths include the creation id and the type, so within a
# session the engine's by-path caching is harmless.
#
# The case that is NOT harmless is a Workshop creation being UPDATED: same id,
# different contents, and a cached parse of the old version. Deleting them here
# closes that hole, because a Workshop update means re-running the generator and
# this installer anyway.
#
# Also clears modmanager_place.blueprint, the single shared filename an earlier
# version used, which is what made selecting one creation spawn another.
$localBlueprints = Join-Path $GamePath "Survival\LocalBlueprints"
if (Test-Path $localBlueprints) {
    $scratch = @(Get-ChildItem (Join-Path $localBlueprints "modmanager_*.blueprint") -ErrorAction SilentlyContinue)
    if ($scratch.Count -gt 0) {
        $scratch | Remove-Item -Force
        Write-Host ("  cleared    {0} scratch blueprint copy/copies from Survival\LocalBlueprints" -f $scratch.Count)
    }
}

$cacheBundle = Join-Path $GamePath "Cache\Bundle"
$cacheBackup = Join-Path $backupRoot "cache"
if (Test-Path $cacheBundle) {
    if (-not (Test-Path $cacheBackup)) { New-Item -ItemType Directory -Force -Path $cacheBackup | Out-Null }
    $target = Join-Path $cacheBundle "core_data.cbo"
    if (Test-Path $target) {
        $keep = Join-Path $cacheBackup "core_data.cbo"
        if (-not (Test-Path $keep)) { Copy-Item $target $keep }
        Remove-Item $target -Force
        Write-Host "  cleared    Cache\Bundle\core_data.cbo (rebuilds on next launch)"
    } else {
        Write-Host "  core_data.cbo already absent - will rebuild"
    }

    # Compiled mesh cache. The game caches each .dae as a .mco keyed by path AND
    # vertex format, so one model produces two of them: one skinned (the tool in
    # your hands) and one not (the inventory preview). Replacing the .dae does
    # NOT invalidate them -- that is how we ended up holding a pitchfork while
    # the preview correctly showed a mattock. Drop ours so both recompile.
    #
    # The pattern list is derived from the meshes we actually copy rather than
    # hardcoded. It used to be the literal string "char_foliage_eraser*", so the
    # moment a second mod shipped a mesh its stale caches would have been left
    # behind and the same confusing half-updated tool would have come back.
    $meshNames = @($copyFiles |
        Where-Object { $_.src -like "*.dae" } |
        ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.src) } |
        Select-Object -Unique)

    $meshCache = Join-Path $GamePath "Cache\Mesh"
    if ((Test-Path $meshCache) -and $meshNames.Count -gt 0) {
        foreach ($mco in Get-ChildItem $meshCache -Recurse -File -ErrorAction SilentlyContinue) {
            foreach ($name in $meshNames) {
                if ($mco.Name -like "$name*") {
                    Remove-Item $mco.FullName -Force
                    Write-Host "  cleared    Cache\Mesh\$($mco.Name)"
                    break
                }
            }
        }
    }

    # Compiled TEXTURE cache, and exactly the same trap as the mesh cache above.
    # The game compiles each .tga to a .tco named <texture>_<hash>.tco, and
    # replacing the .tga does NOT invalidate it.
    #
    # This cost a long detour. Three rounds of recolouring the pipe wrench had no
    # effect in game whatsoever: the player kept seeing a near-white head with a
    # glossy sheen, which was the FIRST texture, still cached, while the .tga on
    # disk had long since changed. Every judgement about the colours was being made
    # against a stale file.
    $texNames = @($copyFiles |
        Where-Object { $_.src -like "*.tga" } |
        ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.src) } |
        Select-Object -Unique)

    $texCache = Join-Path $GamePath "Cache\Textures"
    if ((Test-Path $texCache) -and $texNames.Count -gt 0) {
        foreach ($tco in Get-ChildItem $texCache -Recurse -File -Filter *.tco -ErrorAction SilentlyContinue) {
            foreach ($name in $texNames) {
                if ($tco.Name -like "$name*") {
                    Remove-Item $tco.FullName -Force
                    Write-Host "  cleared    Cache\Textures\$($tco.Name)"
                    break
                }
            }
        }
    }

    # Safety net: put back any bundle a previous run removed but the game never
    # regenerated. Missing bundles cause subtle breakage like invisible characters.
    foreach ($b in Get-ChildItem $cacheBackup -Filter *.cbo -File -ErrorAction SilentlyContinue) {
        if ($b.Name -eq "core_data.cbo") { continue }
        $dest = Join-Path $cacheBundle $b.Name
        if (-not (Test-Path $dest)) {
            Copy-Item $b.FullName $dest
            Write-Host "  restored   Cache\Bundle\$($b.Name) (was missing)"
        }
    }
} else {
    Write-Host "  (no cache bundle folder found - nothing to clear)"
}

Write-Host ""
Write-Host "Installed." -ForegroundColor Green
Write-Host ""
Write-Host "In game:" -ForegroundColor Cyan
Write-Host "  Survival, Creative and Custom Games   type /mods in chat"
Write-Host ""
Write-Host "Tools for enabled mods are added to your Survival inventory automatically."
Write-Host ""
# Reported by the author of the Scrap Mechanic Vortex extension and worth
# passing on: the game itself can crash while rebuilding the cache we just
# cleared. It is the game's own cache generation at fault, not the patch, and
# launching again works. Without this note a crash on the very first launch
# reads as "the mod broke my game".
Write-Host "IF THE GAME CRASHES ON THE FIRST LAUNCH AFTER INSTALLING:" -ForegroundColor Yellow
Write-Host "just launch it again. Scrap Mechanic sometimes crashes while rebuilding" -ForegroundColor Yellow
Write-Host "its cache, which it has to do once after any change to game files. It" -ForegroundColor Yellow
Write-Host "may take a couple of attempts, and is nothing to do with the patch." -ForegroundColor Yellow
Write-Host ""
Write-Host "That first launch is also slower than usual while the cache rebuilds."
Write-Host "One slow load, then it is back to normal speed."
