<#
 Erzeugt aus Projekt-Installer.ps1 eine eigenständige EXE (PS2EXE).
 Aufruf:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Projekt-Installer.ps1
 Symbol: Liegt neben diesem Skript eine setup.ico, wird sie eingebettet
 (erzeugen aus einem PNG mit New-Icon.ps1).
#>
[CmdletBinding()]
param(
    [string]$IconFile = 'setup.ico',
    [string]$Version  = '2.0.0.0'
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Installiere Modul ps2exe (PowerShell Gallery) ...'
    Install-Module ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$src = Join-Path $PSScriptRoot 'Projekt-Installer.ps1'
$dst = Join-Path $PSScriptRoot 'Projekt-Installer.exe'
if (-not (Test-Path -LiteralPath $src)) { throw "Quelldatei nicht gefunden: $src" }

# Metadaten muessen ASCII ohne " und \ sein - PS2EXE schreibt sie unmaskiert
# als C#-Attribute, sonst bricht der Compiler ab (error CS1026).
function Get-SafeMetaText {
    param([string]$Text)
    $t = $Text -replace '"', "'" -replace '\\', '/'
    $t = $t -creplace 'ä', 'ae' -creplace 'ö', 'oe' -creplace 'ü', 'ue' `
            -creplace 'Ä', 'Ae' -creplace 'Ö', 'Oe' -creplace 'Ü', 'Ue' -creplace 'ß', 'ss'
    ($t -replace '[^\x20-\x7E]', '').Trim()
}

$params = @{
    inputFile    = $src
    outputFile   = $dst
    noConsole    = $true
    requireAdmin = $true
    STA          = $true
    x64          = $true
    version      = $Version
    title        = (Get-SafeMetaText 'Projekt-Installer')
    description  = (Get-SafeMetaText 'Richtet ein Projekt auf Basis der Projektvorlage ein (IIS, MySQL, .env, Konsole)')
    company      = (Get-SafeMetaText 'Intern')
    product      = (Get-SafeMetaText 'Projekt-Installer')
    copyright    = (Get-SafeMetaText ('(c) ' + (Get-Date).Year))
}

$ico = Join-Path $PSScriptRoot $IconFile
if (Test-Path -LiteralPath $ico) {
    $params.iconFile = $ico
    Write-Host "Symbol: $ico"
} else {
    Write-Warning "Keine Symboldatei '$IconFile' gefunden - die EXE bekommt das Standardsymbol."
}

$before = if (Test-Path -LiteralPath $dst) { (Get-Item -LiteralPath $dst).LastWriteTimeUtc } else { [datetime]::MinValue }

Invoke-ps2exe @params

if (-not (Test-Path -LiteralPath $dst) -or (Get-Item -LiteralPath $dst).LastWriteTimeUtc -le $before) {
    throw 'Es wurde keine neue EXE erzeugt - PS2EXE hat abgebrochen. Details mit "Invoke-ps2exe @params -verbose" pruefen.'
}

Write-Host "Fertig: $dst"
Write-Host 'Nicht vergessen: projekte.json muss neben der EXE liegen.'
