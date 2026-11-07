@echo off
REM ---------------------------------------------------------------------------
REM  Installs this mod into the Scrap Mechanic Mod Manager.
REM
REM  Double-click it. Nothing to configure.
REM
REM  Close Scrap Mechanic first - the mod cannot be added while the game has its
REM  files open.
REM
REM  FOR MOD AUTHORS: this file and Install-ThisMod.ps1 beside it are free to use.
REM  Copy both into your own mod's zip and it installs itself. Nothing in either
REM  file names a particular mod - the script installs whichever folder next to it
REM  contains a mod.lua - so neither needs editing.
REM ---------------------------------------------------------------------------

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-ThisMod.ps1"
