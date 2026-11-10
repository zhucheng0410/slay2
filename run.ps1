# CardRelicForge launcher. Pure ASCII on purpose: Windows PowerShell 5.1
# reads BOM-less .ps1 files as ANSI, so any non-ASCII byte here would break it.

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
if ([string]::IsNullOrEmpty($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Definition }

function Resolve-Engine([string]$path) {
    if ([string]::IsNullOrEmpty($path)) { return "" }
    if (-not (Test-Path $path)) { return "" }
    # The *_console.exe shipped with Godot mono is a ~200 KB re-launcher stub.
    # Always prefer the real engine binary next to it.
    if ([System.IO.Path]::GetFileName($path) -like "*_console.exe") {
        $real = $path -replace "_console\.exe$", ".exe"
        if (Test-Path $real) { return $real }
    }
    return $path
}

# forge-paths.txt is OPTIONAL and overrides the auto-detected engine. Read it as
# UTF-8 explicitly: PowerShell 5.1's Get-Content would decode it with the system
# ANSI codepage. (Note: run.cmd reads it too, so keep its paths ASCII-only.)
$pathsFile = Join-Path $here "forge-paths.txt"
$godot = ""
$userdir = ""
if (Test-Path $pathsFile) {
    $lines = [System.IO.File]::ReadAllLines($pathsFile, [System.Text.Encoding]::UTF8)
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.StartsWith("godot=")) { $godot = $t.Substring(6).Trim() }
        if ($t.StartsWith("userdir=")) { $userdir = $t.Substring(8).Trim() }
    }
}
$godot = Resolve-Engine $godot

if ([string]::IsNullOrEmpty($godot)) {
    $parent = Split-Path -Parent $here
    $candidates = @(
        (Join-Path $parent "Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64.exe"),
        (Join-Path $parent "Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64.exe"),
        (Join-Path $here "Godot_v4.5.1-stable_mono_win64\Godot_v4.5.1-stable_mono_win64.exe")
    )
    foreach ($c in $candidates) {
        $r = Resolve-Engine $c
        if (-not [string]::IsNullOrEmpty($r)) { $godot = $r; break }
    }
}

if ([string]::IsNullOrEmpty($godot)) {
    Write-Host "Godot 4.5.1 mono executable was not found."
    Write-Host "Put a godot= line into forge-paths.txt next to this script, e.g.:"
    Write-Host "  godot=E:\path\to\Godot_v4.5.1-stable_mono_win64.exe"
    exit 1
}

if ([string]::IsNullOrEmpty($userdir)) {
    $userdir = Join-Path $here ".forge_userdata"
}
if (-not (Test-Path $userdir)) { New-Item -ItemType Directory -Path $userdir | Out-Null }
$env:APPDATA = $userdir

Write-Host "Launching CardRelicForge..."
Write-Host "  engine : $godot"
Write-Host "  userdir: $userdir"

# This is a runtime project (run/main_scene), so a plain launch opens the tool
# window directly. No --editor-pid, no plugin step.
& $godot --path $here
exit $LASTEXITCODE
