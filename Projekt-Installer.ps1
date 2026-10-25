<#
================================================================================
 SNAIL - Simple New-project Automation & Installation Launcher  -  Version 7.4
================================================================================
 Installiert und aktualisiert Anwendungen auf Basis der "projektvorlage"
 (PHP 8.5+, IIS, PostgreSQL 18, config.php) auf einem Windows Server, der vorher
 mit WIPP eingerichtet wurde (IIS, PHP, PostgreSQL, pgAdmin). Der Vertrag
 steht in der projektvorlage: docs/03-installation-betrieb.md.

 KATALOG UND SERVER
   projekte.json (neben dieser Datei bzw. der EXE) ist der KATALOG: welche
   Programme es gibt (dienste). Sie wird mit SNAIL ausgeliefert und bei jedem
   Update mitkopiert. Was auf DIESEM Server installiert ist, liest SNAIL vom
   Server: C:\AK\*\config.php -> php bin\console info (Dienst, Installation,
   URL, Pfade, Datenbank ohne Passwort, Upload-Grenze), der Port aus dem
   IIS-Binding, der Mandanten-Name aus der services.json.

 ABLAUF (alle Schritte wiederholbar)
   Neu installieren (Katalog -> Angaben -> Pruefen):
     Programmcode aus der GitHub-ZIP (Zwischenordner wird erkannt) oder
     vorhandenem Ordner -> Datenordner -> IIS (App-Pool, Website, Binding
     http *:<port>:, anonyme Anfragen als App-Pool-Benutzer, Upload-Grenze)
     -> Rechte (SIDs) -> optional Firewallregel -> PostgreSQL (Rolle +
     Datenbank) -> config.php -> migrate -> user:create -> services.json ->
     Windows-Aufgabe (einmal anstossen) -> check -> tools\windows-pruefung.ps1
   Vorhandene Installation:
     ohne ZIP = Einrichtung wiederholen (alles angleichen, Code bleibt);
     mit ZIP  = Aktualisieren: Sicherung (pg_dump + config.php nach
     <Datenordner>\Sicherung, abwaehlbar nur mit Bestaetigung) -> App-Pool
     anhalten -> robocopy /MIR (config.php mit vollem Pfad ausgenommen) ->
     IIS/Rechte angleichen -> app.key nachtragen (nur wenn er fehlt) -> migrate
     -> services.json -> Aufgabe -> check
   app.key (Schluessel fuer Geheimnisse in der Datenbank): bei der
   Neuinstallation erzeugt; bei Wiederholen/Aktualisieren nur ein fehlender
   oder leerer nachgetragen, ein vorhandener NIE geaendert (Update-
   InstalledConfigKeys: php -l, Vergleich aller Werte, Sicherung, atomar).
   Bindings einer vorhandenen Website fasst SNAIL nie an.

 NAMEN
   Erste Installation eines Dienstes: <Ordner> = <dienst>, jede weitere
   <dienst>-<installation>. IIS-Site, App-Pool und Windows-Aufgabe
   ("\AK\<Ordner> Aufgabenplanung") heissen wie der Ordner, Datenbank/Rolle
   <ordner>/<ordner>_user (- wird zu _).

 SCHNITTSTELLE ZU WIPP (C:\ProgramData\WIPP, Format 1)
   php-pfad.txt               Pfad zu php.exe
   postgres.json              bin, port, version, host, superuser (ohne Passwort)
   postgres-zugangsdaten.txt  Superuser-Passwort; fehlt die Datei, wird das
                              Passwort auf der Seite "Pruefen" eingegeben
 Passwoerter gehen nie ueber die Kommandozeile: psql/pg_dump bekommen sie
 ueber eine temporaere pgpass-Datei (ACL nur Administratoren/SYSTEM), die
 Datenbankrolle nur als SCRAM-Hash.

 ABLAGE (C:\ProgramData\SNAIL, nur Administratoren und SYSTEM)
   snail_JJJJMMTT_HHMMSS.log  Protokoll je Lauf
   zugangsdaten\<Ordner>.txt   DB-Passwort, app.key und Admin-Initialpasswort
   pruefberichte\...           Berichte von tools\windows-pruefung.ps1
 Sicherungen vor einem Update: <Datenordner>\Sicherung\<Zeit>\ (ebenfalls nur
 Administratoren/SYSTEM; robocopy /MIR wuerde sie im Programmordner loeschen),
 dort auch config.php.vor-snail-<Zeit> vor dem Nachtragen von app.key.

 ALS EXE: Build-Projekt-Installer.ps1 (PS2EXE, -noConsole -requireAdmin -STA)

 HINWEISE
   - Diese Datei ist UTF-8 mit BOM gespeichert (CRLF). Kodierung beim
     Bearbeiten beibehalten, sonst gehen die Umlaute kaputt.
   - Laeuft unter Windows PowerShell 5.1 auf Windows Server 2022/2025.
================================================================================
#>

[CmdletBinding()]
param(
    [switch]$NoRelaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.Windows.Forms.Application]::EnableVisualStyles()

# ==============================================================================
#  0) Administratorrechte und STA-Modus sicherstellen
# ==============================================================================

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Läuft das Ganze als PS2EXE-Exe, ist $PSCommandPath leer. Dann ist die
# eigene Exe der Neustart-Kandidat, sonst powershell.exe mit dem Skript.
$script:IsCompiled = [string]::IsNullOrEmpty($PSCommandPath)
$script:SelfPath   = if ($script:IsCompiled) {
    [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
} else {
    $PSCommandPath
}
$script:SelfDir = Split-Path -Parent $script:SelfPath

if (-not $NoRelaunch) {
    $isAdmin = Test-IsAdmin
    $isSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
    if (-not $isAdmin -or -not $isSta) {
        try {
            if ($script:IsCompiled) {
                if (-not $isSta) {
                    throw 'Die EXE wurde ohne den Schalter -STA erzeugt. Bitte mit Build-Projekt-Installer.ps1 neu erstellen.'
                }
                Start-Process -FilePath $script:SelfPath -ArgumentList '-NoRelaunch' -Verb RunAs
            } else {
                $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$script:SelfPath`"", '-NoRelaunch')
                if ($isAdmin) {
                    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList
                } else {
                    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
                }
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "SNAIL benötigt Administratorrechte und konnte nicht neu gestartet werden.`r`n`r`n" +
                "$($_.Exception.Message)`r`n`r`n" +
                'Bitte per Rechtsklick "Als Administrator ausführen" starten.',
                'SNAIL', 'OK', 'Warning') | Out-Null
        }
        exit
    }
}

# ==============================================================================
#  1) Konstanten und Zustand
# ==============================================================================

$script:AppTitle   = 'SNAIL'
$script:AppVersion = '7.4'
$script:FormatVersion = 1        # Format des Katalogs, der services.json und der WIPP-Dateien

$script:JsonPath   = Join-Path $script:SelfDir 'projekte.json'
$script:JsonDir    = $script:SelfDir
$script:AppCmd     = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
$script:PowerShell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Schnittstelle zu WIPP (schreibt WIPP, liest SNAIL)
$script:WippDir      = Join-Path $env:ProgramData 'WIPP'
$script:WippPhpFile  = Join-Path $script:WippDir 'php-pfad.txt'
$script:WippPgJson   = Join-Path $script:WippDir 'postgres.json'
$script:WippPgCred   = Join-Path $script:WippDir 'postgres-zugangsdaten.txt'

# Eigene Ablage
$script:SnailDir   = Join-Path $env:ProgramData 'SNAIL'
$script:LogFile    = Join-Path $script:SnailDir ('snail_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
$script:CredDir    = Join-Path $script:SnailDir 'zugangsdaten'
$script:ReportDir  = Join-Path $script:SnailDir 'pruefberichte'
$script:StagingDir = Join-Path $env:TEMP 'SNAIL'

# Bekannte SIDs - damit es auf jeder Sprachversion von Windows passt
$script:SidAdmins = 'S-1-5-32-544'
$script:SidSystem = 'S-1-5-18'
$script:SidUsers  = 'S-1-5-32-545'

# Firewallregel "im Netzwerk erreichbar": wie WIPP "Lokales Netzwerk"
$script:FwProfiles = @('Domain', 'Private')
$script:FwRemote   = @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', 'fc00::/7', 'fe80::/10')

# Einstellungen (aus projekte.json -> einstellungen)
$script:Settings = [pscustomobject]@{
    ProgRoot  = (Join-Path $env:SystemDrive 'AK')
    DataRoot  = 'D:\AK'
    Zeitzone  = 'Europe/Berlin'
    PhpExe    = ''
    PsqlBin   = ''
    PgPort    = 0
    PortStart = 21100
}

$script:Services      = @{}     # Katalog: dienste, Schluessel = key
$script:ServiceList   = @()     # Katalog in Dateireihenfolge
$script:Instances     = @()     # auf dem Server gefundene Installationen
$script:JsonErrors    = @()     # Meldungen beim Lesen des Katalogs
$script:Target        = $null   # gewaehlte Installation (vorhanden) bzw. Eingaben (neu)
$script:NewService    = $null   # gewaehlter Katalog-Dienst fuer eine Neuinstallation
$script:Plan          = $null   # Ergebnis der Pruefung
$script:CheckOk       = $false
$script:Busy          = $false
$script:AbortRequested = $false
$script:CloseAfterAbort = $false
$script:Result        = @{}
$script:AppIcon       = $null
$script:CurrentPage   = 'select'
$script:Staging       = $null   # entpackte ZIP (Schluessel: Pfad + Zeitstempel)
$script:PathOverride  = $null   # einzeln angepasste Datenpfade (Dialog "Details")

# ==============================================================================
#  2) Protokoll und kleine Helfer
# ==============================================================================

function Invoke-UiPump { [System.Windows.Forms.Application]::DoEvents() }

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step')][string]$Level = 'Info'
    )
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line  = '[{0}] {1}' -f $stamp, $Message
    try {
        if (-not (Test-Path -LiteralPath $script:SnailDir)) { Initialize-SnailDir }
        Add-Content -LiteralPath $script:LogFile -Value ('{0} {1}' -f $Level.PadRight(5), $line) -Encoding UTF8
    } catch { }

    if ($script:LogBox) {
        $color = switch ($Level) {
            'Ok'    { [System.Drawing.Color]::FromArgb(126, 211, 133) }
            'Warn'  { [System.Drawing.Color]::FromArgb(240, 180,  90) }
            'Error' { [System.Drawing.Color]::FromArgb(240, 120, 110) }
            'Step'  { [System.Drawing.Color]::FromArgb(120, 190, 240) }
            default { [System.Drawing.Color]::FromArgb(210, 210, 210) }
        }
        $prefix = switch ($Level) {
            'Ok'    { '  OK   ' }
            'Warn'  { '  !    ' }
            'Error' { '  X    ' }
            'Step'  { '  >    ' }
            default { '       ' }
        }
        $script:LogBox.SelectionStart  = $script:LogBox.TextLength
        $script:LogBox.SelectionLength = 0
        $script:LogBox.SelectionColor  = $color
        $script:LogBox.AppendText(($prefix + $line + [Environment]::NewLine))
        $script:LogBox.ScrollToCaret()
    }
    Invoke-UiPump
}

function Set-Status {
    param([string]$Text)
    if ($script:StatusLabel) { $script:StatusLabel.Text = $Text }
    Invoke-UiPump
}

function Set-Busy {
    param([bool]$On)
    $script:Busy = $On
    foreach ($b in @($script:BtnBack, $script:BtnNext, $script:BtnReload, $script:BtnOpenJson, $script:BtnRecheck, $script:BtnTestDb)) {
        if ($b) { $b.Enabled = -not $On }
    }
    if ($script:Form) {
        $script:Form.Cursor = if ($On) { [System.Windows.Forms.Cursors]::AppStarting }
                              else      { [System.Windows.Forms.Cursors]::Default }
    }
    Invoke-UiPump
}

<#
 Ein Argument fuer die Windows-Kommandozeile maskieren (Regeln von
 CommandLineToArgvW/MSVCRT): in Anfuehrungszeichen, wenn Leerzeichen oder "
 vorkommen; Backslashes vor einem " bzw. am Ende verdoppeln. Ohne das wuerde
 ein Pfad wie "D:\" das schliessende Anfuehrungszeichen verschlucken.
#>
function ConvertTo-CmdArg {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq [char]'\') { $bs++; continue }
        if ($ch -eq [char]'"') {
            [void]$sb.Append([char]'\', (2 * $bs + 1))
            [void]$sb.Append([char]'"')
            $bs = 0
            continue
        }
        if ($bs -gt 0) { [void]$sb.Append([char]'\', $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append([char]'\', (2 * $bs)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-CmdArgs {
    param([string[]]$Values)
    return @($Values | ForEach-Object { ConvertTo-CmdArg $_ })
}

<#
 Startet ein Konsolenprogramm ohne sichtbares Fenster und liefert Ausgabe und
 Exitcode. In einer -noConsole-Exe würde bei "& exe" sonst jedes Mal kurz ein
 schwarzes Fenster aufblitzen.
   -ArgumentList  bereits maskierte Argumente (ConvertTo-CmdArgs), werden nur
                  mit Leerzeichen verbunden
   -StdIn         geht als UTF-8 ohne BOM an die Standardeingabe (psql). Die
                  Standardeingabe wird immer umgeleitet und geschlossen - so
                  wartet kein Programm auf eine Eingabe, die nie kommt
   -Environment   Umgebungsvariablen nur fuer diesen Kindprozess (PGPASSFILE);
                  $null entfernt eine geerbte Variable
   -Utf8Output    Ausgabe als UTF-8 lesen (php.exe, psql)
#>
function Invoke-ExeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$StdIn = '',
        [string]$WorkingDirectory = '',
        [hashtable]$Environment = @{},
        [switch]$Utf8Output,
        [int]$TimeoutSec = 600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    if ($ArgumentList.Count -gt 0) { $psi.Arguments = ($ArgumentList -join ' ') }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($k in $Environment.Keys) {
        if ($null -eq $Environment[$k]) { [void]$psi.EnvironmentVariables.Remove([string]$k) }
        else { $psi.EnvironmentVariables[[string]$k] = [string]$Environment[$k] }
    }
    if ($Utf8Output) {
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding  = New-Object System.Text.UTF8Encoding($false)
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        [void]$proc.Start()
        # Asynchron lesen, sonst blockieren sich volle Puffer gegenseitig
        $errTask = $proc.StandardError.ReadToEndAsync()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        # UTF-8 ohne BOM direkt in den BaseStream: der StreamWriter kodiert
        # unter Windows PowerShell (.NET Framework) in der ANSI-Codepage,
        # StandardInputEncoding gibt es dort nicht. Beendet sich das Programm
        # vorher (psql bei falschem Passwort), ist die Leitung schon zu - das
        # Ergebnis steht dann im Exitcode.
        try {
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StdIn)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
            $proc.StandardInput.Close()
        } catch [System.IO.IOException] {
            Write-Verbose "Standardeingabe geschlossen: $($_.Exception.Message)"
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 100
            Invoke-UiPump
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                try { $proc.Kill() } catch { }
                throw "$([System.IO.Path]::GetFileName($FilePath)) antwortet nicht (Zeitüberschreitung nach $TimeoutSec s)."
            }
        }
        $proc.WaitForExit()
        $out = [string]$outTask.Result
        $err = [string]$errTask.Result
        [pscustomobject]@{
            ExitCode = [int]$proc.ExitCode
            Output   = $out
            Error    = $err
            Lines    = @((($out + "`n" + $err) -split "`r?`n") | Where-Object { $_.Trim() -ne '' })
        }
    } finally {
        $proc.Dispose()
    }
}

# appcmd: wie in v5 - nur Argumente mit Leerzeichen in Anfuehrungszeichen.
# Werte wie /userName:"" muessen unveraendert ankommen.
function Invoke-AppCmd {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $quoted = foreach ($a in $Arguments) {
        if ($a -match '\s' -and $a -notmatch '^".*"$') { '"' + $a + '"' } else { $a }
    }
    $r = Invoke-ExeCapture -FilePath $script:AppCmd -ArgumentList @($quoted) -TimeoutSec 120
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Output = ($r.Lines -join ' '); Lines = $r.Lines }
}

function Open-InBrowser {
    param([Parameter(Mandatory)][string]$Url)
    try {
        Start-Process $Url -ErrorAction Stop
        Write-Log "Browser geöffnet: $Url" 'Ok'
    } catch {
        Write-Log 'Kein Standardbrowser registriert - versuche Edge.' 'Warn'
        try { Start-Process 'msedge.exe' -ArgumentList $Url -ErrorAction Stop }
        catch { Write-Log "Adresse konnte nicht geöffnet werden: $Url" 'Error' }
    }
}

function Open-InNotepad {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Start-Process notepad.exe -ArgumentList "`"$Path`""
    } else {
        Show-Warn "Datei nicht gefunden:`r`n$Path"
    }
}

function Show-Info  { param([string]$Text, [string]$Title = 'Hinweis')
    [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'OK', 'Information') | Out-Null }
function Show-Warn  { param([string]$Text, [string]$Title = 'Achtung')
    [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'OK', 'Warning') | Out-Null }
function Show-Confirm { param([string]$Text, [string]$Title = 'Bestätigen')
    ([System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'YesNo', 'Question') -eq 'Yes') }

# Zufallspasswort aus Buchstaben und Ziffern (ohne Verwechsler), erstes Zeichen
# immer Buchstabe/Ziffer. Der Wert landet in config.php und als SCRAM-Hash in
# PostgreSQL - Sonderzeichen braeuchten dort nichts, machen aber das Abtippen
# schwer. 24 Stellen aus 57 Zeichen (~140 Bit).
function New-RandomPassword {
    param([int]$Length = 24)
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $limit = 256 - (256 % $alphabet.Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object System.Collections.Generic.List[char]
        $b = New-Object byte[] 1
        while ($chars.Count -lt $Length) {
            $rng.GetBytes($b)
            if ($b[0] -lt $limit) { $chars.Add($alphabet[$b[0] % $alphabet.Length]) }
        }
        return (-join $chars)
    } finally {
        $rng.Dispose()
    }
}

# Schluessel fuer app.key (Geheimnisse in der Datenbank, SecretBox der Vorlage):
# Base64 (Standard-Alphabet mit =) von 32 Zufallsbytes = 44 Zeichen. Der Wert
# kommt nie ins Protokoll und nie auf eine Kommandozeile.
function New-AppKey {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

# Gueltiger app.key? Wie SecretBox::parseKey der Vorlage: 44 Zeichen Base64, 32 Byte.
function Test-AppKey {
    param([AllowNull()][AllowEmptyString()][string]$Key)
    $k = ([string]$Key).Trim()
    if ($k -cnotmatch '^[A-Za-z0-9+/]{43}=$') { return $false }
    try { return ([Convert]::FromBase64String($k).Length -eq 32) } catch { return $false }
}

# ==============================================================================
#  3) Rechte auf Dateien mit Geheimnissen, eigene Ablage
# ==============================================================================

# Zugriff auf eine Datei oder einen Ordner auf Administratoren und SYSTEM
# beschraenken - fuer alles, was Passwoerter im Klartext enthaelt.
function Protect-AdminOnly {
    param([Parameter(Mandatory)][string]$Path)
    $isDir = (Get-Item -LiteralPath $Path -Force) -is [System.IO.DirectoryInfo]
    $acl = if ($isDir) { New-Object System.Security.AccessControl.DirectorySecurity }
           else        { New-Object System.Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($script:SidAdmins, $script:SidSystem)) {
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        if ($isDir) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        } else {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
        }
    }
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($script:SidAdmins)))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

<#
 Schreibt eine Datei mit Geheimnis. Reihenfolge ist Absicht (wie in WIPP):
 erst leere Datei, dann Rechte auf Administratoren/SYSTEM, erst danach der
 Inhalt - so liegt das Passwort nie in einer Datei mit geerbten Rechten.
#>
function Write-SecretFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    [System.IO.File]::WriteAllText($Path, '', (New-Object System.Text.UTF8Encoding($false)))
    Protect-AdminOnly -Path $Path
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# C:\ProgramData\SNAIL: Protokolle, Zugangsdaten, Sicherungen - nur fuer
# Administratoren und SYSTEM (ohne das erbt der Ordner "Benutzer: Lesen").
function Initialize-SnailDir {
    if (-not (Test-Path -LiteralPath $script:SnailDir)) {
        New-Item -ItemType Directory -Path $script:SnailDir -Force | Out-Null
    }
    try {
        if (-not (Get-Acl -LiteralPath $script:SnailDir).AreAccessRulesProtected) { Protect-AdminOnly -Path $script:SnailDir }
    } catch { }
}

# ==============================================================================
#  4) Katalog (projekte.json) lesen und prüfen
# ==============================================================================

$script:JsonTemplate = @'
{
  "_doku": "Katalog fuer SNAIL 7 (projektvorlage: PHP, IIS, PostgreSQL, config.php). Liegt neben der EXE, wird mit SNAIL ausgeliefert und bei jedem Update mitkopiert. Er nennt nur die Programme ('dienste'); was auf dem Server installiert ist, liest SNAIL aus C:\\AK\\*\\config.php. Mandant, Port, Adresse usw. werden bei der Neuinstallation eingegeben.",
  "format": 1,

  "einstellungen": {
    "_doku": "programmOrdner: Programme (C:\\AK\\<Ordner>), dort liegen auch services.json und logos. datenOrdner: Vorschlag fuer Data/Cache/Logs/Temp (D:\\AK\\<Ordner>; fehlt das Laufwerk: C:\\AKDaten\\<Ordner>). portStart: ab hier schlaegt SNAIL den naechsten freien Port vor. phpExe/psqlBin/postgresPort nur setzen, um die WIPP-Dateien in C:\\ProgramData\\WIPP zu uebersteuern (leer/0 = automatisch).",
    "programmOrdner": "C:\\AK",
    "datenOrdner": "D:\\AK",
    "zeitzone": "Europe/Berlin",
    "portStart": 21100,
    "phpExe": "",
    "psqlBin": "",
    "postgresPort": 0
  },

  "dienste": [
    {
      "_doku": "key = app.service (a-z, 0-9, _ und -, max. 64 Zeichen). icon: Lucide-Name aus dem Designsystem (Standard box). tone: info, success, warning, danger, primary, purple, amber, muted, neutral. logo: Bilddatei relativ zur projekte.json, z. B. logos/olaf.svg (svg, png, webp, jpg; max. 1 MB); SNAIL kopiert es nach C:\\AK\\logos\\<key>.<ext>. zip: vorgeschlagene ZIP-Datei (relativ zur projekte.json). uploadsMaxMb: Vorschlag fuer uploads.max_mb. phpModule: zusaetzliche PHP-Module. braucht: z. B. [\"python\"].",
      "key": "projekt",
      "name": "Projektvorlage",
      "icon": "box",
      "tone": "info",
      "logo": "",
      "description": "Testinstallation der Vorlage",
      "zip": "projektvorlage-main.zip",
      "uploadsMaxMb": 25,
      "phpModule": [],
      "braucht": []
    }
  ]
}
'@

# Schluessel fuer services.json, app.service, app.installation und Ordner -
# dieselbe Regel wie ServiceDirectory der Vorlage
function Test-ServiceKey {
    param([string]$Key)
    return ($null -ne $Key -and $Key -cmatch '^[a-z0-9][a-z0-9_-]{0,63}$')
}

# Bezeichner fuer Rolle und Datenbank: so, dass er in PostgreSQL ohne
# Anfuehrungszeichen funktioniert (Kleinbuchstaben, Ziffern, _; max. 63 Byte)
function Test-PgIdentifier {
    param([string]$Name, [string]$What = 'Name')
    if ([string]::IsNullOrWhiteSpace($Name)) { return "$What darf nicht leer sein." }
    if ($Name -cnotmatch '^[a-z_][a-z0-9_]{0,62}$') { return "$What '$Name': erlaubt sind Kleinbuchstaben, Ziffern und _, beginnend mit Buchstabe oder _, höchstens 63 Zeichen." }
    if ($Name -like 'pg_*') { return "$What '$Name': Namen mit pg_ sind für PostgreSQL reserviert." }
    if (@('postgres', 'template0', 'template1', 'public') -contains $Name) { return "$What '$Name' ist reserviert." }
    return $null
}

# Standardnamen aus dem Ordnernamen: "projekt-beispiel" -> projekt_beispiel / projekt_beispiel_user
function Get-DefaultDbNames {
    param([Parameter(Mandatory)][string]$Ordner)
    $base = $Ordner.ToLowerInvariant() -replace '[^a-z0-9_]', '_'
    if ($base -notmatch '^[a-z_]') { $base = 'db_' + $base }
    if ($base.Length -gt 58) { $base = $base.Substring(0, 58) }
    return [pscustomobject]@{ Name = $base; User = ($base + '_user') }
}

<#
 Logo eines Dienstes: Dateipfad (relativ zur projekte.json) oder Base64
 (auch als data:-URL). Liefert Bytes und Endung oder eine Fehlermeldung.
 Die Endung kommt aus dem Inhalt, nicht aus dem Dateinamen.
#>
function Get-LogoData {
    param([string]$Value, [string]$BaseDir)
    $res = [pscustomobject]@{ Bytes = $null; Ext = ''; Error = ''; Source = '' }
    if ([string]::IsNullOrWhiteSpace($Value)) { return $res }
    $v = $Value.Trim()
    try {
        if ($v -match '^data:[a-z/+.-]+;base64,(.*)$') {
            $res.Bytes = [Convert]::FromBase64String(($Matches[1] -replace '\s', ''))
            $res.Source = 'Base64'
        } else {
            $file = if ([System.IO.Path]::IsPathRooted($v)) { $v } else { Join-Path $BaseDir $v }
            if ($v.Length -lt 260 -and (Test-Path -LiteralPath $file -PathType Leaf)) {
                $res.Bytes = [System.IO.File]::ReadAllBytes($file)
                $res.Source = $file
            } elseif ($v.Length -ge 64 -and $v -match '^[A-Za-z0-9+/=\s]+$') {
                $res.Bytes = [Convert]::FromBase64String(($v -replace '\s', ''))
                $res.Source = 'Base64'
            } else {
                $res.Error = "Logo-Datei nicht gefunden: $file"
                return $res
            }
        }
    } catch {
        $res.Error = "Logo nicht lesbar: $($_.Exception.Message)"
        $res.Bytes = $null
        return $res
    }
    $b = $res.Bytes
    if ($b.Length -ge 8 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) { $res.Ext = 'png' }
    elseif ($b.Length -ge 3 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8 -and $b[2] -eq 0xFF) { $res.Ext = 'jpg' }
    elseif ($b.Length -ge 12 -and [System.Text.Encoding]::ASCII.GetString($b, 0, 4) -eq 'RIFF' -and
            [System.Text.Encoding]::ASCII.GetString($b, 8, 4) -eq 'WEBP') { $res.Ext = 'webp' }
    else {
        $head = [System.Text.Encoding]::UTF8.GetString($b, 0, [math]::Min($b.Length, 2048))
        if ($head -match '<svg[\s>]') { $res.Ext = 'svg' }
    }
    if ($res.Ext -eq '') { $res.Error = 'Logo: unbekanntes Bildformat (erlaubt: svg, png, webp, jpg).'; $res.Bytes = $null }
    elseif ($b.Length -gt 1048576) { $res.Error = ('Logo: {0:N0} KB - höchstens 1 MB erlaubt.' -f ($b.Length / 1KB)); $res.Bytes = $null }
    return $res
}

# Absoluter Windows-Pfad (C:\... oder \\server\freigabe\...)
function Test-AbsolutePath {
    param([string]$Path)
    return ($Path -match '^[A-Za-z]:\\' -or $Path -match '^\\\\[^\\]+\\[^\\]+')
}

function Get-JsonString {
    param($Value, [string]$Default = '')
    if ($null -eq $Value) { return $Default }
    $s = ([string]$Value).Trim()
    if ($s -eq '') { return $Default }
    return $s
}

$script:KnownNeeds = @('python')

<#
 Prueft den gelesenen Katalog und liefert Einstellungen und Dienste. Fehler
 werden gesammelt, damit die Startseite alle Probleme auf einmal zeigt; ein
 fehlerhafter Dienst wird ausgelassen.
#>
function ConvertFrom-ProjectJson {
    param([Parameter(Mandatory)]$Json, [Parameter(Mandatory)][string]$BaseDir)
    $errors = New-Object System.Collections.Generic.List[string]
    $settings = [pscustomobject]@{
        ProgRoot = $script:Settings.ProgRoot; DataRoot = $script:Settings.DataRoot; Zeitzone = 'Europe/Berlin'
        PhpExe = ''; PsqlBin = ''; PgPort = 0; PortStart = 21100
    }
    $result = [pscustomobject]@{ Settings = $settings; Services = @{}; ServiceList = @(); Errors = $errors }

    if ($null -ne $Json.projekte -and $null -eq $Json.dienste) {
        $errors.Add('Diese projekte.json hat das alte Format (Projektliste mit MySQL und .env). SNAIL 7 braucht den Katalog im Format 1 ("Vorlage anlegen").')
        return $result
    }
    if ([string]$Json.format -ne [string]$script:FormatVersion) {
        $errors.Add("projekte.json: ""format"": $($script:FormatVersion) fehlt oder ist unbekannt ('$($Json.format)').")
        return $result
    }
    if ($null -ne $Json.installationen) {
        $errors.Add('projekte.json: "installationen" wird nicht mehr gelesen - Installationen erkennt SNAIL am Server, Mandant und Port werden bei der Neuinstallation eingegeben.')
    }

    $e = $Json.einstellungen
    if ($e) {
        $settings.ProgRoot = (Get-JsonString $e.programmOrdner $settings.ProgRoot).TrimEnd('\')
        $settings.DataRoot = (Get-JsonString $e.datenOrdner $settings.DataRoot).TrimEnd('\')
        $settings.Zeitzone = Get-JsonString $e.zeitzone $settings.Zeitzone
        $settings.PhpExe   = Get-JsonString $e.phpExe
        $settings.PsqlBin  = Get-JsonString $e.psqlBin
        try { $settings.PgPort = [int]$e.postgresPort } catch { $errors.Add('einstellungen.postgresPort ist keine Zahl.') }
        if ($null -ne $e.portStart -and [string]$e.portStart -ne '') {
            $ps = 0
            try { $ps = [int]$e.portStart } catch { }
            if ($ps -ge 1024 -and $ps -le 65535) { $settings.PortStart = $ps }
            else { $errors.Add('einstellungen.portStart muss zwischen 1024 und 65535 liegen - es gilt 21100.') }
        }
    }
    foreach ($pfad in @($settings.ProgRoot, $settings.DataRoot)) {
        if (-not (Test-AbsolutePath $pfad)) { $errors.Add("einstellungen: '$pfad' ist kein absoluter Pfad.") }
    }

    $services = @{}
    $list = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($d in @($Json.dienste)) {
        $i++
        if ($null -eq $d) { continue }
        $key = Get-JsonString $d.key
        $where = "dienste[$i]" + $(if ($key) { " ('$key')" } else { '' })
        if (-not (Test-ServiceKey $key)) { $errors.Add("${where}: 'key' fehlt oder ist ungültig (a-z, 0-9, _ und -, erstes Zeichen Buchstabe oder Ziffer, max. 64)."); continue }
        if ($services.ContainsKey($key)) { $errors.Add("${where}: Der Dienst '$key' kommt doppelt vor."); continue }
        $name = Get-JsonString $d.name
        if ($name -eq '') { $errors.Add("${where}: 'name' fehlt."); continue }
        $tone = Get-JsonString $d.tone
        if ($tone -ne '' -and @('info', 'success', 'warning', 'danger', 'primary', 'purple', 'amber', 'muted', 'neutral') -cnotcontains $tone) {
            $errors.Add("${where}: tone '$tone' ist ungültig - wird weggelassen.")
            $tone = ''
        }
        $logo = Get-LogoData -Value ([string]$d.logo) -BaseDir $BaseDir
        if ($logo.Error) { $errors.Add("${where}: $($logo.Error) - der App-Switcher zeigt dann das Icon.") }
        $zip = Get-JsonString $d.zip
        if ($zip -and -not [System.IO.Path]::IsPathRooted($zip)) { $zip = Join-Path $BaseDir $zip }
        $upload = 25
        if ($null -ne $d.uploadsMaxMb -and [string]$d.uploadsMaxMb -ne '') {
            try { $upload = [int]$d.uploadsMaxMb } catch { $upload = -1 }
            if ($upload -lt 1 -or $upload -gt 4000) { $errors.Add("${where}: uploadsMaxMb muss zwischen 1 und 4000 liegen - es gilt 25."); $upload = 25 }
        }
        $mods = @($d.phpModule | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
        $needs = @($d.braucht | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ })
        foreach ($n in $needs) { if ($script:KnownNeeds -notcontains $n) { $errors.Add("${where}: braucht '$n' ist unbekannt (bekannt: $($script:KnownNeeds -join ', ')) - wird nicht geprüft.") } }
        $svc = [pscustomobject]@{
            Key = $key; Name = $name; Icon = (Get-JsonString $d.icon); Tone = $tone; Description = (Get-JsonString $d.description)
            Logo = $logo; Zip = $zip; UploadsMaxMb = $upload; PhpModules = $mods; Needs = $needs; InCatalog = $true
        }
        $services[$key] = $svc
        $list.Add($svc)
    }
    if ($list.Count -eq 0 -and $errors.Count -eq 0) { $errors.Add('Der Katalog enthält keine Dienste ("dienste" fehlt oder ist leer).') }
    $result.Services = $services
    $result.ServiceList = $list.ToArray()
    return $result
}

# Ersatz fuer einen Dienst, der installiert ist, aber nicht (mehr) im Katalog
# steht: Name aus services.json bzw. app.name, keine Logo-/Icon-Vorgaben.
function New-PseudoService {
    param([Parameter(Mandatory)][string]$Key, [string]$Name = '')
    return [pscustomobject]@{
        Key = $Key; Name = $(if ($Name) { $Name } else { $Key }); Icon = ''; Tone = ''; Description = ''
        Logo = [pscustomobject]@{ Bytes = $null; Ext = ''; Error = ''; Source = '' }; Zip = ''; UploadsMaxMb = 25
        PhpModules = @(); Needs = @(); InCatalog = $false
    }
}

function Read-ProjectJson {
    $script:Services = @{}
    $script:ServiceList = @()
    $script:JsonErrors = @()
    if (-not (Test-Path -LiteralPath $script:JsonPath)) {
        $script:JsonErrors = @("Der Katalog wurde nicht gefunden: $script:JsonPath")
        return
    }
    try {
        $json = Get-Content -LiteralPath $script:JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $script:JsonErrors = @("projekte.json ist kein gültiges JSON: $($_.Exception.Message)")
        return
    }
    $r = ConvertFrom-ProjectJson -Json $json -BaseDir $script:JsonDir
    $script:Settings    = $r.Settings
    $script:Services    = $r.Services
    $script:ServiceList = $r.ServiceList
    $script:JsonErrors  = @($r.Errors)
}

# Ersatzsymbol: farbiges Quadrat mit dem Anfangsbuchstaben
function New-LetterIcon {
    param([string]$Name, [int]$Index, [int]$Size = 28)
    $palette = @(
        [System.Drawing.Color]::FromArgb(0, 99, 177),
        [System.Drawing.Color]::FromArgb(16, 124, 65),
        [System.Drawing.Color]::FromArgb(191, 87, 0),
        [System.Drawing.Color]::FromArgb(122, 68, 165),
        [System.Drawing.Color]::FromArgb(170, 51, 61),
        [System.Drawing.Color]::FromArgb(0, 130, 135)
    )
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $brush = New-Object System.Drawing.SolidBrush($palette[$Index % $palette.Count])
        $g.FillRectangle($brush, 0, 0, $Size, $Size)
        $brush.Dispose()
        $letter = if ($Name.Length -gt 0) { $Name.Substring(0, 1).ToUpper() } else { '?' }
        $font   = New-Object System.Drawing.Font('Segoe UI', [float]($Size * 0.5), [System.Drawing.FontStyle]::Bold)
        $fmt    = New-Object System.Drawing.StringFormat
        $fmt.Alignment     = 'Center'
        $fmt.LineAlignment = 'Center'
        $rect = New-Object System.Drawing.RectangleF(0, 1, $Size, $Size)
        $g.DrawString($letter, $font, [System.Drawing.Brushes]::White, $rect, $fmt)
        $font.Dispose(); $fmt.Dispose()
    } finally { $g.Dispose() }
    return $bmp
}

# Logo als Bild fuer die Liste (PNG/JPG; SVG und WebP kann System.Drawing nicht)
function Get-ServiceImage {
    param($Service, [int]$Index)
    if ($Service.Logo.Bytes -and @('png', 'jpg') -contains $Service.Logo.Ext) {
        try {
            $ms = New-Object System.IO.MemoryStream(, $Service.Logo.Bytes)
            return [System.Drawing.Image]::FromStream($ms)
        } catch { }
    }
    return (New-LetterIcon -Name $Service.Name -Index $Index)
}

# ==============================================================================
#  5) config.php aus der config.example.php
# ==============================================================================

# PHP-Literal fuer einen Wert: Zeichenkette in '...' (nur \ und ' maskieren),
# Zahl, true/false - genau die Literale, die die Vorlage zulaesst.
function ConvertTo-PhpLiteral {
    param($Value)
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long]) { return ([string]$Value) }
    $s = [string]$Value
    if ($s -match '[\x00-\x1F]') { throw 'Wert für config.php enthält Steuerzeichen (Zeilenumbruch, Tabulator).' }
    return "'" + $s.Replace('\', '\\').Replace("'", "\'") + "'"
}

<#
 Setzt Werte in den Text der config.example.php ein. Zeile fuer Zeile:
   'bereich' => [            -> Bereich betreten
   ],                        -> Bereich verlassen
   'schluessel' => <Literal>,   // Kommentar  -> Literal ersetzen, Rest bleibt
 Kommentare, Reihenfolge und Einrueckung der Vorlage bleiben erhalten.
 $Values: Schluessel in Punkt-Schreibweise ('db.password'). Liefert den Text
 und die Schluessel, die in der Vorlage nicht gefunden wurden.
#>
function Set-ConfigTemplateValues {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)]$Values)
    $literal = "(?:'(?:[^'\\]|\\.)*'|-?\d+(?:\.\d+)?|true|false|null)"
    $rxPair  = [regex]("^(\s*'([A-Za-z0-9_]+)'\s*=>\s*)(" + $literal + ")(\s*,?\s*(?://.*|/\*.*)?)$")
    $rxOpen  = [regex]"^\s*'([A-Za-z0-9_]+)'\s*=>\s*\[\s*(?://.*)?$"
    $rxClose = [regex]'^\s*\]\s*[,;]?\s*(?://.*)?$'

    $todo = @{}
    foreach ($k in $Values.Keys) { $todo[[string]$k] = $true }
    $stack = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $Text -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ($inBlock) {
            if ($trim.Contains('*/')) { $inBlock = $false }
            $out.Add($line); continue
        }
        if ($trim.StartsWith('/*')) {
            if (-not $trim.Contains('*/')) { $inBlock = $true }
            $out.Add($line); continue
        }
        if ($trim.StartsWith('//') -or $trim.StartsWith('#')) { $out.Add($line); continue }

        $m = $rxOpen.Match($line)
        if ($m.Success) { $stack.Add($m.Groups[1].Value); $out.Add($line); continue }
        if ($rxClose.IsMatch($line)) {
            if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }
            $out.Add($line); continue
        }
        $m = $rxPair.Match($line)
        if ($m.Success) {
            $path = (@($stack) + $m.Groups[2].Value) -join '.'
            if ($todo.ContainsKey($path)) {
                $line = $m.Groups[1].Value + (ConvertTo-PhpLiteral $Values[$path]) + $m.Groups[4].Value
                $todo.Remove($path)
            }
        }
        $out.Add($line)
    }
    return [pscustomobject]@{ Text = ($out -join $nl); Missing = @($todo.Keys | Sort-Object) }
}

<#
 Werte fuer die config.php einer Installation. session.name bleibt leer (die
 Anwendung bildet <app.service>_<app.installation>_session). Der Platzhalter
 "Projekt" in mail.from_name wird immer durch den Dienstnamen ersetzt.
 python.exe gehoert zu den optionalen Schluesseln: Er wird nur gesetzt, wenn
 die config.example.php des Projekts ihn enthaelt.
#>
$script:OptionalConfigKeys = @('python.exe', 'app.key')

function Get-ConfigValues {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$DbPassword, [string]$AppKey = '')
    $inst = $Plan.Inst
    $v = [ordered]@{
        'app.name'           = $inst.Service.Name
        'app.url'            = $inst.Url
        'app.timezone'       = $inst.Zeitzone
        'app.service'        = $inst.Service.Key
        'app.installation'   = $inst.Key
        'db.host'            = $Plan.Pg.Host
        'db.port'            = [int]$Plan.Pg.Port
        'db.name'            = $Plan.DbName
        'db.user'            = $Plan.DbUser
        'db.password'        = $DbPassword
        'paths.data'         = $Plan.Paths.Data
        'paths.cache'        = $Plan.Paths.Cache
        'paths.logs'         = $Plan.Paths.Logs
        'paths.temp'         = $Plan.Paths.Temp
        'paths.services_json' = $Plan.ServicesJson
        'uploads.max_mb'     = [int]$inst.UploadsMaxMb
        'mail.from_name'     = $inst.Service.Name
    }
    if ($inst.Cloudflare) {
        $v['cloudflare.team_domain'] = $inst.Cloudflare.TeamDomain
        $v['cloudflare.aud']         = $inst.Cloudflare.Aud
        $v['cloudflare.guard']       = [bool]$inst.Cloudflare.Guard
    }
    if ($inst.Mail) {
        $v['mail.enabled']    = [bool]$inst.Mail.Enabled
        $v['mail.host']       = $inst.Mail.Host
        $v['mail.port']       = [int]$inst.Mail.Port
        $v['mail.encryption'] = $inst.Mail.Encryption
        $v['mail.username']   = $inst.Mail.Username
        $v['mail.password']   = $inst.Mail.Password
        if ($inst.Mail.From)     { $v['mail.from'] = $inst.Mail.From }
        if ($inst.Mail.FromName) { $v['mail.from_name'] = $inst.Mail.FromName }
    }
    if ($Plan.PythonExe) { $v['python.exe'] = $Plan.PythonExe }
    if ($AppKey) { $v['app.key'] = $AppKey }
    return $v
}

<#
 Schreibt die config.php: erst config.php.neu (UTF-8 OHNE BOM -
 Set-Content -Encoding UTF8 schriebe unter 5.1 ein BOM), mit "php -l"
 pruefen, dann umbenennen. Eine vorhandene config.php wird nie ueberschrieben.
#>
function Write-ProjectConfig {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$DbPassword, [string]$AppKey = '')
    $target  = Join-Path $Plan.ProgDir 'config.php'
    $example = Join-Path $Plan.ProgDir 'config.example.php'
    if (Test-Path -LiteralPath $target) { throw "config.php existiert bereits: $target" }
    if (-not (Test-Path -LiteralPath $example)) { throw "config.example.php nicht gefunden: $example" }

    $text = [System.IO.File]::ReadAllText($example, [System.Text.Encoding]::UTF8)
    $values = Get-ConfigValues -Plan $Plan -DbPassword $DbPassword -AppKey $AppKey
    $r = Set-ConfigTemplateValues -Text $text -Values $values
    $missing = @($r.Missing | Where-Object { $script:OptionalConfigKeys -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw ("In der config.example.php fehlen Schlüssel, die SNAIL setzen muss: {0}. Passen SNAIL und Vorlage zusammen?" -f ($missing -join ', '))
    }
    foreach ($k in @($r.Missing)) { Write-Log "Optionaler Schlüssel $k steht nicht in der config.example.php - nicht gesetzt." }
    $neu = $target + '.neu'
    [System.IO.File]::WriteAllText($neu, $r.Text, (New-Object System.Text.UTF8Encoding($false)))
    $lint = Invoke-ExeCapture -FilePath $Plan.PhpExe -ArgumentList (ConvertTo-CmdArgs @('-l', $neu)) -Utf8Output -TimeoutSec 60
    if ($lint.ExitCode -ne 0) {
        Remove-Item -LiteralPath $neu -Force -ErrorAction SilentlyContinue
        throw "Die erzeugte config.php ist kein gültiges PHP: $($lint.Lines -join ' ')"
    }
    [System.IO.File]::Move($neu, $target)
    return $target
}

# Steht ein Schluessel (Punkt-Schreibweise) in der config.example.php?
function Test-ConfigTemplateKey {
    param([Parameter(Mandatory)][string]$ExampleFile, [Parameter(Mandatory)][string]$Key)
    if (-not (Test-Path -LiteralPath $ExampleFile)) { return $false }
    $r = Set-ConfigTemplateValues -Text ([System.IO.File]::ReadAllText($ExampleFile, [System.Text.Encoding]::UTF8)) -Values ([ordered]@{ $Key = '' })
    return ($r.Missing.Count -eq 0)
}

<#
 Liest eine vorhandene config.php ueber php.exe (die Datei ist PHP, kein
 Textformat). Liefert das Array als Objekt oder $null. Ein BOM vor <?php gibt
 PHP als Text aus - deshalb ab der ersten { lesen.
#>
function Read-InstalledConfig {
    param([Parameter(Mandatory)][string]$ProgDir, [Parameter(Mandatory)][string]$PhpExe)
    $file = Join-Path $ProgDir 'config.php'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $code = 'echo json_encode(require $argv[1], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);'
    $r = Invoke-ExeCapture -FilePath $PhpExe -ArgumentList (ConvertTo-CmdArgs @('-r', $code, $file)) -Utf8Output -TimeoutSec 60
    $pos = $r.Output.IndexOf('{')
    if ($r.ExitCode -ne 0 -or $pos -lt 0) { throw "config.php ist nicht lesbar: $($r.Lines -join ' ')" }
    return ($r.Output.Substring($pos) | ConvertFrom-Json)
}

<#
 Ergaenzt Schluessel im Text einer VORHANDENEN config.php, ohne sonst etwas
 anzufassen (app.key und die anderen Schluessel von CONFIG_VERSION 4).
 Zeilenweise wie Set-ConfigTemplateValues, aber strenger:
   - Bereiche nur auf oberster Ebene ('app' => [ ... ],), jeder genau einmal
   - steht der Schluessel schon da, wird sein Literal nur ersetzt, wenn es
     ein erlaubter alter Wert ist (Standard '' oder null) - ein vorhandener
     Wert wird nie ueberschrieben
   - fehlt er, kommt er vor das schliessende ] des Bereichs (Einrueckung wie
     die Nachbarn, fehlendes Komma der Vorzeile ergaenzt)
 Alles Unerwartete (Bereich fehlt, doppelt oder in einer Zeile, Schluessel
 doppelt) liefert Error und den unveraenderten Text. Ob das Ergebnis stimmt,
 prueft danach PHP (Test-ConfigEdit) - der Text allein reicht nicht.
 $Values: Punkt-Schreibweise mit hoechstens einer Ebene ('app.key',
 'CONFIG_VERSION'). $Allowed: je Schluessel die erlaubten alten Literale.
 Fehlertexte nennen nur Schluesselnamen, nie Werte.
#>
function Add-ConfigKeys {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)]$Values, [hashtable]$Allowed = @{})
    $literal = "(?:'(?:[^'\\]|\\.)*'|-?\d+(?:\.\d+)?|true|false|null)"
    $rxPair  = [regex]("^(\s*'([A-Za-z0-9_]+)'\s*=>\s*)(" + $literal + ")(\s*,?\s*(?://.*|/\*.*)?)$")
    $rxOpen  = [regex]"^(\s*)'([A-Za-z0-9_]+)'\s*=>\s*\[\s*(?://.*)?$"
    $rxClose = [regex]'^(\s*)\]\s*([,;]?)\s*(?://.*)?$'
    $fail = { param([string]$Msg) [pscustomobject]@{ Text = $Text; Changed = @(); Error = $Msg } }

    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($Text -split "`r?`n")) { $lines.Add($l) }

    # 1) Aufbau erfassen: Art jeder Zeile, Paare mit Pfad, Bereiche der obersten Ebene
    $kind = New-Object string[] $lines.Count
    $pairs = New-Object System.Collections.Generic.List[object]
    $sections = @{}
    $stack = New-Object System.Collections.Generic.List[object]
    $inBlock = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]; $trim = $line.Trim()
        if ($inBlock) { if ($trim.Contains('*/')) { $inBlock = $false }; $kind[$i] = 'comment'; continue }
        if ($trim -eq '') { $kind[$i] = 'blank'; continue }
        if ($trim.StartsWith('/*')) { if (-not $trim.Contains('*/')) { $inBlock = $true }; $kind[$i] = 'comment'; continue }
        if ($trim.StartsWith('//') -or $trim.StartsWith('#')) { $kind[$i] = 'comment'; continue }
        $m = $rxOpen.Match($line)
        if ($m.Success) {
            $kind[$i] = 'open'
            $name = $m.Groups[2].Value
            $top = ($stack.Count -eq 0)
            $stack.Add(@{ Name = $name; Top = $top })
            if ($top) {
                if ($sections.ContainsKey($name)) { $sections[$name].Count++ }
                else { $sections[$name] = @{ Open = $i; Close = -1; Count = 1; Indent = $m.Groups[1].Value } }
            }
            continue
        }
        $m = $rxClose.Match($line)
        if ($m.Success) {
            $kind[$i] = 'close'
            if ($stack.Count -gt 0) {
                $s = $stack[$stack.Count - 1]
                $stack.RemoveAt($stack.Count - 1)
                if ($s.Top -and $sections[$s.Name].Close -lt 0) { $sections[$s.Name].Close = $i }
            }
            continue
        }
        $m = $rxPair.Match($line)
        if ($m.Success) {
            $kind[$i] = 'pair'
            $path = (@($stack | ForEach-Object { $_.Name }) + $m.Groups[2].Value) -join '.'
            $pairs.Add(@{ Index = $i; Path = $path; Prefix = $m.Groups[1].Value; Literal = $m.Groups[3].Value; Suffix = $m.Groups[4].Value })
            continue
        }
        $kind[$i] = 'other'
    }

    # 2) Ersetzen bzw. zum Einfuegen vormerken
    $insert = @{}
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Values.Keys) {
        $path = [string]$key
        $parts = $path.Split('.')
        if ($parts.Count -gt 2) { return (& $fail "$path`: nur eine Ebene wird unterstützt") }
        $hits = @($pairs | Where-Object { $_.Path -ceq $path })
        if ($hits.Count -gt 1) { return (& $fail "$path steht mehrfach in der config.php") }
        if ($hits.Count -eq 1) {
            $h = $hits[0]
            $ok = if ($Allowed.ContainsKey($path)) { @($Allowed[$path]) } else { @("''", 'null') }
            if ($ok -cnotcontains $h.Literal) { return (& $fail "$path hat schon einen Wert - wird nicht geändert") }
            $lines[$h.Index] = $h.Prefix + (ConvertTo-PhpLiteral $Values[$key]) + $h.Suffix
            $changed.Add($path)
            continue
        }
        if ($parts.Count -eq 1) { return (& $fail "$path fehlt auf oberster Ebene - wird nicht ergänzt") }
        $sec = $parts[0]
        if (-not $sections.ContainsKey($sec)) { return (& $fail "Bereich '$sec' => [ ... ] nicht gefunden (oder nicht in der üblichen Schreibweise)") }
        if ($sections[$sec].Count -gt 1) { return (& $fail "Bereich '$sec' steht mehrfach in der config.php") }
        if ($sections[$sec].Close -lt 0) { return (& $fail "Ende des Bereichs '$sec' nicht gefunden") }
        # z. B. "key" in doppelten Anfuehrungszeichen: nicht als Paar erkannt, aber vorhanden
        $rxAny = [regex]("^\s*['""]" + [regex]::Escape($parts[1]) + "['""]\s*=>")
        for ($j = $sections[$sec].Open + 1; $j -lt $sections[$sec].Close; $j++) {
            if ($kind[$j] -eq 'other' -and $rxAny.IsMatch($lines[$j])) { return (& $fail "$path steht in einer Schreibweise da, die SNAIL nicht sicher ändern kann") }
        }
        if (-not $insert.ContainsKey($sec)) { $insert[$sec] = New-Object System.Collections.Generic.List[string] }
        $insert[$sec].Add($path)
    }

    # 3) Einfuegen, von hinten nach vorn (Zeilennummern davor bleiben gueltig)
    foreach ($sec in @($insert.Keys | Sort-Object { $sections[$_].Close } -Descending)) {
        $s = $sections[$sec]
        $last = -1
        for ($j = $s.Close - 1; $j -gt $s.Open; $j--) {
            if ($kind[$j] -ne 'blank' -and $kind[$j] -ne 'comment') { $last = $j; break }
        }
        $indent = $null
        foreach ($p in $pairs) {
            if ($p.Index -gt $s.Open -and $p.Index -lt $s.Close -and $p.Path.Split('.').Count -eq 2) { $indent = ($p.Prefix -replace "^(\s*).*$", '$1'); break }
        }
        if ($null -eq $indent) { $indent = $s.Indent + '    ' }
        if ($last -ge 0) {
            $code = $lines[$last]
            if ($kind[$last] -eq 'pair') {
                $m = $rxPair.Match($code)
                if (-not $m.Groups[4].Value.TrimStart().StartsWith(',')) { $lines[$last] = $m.Groups[1].Value + $m.Groups[3].Value + ',' + $m.Groups[4].Value }
            } elseif ($kind[$last] -eq 'close') {
                $m = $rxClose.Match($code)
                if ($m.Groups[2].Value -eq ';') { return (& $fail "Bereich '$sec' unerwartet aufgebaut") }
                if ($m.Groups[2].Value -eq '') { $lines[$last] = $code.Substring(0, $code.IndexOf(']') + 1) + ',' + $code.Substring($code.IndexOf(']') + 1) }
            } else {
                return (& $fail "Bereich '$sec' enthält Zeilen, die SNAIL nicht sicher lesen kann - bitte von Hand ergänzen")
            }
        }
        $new = New-Object System.Collections.Generic.List[string]
        $new.Add($indent + '// von SNAIL ergaenzt (Erklaerung in der config.example.php)')
        foreach ($path in $insert[$sec]) {
            $new.Add(("{0}'{1}' => {2}," -f $indent, $path.Split('.')[1], (ConvertTo-PhpLiteral $Values[$path])))
            $changed.Add($path)
        }
        $lines.InsertRange($s.Close, $new)
    }
    $order = @($Values.Keys | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Text = ($lines -join $nl); Changed = @($order | Where-Object { $changed -contains $_ }); Error = '' }
}

# PHP-Hilfen fuer das Ergaenzen. Einzeilig (php -r), ohne //-Kommentare.
# Beide geben nur Schluesselnamen und Zustaende aus, NIE Werte - auch nicht
# im Fehlerfall (die config.php enthaelt das DB-Passwort).
$script:PhpConfigHelpers = @'
function snail_has($a, $p) { foreach (explode('.', $p) as $k) { if (!is_array($a) || !array_key_exists($k, $a)) { return [false, null]; } $a = $a[$k]; } return [true, $a]; }
function snail_unset(&$a, $p) { $k = explode('.', $p); if (count($k) === 1) { unset($a[$k[0]]); } elseif (isset($a[$k[0]]) && is_array($a[$k[0]])) { unset($a[$k[0]][$k[1]]); } }
function snail_keys($a, $p = '') { $o = []; foreach ($a as $k => $v) { if (is_array($v) && $v !== [] && !array_is_list($v)) { $o = array_merge($o, snail_keys($v, $p . $k . '.')); } else { $o[] = $p . $k; } } return $o; }
function snail_diff($a, $b, $p = '') { if (is_array($a) && is_array($b)) { $o = []; foreach (array_unique(array_merge(array_keys($a), array_keys($b))) as $k) { if (!array_key_exists($k, $a) || !array_key_exists($k, $b)) { $o[] = $p . $k; } else { $o = array_merge($o, snail_diff($a[$k], $b[$k], $p . $k . '.')); } } if ($o === [] && $a !== $b) { $o[] = ($p === '' ? '(Reihenfolge)' : rtrim($p, '.')); } return $o; } return $a === $b ? [] : [($p === '' ? '(Datei)' : rtrim($p, '.'))]; }
'@

$script:PhpConfigState = $script:PhpConfigHelpers + @'
$c = require $argv[1]; $e = require $argv[2];
if (!is_array($c) || !is_array($e)) { echo json_encode(['error' => 'kein Array']); exit(1); }
$o = ['keys' => [], 'version' => (is_int($c['CONFIG_VERSION'] ?? null) ? $c['CONFIG_VERSION'] : null), 'example_version' => (is_int($e['CONFIG_VERSION'] ?? null) ? $e['CONFIG_VERSION'] : null), 'missing' => array_values(array_diff(snail_keys($e), snail_keys($c)))];
foreach (['app.key', 'app.key_previous', 'mail.redirect_to'] as $k) { [$f, $v] = snail_has($c, $k); [$fe] = snail_has($e, $k); if (!$f) { $s = 'missing'; } elseif ($v === null || $v === '') { $s = 'empty'; } elseif ($k !== 'app.key') { $s = 'set'; } else { $t = is_string($v) ? trim($v) : ''; $r = strlen($t) === 44 ? base64_decode($t, true) : false; $s = ($r !== false && strlen($r) === 32) ? 'valid' : 'invalid'; } $o['keys'][$k] = ['state' => $s, 'example' => $fe]; }
echo json_encode($o);
'@

$script:PhpConfigVerify = $script:PhpConfigHelpers + @'
$old = require $argv[1]; $new = require $argv[2]; $e = require $argv[3];
$want = json_decode(stream_get_contents(STDIN), true);
if (!is_array($old) || !is_array($new) || !is_array($e) || !is_array($want)) { echo json_encode(['ok' => false, 'error' => 'kein Array']); exit(1); }
$o = ['wrong' => [], 'differs' => [], 'missing' => []];
foreach ($want as $k => $v) { [$f, $nv] = snail_has($new, $k); if (!$f || $nv !== $v) { $o['wrong'][] = $k; } snail_unset($old, $k); snail_unset($new, $k); }
$o['differs'] = snail_diff($old, $new);
$o['missing'] = array_values(array_diff(snail_keys($e), snail_keys(require $argv[2])));
$o['ok'] = ($o['wrong'] === [] && $o['differs'] === []);
echo json_encode($o);
'@

# PHP-Hilfe ausfuehren; liefert das JSON-Ergebnis. Ausgabe und Fehlertext
# kommen nie ins Protokoll oder in die Meldung.
function Invoke-PhpConfigHelper {
    param([Parameter(Mandatory)][string]$PhpExe, [Parameter(Mandatory)][string]$Code, [string[]]$Arguments = @(), [string]$StdIn = '')
    $oneLine = ($Code -replace "\r?\n", ' ')
    $r = Invoke-ExeCapture -FilePath $PhpExe -ArgumentList (ConvertTo-CmdArgs (@('-r', $oneLine) + $Arguments)) -StdIn $StdIn -Utf8Output -TimeoutSec 60
    $pos = $r.Output.IndexOf('{')
    if ($pos -lt 0) { throw "PHP konnte die config.php nicht auswerten (Exit-Code $($r.ExitCode))." }
    $j = $null
    try { $j = $r.Output.Substring($pos) | ConvertFrom-Json } catch { }
    if ($null -eq $j -or $r.ExitCode -ne 0) { throw "PHP konnte die config.php nicht auswerten (Exit-Code $($r.ExitCode))." }
    return $j
}

# Kopie der config.php vor einer Aenderung durch SNAIL nach
# <Datenordner>\Sicherung\config.php.vor-snail-<Zeit> (nur Administratoren/
# SYSTEM; im Programmordner wuerde robocopy /MIR sie beim naechsten Update
# loeschen). Enthaelt das DB-Passwort; SNAIL loescht sie nie.
function Backup-ConfigFile {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][byte[]]$Bytes)
    $root = Get-BackupRoot -Plan $Plan
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    Protect-AdminOnly -Path $root
    $file = [System.IO.Path]::Combine($root, ('config.php.vor-snail-{0:yyyyMMdd_HHmmss}' -f (Get-Date)))
    [System.IO.File]::WriteAllBytes($file, [byte[]]@())
    Protect-AdminOnly -Path $file
    [System.IO.File]::WriteAllBytes($file, $Bytes)
    return $file
}

<#
 app.key in einer vorhandenen config.php nachtragen (Wiederholen/Aktualisieren),
 dazu app.key_previous und mail.redirect_to als '' - nur was fehlt, nur wenn
 die config.example.php des Programmcodes sie kennt. CONFIG_VERSION 3 -> 4
 nur, wenn danach kein Schluessel der Vorlage mehr fehlt.
   1. Zustand per PHP (nur Zustaende, keine Werte). app.key gueltig -> nur
      die anderen ergaenzen; ungueltig -> gar nichts aendern (Warnung)
   2. Text ergaenzen (Add-ConfigKeys) -> config.php.neu (BOM wie vorher)
   3. php -l, dann PHP-Vergleich: neue Werte wie gewollt, alle anderen
      Werte unveraendert (Typ und Reihenfolge), Original seit dem Lesen gleich
   4. erst dann Sicherung und atomar ersetzen ([IO.File]::Replace behaelt die
      Rechte der config.php)
 Jeder Fehler: .neu weg, config.php unveraendert; fehlte app.key, zeigt
 "Fertig" einen Schluessel zum Selbsteintragen (Status manual).
 Status: none (Vorlage ohne app.key) | present | invalid | added | manual | failed
#>
$script:ConfigV4Keys = @('app.key_previous', 'mail.redirect_to')

function Update-InstalledConfigKeys {
    param([Parameter(Mandatory)]$Plan)
    $res = [pscustomobject]@{ Status = 'none'; Key = ''; Changed = @(); Backup = ''; Text = '' }
    $file = Join-Path $Plan.ProgDir 'config.php'
    $example = Join-Path $Plan.ProgDir 'config.example.php'
    if (-not (Test-ConfigTemplateKey -ExampleFile $example -Key 'app.key')) {
        $res.Text = 'Die config.example.php dieses Programmstands kennt app.key nicht - nichts zu ergänzen.'
        return $res
    }
    $orig = [System.IO.File]::ReadAllBytes($file)
    $st = Invoke-PhpConfigHelper -PhpExe $Plan.PhpExe -Code $script:PhpConfigState -Arguments @($file, $example)
    $keyState = [string]$st.keys.'app.key'.state
    if ($keyState -eq 'invalid') {
        $res.Status = 'invalid'
        $res.Text = 'app.key in der config.php ist kein gültiger Schlüssel (Base64 von 32 Byte, 44 Zeichen). SNAIL ändert nichts - ein falscher Schlüssel macht gespeicherte Passwörter unlesbar. Bitte den richtigen Schlüssel aus Sicherung/Passwortmanager eintragen; nur wenn noch nie Passwörter gespeichert wurden, einen neuen (php bin\console app:key).'
        return $res
    }
    $values = [ordered]@{}
    if ($keyState -eq 'missing' -or $keyState -eq 'empty') { $res.Key = New-AppKey; $values['app.key'] = $res.Key }
    foreach ($k in $script:ConfigV4Keys) {
        if ($st.keys.$k.example -and [string]$st.keys.$k.state -eq 'missing') { $values[$k] = '' }
    }
    $allowed = @{}
    $rest = @($st.missing | Where-Object { -not $values.Contains([string]$_) })
    if ($values.Count -gt 0 -and $st.version -eq 3 -and $st.example_version -eq 4 -and $rest.Count -eq 0) {
        $values['CONFIG_VERSION'] = 4
        $allowed['CONFIG_VERSION'] = @('3')
    }
    if ($values.Count -eq 0) {
        $res.Status = 'present'
        $res.Text = 'app.key ist gesetzt und gültig - config.php unverändert.'
        return $res
    }
    $res.Status = if ($res.Key) { 'added' } else { 'present' }

    $neu = $file + '.neu'
    try {
        $bom = ($orig.Length -ge 3 -and $orig[0] -eq 0xEF -and $orig[1] -eq 0xBB -and $orig[2] -eq 0xBF)
        $off = if ($bom) { 3 } else { 0 }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $utf8.GetString($orig, $off, $orig.Length - $off)
        $edit = Add-ConfigKeys -Text $text -Values $values -Allowed $allowed
        if ($edit.Error) { throw $edit.Error }
        $body = $utf8.GetBytes($edit.Text)
        $bytes = if ($bom) { [byte[]](@(0xEF, 0xBB, 0xBF) + $body) } else { $body }
        [System.IO.File]::WriteAllBytes($neu, $bytes)

        $lint = Invoke-ExeCapture -FilePath $Plan.PhpExe -ArgumentList (ConvertTo-CmdArgs @('-l', $neu)) -Utf8Output -TimeoutSec 60
        if ($lint.ExitCode -ne 0) {
            $zeile = if ($lint.Output -match 'on line (\d+)') { " (Zeile $($Matches[1]))" } else { '' }
            throw "php -l meldet einen Fehler in der ergänzten Datei$zeile."
        }
        $want = New-Object System.Text.StringBuilder
        [void]$want.Append('{')
        $first = $true
        foreach ($k in $values.Keys) {
            if (-not $first) { [void]$want.Append(',') }
            $first = $false
            $v = $values[$k]
            $json = if ($v -is [int]) { [string]$v } else { '"' + ([string]$v).Replace('\', '\\').Replace('"', '\"') + '"' }
            [void]$want.Append('"' + $k + '":' + $json)
        }
        [void]$want.Append('}')
        $chk = Invoke-PhpConfigHelper -PhpExe $Plan.PhpExe -Code $script:PhpConfigVerify -Arguments @($file, $neu, $example) -StdIn $want.ToString()
        if (-not $chk.ok) {
            $why = @()
            if (@($chk.wrong).Count -gt 0) { $why += 'nicht wie gewollt gesetzt: ' + (@($chk.wrong) -join ', ') }
            if (@($chk.differs).Count -gt 0) { $why += 'sonst abweichend: ' + (@($chk.differs) -join ', ') }
            throw ('Prüfung nach dem Ergänzen fehlgeschlagen (' + ($why -join '; ') + ').')
        }
        if ($values.Contains('CONFIG_VERSION') -and @($chk.missing).Count -gt 0) {
            throw ('Nach dem Ergänzen fehlen noch Schlüssel der Vorlage: ' + (@($chk.missing) -join ', ') + '.')
        }
        if ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file)) -cne [Convert]::ToBase64String($orig)) {
            throw 'Die config.php wurde während des Laufs geändert.'
        }
        $res.Backup = Backup-ConfigFile -Plan $Plan -Bytes $orig
        [System.IO.File]::Replace($neu, $file, [NullString]::Value)
        $res.Changed = @($edit.Changed)
        $res.Text = ('Ergänzt: {0} (php -l und Vergleich ohne Befund, alle anderen Werte unverändert). Vorheriger Stand: {1}' -f ($res.Changed -join ', '), $res.Backup)
    } catch {
        Remove-Item -LiteralPath $neu -Force -ErrorAction SilentlyContinue
        $res.Changed = @()
        $res.Status = if ($res.Key) { 'manual' } else { 'failed' }
        $res.Text = 'config.php nicht geändert: ' + $_.Exception.Message
        if ($res.Text -notmatch '[.!?]$') { $res.Text += '.' }
    }
    return $res
}

# requirements und version aus config/app.php der Vorlage (ZIP oder Ordner).
# Name und Version des Projekts stehen seit der Vorlage mit config/projekt/app.php
# dort (Literal-Array name/version/description, ueberschreibt config/app.php);
# fehlt die Datei, gilt version aus config/app.php wie bisher.
function Get-TemplateInfo {
    param([Parameter(Mandatory)][string]$Root, [string]$PhpExe)
    $info = [pscustomobject]@{ Version = ''; PhpMin = '8.5.0'; PgMin = 18; Extensions = @('pdo_pgsql', 'mbstring', 'openssl', 'json', 'ctype', 'fileinfo', 'session'); ExampleService = ''; Name = '' }
    # app.service der config.example.php: fuer welchen Dienst ist der Programmcode gebaut?
    # (die Vorlage selbst: 'projekt'; nur Literale, deshalb gefahrlos per php -r)
    $example = Join-Path $Root 'config.example.php'
    if ($PhpExe -and (Test-Path -LiteralPath $example)) {
        try {
            $code = '$c = require $argv[1]; echo json_encode(["service" => (is_array($c) ? ($c["app"]["service"] ?? "") : "")]);'
            $r = Invoke-ExeCapture -FilePath $PhpExe -ArgumentList (ConvertTo-CmdArgs @('-r', $code, $example)) -Utf8Output -TimeoutSec 60
            $pos = $r.Output.IndexOf('{')
            if ($r.ExitCode -eq 0 -and $pos -ge 0) { $info.ExampleService = [string]($r.Output.Substring($pos) | ConvertFrom-Json).service }
        } catch { }
    }
    $file = Join-Path (Join-Path $Root 'config') 'app.php'
    if (-not $PhpExe -or -not (Test-Path -LiteralPath $file)) { return $info }
    $projekt = [System.IO.Path]::Combine($Root, 'config', 'projekt', 'app.php')
    $code = '$a = require $argv[1]; $p = is_file($argv[2]) ? require $argv[2] : []; if (!is_array($p)) { $p = []; } echo json_encode(["version" => (string) ($p["version"] ?? $a["version"] ?? ""), "name" => (string) ($p["name"] ?? $a["name"] ?? ""), "requirements" => $a["requirements"] ?? null]);'
    try {
        $r = Invoke-ExeCapture -FilePath $PhpExe -ArgumentList (ConvertTo-CmdArgs @('-r', $code, $file, $projekt)) -Utf8Output -TimeoutSec 60
        $pos = $r.Output.IndexOf('{')
        if ($r.ExitCode -eq 0 -and $pos -ge 0) {
            $j = $r.Output.Substring($pos) | ConvertFrom-Json
            $info.Version = [string]$j.version
            $info.Name = [string]$j.name
            if ($j.requirements) {
                if ($j.requirements.php_min) { $info.PhpMin = [string]$j.requirements.php_min }
                if ($j.requirements.postgres_min) { $info.PgMin = [int]$j.requirements.postgres_min }
                if ($j.requirements.extensions) { $info.Extensions = @($j.requirements.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() }) }
            }
        }
    } catch { }
    return $info
}

<#
 Passt die ZIP zum gewaehlten Katalog-Eintrag? Nur Warnungen (z. B. werner
 gewaehlt, aber die ZIP der projektvorlage angegeben - oder umgekehrt):
   1. app.service in der config.example.php der ZIP gegen den Dienst
   2. sonst der Projektstamm (GitHub: <repo>-<branch>) gegen den Namen der
      vorgeschlagenen ZIP im Katalog (zip = werner-main.zip -> werner-main)
#>
function Get-ZipServiceWarnings {
    param([Parameter(Mandatory)]$Service, [string]$ExampleService = '', [string]$Inner = '')
    if ($ExampleService -and $ExampleService -cne $Service.Key) {
        return @("Die ZIP ist fuer den Dienst '$ExampleService' gebaut (app.service in der config.example.php), gewaehlt ist '$($Service.Key)' ($($Service.Name)) - passt die ZIP zum Katalog-Eintrag?")
    }
    $leaf = if ($Inner) { @($Inner -split '[\\/]')[-1] } else { '' }
    $expect = if ($Service.Zip) { [System.IO.Path]::GetFileNameWithoutExtension([string]$Service.Zip) } else { '' }
    if ($leaf -and $expect -and $leaf -ine $expect) {
        return @("Projektstamm '$leaf' passt nicht zur ZIP des Katalog-Eintrags '$($Service.Name)' ($expect.zip) - richtige ZIP gewaehlt?")
    }
    return @()
}

# ==============================================================================
#  6) services.json (Vertrag in docs/03 der Vorlage)
# ==============================================================================

# ConvertFrom-Json liefert PSCustomObjects; fuer das Angleichen in geordnete
# Tabellen umbauen - unbekannte (von Hand ergaenzte) Felder bleiben erhalten.
function ConvertTo-OrderedTree {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($prop in $Node.PSObject.Properties) { $h[$prop.Name] = ConvertTo-OrderedTree $prop.Value }
        return $h
    }
    if ($Node -is [System.Collections.IList]) {
        return , @($Node | ForEach-Object { ConvertTo-OrderedTree $_ })
    }
    return $Node
}

<#
 Ergaenzt oder gleicht genau den eigenen Dienst und die eigene Installation an
 (Zuordnung ueber die Schluessel). Alles andere bleibt unveraendert,
 Reihenfolge bleibt, neue Dienste/Installationen kommen ans Ende. Felder, die
 die projekte.json nicht setzt, bleiben wie sie sind.
#>
function Merge-ServicesJson {
    param(
        $Tree,
        [Parameter(Mandatory)]$Service,      # Key, Name, Icon, Tone, Description
        [string]$LogoRel = '',
        [Parameter(Mandatory)]$Installation  # Key, Name, Url
    )
    if ($null -eq $Tree) { $Tree = [ordered]@{ format = $script:FormatVersion; services = @() } }
    if ([string]$Tree['format'] -ne [string]$script:FormatVersion) {
        throw "services.json hat ein unbekanntes Format ('$($Tree['format'])') - wird nicht verändert."
    }
    $services = @($Tree['services'] | Where-Object { $null -ne $_ })
    $svc = $null
    foreach ($s in $services) { if ($s -is [System.Collections.IDictionary] -and [string]$s['key'] -ceq $Service.Key) { $svc = $s; break } }
    if ($null -eq $svc) {
        $svc = [ordered]@{ key = $Service.Key }
        $services += , $svc
    }
    $svc['name'] = $Service.Name
    if ($Service.Icon)        { $svc['icon'] = $Service.Icon }
    if ($Service.Tone)        { $svc['tone'] = $Service.Tone }
    if ($LogoRel)             { $svc['logo'] = $LogoRel }
    if ($Service.Description) { $svc['description'] = $Service.Description }

    $insts = @($svc['installations'] | Where-Object { $null -ne $_ })
    $own = $null
    foreach ($x in $insts) { if ($x -is [System.Collections.IDictionary] -and [string]$x['key'] -ceq $Installation.Key) { $own = $x; break } }
    if ($null -eq $own) {
        $own = [ordered]@{ key = $Installation.Key }
        $insts += , $own
    }
    $own['name'] = $Installation.Name
    $own['url']  = $Installation.Url
    # "installations" ans Ende des Dienst-Eintrags, wie im Beispiel der Vorlage
    if ($svc.Contains('installations')) { $svc.Remove('installations') }
    $svc['installations'] = $insts
    $Tree['services'] = $services
    return $Tree
}

<#
 Regeln aus docs/03 pruefen, bevor geschrieben wird. Liefert Fehler (dann
 nicht schreiben) und Hinweise (z. B. fehlende Logo-Datei eines anderen Dienstes).
#>
function Test-ServicesJsonRules {
    param([Parameter(Mandatory)]$Tree, [Parameter(Mandatory)][string]$BaseDir)
    $errors = New-Object System.Collections.Generic.List[string]
    $hints  = New-Object System.Collections.Generic.List[string]
    $tones  = @('info', 'success', 'warning', 'danger', 'primary', 'purple', 'amber', 'muted', 'neutral')
    if ([string]$Tree['format'] -ne [string]$script:FormatVersion) { $errors.Add('format muss 1 sein.') }
    $services = @($Tree['services'])
    if ($services.Count -eq 0) { $errors.Add('services ist leer.') }
    $seen = @{}
    $i = 0
    foreach ($s in $services) {
        $w = "services[$i]"; $i++
        if ($s -isnot [System.Collections.IDictionary]) { $errors.Add("$w ist kein Objekt."); continue }
        $key = [string]$s['key']
        if (-not (Test-ServiceKey $key)) { $errors.Add("$w.key '$key' ist ungültig (a-z, 0-9, _ und -, max. 64)."); continue }
        if ($seen.ContainsKey($key)) { $errors.Add("Dienst '$key' kommt doppelt vor.") }
        $seen[$key] = $true
        if ($s['name'] -isnot [string] -or ([string]$s['name']).Trim() -eq '') { $errors.Add("$w ('$key'): name fehlt.") }
        if ($null -ne $s['tone'] -and $tones -cnotcontains [string]$s['tone']) { $errors.Add("$w ('$key'): tone '$($s['tone'])' ist ungültig.") }
        if ($null -ne $s['logo'] -and [string]$s['logo'] -ne '') {
            $logo = ([string]$s['logo']).Replace('\', '/')
            if ($logo -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*\.(svg|png|webp|jpe?g)$') {
                $errors.Add("$w ('$key'): logo '$logo' ist ungültig (svg/png/webp/jpg, relativ, Datei- und Ordnernamen ohne Leerzeichen).")
            } else {
                $file = Join-Path $BaseDir ($logo.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $hints.Add("Logo von '$key' fehlt: $file (der App-Switcher zeigt das Icon).") }
                elseif ((Get-Item -LiteralPath $file).Length -gt 1048576) { $errors.Add("Logo von '$key' ist größer als 1 MB.") }
            }
        }
        $insts = @($s['installations'])
        if ($insts.Count -eq 0) { $errors.Add("$w ('$key'): installations ist leer.") }
        $seenInst = @{}
        $j = 0
        foreach ($x in $insts) {
            $wi = "$w.installations[$j]"; $j++
            if ($x -isnot [System.Collections.IDictionary]) { $errors.Add("$wi ist kein Objekt."); continue }
            $ik = [string]$x['key']
            if (-not (Test-ServiceKey $ik)) { $errors.Add("$wi ('$key'): key '$ik' ist ungültig."); continue }
            if ($seenInst.ContainsKey($ik)) { $errors.Add("Installation '$ik' kommt in '$key' doppelt vor.") }
            $seenInst[$ik] = $true
            if ([string]$x['url'] -notmatch '^https?://[^\s/]+[^\s]*$') { $errors.Add("$wi ('$key/$ik'): url muss mit http:// oder https:// beginnen und darf keine Leerzeichen enthalten.") }
        }
    }
    return [pscustomobject]@{ Errors = $errors.ToArray(); Hints = $hints.ToArray() }
}

function Read-ServicesJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    return (ConvertTo-OrderedTree ($raw | ConvertFrom-Json))
}

# Erst <datei>.neu schreiben, dann ersetzen - die Anwendungen lesen die Datei
# bei jedem Seitenaufbau und sollen nie eine halbe Datei sehen.
function Write-FileAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    $neu = $Path + '.neu'
    [System.IO.File]::WriteAllBytes($neu, $Bytes)
    # [NullString]::Value: $null kaeme bei einem .NET-String-Parameter als "" an
    if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($neu, $Path, [NullString]::Value) }
    else { [System.IO.File]::Move($neu, $Path) }
}

function ConvertTo-ServicesJsonText {
    param([Parameter(Mandatory)]$Tree)
    # -InputObject statt Pipeline: sonst wuerde eine Liste aufgefaltet
    return (ConvertTo-Json -InputObject $Tree -Depth 5)
}

<#
 services.json fuer eine Installation ergaenzen/angleichen. Logo nach
 <Ordner der services.json>\logos\<dienst>.<ext>. Bei einem Regelverstoss
 wird nichts geschrieben. Liefert @{ Ok; Text; Hints }.
#>
function Update-ServicesJson {
    param([Parameter(Mandatory)]$Plan)
    $inst = $Plan.Inst
    $path = $Plan.ServicesJson
    $base = Split-Path -Parent $path
    $hints = New-Object System.Collections.Generic.List[string]

    $tree = $null
    try { $tree = Read-ServicesJson -Path $path }
    catch { return [pscustomobject]@{ Ok = $false; Text = "services.json ist kein gültiges JSON und wird nicht verändert: $($_.Exception.Message)"; Hints = @() } }
    $before = Get-ServicesEntry -Tree $tree -ServiceKey $inst.Service.Key -InstKey $inst.Key
    if ($before.Found -and $before.Url -ne $inst.Url) { $hints.Add("url in der services.json war '$($before.Url)' - angeglichen an '$($inst.Url)' (app.url).") }

    $logoRel = ''
    if ($inst.Service.Logo.Bytes) {
        $logoDir = Join-Path $base 'logos'
        if (-not (Test-Path -LiteralPath $logoDir)) { New-Item -ItemType Directory -Path $logoDir -Force | Out-Null }
        $logoRel = 'logos/' + $inst.Service.Key + '.' + $inst.Service.Logo.Ext
        $logoFile = Join-Path $logoDir ($inst.Service.Key + '.' + $inst.Service.Logo.Ext)
        $same = $false
        if (Test-Path -LiteralPath $logoFile) {
            $old = [System.IO.File]::ReadAllBytes($logoFile)
            $same = ([Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($inst.Service.Logo.Bytes))
        }
        if (-not $same) { Write-FileAtomic -Path $logoFile -Bytes $inst.Service.Logo.Bytes; Write-Log "Logo abgelegt: $logoFile" 'Ok' }
        else { Write-Log "Logo unverändert: $logoFile" }
    } elseif ($inst.Service.Logo.Error) {
        $hints.Add($inst.Service.Logo.Error)
    }

    try {
        $tree = Merge-ServicesJson -Tree $tree -Service $inst.Service -LogoRel $logoRel `
            -Installation ([pscustomobject]@{ Key = $inst.Key; Name = $inst.Name; Url = $inst.Url })
    } catch {
        return [pscustomobject]@{ Ok = $false; Text = $_.Exception.Message; Hints = $hints.ToArray() }
    }
    $rules = Test-ServicesJsonRules -Tree $tree -BaseDir $base
    foreach ($h in $rules.Hints) { $hints.Add($h) }
    if ($rules.Errors.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Text = ('services.json wird nicht geschrieben: ' + ($rules.Errors -join ' | ')); Hints = $hints.ToArray() }
    }
    $text = ConvertTo-ServicesJsonText -Tree $tree
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
    Write-FileAtomic -Path $path -Bytes $bytes
    return [pscustomobject]@{ Ok = $true; Text = "services.json: $($inst.Service.Key)/$($inst.Key) eingetragen ($path)"; Hints = $hints.ToArray() }
}

# Vorhandene Mandanten-Schluessel aus der services.json: key -> Namen + Dienste
function Get-KnownTenants {
    param([string]$Path)
    $map = @{}
    try { $tree = Read-ServicesJson -Path $Path } catch { return $map }
    if ($null -eq $tree) { return $map }
    foreach ($s in @($tree['services'])) {
        if ($s -isnot [System.Collections.IDictionary]) { continue }
        foreach ($x in @($s['installations'])) {
            if ($x -isnot [System.Collections.IDictionary]) { continue }
            $k = [string]$x['key']
            if (-not $map.ContainsKey($k)) { $map[$k] = [pscustomobject]@{ Key = $k; Name = [string]$x['name']; Services = @() } }
            $map[$k].Services += [string]$s['key']
        }
    }
    return $map
}

# ==============================================================================
#  7) IIS: Anwendungspool, Website, Upload-Grenze, Portpruefung
# ==============================================================================

<#
 Liest die vorhandenen Websites über "appcmd list site":
   SITE "Default Web Site" (id:1,bindings:http/*:80:,state:Started)
#>
function Get-IisSites {
    if (-not (Test-Path -LiteralPath $script:AppCmd)) { return @() }
    $r = Invoke-AppCmd @('list', 'site')
    $sites = New-Object System.Collections.Generic.List[object]
    foreach ($line in $r.Lines) {
        if ($line -match '^SITE\s+"(.*)"\s+\(id:(\d+),bindings:(.*),state:([^,)]*)\)') {
            $sites.Add([pscustomobject]@{ Name = $Matches[1]; Id = [int]$Matches[2]; Bindings = $Matches[3]; State = $Matches[4] })
        }
    }
    return $sites.ToArray()
}

# Physischer Pfad des Stammverzeichnisses einer Website (oder $null)
function Get-IisSitePath {
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-AppCmd @('list', 'vdir', "/app.name:$Name/")
    foreach ($line in $r.Lines) {
        if ($line -match 'physicalPath:(.+?)\)\s*$') { return [System.Environment]::ExpandEnvironmentVariables($Matches[1]).TrimEnd('\') }
    }
    return $null
}

function Test-AppPoolExists {
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-AppCmd @('list', 'apppool', "/name:$Name")
    return (@($r.Lines | Where-Object { $_ -match '^APPPOOL\s+"' }).Count -gt 0)
}

# Anwendungen, die einen App-Pool nutzen (z. B. "olaf/", "Default Web Site/")
function Get-AppPoolApps {
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-AppCmd @('list', 'app', "/apppool.name:$Name")
    return @($r.Lines | ForEach-Object { if ($_ -match '^APP\s+"([^"]+)"') { $Matches[1] } })
}

function Test-TcpPortInUse {
    param([Parameter(Mandatory)][int]$Port)
    try {
        foreach ($l in [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) {
            if ($l.Port -eq $Port) { return $true }
        }
    } catch { }
    return $false
}

function Test-UrlRewriteInstalled {
    if (Test-Path -LiteralPath (Join-Path $env:windir 'system32\inetsrv\rewrite.dll')) { return $true }
    $r = Invoke-AppCmd @('list', 'config', '-section:system.webServer/globalModules')
    return ($r.Output -match 'RewriteModule')
}

function Test-WebDavInstalled {
    return (Test-Path -LiteralPath (Join-Path $env:windir 'system32\inetsrv\webdav.dll'))
}

# Gueltiger Wert von maxAllowedContentLength fuer eine Website (Bytes, -1 = unbekannt)
function Get-IisUploadLimit {
    param([Parameter(Mandatory)][string]$Site)
    $r = Invoke-AppCmd @('list', 'config', $Site, '-section:system.webServer/security/requestFiltering')
    if ($r.Output -match 'maxAllowedContentLength="(\d+)"') { return [long]$Matches[1] }
    if ($r.ExitCode -eq 0) { return [long]30000000 }   # IIS-Standard, wenn nichts eingetragen ist
    return [long]-1
}

function Stop-ProjectPool {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-AppPoolExists -Name $Name)) { return $false }
    $r = Invoke-AppCmd @('stop', 'apppool', "/apppool.name:$Name")
    if ($r.ExitCode -eq 0) { Write-Log "App-Pool '$Name' angehalten." 'Ok'; return $true }
    Write-Log "App-Pool '$Name' lief nicht ($($r.Output))."
    return $true
}

function Start-ProjectPool {
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-AppCmd @('start', 'apppool', "/apppool.name:$Name")
    if ($r.ExitCode -eq 0) { Write-Log "App-Pool '$Name' gestartet." 'Ok' }
    else { Write-Log "App-Pool '$Name': $($r.Output)" }
}

# Port des ersten http-Bindings ("http/*:21100:,https/*:443:..." -> 21100), sonst 0
function Get-PortFromBindings {
    param([string]$Bindings)
    if ($Bindings -match 'http/[^:,]*:(\d+):') { return [int]$Matches[1] }
    return 0
}

# Ausgabe von "netsh interface ipv4 show excludedportrange protocol=tcp" -> Bereiche
function ConvertFrom-ExcludedPortOutput {
    param([string[]]$Lines)
    $ranges = New-Object System.Collections.Generic.List[object]
    foreach ($l in $Lines) {
        if ($l -match '^\s*(\d+)\s+(\d+)\b') { $ranges.Add([pscustomobject]@{ Start = [int]$Matches[1]; End = [int]$Matches[2] }) }
    }
    return $ranges.ToArray()
}

# Von Windows reservierte Ports (Hyper-V, WinNAT ...) - dort kann IIS nicht binden
function Get-ExcludedPortRanges {
    try {
        $netsh = Join-Path $env:windir 'System32\netsh.exe'
        $r = Invoke-ExeCapture -FilePath $netsh -ArgumentList @('interface', 'ipv4', 'show', 'excludedportrange', 'protocol=tcp') -TimeoutSec 30
        return (ConvertFrom-ExcludedPortOutput -Lines $r.Lines)
    } catch {
        Write-Log "Reservierte Ports nicht lesbar: $($_.Exception.Message)" 'Warn'
        return @()
    }
}

<#
 Ist ein Port fuer eine neue Website frei? Liefert $null oder den Grund:
 Binding einer IIS-Website, von Windows reserviert, aktiver TCP-Listener.
 -OwnSite: Bindings dieser Website zaehlen nicht (Wiederholung nach Abbruch).
 HTTP.sys traegt den Port jeder laufenden Website als verwalteten
 Portausschluss in die excludedportrange ein - ein Port, den die eigene
 Website gebunden hat, gilt deshalb weder als reserviert noch als belegt.
#>
function Test-PortFree {
    param([Parameter(Mandatory)][int]$Port, $Sites = @(), $Excluded = @(), [string]$OwnSite = '', [scriptblock]$ListenerTest = $null)
    if ($Port -lt 1 -or $Port -gt 65535) { return 'kein gültiger Port (1-65535)' }
    $site = @($Sites | Where-Object { $_.Name -ine $OwnSite -and $_.Bindings -match (':' + $Port + ':') }) | Select-Object -First 1
    if ($site) { return "gehört zur Website '$($site.Name)'" }
    $ownHas = $OwnSite -and @($Sites | Where-Object { $_.Name -ieq $OwnSite -and $_.Bindings -match (':' + $Port + ':') }).Count -gt 0
    if ($ownHas) { return $null }
    foreach ($x in $Excluded) {
        if ($Port -ge $x.Start -and $Port -le $x.End) { return $(if ($x.Start -eq $x.End) { "von Windows reserviert ($Port)" } else { "von Windows reserviert ($($x.Start)-$($x.End))" }) }
    }
    $inUse = if ($ListenerTest) { & $ListenerTest $Port } else { Test-TcpPortInUse -Port $Port }
    if ($inUse) { return 'von einem anderen Programm belegt (TCP-Listener)' }
    return $null
}

function Get-NextFreePort {
    param([int]$Start = 21100, $Sites = @(), $Excluded = @(), [int[]]$Skip = @(), [scriptblock]$ListenerTest = $null)
    for ($p = $Start; $p -le 65535; $p++) {
        if ($Skip -contains $p) { continue }
        if ($null -eq (Test-PortFree -Port $p -Sites $Sites -Excluded $Excluded -ListenerTest $ListenerTest)) { return $p }
    }
    return 0
}

<#
 App-Pool und Website anlegen bzw. angleichen. Pool, Site und Ordner heissen
 gleich ($Plan.Ordner).
   - Pool: kein verwalteter Code, ApplicationPoolIdentity
   - Website: physischer Pfad <Ordner>\public. Das Binding http/*:<port>:
     (ein Cloudflare Tunnel, falls genutzt, zeigt auf localhost:<port>) wird
     NUR beim Anlegen gesetzt; die Bindings einer vorhandenen Website (auch
     von Hand ergaenzte, z. B. https) fasst SNAIL nie an.
   - Anonyme Anmeldung = App-Pool-Benutzer (userName leer) - Voraussetzung
     fuer die Haertung, sonst 401.3. Gesperrter Abschnitt -> /commit:apphost
   - Upload-Grenze je Website (/commit:apphost, NICHT public\web.config - die
     ueberschreibt jedes Update). Ein hoeherer gueltiger Wert wird nie gesenkt.
 Handler/Module fasst SNAIL nicht an (macht WIPP auf Serverebene).
#>
function Set-ProjectSite {
    param([Parameter(Mandatory)]$Plan)
    $name = $Plan.Ordner
    $docRoot = Join-Path $Plan.ProgDir 'public'
    if (-not (Test-Path -LiteralPath $docRoot)) { throw "Der Website-Pfad existiert nicht: $docRoot" }

    if (Test-AppPoolExists -Name $name) {
        Write-Log "App-Pool '$name' vorhanden - wird angeglichen."
    } else {
        $r = Invoke-AppCmd @('add', 'apppool', "/name:$name")
        if ($r.ExitCode -ne 0) { throw "appcmd add apppool fehlgeschlagen: $($r.Output)" }
        Write-Log "App-Pool '$name' angelegt." 'Ok'
    }
    $r = Invoke-AppCmd @('set', 'apppool', "/apppool.name:$name", '/managedRuntimeVersion:""',
        '/enable32BitAppOnWin64:false', '/processModel.identityType:ApplicationPoolIdentity')
    if ($r.ExitCode -ne 0) { throw "App-Pool konnte nicht eingestellt werden: $($r.Output)" }
    Write-Log 'App-Pool: kein verwalteter Code, Identität ApplicationPoolIdentity.' 'Ok'

    $site = @(Get-IisSites | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
    if ($null -eq $site) {
        if ($Plan.Inst.Port -lt 1) { throw "Die Website '$name' fehlt und der Port ist unbekannt - Bindings legt SNAIL nur bei einer Neuinstallation an." }
        $binding = "*:$($Plan.Inst.Port):"
        Write-Log ("Lege Website an: {0} -> {1} (http {2})" -f $name, $docRoot, $binding)
        $r = Invoke-AppCmd @('add', 'site', "/name:$name", "/physicalPath:$docRoot", "/bindings:http/$binding")
        if ($r.ExitCode -ne 0) { throw "appcmd add site fehlgeschlagen: $($r.Output)" }
        Write-Log 'Website angelegt.' 'Ok'
    } else {
        Write-Log "Website '$name' vorhanden - Bindings bleiben unverändert ($($site.Bindings))."
    }

    $r = Invoke-AppCmd @('set', 'app', "$name/", "/applicationPool:$name")
    if ($r.ExitCode -ne 0) { throw "App-Pool konnte nicht zugewiesen werden: $($r.Output)" }
    $r = Invoke-AppCmd @('set', 'vdir', "$name/", "/physicalPath:$docRoot")
    if ($r.ExitCode -ne 0) { throw "Physischer Pfad konnte nicht gesetzt werden: $($r.Output)" }
    Write-Log "Website nutzt App-Pool '$name', physischer Pfad $docRoot." 'Ok'

    $r = Invoke-AppCmd @('set', 'config', $name,
        '-section:system.webServer/security/authentication/anonymousAuthentication',
        '/enabled:true', '/userName:""', '/commit:apphost')
    if ($r.ExitCode -ne 0) { throw "Anonyme Anmeldung konnte nicht auf den App-Pool-Benutzer gestellt werden: $($r.Output)" }
    Write-Log "Anonyme Anfragen laufen als IIS AppPool\$name." 'Ok'

    # +1 MB fuer den Rahmen einer multipart-Anfrage: eine Datei von genau
    # uploads.max_mb soll noch bis zur Anwendung kommen
    $want = [long](($Plan.Inst.UploadsMaxMb + 1) * 1048576)
    $have = Get-IisUploadLimit -Site $name
    $bytes = [long][math]::Max($want, $have)
    $r = Invoke-AppCmd @('set', 'config', $name, '-section:system.webServer/security/requestFiltering',
        "/requestLimits.maxAllowedContentLength:$bytes", '/commit:apphost')
    if ($r.ExitCode -ne 0) { throw "Upload-Grenze konnte nicht gesetzt werden: $($r.Output)" }
    Write-Log ("Upload-Grenze der Website: {0} Bytes ({1} MB, uploads.max_mb = {2})" -f $bytes, [math]::Floor($bytes / 1MB), $Plan.Inst.UploadsMaxMb) 'Ok'

    Start-ProjectPool -Name $name
    $r = Invoke-AppCmd @('start', 'site', "/site.name:$name")
    if ($r.ExitCode -eq 0) {
        Write-Log 'Website gestartet.' 'Ok'
    } else {
        $state = @(Get-IisSites | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
        if ($state -and $state.State -eq 'Started') { Write-Log 'Website läuft bereits.' 'Ok' }
        else { throw "Die Website konnte nicht gestartet werden: $($r.Output)" }
    }
}

# ==============================================================================
#  8) Ordner und Rechte
# ==============================================================================

function Invoke-Icacls {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = Join-Path $env:windir 'System32\icacls.exe'
    $r = Invoke-ExeCapture -FilePath $exe -ArgumentList (ConvertTo-CmdArgs $Arguments) -TimeoutSec 600
    if ($r.ExitCode -ne 0) { throw "icacls $($Arguments[0]): $($r.Lines -join ' ')" }
}

<#
 Rechte wie in docs/03 "Ordner haerten" (SIDs statt Gruppennamen):
   Programmordner  Administratoren/SYSTEM Vollzugriff, App-Pool Lesen/Ausfuehren,
                   Vererbung gekappt
   Datenordner     Administratoren/SYSTEM Vollzugriff, App-Pool Aendern (OI)(CI)
                   - die Windows-Aufgabe legt als SYSTEM Dateien an, die der
                   App-Pool weiter beschreiben muss. Liegen Data/Cache/Logs/Temp
                   nicht unter einem gemeinsamen Ordner, je Pfad einzeln.
   C:\AK           Administratoren/SYSTEM Vollzugriff, Benutzer Lesen (alle
                   App-Pools brauchen services.json und logos) - erst NACH dem
                   Programmordner, der darunter liegt
 Der Ordner Sicherung im Datenordner hat eigene Rechte (nur Administratoren/
 SYSTEM, Vererbung gekappt) und bleibt davon unberuehrt.
#>
function Set-ProjectAcls {
    param([Parameter(Mandatory)]$Plan)
    $pool = "IIS AppPool\$($Plan.Ordner)"
    try { [void](New-Object System.Security.Principal.NTAccount($pool)).Translate([System.Security.Principal.SecurityIdentifier]) }
    catch { throw "Das Konto '$pool' gibt es nicht ($($_.Exception.Message)). Ist der App-Pool angelegt?" }
    $adm = "*$($script:SidAdmins):(OI)(CI)F"
    $sys = "*$($script:SidSystem):(OI)(CI)F"

    Invoke-Icacls @($Plan.ProgDir, '/inheritance:r', '/grant:r', $adm, $sys, "${pool}:(OI)(CI)RX")
    Write-Log "Programmordner gehärtet: $($Plan.ProgDir) (Administratoren/SYSTEM voll, $pool lesen)" 'Ok'

    foreach ($d in @($Plan.AclDataDirs)) {
        Invoke-Icacls @($d, '/inheritance:r', '/grant:r', $adm, $sys, "${pool}:(OI)(CI)M")
        Write-Log "Datenordner gehärtet: $d (Administratoren/SYSTEM voll, $pool ändern)" 'Ok'
    }

    Set-SharedRootAcl -Root $Plan.ProgRoot
}

function New-DataFolders {
    param([Parameter(Mandatory)]$Plan)
    $all = @()
    if ($Plan.DataDir) { $all += $Plan.DataDir }
    $all += @($Plan.Paths.Data, $Plan.Paths.Cache, $Plan.Paths.Logs, $Plan.Paths.Temp)
    foreach ($p in $all) {
        if (Test-Path -LiteralPath $p) { Write-Log "vorhanden: $p" }
        else { New-Item -ItemType Directory -Path $p -Force | Out-Null; Write-Log "angelegt: $p" 'Ok' }
    }
}

# Vorschlag fuer den Datenordner: <datenOrdner>\<Ordner>, ohne Laufwerk C:\AKDaten\<Ordner>
function Get-DefaultDataRoot {
    if (Test-FixedDrive $script:Settings.DataRoot) { return $script:Settings.DataRoot }
    return (Join-Path $env:SystemDrive 'AKDaten')
}

# [IO.Path]::Combine statt Join-Path: Join-Path bricht bei einem nicht
# vorhandenen Laufwerk ab ("X:\AK" soll in der Pruefung gemeldet werden)
function Get-DefaultPaths {
    param([Parameter(Mandatory)][string]$DataDir)
    return [pscustomobject]@{
        Data  = [System.IO.Path]::Combine($DataDir, 'Data')
        Cache = [System.IO.Path]::Combine($DataDir, 'Cache')
        Logs  = [System.IO.Path]::Combine($DataDir, 'Logs')
        Temp  = [System.IO.Path]::Combine($DataDir, 'Temp')
    }
}

# Laufwerk bzw. Freigabe eines Pfades ("c:" oder "\\server\freigabe")
function Get-PathVolume {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]:)') { return $Matches[1].ToLowerInvariant() }
    if ($Path -match '^(\\\\[^\\]+\\[^\\]+)') { return $Matches[1].ToLowerInvariant() }
    return ''
}

function Test-PathUnder {
    param([string]$Path, [string]$Parent)
    $p = $Path.TrimEnd('\'); $q = $Parent.TrimEnd('\')
    return ($p -ieq $q -or $p.StartsWith($q + '\', [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($q + '/', [StringComparison]::OrdinalIgnoreCase))
}

<#
 Regeln der Vorlage fuer Data/Cache/Logs/Temp: absolut, nicht im
 Programmordner oder public\, Temp auf demselben Laufwerk wie Data (Umbenennen
 nach dem Upload ist nur dann atomar). Liefert Fehler und Hinweise.
#>
function Test-DataPaths {
    param([Parameter(Mandatory)]$Paths, [Parameter(Mandatory)][string]$ProgDir, [scriptblock]$DriveTest = $null)
    $errors = New-Object System.Collections.Generic.List[string]
    $hints = New-Object System.Collections.Generic.List[string]
    foreach ($n in @('Data', 'Cache', 'Logs', 'Temp')) {
        $p = [string]$Paths.$n
        if (-not (Test-AbsolutePath $p)) { $errors.Add("paths.$($n.ToLowerInvariant()): '$p' ist kein absoluter Pfad."); continue }
        if (Test-PathUnder $p $ProgDir) { $errors.Add("paths.$($n.ToLowerInvariant()): $p liegt im Programmordner - nicht erlaubt."); continue }
        if ($p.StartsWith('\\')) { $hints.Add("paths.$($n.ToLowerInvariant()): $p ist eine Netzwerkfreigabe - der App-Pool-Benutzer braucht dort Rechte (Computerkonto).") }
        else {
            $ok = if ($DriveTest) { & $DriveTest $p } else { Test-FixedDrive $p }
            if (-not $ok) { $errors.Add("paths.$($n.ToLowerInvariant()): Laufwerk von $p fehlt oder ist kein Festplattenlaufwerk.") }
        }
    }
    if ((Get-PathVolume $Paths.Data) -ne (Get-PathVolume $Paths.Temp)) {
        $errors.Add("paths.temp ($($Paths.Temp)) muss auf demselben Laufwerk liegen wie paths.data ($($Paths.Data)).")
    }
    return [pscustomobject]@{ Errors = $errors.ToArray(); Hints = $hints.ToArray() }
}

# Elternordner eines Windows-Pfades (reine Zeichenkette, auch unter Linux testbar)
function Get-ParentPath {
    param([string]$Path)
    $p = $Path.TrimEnd('\', '/')
    $i = $p.LastIndexOfAny([char[]]@('\', '/'))
    if ($i -lt 0) { return '' }
    return $p.Substring(0, $i)
}

# Gemeinsamer Datenordner einer vorhandenen Installation: Liegen Data, Cache,
# Logs und Temp direkt im selben Ordner (und der ist kein Laufwerk), ist es
# dieser - sonst $null.
function Get-CommonDataDir {
    param([Parameter(Mandatory)]$Paths)
    $parents = @(@($Paths.Data, $Paths.Cache, $Paths.Logs, $Paths.Temp) | ForEach-Object { Get-ParentPath ([string]$_) } | Sort-Object -Unique)
    if ($parents.Count -eq 1 -and $parents[0] -and (Get-ParentPath $parents[0]) -ne '' -and $parents[0] -notmatch '^\\\\[^\\]+\\[^\\]+$') { return $parents[0] }
    return $null
}

<#
 Welche Ordner bekommen die Datenrechte? Der Datenordner und jeder Pfad, der
 nicht darunter liegt; ohne Datenordner (vorhandene Installation mit
 verstreuten Pfaden) jeder Pfad einzeln.
#>
function Get-AclDataDirs {
    param([string]$DataDir, [Parameter(Mandatory)]$Paths)
    $list = @(@($Paths.Data, $Paths.Cache, $Paths.Logs, $Paths.Temp) | ForEach-Object { ([string]$_).TrimEnd('\') })
    $dirs = @()
    if ($DataDir) { $dirs += $DataDir.TrimEnd('\') }
    foreach ($p in $list) {
        if ($DataDir -and (Test-PathUnder $p $DataDir)) { continue }
        if ($dirs -notcontains $p) { $dirs += $p }
    }
    return $dirs
}

# ------------------------------------------------------------------------------
#  Firewall
# ------------------------------------------------------------------------------

# Sind alle Profile der Windows-Firewall aktiv? Liefert die inaktiven (leer = alles gut) oder $null (unbekannt)
function Get-DisabledFirewallProfiles {
    # Enabled ist ein GpoBoolean (True/False/NotConfigured; NotConfigured = Standard = an).
    # Komma vor dem Array: sonst wird eine leere Liste beim return zu $null ("nicht lesbar")
    try { return , @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { [string]$_.Enabled -eq 'False' } | ForEach-Object { [string]$_.Name }) }
    catch { return $null }
}

function Get-FirewallRuleName { param([string]$Ordner) return "SNAIL-$Ordner" }

# Netzwerke im Profil "Oeffentlich" - dort greift die SNAIL-Regel (Domaene/Privat) nicht
function Get-PublicNetworks {
    try { return , @(Get-NetConnectionProfile -ErrorAction Stop | Where-Object { [string]$_.NetworkCategory -eq 'Public' } | ForEach-Object { '{0} ({1})' -f $_.Name, $_.InterfaceAlias }) }
    catch { return , @() }
}

function Get-FirewallPreview {
    param([Parameter(Mandatory)][string]$Ordner, [Parameter(Mandatory)][int]$Port)
    return @"
Name           : SNAIL $Ordner (TCP $Port)
Richtung/Aktion: eingehend, zulassen, TCP, lokaler Port $Port
Profile        : Domäne, Privat
Remote-Adressen: private Bereiche (10/8, 172.16/12, 192.168/16, fc00::/7, fe80::/10)
"@
}

<#
 Firewallregel "im Netzwerk erreichbar" (nur auf Wunsch, nur bei einer
 Neuinstallation). Ohne Regel ist der Port nur lokal erreichbar - das reicht,
 wenn ein Cloudflare Tunnel auf localhost:<port> zeigt.
#>
function Set-ProjectFirewallRule {
    param([Parameter(Mandatory)]$Plan)
    $id = Get-FirewallRuleName $Plan.Ordner
    $old = Get-NetFirewallRule -Name $id -ErrorAction SilentlyContinue
    if ($old) { $old | Remove-NetFirewallRule; Write-Log "Vorhandene Firewallregel $id ersetzt." }
    New-NetFirewallRule -Name $id -DisplayName "SNAIL $($Plan.Ordner) (TCP $($Plan.Inst.Port))" -Description 'Von SNAIL angelegt (Website im Netzwerk erreichbar)' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Plan.Inst.Port -Profile $script:FwProfiles -RemoteAddress $script:FwRemote | Out-Null
    Write-Log "Firewallregel angelegt: SNAIL $($Plan.Ordner) (TCP $($Plan.Inst.Port), Domäne/Privat, private Adressbereiche)" 'Ok'
}

function Set-SharedRootAcl {
    param([Parameter(Mandatory)][string]$Root)
    # Unterordner, die noch von C:\AK erben (nicht gehaertete Programme), nennen -
    # sie bekommen danach nur noch Administratoren/SYSTEM/Benutzer-Lesen
    $offen = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        try { if (-not (Get-Acl -LiteralPath $d.FullName).AreAccessRulesProtected -and $d.Name -ne 'logos') { $offen += $d.Name } } catch { }
    }
    if ($offen.Count -gt 0) {
        Write-Log ("Diese Ordner unter $Root erben noch Rechte (nicht gehärtet): {0}" -f ($offen -join ', ')) 'Warn'
    }
    Invoke-Icacls @($Root, '/inheritance:r', '/grant:r', "*$($script:SidAdmins):(OI)(CI)F", "*$($script:SidSystem):(OI)(CI)F", "*$($script:SidUsers):(OI)(CI)RX")
    Write-Log "Gemeinsamer Ordner gehärtet: $Root (Administratoren/SYSTEM voll, Benutzer lesen)" 'Ok'
}

# Laufwerk vorhanden und Festplatte? (fuer den Vorschlag des Datenordners)
function Test-FixedDrive {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root -or $root.StartsWith('\\')) { return $false }
        $d = New-Object System.IO.DriveInfo($root)
        return ($d.IsReady -and $d.DriveType -eq [System.IO.DriveType]::Fixed)
    } catch { return $false }
}

# ==============================================================================
#  9) Programmcode: ZIP entpacken, Vorlage erkennen, robocopy
# ==============================================================================

# Ordner mit bin\console und public\index.php suchen (GitHub-ZIPs haben einen
# Zwischenordner "<repo>-<branch>"), hoechstens zwei Ebenen tief
# Liefert @{ Path; Rel } oder $null. Rel wird aus den Ordnernamen gebildet,
# nicht per Substring: %TEMP% kann in 8.3-Kurzform (ADMINI~1) vorliegen,
# Get-ChildItem liefert aber die lange Form.
function Find-TemplateRoot {
    param([Parameter(Mandatory)][string]$Dir)
    $kandidaten = @([pscustomobject]@{ Path = (Get-Item -LiteralPath $Dir).FullName; Rel = '' })
    foreach ($a in @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue)) {
        $kandidaten += [pscustomobject]@{ Path = $a.FullName; Rel = $a.Name }
        foreach ($b in @(Get-ChildItem -LiteralPath $a.FullName -Directory -ErrorAction SilentlyContinue)) {
            $kandidaten += [pscustomobject]@{ Path = $b.FullName; Rel = ($a.Name + '\' + $b.Name) }
        }
    }
    foreach ($k in $kandidaten) {
        $console = Join-Path (Join-Path $k.Path 'bin') 'console'
        $index = Join-Path (Join-Path $k.Path 'public') 'index.php'
        if ((Test-Path -LiteralPath $console) -and (Test-Path -LiteralPath $index)) { return $k }
    }
    return $null
}

<#
 Entpackt die ZIP in einen eigenen Ordner unter %TEMP%\SNAIL und merkt sich
 das Ergebnis (gleiche Datei, gleicher Zeitstempel -> nicht noch einmal).
#>
function Expand-TemplateZip {
    param([Parameter(Mandatory)][string]$Zip)
    $item = Get-Item -LiteralPath $Zip
    $tag = $item.FullName + '|' + $item.LastWriteTimeUtc.Ticks
    if ($script:Staging -and $script:Staging.Tag -eq $tag -and (Test-Path -LiteralPath $script:Staging.Root)) { return $script:Staging }
    Remove-Staging
    $dir = Join-Path $script:StagingDir ('zip-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Log "Entpacke $($item.FullName) ..."
    [System.IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $dir)
    $found = Find-TemplateRoot -Dir $dir
    $script:Staging = [pscustomobject]@{
        Tag = $tag; Dir = $dir; Root = $(if ($found) { $found.Path } else { $null }); Inner = $(if ($found) { $found.Rel } else { '' }); Zip = $item.FullName
    }
    return $script:Staging
}

function Remove-Staging {
    if ($script:Staging -and $script:Staging.Dir -and (Test-Path -LiteralPath $script:Staging.Dir)) {
        Remove-Item -LiteralPath $script:Staging.Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:Staging = $null
}

# Aufbau nach Vorlage (Pflicht) - liefert fehlende Teile
function Test-TemplateStructure {
    param([Parameter(Mandatory)][string]$Root)
    $fehlt = @()
    foreach ($f in @('public\index.php', 'public\web.config', 'bin\console', 'config.example.php')) {
        $p = $Root
        foreach ($teil in $f.Split('\')) { $p = Join-Path $p $teil }
        if (-not (Test-Path -LiteralPath $p)) { $fehlt += $f }
    }
    $mig = Join-Path (Join-Path $Root 'database') 'migrations'
    if (-not (Test-Path -LiteralPath $mig) -or @(Get-ChildItem -LiteralPath $mig -Filter '*.sql' -File -ErrorAction SilentlyContinue).Count -eq 0) {
        $fehlt += 'database\migrations\*.sql'
    }
    return $fehlt
}

<#
 Programmcode nach C:\AK\<Ordner> spiegeln. robocopy /MIR - die config.php mit
 VOLLEM Pfad ausnehmen: /XF config.php traefe auch src\Support\Config.php
 (Windows unterscheidet keine Gross-/Kleinschreibung). Neue Dateien erben die
 Rechte des Zielordners. Exitcode ab 8 = Fehler.
#>
function Copy-ProgramCode {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target)
    if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
    $exe = Join-Path $env:windir 'System32\robocopy.exe'
    $cfg = Join-Path $Target 'config.php'
    $rcArgs = ConvertTo-CmdArgs @($Source, $Target, '/MIR', '/XF', $cfg, '/R:2', '/W:2', '/NP', '/NFL', '/NDL')
    Write-Log "robocopy $Source -> $Target /MIR /XF $cfg"
    $r = Invoke-ExeCapture -FilePath $exe -ArgumentList $rcArgs -TimeoutSec 1800
    foreach ($l in @($r.Lines | Where-Object { $_ -match '\S' } | Select-Object -Last 8)) { Write-Log ('  ' + $l.Trim()) }
    if ($r.ExitCode -ge 8) { throw "robocopy meldet Fehler (Exitcode $($r.ExitCode)) - Einzelheiten im Protokoll." }
    Write-Log "Programmcode kopiert (robocopy Exitcode $($r.ExitCode))." 'Ok'
}

# ==============================================================================
# 10) PostgreSQL
# ==============================================================================

<#
 Wo liegt psql.exe, welcher Port? Reihenfolge: einstellungen (psqlBin,
 postgresPort) -> C:\ProgramData\WIPP\postgres.json -> Suche unter
 C:\Program Files\PostgreSQL\<Version>\bin, Port 5432.
#>
function Get-PgSettings {
    $pg = [pscustomobject]@{ Bin = ''; Port = 5432; Host = 'localhost'; Superuser = 'postgres'; Version = ''; Source = '' }
    $json = $null
    if (Test-Path -LiteralPath $script:WippPgJson) {
        try { $json = Get-Content -LiteralPath $script:WippPgJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $json = $null }
    }
    if ($json -and [string]$json.format -eq [string]$script:FormatVersion) {
        $pg.Bin = [string]$json.bin
        if ($json.port) { $pg.Port = [int]$json.port }
        if ($json.host) { $pg.Host = [string]$json.host }
        if ($json.superuser) { $pg.Superuser = [string]$json.superuser }
        $pg.Version = [string]$json.version
        $pg.Source = $script:WippPgJson
    }
    if ($script:Settings.PsqlBin) { $pg.Bin = $script:Settings.PsqlBin; $pg.Source = 'projekte.json (einstellungen.psqlBin)' }
    if ($script:Settings.PgPort -gt 0) { $pg.Port = [int]$script:Settings.PgPort }
    if (-not $pg.Bin) {
        $pf = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PostgreSQL'
        $best = @(Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'bin\psql.exe')) } |
                  Sort-Object { [int]$_.Name } -Descending) | Select-Object -First 1
        if ($best) { $pg.Bin = Join-Path $best.FullName 'bin'; $pg.Source = 'gefunden unter ' + $pf }
    }
    $pg.Bin = $pg.Bin.TrimEnd('\')
    return $pg
}

# WIPP-Format: #-Zeilen und Zeilen ohne = ueberspringen; Schluessel bis zum
# ersten = (getrimmt), Wert ist ALLES danach (nicht getrimmt).
function Read-KeyValueFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $h = @{}
    foreach ($l in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($l -match '^\s*#' -or $l.IndexOf('=') -lt 0) { continue }
        $i = $l.IndexOf('=')
        $h[$l.Substring(0, $i).Trim()] = $l.Substring($i + 1)
    }
    return $h
}

function Get-SavedSuperuserPassword {
    $h = $null
    try { $h = Read-KeyValueFile -Path $script:WippPgCred } catch { }
    if ($h -and $h['passwort']) { return [string]$h['passwort'] }
    return $null
}

<#
 SCRAM-SHA-256-Verifier (RFC 5802/7677) im Format von PostgreSQL - wie WIPP.
 CREATE/ALTER ROLE ... PASSWORD '<Verifier>' uebernimmt den fertigen Hash;
 das Klartextpasswort erreicht weder Server noch dessen Protokoll.
#>
function ConvertTo-ScramVerifier {
    param([Parameter(Mandatory)][string]$Password, [int]$Iterations = 4096, [byte[]]$Salt = $null)
    if (-not $Salt) {
        $Salt = New-Object byte[] 16
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($Salt)
        $rng.Dispose()
    }
    $pw  = [System.Text.Encoding]::UTF8.GetBytes($Password)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $salted = $kdf.GetBytes(32)
    $kdf.Dispose()
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $salted)
    $clientKey = $hmac.ComputeHash([System.Text.Encoding]::ASCII.GetBytes('Client Key'))
    $serverKey = $hmac.ComputeHash([System.Text.Encoding]::ASCII.GetBytes('Server Key'))
    $hmac.Dispose()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $storedKey = $sha.ComputeHash($clientKey)
    $sha.Dispose()
    return ('SCRAM-SHA-256${0}:{1}${2}:{3}' -f $Iterations, [Convert]::ToBase64String($Salt),
        [Convert]::ToBase64String($storedKey), [Convert]::ToBase64String($serverKey))
}

<#
 Fuehrt ein PostgreSQL-Programm (psql, pg_dump) als Superuser aus, ohne dass
 das Passwort in einer Kommandozeile landet: Es steht nur in einer
 temporaeren pgpass-Datei (ACL nur Administratoren/SYSTEM), deren Pfad das
 Programm ueber PGPASSFILE erhaelt; die Datei wird sofort geloescht.
#>
function Invoke-PgTool {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)]$Pg,
        [string]$StdIn = '',
        [int]$TimeoutSec = 120
    )
    $exe = Join-Path $Pg.Bin $Tool
    if (-not (Test-Path -LiteralPath $exe)) { throw "$Tool nicht gefunden: $exe" }
    if (-not (Test-Path -LiteralPath $script:StagingDir)) { New-Item -ItemType Directory -Path $script:StagingDir -Force | Out-Null }
    $pass = Join-Path $script:StagingDir ('snail_{0}.pgpass' -f [guid]::NewGuid().ToString('N'))
    try {
        # pgpass: Doppelpunkt und Backslash im Passwort maskieren
        $esc = $Password.Replace('\', '\\').Replace(':', '\:')
        Write-SecretFile -Path $pass -Text ("*:{0}:*:{1}:{2}`n" -f $Pg.Port, $Pg.Superuser, $esc)
        $all = @('-h', '127.0.0.1', '-p', [string]$Pg.Port, '-U', $Pg.Superuser, '-w') + $Arguments
        return (Invoke-ExeCapture -FilePath $exe -ArgumentList (ConvertTo-CmdArgs $all) -StdIn $StdIn -Utf8Output -TimeoutSec $TimeoutSec -Environment @{
            PGPASSFILE        = $pass
            PGPASSWORD        = $null     # eine geerbte Variable haette Vorrang
            PGCONNECT_TIMEOUT = '10'
            PGCLIENTENCODING  = 'UTF8'
        })
    } finally {
        if (Test-Path -LiteralPath $pass) { Remove-Item -LiteralPath $pass -Force -ErrorAction SilentlyContinue }
    }
}

# SQL ueber die Standardeingabe an psql (-f -), Ausgabe ohne Kopf (-t -A)
function Invoke-Psql {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)]$Pg,
        [string]$Database = 'postgres',
        [switch]$NoThrow
    )
    $r = Invoke-PgTool -Tool 'psql.exe' -Pg $Pg -Password $Password -StdIn $Sql `
        -Arguments @('-X', '-q', '-t', '-A', '-v', 'ON_ERROR_STOP=1', '-d', $Database, '-f', '-')
    if ($r.ExitCode -ne 0 -and -not $NoThrow) { throw "psql meldet Fehler: $($r.Error.Trim() -replace '\s+', ' ')" }
    return $r
}

function Test-PgSuperuser {
    param([Parameter(Mandatory)]$Pg, [string]$Password)
    if ([string]::IsNullOrEmpty($Password)) { return [pscustomobject]@{ Ok = $false; Major = 0; Version = ''; Message = 'Kein Passwort.' } }
    try {
        $r = Invoke-Psql -Pg $Pg -Password $Password -NoThrow -Sql "SELECT current_setting('server_version_num') || '|' || current_setting('server_version');"
    } catch {
        return [pscustomobject]@{ Ok = $false; Major = 0; Version = ''; Message = $_.Exception.Message }
    }
    $line = @($r.Output -split "`r?`n" | Where-Object { $_ -match '^\d+\|' }) | Select-Object -First 1
    if ($r.ExitCode -eq 0 -and $line) {
        $num, $ver = $line -split '\|', 2
        $ver = ($ver -replace '\s.*$', '')
        return [pscustomobject]@{ Ok = $true; Major = [int]([math]::Floor([int]$num / 10000)); Version = $ver; Message = "Verbindung ok, PostgreSQL $ver" }
    }
    $msg = ($r.Error.Trim() -split "`r?`n" | Select-Object -First 1)
    return [pscustomobject]@{ Ok = $false; Major = 0; Version = ''; Message = $(if ($msg) { $msg } else { "psql Exitcode $($r.ExitCode)" }) }
}

# Gibt es Rolle und Datenbank schon, und wem gehoert die Datenbank?
function Get-PgObjectState {
    param([Parameter(Mandatory)]$Pg, [Parameter(Mandatory)][string]$Password, [Parameter(Mandatory)][string]$DbName, [Parameter(Mandatory)][string]$Role)
    foreach ($n in @($DbName, $Role)) { $m = Test-PgIdentifier $n; if ($m) { throw $m } }
    $sql = "SELECT (SELECT count(*) FROM pg_roles WHERE rolname = '$Role') || '|' || coalesce((SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$DbName'), '');"
    $r = Invoke-Psql -Pg $Pg -Password $Password -Sql $sql
    $line = @($r.Output -split "`r?`n" | Where-Object { $_ -match '^\d+\|' }) | Select-Object -First 1
    if (-not $line) { throw "Unerwartete Antwort von psql: $($r.Output.Trim())" }
    $cnt, $owner = $line -split '\|', 2
    return [pscustomobject]@{ RoleExists = ([int]$cnt -gt 0); DbExists = ($owner -ne ''); DbOwner = $owner }
}

<#
 Rolle und Datenbank wie in docs/03:
   CREATE ROLE <user> LOGIN PASSWORD '...';
   CREATE DATABASE <db> OWNER <user> ENCODING 'UTF8' TEMPLATE template0;
 Wiederholbar: Rolle vorhanden -> ALTER ROLE mit dem Passwort, das in der
 config.php steht bzw. stehen wird. Datenbank vorhanden und gehoert der Rolle
 -> nichts zu tun; gehoert sie jemand anderem -> Fehler.
#>
function New-ProjectDatabase {
    param([Parameter(Mandatory)]$Pg, [Parameter(Mandatory)][string]$Password,
          [Parameter(Mandatory)][string]$DbName, [Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$DbPassword)
    $state = Get-PgObjectState -Pg $Pg -Password $Password -DbName $DbName -Role $Role
    $verifier = ConvertTo-ScramVerifier -Password $DbPassword
    if ($state.RoleExists) {
        Invoke-Psql -Pg $Pg -Password $Password -Sql "ALTER ROLE ""$Role"" WITH LOGIN PASSWORD '$verifier';" | Out-Null
        Write-Log "Rolle '$Role' vorhanden - Passwort angeglichen (als SCRAM-Hash übertragen)." 'Ok'
    } else {
        Invoke-Psql -Pg $Pg -Password $Password -Sql "CREATE ROLE ""$Role"" LOGIN PASSWORD '$verifier';" | Out-Null
        Write-Log "Rolle '$Role' angelegt (Passwort als SCRAM-Hash übertragen)." 'Ok'
    }
    if ($state.DbExists) {
        if ($state.DbOwner -ne $Role) { throw "Die Datenbank '$DbName' gibt es schon, sie gehört aber '$($state.DbOwner)' statt '$Role'." }
        Write-Log "Datenbank '$DbName' vorhanden (Eigentümer $Role)." 'Ok'
    } else {
        # CREATE DATABASE darf nicht in einer Transaktion laufen - eigener Aufruf
        Invoke-Psql -Pg $Pg -Password $Password -Sql "CREATE DATABASE ""$DbName"" OWNER ""$Role"" ENCODING 'UTF8' TEMPLATE template0;" | Out-Null
        Write-Log "Datenbank '$DbName' angelegt (Eigentümer $Role, UTF8, template0)." 'Ok'
    }
}

<#
 Sperre im Schritt "Datenbank" einer Neuinstallation: Gibt es Datenbank oder
 Rolle schon, wird sie nur uebernommen, wenn die Pruefung das als Fortsetzen
 desselben Ordners erkannt oder der Anwender das Uebernehmen bestaetigt hat.
#>
function Assert-DbNotExisting {
    param([Parameter(Mandatory)]$Pg, [Parameter(Mandatory)][string]$Password, [Parameter(Mandatory)][string]$DbName, [Parameter(Mandatory)][string]$Role)
    $s = Get-PgObjectState -Pg $Pg -Password $Password -DbName $DbName -Role $Role
    if ($s.DbExists -or $s.RoleExists) {
        $what = @()
        if ($s.DbExists) { $what += "Datenbank '$DbName'" }
        if ($s.RoleExists) { $what += "Rolle '$Role'" }
        throw ("{0} gibt es schon - übernommen wird nur nach Bestätigung auf der Seite ""Prüfen"" (Zurück, erneut prüfen)." -f ($what -join ' und '))
    }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f [math]::Ceiling($Bytes / 1KB))
}

# Ordner fuer Sicherungen einer Installation: <Datenordner>\Sicherung
# (nicht im Programmordner - robocopy /MIR wuerde sie loeschen)
function Get-BackupRoot {
    param([Parameter(Mandatory)]$Plan)
    $base = if ($Plan.DataDir) { $Plan.DataDir } else { Get-ParentPath $Plan.Paths.Data }
    return [System.IO.Path]::Combine($base, 'Sicherung')
}

# Anzahl und Groesse vorhandener Sicherungen (fuer die Anzeige; SNAIL raeumt nie auf)
function Get-BackupInfo {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return [pscustomobject]@{ Count = 0; Bytes = [long]0; Text = "noch keine ($Root)" } }
    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)
    $bytes = [long](@(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum)
    return [pscustomobject]@{ Count = $dirs.Count; Bytes = $bytes; Text = ('{0} Sicherung(en), zusammen {1} in {2} - SNAIL löscht nie automatisch' -f $dirs.Count, (Format-Size $bytes), $Root) }
}

<#
 Sicherung vor einem Update: pg_dump (Custom-Format) und config.php nach
 <Datenordner>\Sicherung\<Zeit>\. Der Ordner Sicherung bekommt eigene Rechte
 (nur Administratoren/SYSTEM, Vererbung gekappt) - der App-Pool darf im
 Datenordner sonst aendern.
#>
function Backup-Installation {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$Password)
    $root = Get-BackupRoot -Plan $Plan
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    Protect-AdminOnly -Path $root
    $dir = Join-Path $root ('{0:yyyyMMdd_HHmmss}' -f (Get-Date))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $Plan.ProgDir 'config.php') -Destination (Join-Path $dir 'config.php')
    $dump = Join-Path $dir ($Plan.DbName + '.dump')
    $r = Invoke-PgTool -Tool 'pg_dump.exe' -Pg $Plan.Pg -Password $Password -TimeoutSec 3600 -Arguments @('-Fc', '-f', $dump, '-d', $Plan.DbName)
    if ($r.ExitCode -ne 0) { throw "pg_dump fehlgeschlagen: $($r.Error.Trim() -replace '\s+', ' ')" }
    # Groesse wie auf "Pruefen": ganze Sicherung (Dump + config.php)
    $size = [long](@(Get-ChildItem -LiteralPath $dir -File | Measure-Object -Property Length -Sum).Sum)
    Write-Log ("Sicherung: {0} und config.php in {1} (zusammen {2})" -f (Split-Path -Leaf $dump), $dir, (Format-Size $size)) 'Ok'
    Write-Log 'Der Data-Ordner gehört in die reguläre Sicherung - SNAIL kopiert ihn nicht.'
    return [pscustomobject]@{ Dir = $dir; Bytes = [long]$size; Text = ('{0} ({1})' -f $dir, (Format-Size $size)) }
}

# Wie viele Benutzerkonten hat die Anwendung? (-1 = Tabelle fehlt / nicht lesbar)
function Get-UserCount {
    param([Parameter(Mandatory)]$Pg, [Parameter(Mandatory)][string]$Password, [Parameter(Mandatory)][string]$DbName)
    $r = Invoke-Psql -Pg $Pg -Password $Password -Database $DbName -NoThrow -Sql "SELECT 'n=' || count(*) FROM users;"
    if ($r.ExitCode -eq 0 -and $r.Output -match 'n=(\d+)') { return [int]$Matches[1] }
    return -1
}

# ==============================================================================
# 11) PHP: php.exe finden, Module pruefen, Projekt-Konsole aufrufen
# ==============================================================================

<#
 Sucht php.exe: einstellungen.phpExe -> C:\ProgramData\WIPP\php-pfad.txt ->
 die in IIS registrierte FastCGI-Anwendung (php-cgi.exe -> php.exe daneben) ->
 PATH (auch der maschinenweite) -> C:\Program Files\PHP.
#>
function Find-PhpExe {
    $cands = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        $p = $p.Trim().Trim('"')
        if ($p -match '\.exe$') { $cands.Add($p) } else { $cands.Add((Join-Path $p 'php.exe')) }
    }
    & $add $script:Settings.PhpExe
    if (Test-Path -LiteralPath $script:WippPhpFile) {
        # ReadAllText entfernt ein BOM selbst
        try { & $add ([System.IO.File]::ReadAllText($script:WippPhpFile, [System.Text.Encoding]::UTF8).Trim()) } catch { }
    }
    if (Test-Path -LiteralPath $script:AppCmd) {
        try {
            $r = Invoke-AppCmd @('list', 'config', '-section:system.webServer/fastCgi')
            foreach ($m in [regex]::Matches(($r.Lines -join "`n"), 'fullPath="([^"]+?php-cgi\.exe)"', 'IgnoreCase')) {
                $cands.Add((Join-Path (Split-Path -Parent $m.Groups[1].Value) 'php.exe'))
            }
        } catch { }
    }
    $cmd = Get-Command php.exe -ErrorAction SilentlyContinue
    if ($cmd) { $cands.Add($cmd.Source) }
    try {
        foreach ($d in ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';')) { if ($d.Trim()) { $cands.Add((Join-Path $d.Trim() 'php.exe')) } }
    } catch { }
    $cands.Add((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PHP\php.exe'))
    foreach ($c in $cands) {
        try { if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path } } catch { }
    }
    return $null
}

# Version, Module und Upload-Grenzen von php.exe
function Get-PhpInfo {
    param([Parameter(Mandatory)][string]$Exe)
    $code = 'echo PHP_VERSION, "|", ini_get("upload_max_filesize"), "|", ini_get("post_max_size"), "|", implode(",", array_map("strtolower", get_loaded_extensions()));'
    $r = Invoke-ExeCapture -FilePath $Exe -ArgumentList (ConvertTo-CmdArgs @('-r', $code)) -Utf8Output -TimeoutSec 60
    $line = @($r.Output -split "`r?`n" | Where-Object { $_ -match '^\d+\.\d+\.\d+.*\|' }) | Select-Object -First 1
    $info = [pscustomobject]@{ Version = $null; Text = ''; Upload = ''; Post = ''; Modules = @(); LoadErrors = @() }
    if ($line) {
        $parts = $line -split '\|'
        if ($parts[0] -match '^(\d+\.\d+\.\d+)') { $info.Version = [version]$Matches[1] }
        $info.Text = $parts[0]
        $info.Upload = $parts[1]; $info.Post = $parts[2]
        $info.Modules = @($parts[3] -split ',')
    } else {
        $info.Text = ($r.Lines | Select-Object -First 1)
    }
    $info.LoadErrors = @($r.Lines | Where-Object { $_ -match 'Warning|Unable to load|Fatal' })
    return $info
}

# "250M" -> MB
function ConvertTo-Megabytes {
    param([string]$Value)
    if ($Value -match '^\s*(\d+)\s*([KMG]?)\s*$') {
        $n = [double]$Matches[1]
        switch ($Matches[2].ToUpperInvariant()) { 'K' { return $n / 1024 } 'G' { return $n * 1024 } 'M' { return $n } default { return $n / 1048576 } }
    }
    return -1
}

<#
 "php bin\console <Befehl>" im Programmordner. Zeilen mit einem Passwort
 (user:create: "Initiales Passwort: ...") kommen nicht ins Protokoll.
#>
# -ExitCodeChecked: einen Exit-Code ungleich 0 wertet der Aufrufer aus (z. B.
# user:create bei vorhandenem Benutzer) - dann keine Error-Zeile im Protokoll
function Invoke-Console {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSec = 600, [switch]$ExitCodeChecked)
    $console = Join-Path (Join-Path $Plan.ProgDir 'bin') 'console'
    if (-not (Test-Path -LiteralPath $console)) { throw "Projekt-Konsole nicht gefunden: $console" }
    Write-Log ("php bin\console {0}" -f ($Arguments -join ' '))
    $r = Invoke-ExeCapture -FilePath $Plan.PhpExe -ArgumentList (ConvertTo-CmdArgs (@($console) + $Arguments)) -WorkingDirectory $Plan.ProgDir -Utf8Output -TimeoutSec $TimeoutSec
    foreach ($l in $r.Lines) {
        $shown = if ($l -match 'Passwort:\s*\S') { ($l -replace '(Passwort:\s*).*$', '$1********') } else { $l }
        Write-Log ('  ' + $shown) $(if ($r.ExitCode -eq 0 -or $ExitCodeChecked) { 'Info' } else { 'Warn' })
    }
    Write-Log ("Exit-Code {0}" -f $r.ExitCode) $(if ($r.ExitCode -eq 0) { 'Ok' } elseif ($ExitCodeChecked) { 'Info' } else { 'Error' })
    return $r
}

function Invoke-ConsoleMigrate {
    param([Parameter(Mandatory)]$Plan)
    $r = Invoke-Console -Plan $Plan -Arguments @('migrate')
    if ($r.ExitCode -ne 0) { throw "Migrationen fehlgeschlagen (php bin\console migrate): $(Get-ErrorLine -Lines $r.Lines)" }
    $count = @($r.Lines | Where-Object { $_ -match '^\s*\[OK\]' }).Count
    return [pscustomobject]@{ Count = $count; UpToDate = (($r.Lines -join ' ') -match 'Keine offenen Migrationen') }
}

# Aussagekraeftige Fehlerzeile aus einer Ausgabe: die erste mit [FEHLER]/Fehler,
# sonst die letzte, die nicht nur aus Zeichen wie ^ oder ~ besteht (PostgreSQL markiert so die Stelle)
function Get-ErrorLine {
    param([string[]]$Lines)
    $hit = @($Lines | Where-Object { $_ -match '\[FEHLER\]|FEHLER|Fehler|Error|Exception' }) | Select-Object -First 1
    if (-not $hit) { $hit = @($Lines | Where-Object { $_ -match '[\p{L}\d]' }) | Select-Object -Last 1 }
    return ([string]$hit).Trim()
}

<#
 Erster Administrator. Die Konsole gibt das Initialpasswort aus (Wechsel beim
 ersten Login erzwungen). Gibt es den Benutzer schon, ist das kein Fehler -
 das Passwort bleibt dann unveraendert.
#>
function Invoke-ConsoleUserCreate {
    param([Parameter(Mandatory)]$Plan, [string]$Email = '')
    $a = $Plan.Inst.Admin
    $cmdArgs = @('user:create', $a.Login, $a.Name, 'admin')
    if ($Email) { $cmdArgs += $Email }
    $r = Invoke-Console -Plan $Plan -Arguments $cmdArgs -TimeoutSec 120 -ExitCodeChecked
    $all = $r.Lines -join "`n"
    if ($r.ExitCode -eq 0) {
        if ($all -match 'Initiales Passwort:\s*(\S+)') {
            return [pscustomobject]@{ Existed = $false; Passwort = $Matches[1]; Text = "Benutzer '$($a.Login)' angelegt" }
        }
        throw 'user:create meldet Erfolg, aber kein Initialpasswort in der Ausgabe - bitte Protokoll prüfen.'
    }
    if ($all -match 'existiert bereits') {
        Write-Log "Benutzer '$($a.Login)' existiert bereits - Passwort bleibt unverändert (Notfall: php bin\console user:password $($a.Login))."
        return [pscustomobject]@{ Existed = $true; Passwort = $null; Text = "Benutzer '$($a.Login)' war bereits vorhanden" }
    }
    throw "Administrator konnte nicht angelegt werden (php bin\console user:create): $(Get-ErrorLine -Lines $r.Lines)"
}

<#
 "check": Selbstpruefung der Anwendung. Exit 0 = startklar (Warnungen
 erlaubt), 1 = mindestens ein Fehler. Ausgabezeilen:
   [WARNUNG] services.json
             Hinweis ...              <- eingerueckt
             Detail: ...
#>
function ConvertFrom-CheckOutput {
    param([string[]]$Lines)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($l in $Lines) {
        if ($l -match '^\[\s*(OK|WARNUNG|FEHLER|INFO)\s*\]\s*(.*)$') {
            $items.Add([pscustomobject]@{ Status = $Matches[1]; Label = $Matches[2].Trim(); Hint = '' })
        } elseif ($l -match '^\s{4,}(\S.*)$' -and $items.Count -gt 0) {
            $last = $items[$items.Count - 1]
            $last.Hint = ($last.Hint + ' ' + ($Matches[1].Trim() -replace '^\|\s*', '')).Trim()
        }
    }
    return $items.ToArray()
}

function Invoke-ConsoleCheck {
    param([Parameter(Mandatory)]$Plan)
    $r = Invoke-Console -Plan $Plan -Arguments @('check') -TimeoutSec 180
    [pscustomobject]@{
        Ok       = ($r.ExitCode -eq 0)
        ExitCode = $r.ExitCode
        Items    = (ConvertFrom-CheckOutput -Lines $r.Lines)
        Summary  = ($r.Lines | Where-Object { $_ -match '^Ergebnis:' } | Select-Object -Last 1)
    }
}

<#
 Python fuer Dienste mit "braucht": ["python"]. Gesucht wird im PATH (ohne
 den Platzhalter aus dem Microsoft Store unter WindowsApps), im
 maschinenweiten PATH und in der Registry (PythonCore, so installiert es WIPP
 systemweit). Die Skripte selbst startet die Anwendung ueber tasks:run.
#>
function Find-PythonExe {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) { $cands.Add([string]$c.Source) }
    try {
        foreach ($d in ([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';')) { if ($d.Trim()) { $cands.Add((Join-Path $d.Trim() 'python.exe')) } }
    } catch { }
    foreach ($hive in @('HKLM:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore', 'HKCU:\SOFTWARE\Python\PythonCore')) {
        foreach ($k in @(Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue | Sort-Object { try { [version]($_.PSChildName -replace '[^\d.]', '') } catch { [version]'0.0' } } -Descending)) {
            try {
                $ip = Get-ItemProperty -LiteralPath (Join-Path $k.PSPath 'InstallPath') -ErrorAction Stop
                if ($ip.ExecutablePath) { $cands.Add([string]$ip.ExecutablePath) }
                elseif ($ip.'(default)') { $cands.Add((Join-Path ([string]$ip.'(default)') 'python.exe')) }
            } catch { }
        }
    }
    foreach ($c in $cands) {
        if ($c -match '\\WindowsApps\\') { continue }
        try { if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).Path } } catch { }
    }
    return $null
}

# ==============================================================================
# 12) Skripte der Vorlage: Windows-Aufgabe, Pruefskript
# ==============================================================================

<#
 setup\Aufgabenplanung\aufgabe_erstellen.ps1 -ProjektPfad -PhpExe -Unbeaufsichtigt
 Rueckgabe: 0 = eingerichtet, 1 = Fehler, 2 = Rechte fehlen, 3 = Programmordner unklar
#>
function Invoke-TaskScript {
    param([Parameter(Mandatory)]$Plan)
    $file = Join-Path $Plan.ProgDir 'setup\Aufgabenplanung\aufgabe_erstellen.ps1'
    if (-not (Test-Path -LiteralPath $file)) {
        return [pscustomobject]@{ Ok = $false; Text = "Skript fehlt: $file" }
    }
    $a = ConvertTo-CmdArgs @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file,
        '-ProjektPfad', $Plan.ProgDir, '-PhpExe', $Plan.PhpExe, '-Unbeaufsichtigt')
    $r = Invoke-ExeCapture -FilePath $script:PowerShell -ArgumentList $a -TimeoutSec 300
    foreach ($l in $r.Lines) { Write-Log ('  ' + $l) }
    $text = switch ($r.ExitCode) {
        0 { "Windows-Aufgabe '\AK\$($Plan.Ordner) Aufgabenplanung' eingerichtet" }
        1 { 'Fehler beim Anlegen der Aufgabe' }
        2 { 'keine Administratorrechte' }
        3 { 'Programmordner unklar (bin\console nicht gefunden)' }
        default { "unerwarteter Exitcode $($r.ExitCode)" }
    }
    if ($r.ExitCode -ne 0) {
        $last = @($r.Lines) | Select-Object -Last 1
        if ($last) { $text += ': ' + $last.Trim() }
    }
    Write-Log ("aufgabe_erstellen.ps1: Exitcode {0} - {1}" -f $r.ExitCode, $text) $(if ($r.ExitCode -eq 0) { 'Ok' } else { 'Error' })
    $first = ''
    if ($r.ExitCode -eq 0) { $first = Start-TaskOnce -Name "$($Plan.Ordner) Aufgabenplanung" }
    return [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Text = $text; FirstRun = $first }
}

<#
 Die neue Windows-Aufgabe einmal anstossen: zeigt, dass sie als SYSTEM laeuft,
 und check/windows-pruefung melden danach nicht "tasks:run noch nie
 aufgerufen". tasks:run darf jederzeit laufen (die Anwendung entscheidet, was
 faellig ist). Wartet hoechstens 2 Minuten.
#>
function Start-TaskOnce {
    param([Parameter(Mandatory)][string]$Name)
    try {
        Start-ScheduledTask -TaskPath '\AK\' -TaskName $Name
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            for ($k = 0; $k -lt 10; $k++) { Start-Sleep -Milliseconds 100; Invoke-UiPump }
            $state = [string](Get-ScheduledTask -TaskPath '\AK\' -TaskName $Name).State
        } while ($state -eq 'Running' -and $sw.Elapsed.TotalSeconds -lt 120)
        $info = Get-ScheduledTaskInfo -TaskPath '\AK\' -TaskName $Name
        $res = [int64]$info.LastTaskResult
        $text = switch ($res) {
            0       { 'erster Lauf ohne Fehler' }
            1       { 'erster Lauf: eine Aufgabe ist fehlgeschlagen (php bin\console tasks:status)' }
            267009  { 'erster Lauf läuft noch' }
            267011  { 'noch nicht gelaufen' }
            default { 'erster Lauf: Ergebnis 0x{0:X}' -f $res }
        }
        Write-Log "Windows-Aufgabe '\AK\$Name' angestoßen: $text" $(if ($res -eq 0) { 'Ok' } else { 'Warn' })
        return $text
    } catch {
        Write-Log "Windows-Aufgabe konnte nicht angestoßen werden: $($_.Exception.Message)" 'Warn'
        return 'nicht angestoßen'
    }
}

<#
 tools\windows-pruefung.ps1 unter Windows PowerShell 5.1 (das IIS-Modul laeuft
 nicht unter PowerShell 7). Aendert nichts, schreibt einen Bericht.
#>
function Invoke-WindowsCheck {
    param([Parameter(Mandatory)]$Plan)
    $file = Join-Path $Plan.ProgDir 'tools\windows-pruefung.ps1'
    if (-not (Test-Path -LiteralPath $file)) {
        return [pscustomobject]@{ Ok = $false; Ran = $false; Errors = 0; Warnings = 0; Items = @(); Report = ''; Text = "Prüfskript fehlt: $file" }
    }
    Initialize-SnailDir
    if (-not (Test-Path -LiteralPath $script:ReportDir)) { New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null }
    $report = Join-Path $script:ReportDir ('{0}_{1:yyyyMMdd_HHmmss}.txt' -f $Plan.Ordner, (Get-Date))
    # Ohne bekannten Port (Website ohne http-Binding) laeuft das Skript ohne HTTP-Pruefungen
    $url = if ($Plan.Inst.Port -gt 0) { "http://localhost:$($Plan.Inst.Port)" } else { '' }
    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file, '-ProjektPfad', $Plan.ProgDir, '-PhpExe', $Plan.PhpExe, '-Bericht', $report)
    if ($url) { $list += @('-Url', $url) }
    $a = ConvertTo-CmdArgs $list
    $r = Invoke-ExeCapture -FilePath $script:PowerShell -ArgumentList $a -WorkingDirectory $Plan.ProgDir -TimeoutSec 900
    $items = New-Object System.Collections.Generic.List[object]
    $fehler = 0; $warn = 0
    foreach ($l in $r.Lines) {
        Write-Log ('  ' + $l)
        if ($l -match '^\[(FEHLER|WARNUNG)\s*\]\s*(.*)$') {
            $items.Add([pscustomobject]@{ Status = $Matches[1]; Label = $Matches[2].Trim(); Hint = '' })
            if ($Matches[1] -eq 'FEHLER') { $fehler++ } else { $warn++ }
        } elseif ($l -match '^\s{6,}(\S.*)$' -and $items.Count -gt 0 -and $items[$items.Count - 1].Hint -eq '') {
            $items[$items.Count - 1].Hint = $Matches[1].Trim()
        }
    }
    $text = "$fehler Fehler, $warn Warnung(en) - Bericht: $report"
    Write-Log ("windows-pruefung.ps1 -Url {0}: {1}" -f $url, $text) $(if ($fehler -eq 0) { 'Ok' } else { 'Warn' })
    return [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Ran = $true; Errors = $fehler; Warnings = $warn; Items = $items.ToArray(); Report = $report; Text = $text }
}

# ==============================================================================
# 13) Zugangsdaten ablegen
# ==============================================================================

<#
 C:\ProgramData\SNAIL\zugangsdaten\<Ordner>.txt (nur Administratoren/SYSTEM).
 Vorhandene Werte bleiben erhalten (z. B. das Initialpasswort eines frueheren
 Laufs), neue ueberschreiben sie. Fehler brechen die Installation nicht ab.
#>
function Save-InstallCredentials {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][hashtable]$Values)
    $file = Join-Path $script:CredDir ($Plan.Ordner + '.txt')
    try {
        Initialize-SnailDir
        if (-not (Test-Path -LiteralPath $script:CredDir)) { New-Item -ItemType Directory -Path $script:CredDir -Force | Out-Null }
        $map = [ordered]@{}
        $old = Read-KeyValueFile -Path $file
        $order = @('format', 'dienst', 'installation', 'mandant_name', 'ordner', 'url', 'lokal', 'db_host', 'db_port', 'db_name', 'db_benutzer', 'db_passwort', 'app_key', 'admin_login', 'admin_initialpasswort')
        foreach ($k in $order) { if ($old -and $old.ContainsKey($k)) { $map[$k] = $old[$k] } }
        if ($old) { foreach ($k in $old.Keys) { if (-not $map.Contains($k)) { $map[$k] = $old[$k] } } }
        $map['format'] = [string]$script:FormatVersion
        $map['dienst'] = $Plan.Inst.Service.Key
        $map['installation'] = $Plan.Inst.Key
        $map['mandant_name'] = $Plan.Inst.Name
        $map['ordner'] = $Plan.ProgDir
        $map['url'] = $Plan.Inst.Url
        $map['lokal'] = "http://localhost:$($Plan.Inst.Port)/"
        foreach ($k in $Values.Keys) { if ($null -ne $Values[$k] -and [string]$Values[$k] -ne '') { $map[$k] = [string]$Values[$k] } }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("# SNAIL - Zugangsdaten $($Plan.Inst.Display)")
        [void]$sb.AppendLine(('# Stand: {0:yyyy-MM-dd HH:mm} auf {1}' -f (Get-Date), $env:COMPUTERNAME))
        [void]$sb.AppendLine('# Diese Datei enthaelt Klartextpasswoerter. Nach dem Uebertragen in den')
        [void]$sb.AppendLine('# Passwortmanager bitte loeschen. Das DB-Passwort steht auch in der config.php,')
        [void]$sb.AppendLine('# das Initialpasswort gilt nur bis zum ersten Login (Wechsel erzwungen).')
        if ($map.Contains('app_key')) {
            [void]$sb.AppendLine('# app_key (= app.key in der config.php): mit der config.php sichern und im')
            [void]$sb.AppendLine('# Passwortmanager ablegen - ohne ihn sind gespeicherte Passwoerter verloren.')
        }
        foreach ($k in $map.Keys) { [void]$sb.AppendLine(('{0}={1}' -f $k, $map[$k])) }
        Write-SecretFile -Path $file -Text ($sb.ToString() -replace "`r?`n", "`r`n")
        Write-Log "Zugangsdaten abgelegt: $file (nur Administratoren/SYSTEM)" 'Ok'
    } catch {
        Write-Log "Zugangsdaten konnten nicht abgelegt werden ($file): $($_.Exception.Message)" 'Warn'
    }
    return $file
}

# ==============================================================================
# 14) Installationen am Server erkennen, Eingaben prüfen, Prüfung (Seite 3)
# ==============================================================================

# Eintrag eines Dienstes/einer Installation in der services.json (Namen, url)
function Get-ServicesEntry {
    param($Tree, [string]$ServiceKey, [string]$InstKey)
    $res = [pscustomobject]@{ ServiceName = ''; InstName = ''; Url = ''; Found = $false; Logo = '' }
    if ($null -eq $Tree) { return $res }
    foreach ($s in @($Tree['services'])) {
        if ($s -isnot [System.Collections.IDictionary] -or [string]$s['key'] -cne $ServiceKey) { continue }
        $res.ServiceName = [string]$s['name']
        $res.Logo = [string]$s['logo']
        foreach ($x in @($s['installations'])) {
            if ($x -is [System.Collections.IDictionary] -and [string]$x['key'] -ceq $InstKey) {
                $res.InstName = [string]$x['name']; $res.Url = [string]$x['url']; $res.Found = $true
            }
        }
    }
    return $res
}

<#
 Installationen auf diesem Server: jeder Ordner unter C:\AK mit config.php
 UND bin\console (C:\AK\logos u. a. werden uebersprungen). Die Daten kommen
 aus "php bin\console info" (JSON, Datenbank ohne Passwort) - SNAIL liest die
 config.php nicht selbst. Aeltere Staende ohne db in info: Datenbankname und
 Rolle per php -r aus der config.php. Port aus dem IIS-Binding der
 gleichnamigen Website, Mandanten-Name aus der services.json, Dienst aus dem
 Katalog (fehlt er dort, gilt der Name aus services.json bzw. app.name).
#>
function Get-InstalledInstances {
    param([Parameter(Mandatory)][string]$ProgRoot, [string]$PhpExe, $Catalog = @{}, $Sites = @(), [string]$ServicesJson = '', [string]$CredDir = '')
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $ProgRoot)) { return @() }
    $tree = $null
    if ($ServicesJson) { try { $tree = Read-ServicesJson -Path $ServicesJson } catch { $tree = $null } }
    foreach ($d in @(Get-ChildItem -LiteralPath $ProgRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $console = Join-Path (Join-Path $d.FullName 'bin') 'console'
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'config.php')) -or -not (Test-Path -LiteralPath $console)) { continue }
        $inst = [pscustomobject]@{
            Ordner = $d.Name; ProgDir = $d.FullName; ServiceKey = ''; Key = ''; Name = ''; Url = ''; AppName = ''; Version = ''
            Port = 0; Bindings = ''; Paths = $null; Db = $null; UploadsMaxMb = 25; Service = $null; InServicesJson = $false
            ServicesUrl = ''; Error = ''; Display = $d.Name
        }
        try {
            if (-not $PhpExe) { throw 'php.exe nicht gefunden' }
            $r = Invoke-ExeCapture -FilePath $PhpExe -ArgumentList (ConvertTo-CmdArgs @($console, 'info')) -WorkingDirectory $d.FullName -Utf8Output -TimeoutSec 60
            $pos = $r.Output.IndexOf('{')
            if ($r.ExitCode -ne 0 -or $pos -lt 0) { throw ("php bin\console info: " + (@($r.Lines) | Select-Object -Last 1)) }
            $j = $r.Output.Substring($pos) | ConvertFrom-Json
            $inst.ServiceKey = [string]$j.app.service
            $inst.Key = [string]$j.app.installation
            $inst.Url = [string]$j.app.url
            $inst.AppName = [string]$j.app.name
            $inst.Version = [string]$j.app.version
            $inst.Paths = [pscustomobject]@{
                Data = [string]$j.paths.data; Cache = [string]$j.paths.cache; Logs = [string]$j.paths.logs
                Temp = [string]$j.paths.temp; ServicesJson = [string]$j.paths.services_json
            }
            if ($null -ne $j.uploads_max_mb) { $inst.UploadsMaxMb = [int]$j.uploads_max_mb }
            $db = $j.db
            if ($null -eq $db) { $db = (Read-InstalledConfig -ProgDir $d.FullName -PhpExe $PhpExe).db }
            $inst.Db = [pscustomobject]@{ Host = [string]$db.host; Port = [int]$db.port; Name = [string]$db.name; User = [string]$db.user }
            if (-not (Test-ServiceKey $inst.ServiceKey) -or -not (Test-ServiceKey $inst.Key)) { throw "app.service/app.installation fehlen oder sind ungültig ('$($inst.ServiceKey)'/'$($inst.Key)')" }
        } catch {
            $inst.Error = $_.Exception.Message
        }
        $site = @($Sites | Where-Object { $_.Name -ieq $d.Name }) | Select-Object -First 1
        if ($site) { $inst.Bindings = $site.Bindings; $inst.Port = Get-PortFromBindings $site.Bindings }
        $entry = Get-ServicesEntry -Tree $tree -ServiceKey $inst.ServiceKey -InstKey $inst.Key
        $inst.InServicesJson = $entry.Found
        $inst.ServicesUrl = $entry.Url
        # Mandanten-Name: services.json, sonst die Zugangsdatei (Abbruch vor dem
        # services.json-Schritt), sonst der Schluessel
        $credName = ''
        if (-not $entry.InstName -and $CredDir) {
            try { $kv = Read-KeyValueFile -Path (Join-Path $CredDir ($d.Name + '.txt')); if ($kv -and $kv['mandant_name']) { $credName = [string]$kv['mandant_name'] } } catch { }
        }
        $inst.Name = if ($entry.InstName) { $entry.InstName } elseif ($credName) { $credName } elseif ($inst.Key) { $inst.Key } else { '?' }
        if ($inst.ServiceKey -and $Catalog.ContainsKey($inst.ServiceKey)) { $inst.Service = $Catalog[$inst.ServiceKey] }
        else {
            $n = if ($entry.ServiceName) { $entry.ServiceName } elseif ($inst.AppName) { $inst.AppName } else { $d.Name }
            $inst.Service = New-PseudoService -Key $(if ($inst.ServiceKey) { $inst.ServiceKey } else { $d.Name }) -Name $n
            # nur fuer die Anzeige in SNAIL - die services.json behaelt ihren Eintrag
            if ($entry.Logo -and $ServicesJson) { $inst.Service.Logo = Get-LogoData -Value $entry.Logo -BaseDir (Split-Path -Parent $ServicesJson) }
        }
        $inst.Display = if ($inst.Error) { "$($d.Name) (nicht lesbar)" } else { '{0} - {1}' -f $inst.Service.Name, $inst.Name }
        $list.Add($inst)
    }
    return $list.ToArray()
}

# Kurzbezeichnung einer erkannten Installation fuer Meldungen: Ordner (dienst/mandant)
function Format-InstanceRef {
    param([Parameter(Mandatory)]$Instance)
    if ($Instance.Error) { return "$($Instance.Ordner) (nicht lesbar)" }
    return '{0} ({1}/{2})' -f $Instance.Ordner, $Instance.ServiceKey, $Instance.Key
}

<#
 Fortsetzen eines abgebrochenen Laufs DESSELBEN Ordners: Der Programmordner
 existiert (ohne config.php - sonst waere es eine erkannte Installation), die
 Zugangsdatei <Ordner>.txt nennt dieselbe Datenbank und Rolle und ist nicht
 aelter als der Programmordner. Die Datei schreibt der Schritt "Datenbank"
 nach dem Anlegen; eine alte Datei einer von Hand entfernten Installation ist
 aelter als der neu angelegte Programmordner und zaehlt deshalb nicht.
#>
function Test-ResumeRun {
    param([Parameter(Mandatory)][string]$CredFile, [Parameter(Mandatory)][string]$ProgDir, [string]$DbName, [string]$Role)
    if (-not (Test-Path -LiteralPath $ProgDir -PathType Container)) { return $false }
    $kv = $null
    try { $kv = Read-KeyValueFile -Path $CredFile } catch { $kv = $null }
    if (-not $kv -or [string]$kv['db_name'] -cne $DbName -or [string]$kv['db_benutzer'] -cne $Role) { return $false }
    return ((Get-Item -LiteralPath $CredFile).LastWriteTimeUtc -ge (Get-Item -LiteralPath $ProgDir).CreationTimeUtc)
}

<#
 Datenbank und Rolle einer Neuinstallation gegen den Bestand abgleichen
 (-State aus Get-PgObjectState, -Instances = erkannte Installationen mit
 db.name/db.user aus "php bin\console info"):
   Error        gehoert einer anderen Installation oder fremdem Eigentuemer
   Ok           wird angelegt, oder Fortsetzen nach Abbruch (-Resume)
   Warn + Adopt vorhanden, aber keiner erkannten Installation zugeordnet -
                uebernommen wird nur mit Haekchen (Confirm = Text dafuer)
#>
function Get-DbCollision {
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string]$DbName, [Parameter(Mandatory)][string]$Role, $Instances = @(), [bool]$Resume = $false)
    $res = [pscustomobject]@{ Level = 'Ok'; Text = ''; Adopt = $false; Resume = $false; Confirm = '' }
    foreach ($i in @($Instances)) {
        if ($null -eq $i -or $null -eq $i.Db) { continue }
        $hit = @()
        if ($i.Db.Name -and $i.Db.Name -ieq $DbName) { $hit += "Datenbank '$DbName'" }
        if ($i.Db.User -and $i.Db.User -ieq $Role) { $hit += "Rolle '$Role'" }
        if ($hit.Count -gt 0) {
            $res.Level = 'Error'
            $res.Text = '{0} {1} zur Installation {2}.' -f ($hit -join ' und '), $(if ($hit.Count -gt 1) { 'gehören' } else { 'gehört' }), (Format-InstanceRef $i)
            return $res
        }
    }
    if ($State.DbExists -and $State.DbOwner -ne $Role) {
        $res.Level = 'Error'
        $res.Text = "'$DbName' gibt es schon, Eigentümer ist '$($State.DbOwner)' statt '$Role'."
        return $res
    }
    $desc = "{0} ({1}) / Rolle {2} ({3})" -f $DbName, $(if ($State.DbExists) { 'vorhanden' } else { 'wird angelegt' }), $Role, $(if ($State.RoleExists) { 'vorhanden' } else { 'wird angelegt' })
    if (-not $State.DbExists -and -not $State.RoleExists) { $res.Text = $desc; return $res }
    if ($Resume) {
        $res.Resume = $true
        $res.Text = "$desc - Fortsetzen nach Abbruch (laut Zugangsdatei dieses Ordners), Passwort der Rolle wird neu gesetzt"
        return $res
    }
    $res.Level = 'Warn'
    $res.Adopt = $true
    $unread = @($Instances | Where-Object { $_ -and $_.Error } | ForEach-Object { $_.Ordner })
    $res.Text = "$desc - gehört zu keiner erkannten Installation (Rest einer entfernten Installation?). Übernehmen nur mit Häkchen unten: alte Daten bleiben erhalten, das Passwort der Rolle wird neu gesetzt." +
        $(if ($unread.Count -gt 0) { " Nicht lesbar: $($unread -join ', ') - vorher prüfen, ob diese Installation die Datenbank nutzt." } else { '' })
    $res.Confirm = if ($State.DbExists) { "Vorhandene Datenbank '$DbName' übernehmen (alte Daten bleiben erhalten)" } else { "Vorhandene Rolle '$Role' übernehmen (ihr Passwort wird neu gesetzt)" }
    return $res
}

<#
 Gehoeren eine vorhandene IIS-Website bzw. ein App-Pool namens <Ordner> zu
 dieser Neuinstallation? Die Website muss auf <Programmordner>\public zeigen,
 den App-Pool darf hoechstens diese Website nutzen; ein unbenutzter App-Pool
 zaehlt nur, wenn Website oder Programmordner schon da sind (abgebrochener
 Lauf). Liefert die Fehler als Liste (leer = in Ordnung).
#>
function Get-IisNameConflicts {
    param([Parameter(Mandatory)][string]$Ordner, [Parameter(Mandatory)][string]$ProgDir, [bool]$SiteExists = $false, [string]$SitePath = '',
          [bool]$PoolExists = $false, [string[]]$PoolApps = @(), [bool]$ProgDirExists = $false)
    $res = @()
    $docRoot = Join-Path $ProgDir 'public'
    if ($SiteExists -and $SitePath -and $SitePath -ine $docRoot) {
        $res += [pscustomobject]@{ Name = 'Website'; Text = "'$Ordner' gibt es schon und sie zeigt auf $SitePath - gehört nicht zu dieser Installation." }
    }
    if ($PoolExists) {
        $foreign = @($PoolApps | ForEach-Object { ($_ -split '/', 2)[0] } | Where-Object { $_ -and $_ -ine $Ordner } | Sort-Object -Unique)
        if ($foreign.Count -gt 0) {
            $res += [pscustomobject]@{ Name = 'App-Pool'; Text = "'$Ordner' gibt es schon und wird von $($foreign -join ', ') genutzt - gehört nicht zu dieser Installation." }
        } elseif (-not $SiteExists -and -not $ProgDirExists) {
            $res += [pscustomobject]@{ Name = 'App-Pool'; Text = "'$Ordner' gibt es schon, ohne Website und Programmordner (Rest einer entfernten Installation?) - im IIS-Manager entfernen oder einen anderen Mandanten-Schlüssel wählen." }
        }
    }
    return $res
}

<#
 Ist <dienst> als Ordnername frei? Nicht frei, wenn dort eine config.php
 liegt (eine Installation, die nicht zu diesem Dienst gehoert oder nicht
 lesbar ist) oder eine IIS-Website dieses Namens woandershin zeigt (z. B. eine
 alte MySQL-Site "Olaf" in C:\inetpub).
#>
function Test-FirstOrdnerFree {
    param([Parameter(Mandatory)][string]$ServiceKey, [Parameter(Mandatory)][string]$ProgRoot, $Sites = @())
    $dir = Join-Path $ProgRoot $ServiceKey
    if (Test-Path -LiteralPath (Join-Path $dir 'config.php')) {
        return [pscustomobject]@{ Free = $false; Reason = "$dir enthält die config.php einer anderen Installation" }
    }
    $site = @($Sites | Where-Object { $_.Name -ieq $ServiceKey }) | Select-Object -First 1
    if ($site) {
        $path = Get-IisSitePath -Name $site.Name
        if ($path -and $path -ine (Join-Path $dir 'public')) {
            return [pscustomobject]@{ Free = $false; Reason = "IIS-Website '$($site.Name)' zeigt auf $path" }
        }
    }
    return [pscustomobject]@{ Free = $true; Reason = '' }
}

<#
 Ordnername: erste Installation eines Dienstes = <dienst>, jede weitere
 <dienst>-<installation>. Ob es die erste ist, entscheiden die gefundenen
 Installationen (nicht eine Liste in der JSON).
#>
function Resolve-Ordner {
    param([Parameter(Mandatory)][string]$ServiceKey, [Parameter(Mandatory)][string]$InstKey, $Instances = @(), [bool]$FirstFree = $true, [string]$FirstReason = '')
    $mine = @($Instances | Where-Object { $_.ServiceKey -ceq $ServiceKey -and $_.Key -ceq $InstKey }) | Select-Object -First 1
    if ($mine) { return [pscustomobject]@{ Name = $mine.Ordner; Reason = 'bereits installiert'; Existing = $mine } }
    $same = @($Instances | Where-Object { $_.ServiceKey -ceq $ServiceKey })
    $other = "$ServiceKey-$InstKey"
    if ($same.Count -gt 0) {
        $wo = if ($same.Count -eq 1) { "als $($same[0].Ordner)" } else { "$($same.Count)-mal" }
        return [pscustomobject]@{ Name = $other; Reason = ("weitere Installation ('{0}' ist schon {1} installiert)" -f $ServiceKey, $wo); Existing = $null }
    }
    if (-not $FirstFree) { return [pscustomobject]@{ Name = $other; Reason = "weitere Installation ($FirstReason)"; Existing = $null } }
    return [pscustomobject]@{ Name = $ServiceKey; Reason = 'erste Installation des Dienstes'; Existing = $null }
}

<#
 Eingaben der Seite "Angaben" (Neuinstallation) pruefen und in das
 Installationsobjekt umsetzen. $Values: Key, Name, Url, Port, UploadsMaxMb,
 AdminLogin, AdminName, AdminEmail, DataDir, Paths ($null = aus DataDir),
 Firewall, CfTeam, CfAud, CfGuard, MailEnabled, MailHost, MailPort, MailEnc,
 MailUser, MailPass, MailFrom, MailFromName. Ordner, Site, Pool und
 Datenbank folgen aus Dienst + Mandanten-Schluessel und sind nicht editierbar.
#>
function New-InstanceInput {
    param([Parameter(Mandatory)]$Service, [Parameter(Mandatory)][hashtable]$Values, $Instances = @(), [bool]$FirstFree = $true, [string]$FirstReason = '')
    $errors = New-Object System.Collections.Generic.List[string]
    $hints  = New-Object System.Collections.Generic.List[string]
    $v = @{}
    foreach ($k in $Values.Keys) { $v[$k] = $(if ($Values[$k] -is [string]) { $Values[$k].Trim() } else { $Values[$k] }) }

    $key = [string]$v['Key']
    if (-not (Test-ServiceKey $key)) { $errors.Add("Mandanten-Schlüssel '$key': a-z, 0-9, _ und -, erstes Zeichen Buchstabe oder Ziffer, max. 64.") }
    $ord = $null
    if (Test-ServiceKey $key) {
        $ord = Resolve-Ordner -ServiceKey $Service.Key -InstKey $key -Instances $Instances -FirstFree $FirstFree -FirstReason $FirstReason
        if ($ord.Existing) { $errors.Add("$($Service.Name) ist für den Mandanten '$key' schon installiert ($($ord.Name)) - oben unter ""Auf diesem Server installiert"" wählen.") }
        elseif ($ord.Name.Length -gt 64) { $errors.Add("Ordnername '$($ord.Name)' ist länger als 64 Zeichen - kürzeren Schlüssel wählen.") }
    }
    $name = [string]$v['Name']
    if ($name -eq '') { $name = $key }

    $port = 0
    if (-not [int]::TryParse([string]$v['Port'], [ref]$port) -or $port -lt 1 -or $port -gt 65535) { $errors.Add("Port '$($v['Port'])' ist ungültig (1-65535)."); $port = 0 }

    $url = [string]$v['Url']
    if ($url -eq '') { $url = "http://localhost:$port/" }
    if ($url -notmatch '^https?://[^\s/]+[^\s]*$') { $errors.Add('Die Adresse muss mit http:// oder https:// beginnen und darf keine Leerzeichen enthalten.') }

    $upload = 0
    if (-not [int]::TryParse([string]$v['UploadsMaxMb'], [ref]$upload) -or $upload -lt 1 -or $upload -gt 4000) { $errors.Add('Upload-Grenze: 1 bis 4000 MB.'); $upload = 25 }

    $admin = [pscustomobject]@{
        Login = $(if ($v['AdminLogin']) { [string]$v['AdminLogin'] } else { 'admin' })
        Name  = $(if ($v['AdminName']) { [string]$v['AdminName'] } else { 'Administrator' })
        Email = [string]$v['AdminEmail']
    }
    if ($admin.Login -notmatch '^[\w.@-]{1,50}$') { $errors.Add('Admin-Login: 1-50 Zeichen, Buchstaben, Ziffern, . _ @ -.') }
    if ($admin.Name.Length -gt 100) { $errors.Add('Admin-Name: höchstens 100 Zeichen.') }
    if ($admin.Email -and $admin.Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { $errors.Add("Admin-E-Mail '$($admin.Email)' ist keine E-Mail-Adresse.") }

    $cf = $null
    if ($v['CfTeam'] -or $v['CfAud'] -or $v['CfGuard']) {
        $cf = [pscustomobject]@{ TeamDomain = [string]$v['CfTeam']; Aud = [string]$v['CfAud']; Guard = [bool]$v['CfGuard'] }
        if (($cf.TeamDomain -eq '') -ne ($cf.Aud -eq '')) { $hints.Add('Cloudflare: Für die SSO-Anmeldung braucht es Team-Domain UND AUD - sonst bleibt sie aus.') }
    }

    $mail = $null
    if ($v['MailEnabled'] -or $v['MailHost'] -or $v['MailUser'] -or $v['MailPass'] -or $v['MailFrom']) {
        $mp = 587
        if ([string]$v['MailPort'] -ne '' -and (-not [int]::TryParse([string]$v['MailPort'], [ref]$mp) -or $mp -lt 1 -or $mp -gt 65535)) { $errors.Add('Mail-Port ist ungültig.'); $mp = 587 }
        $enc = if ($v['MailEnc']) { [string]$v['MailEnc'] } else { 'tls' }
        if (@('tls', 'ssl', 'none') -notcontains $enc) { $errors.Add('Mail-Verschlüsselung: tls, ssl oder none.') }
        $mail = [pscustomobject]@{
            Enabled = [bool]$v['MailEnabled']; Host = [string]$v['MailHost']; Port = $mp; Encryption = $enc
            Username = [string]$v['MailUser']; Password = [string]$Values['MailPass']; From = [string]$v['MailFrom']; FromName = [string]$v['MailFromName']
        }
        if ($mail.Enabled -and ($mail.Host -eq '' -or $mail.From -eq '')) { $errors.Add('Mail-Versand eingeschaltet: Server und Absender sind Pflicht.') }
    }

    $dataDir = ([string]$v['DataDir']).TrimEnd('\')
    if (-not (Test-AbsolutePath $dataDir)) { $errors.Add("Datenordner '$dataDir' ist kein absoluter Pfad.") }
    $paths = if ($Values['Paths']) { $Values['Paths'] } else { Get-DefaultPaths -DataDir $dataDir }

    $ordner = if ($ord) { $ord.Name } else { '' }
    $db = if ($ordner) { Get-DefaultDbNames -Ordner $ordner } else { [pscustomobject]@{ Name = ''; User = '' } }
    $inst = [pscustomobject]@{
        Kind = 'new'; Service = $Service; Key = $key; Name = $name; Display = ('{0} - {1}' -f $Service.Name, $name)
        Port = $port; Url = $url; UploadsMaxMb = $upload; Admin = $admin; Zeitzone = $script:Settings.Zeitzone
        Cloudflare = $cf; Mail = $mail; Ordner = $ordner; OrdnerReason = $(if ($ord) { $ord.Reason } else { '' })
        DataDir = $dataDir; Paths = $paths; Firewall = [bool]$v['Firewall']; DbName = $db.Name; DbUser = $db.User; Instance = $null
    }
    return [pscustomobject]@{ Errors = $errors.ToArray(); Hints = $hints.ToArray(); Inst = $inst }
}

# Gefundene Installation -> Installationsobjekt fuer Pruefung und Ablauf
function ConvertTo-InstallTarget {
    param([Parameter(Mandatory)]$Instance)
    $p = $Instance.Paths
    $paths = if ($p) { [pscustomobject]@{ Data = $p.Data; Cache = $p.Cache; Logs = $p.Logs; Temp = $p.Temp } } else { $null }
    return [pscustomobject]@{
        Kind = 'installed'; Service = $Instance.Service; Key = $Instance.Key; Name = $Instance.Name; Display = $Instance.Display
        Port = $Instance.Port; Url = $Instance.Url; UploadsMaxMb = $Instance.UploadsMaxMb
        Admin = [pscustomobject]@{ Login = 'admin'; Name = 'Administrator'; Email = '' }; Zeitzone = $script:Settings.Zeitzone
        Cloudflare = $null; Mail = $null; Ordner = $Instance.Ordner; OrdnerReason = 'vorhandene Installation'
        DataDir = $(if ($paths) { Get-CommonDataDir -Paths $paths } else { $null }); Paths = $paths; Firewall = $false
        DbName = $(if ($Instance.Db) { $Instance.Db.Name } else { '' }); DbUser = $(if ($Instance.Db) { $Instance.Db.User } else { '' })
        Instance = $Instance
    }
}

<#
 Liefert die Pruefpunkte (Level Ok/Warn/Error/Info, Name, Text) und den Plan.
 Fehler blockieren. Geprueft wird alles, was vorher feststellbar ist - so
 scheitert nichts an einem fehlenden PHP-Modul, nachdem Website und
 Datenbank schon angelegt sind.
#>
function Test-Installation {
    param(
        [Parameter(Mandatory)]$Target,
        [string]$ZipPath = '',
        [bool]$UseZip = $false,
        [string]$Password = ''
    )
    $items = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Level, $Name, $Text)
        $items.Add([pscustomobject]@{ Level = $Level; Name = $Name; Text = $Text })
        Write-Log ("{0,-16}: {1}" -f $Name, $Text) $Level
    }
    $inst = $Target
    $isNew = ($inst.Kind -eq 'new')
    Write-Log ("Prüfung: {0}" -f $inst.Display) 'Step'
    $progRoot = $script:Settings.ProgRoot
    $sj = if (-not $isNew -and $inst.Instance.Paths -and $inst.Instance.Paths.ServicesJson) { $inst.Instance.Paths.ServicesJson } else { Join-Path $progRoot 'services.json' }
    $plan = [pscustomobject]@{
        Inst = $inst; Kind = $inst.Kind; Mode = $(if ($isNew) { 'install' } else { 'repeat' }); Ordner = $inst.Ordner; ProgRoot = $progRoot
        ProgDir = (Join-Path $progRoot $inst.Ordner); DataDir = $inst.DataDir; Paths = $inst.Paths; AclDataDirs = @()
        ServicesJson = $sj; Source = $null; PhpExe = $null; Pg = $null; DbName = $inst.DbName; DbUser = $inst.DbUser
        ExistingConfig = $null; Template = $null; InstalledVersion = ''; SkipBackup = $false; PythonExe = $null; BackupInfo = $null
        DbResume = $false; DbAdoptNeeded = $false; DbAdoptText = ''; AdoptDb = $false
    }
    if (-not $isNew) { $plan.ProgDir = $inst.Instance.ProgDir }

    # --- Server ---------------------------------------------------------------
    if (Test-IsAdmin) { & $add 'Ok' 'Administrator' 'SNAIL läuft mit Administratorrechten.' }
    else { & $add 'Error' 'Administrator' 'Keine Administratorrechte.' }
    $iis = Test-Path -LiteralPath $script:AppCmd
    if ($iis) { & $add 'Ok' 'IIS' 'appcmd.exe gefunden.' } else { & $add 'Error' 'IIS' 'appcmd.exe fehlt - IIS ist nicht installiert (WIPP ausführen).' }
    if ($iis) {
        if (Test-UrlRewriteInstalled) { & $add 'Ok' 'URL Rewrite' 'installiert.' }
        else { & $add 'Error' 'URL Rewrite' 'URL Rewrite Module 2 fehlt - ohne Rewrite enden alle Seiten außer / mit 404.' }
        if (Test-WebDavInstalled) { & $add 'Warn' 'WebDAV' 'installiert - beantwortet PUT/DELETE mit 405 (Löschen in der Dateiablage). Entfernen: Disable-WindowsOptionalFeature -Online -FeatureName IIS-WebDAV' }
        else { & $add 'Ok' 'WebDAV' 'nicht installiert.' }
    }
    $fwOff = Get-DisabledFirewallProfiles
    if ($null -eq $fwOff) { & $add 'Info' 'Firewall' 'Zustand der Windows-Firewall nicht lesbar.' }
    elseif ($fwOff.Count -gt 0) { & $add 'Warn' 'Firewall' ("Windows-Firewall ist für {0} ausgeschaltet - die Ports der Websites sind dann aus dem Netz erreichbar." -f ($fwOff -join ', ')) }
    else { & $add 'Ok' 'Firewall' 'Windows-Firewall ist für alle Profile aktiv.' }

    $php = Find-PhpExe
    $plan.PhpExe = $php
    if (-not $php) { & $add 'Error' 'php.exe' 'nicht gefunden - WIPP-Datei php-pfad.txt fehlt; Pfad im Katalog unter einstellungen.phpExe eintragen.' }

    # --- Installation, Website, Port ----------------------------------------
    $sites = if ($iis) { @(Get-IisSites) } else { @() }
    $own = @($sites | Where-Object { $_.Name -ieq $plan.Ordner }) | Select-Object -First 1
    & $add 'Info' 'Name' ("{0}  ({1}) - Ordner, IIS-Site, App-Pool, Aufgabe '\AK\{0} Aufgabenplanung'" -f $plan.Ordner, $inst.OrdnerReason)
    if ($isNew) {
        $owner = @($script:Instances | Where-Object { $_ -and $_.Ordner -ieq $plan.Ordner }) | Select-Object -First 1
        if ($owner) {
            & $add 'Error' 'Name' "Ordner '$($plan.Ordner)' gehört zur Installation $(Format-InstanceRef $owner)."
        } elseif (Test-Path -LiteralPath (Join-Path $plan.ProgDir 'config.php')) {
            & $add 'Error' 'Programmordner' "$($plan.ProgDir) enthält schon eine config.php (andere oder nicht lesbare Installation)."
        }
        $ownPort = 0
        $ownPath = ''
        if ($own) { $ownPath = Get-IisSitePath -Name $own.Name; $ownPort = Get-PortFromBindings $own.Bindings }
        $poolExists = $iis -and (Test-AppPoolExists -Name $plan.Ordner)
        $poolApps = if ($poolExists) { @(Get-AppPoolApps -Name $plan.Ordner) } else { @() }
        $conflicts = @(Get-IisNameConflicts -Ordner $plan.Ordner -ProgDir $plan.ProgDir -SiteExists ([bool]$own) -SitePath ([string]$ownPath) `
            -PoolExists $poolExists -PoolApps $poolApps -ProgDirExists (Test-Path -LiteralPath $plan.ProgDir -PathType Container))
        foreach ($c in $conflicts) { & $add 'Error' $c.Name $c.Text }
        if ($own -and @($conflicts | Where-Object { $_.Name -eq 'Website' }).Count -eq 0) {
            if ($ownPort -ne $inst.Port) {
                & $add 'Error' 'Website' "'$($own.Name)' gibt es schon (Bindings $($own.Bindings)); SNAIL ändert keine Bindings - Port $ownPort eingeben oder die Website entfernen."
            } else {
                & $add 'Warn' 'Website' "'$($own.Name)' gibt es schon (z. B. von einem abgebrochenen Lauf) - wird angeglichen, Bindings bleiben."
            }
        }
        $why = Test-PortFree -Port $inst.Port -Sites $sites -Excluded (Get-ExcludedPortRanges) -OwnSite $(if ($own) { $own.Name } else { '' })
        if ($why) { & $add 'Error' 'Port' "$($inst.Port) $why." }
        else { & $add 'Ok' 'Port' ("{0} frei (http://localhost:{0}/; falls ein Cloudflare Tunnel genutzt wird, zeigt er hierhin)" -f $inst.Port) }
        if ($inst.Firewall) {
            & $add 'Info' 'Firewallregel' ("wird angelegt: SNAIL {0} (TCP {1}, Domäne/Privat, private Adressbereiche)" -f $plan.Ordner, $inst.Port)
            $pub = Get-PublicNetworks   # liefert immer eine Liste (ohne @(), das wuerde sie einpacken)
            if ($pub.Count -gt 0) { & $add 'Warn' 'Firewallregel' ("Netzwerk im Profil Öffentlich: {0} - dort greift die Regel nicht (nur Domäne/Privat). Netzwerkprofil prüfen." -f ($pub -join ', ')) }
        }
        else { & $add 'Ok' 'Firewallregel' 'keine - der Port ist nur auf diesem Server erreichbar.' }
    } else {
        $i0 = $inst.Instance
        if ($i0.Error) { & $add 'Error' 'Installation' "$($i0.ProgDir): $($i0.Error)" }
        else { & $add 'Ok' 'Installation' ("{0}/{1} in {2}, Version {3}" -f $i0.ServiceKey, $i0.Key, $i0.ProgDir, $i0.Version) }
        if (-not $inst.Service.InCatalog) { & $add 'Info' 'Katalog' "Dienst '$($inst.Service.Key)' steht nicht im Katalog - services.json behält Logo, Icon und Beschreibung." }
        if ($own) { & $add 'Ok' 'Website' "'$($own.Name)' ($($own.Bindings), $($own.State)) - wird angeglichen, Bindings bleiben." }
        else { & $add 'Error' 'Website' "IIS-Website '$($plan.Ordner)' fehlt - SNAIL legt Bindings nur bei einer Neuinstallation an. Website von Hand anlegen (physischer Pfad $($plan.ProgDir)\public)." }
        $fwRule = $null
        try { $fwRule = Get-NetFirewallRule -Name (Get-FirewallRuleName $plan.Ordner) -ErrorAction SilentlyContinue } catch { }
        if ($fwRule) { & $add 'Info' 'Firewallregel' "$($fwRule.DisplayName) vorhanden - bleibt unverändert." }
    }

    # --- Programmcode und Modus ---------------------------------------------
    $srcRoot = $null
    if ($UseZip) {
        if ([string]::IsNullOrWhiteSpace($ZipPath) -or -not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
            & $add 'Error' 'ZIP-Datei' "nicht gefunden: $ZipPath"
        } else {
            try {
                $st = Expand-TemplateZip -Zip $ZipPath
                if (-not $st.Root) { & $add 'Error' 'ZIP-Datei' 'enthält keinen Programmordner nach Vorlage (bin\console und public\index.php fehlen).' }
                else {
                    $srcRoot = $st.Root
                    $plan.Source = $st
                    & $add 'Ok' 'ZIP-Datei' ("{0}{1}" -f $st.Zip, $(if ($st.Inner) { " (Projektstamm '$($st.Inner)' erkannt)" } else { '' }))
                }
            } catch {
                & $add 'Error' 'ZIP-Datei' "lässt sich nicht entpacken: $($_.Exception.Message)"
            }
        }
    } else {
        if (Test-Path -LiteralPath $plan.ProgDir) { $srcRoot = $plan.ProgDir; & $add 'Ok' 'Programmordner' "$($plan.ProgDir) (vorhanden, wird genutzt)" }
        else { & $add 'Error' 'Programmordner' "$($plan.ProgDir) existiert nicht - ZIP-Datei wählen." }
    }
    if ($srcRoot) {
        $fehlt = @(Test-TemplateStructure -Root $srcRoot)
        if ($fehlt.Count -eq 0) { & $add 'Ok' 'Vorlage' 'Aufbau nach Vorlage (public\index.php, public\web.config, bin\console, config.example.php, database\migrations).' }
        else { & $add 'Error' 'Vorlage' ("fehlt: {0} - entspricht nicht der projektvorlage." -f ($fehlt -join ', ')) }
        foreach ($f in @('setup\Aufgabenplanung\aufgabe_erstellen.ps1', 'tools\windows-pruefung.ps1')) {
            if (-not (Test-Path -LiteralPath (Join-Path $srcRoot $f))) { & $add 'Warn' 'Vorlage' "$f fehlt - dieser Schritt wird übersprungen." }
        }
        $plan.Template = Get-TemplateInfo -Root $srcRoot -PhpExe $php
        if ($plan.Source) {
            foreach ($w in @(Get-ZipServiceWarnings -Service $inst.Service -ExampleService $plan.Template.ExampleService -Inner $plan.Source.Inner)) { & $add 'Warn' 'ZIP-Datei' $w }
        }
    } else {
        $plan.Template = Get-TemplateInfo -Root $plan.ProgDir -PhpExe $null
    }
    if (-not $isNew) {
        $plan.InstalledVersion = $inst.Instance.Version
        if ($UseZip) {
            $plan.Mode = 'update'
            & $add 'Info' 'Modus' ("Aktualisieren: {0} -> {1} (Sicherung, robocopy, migrate; config.php bleibt, nur ein fehlender app.key wird nachgetragen)" -f $(if ($plan.InstalledVersion) { $plan.InstalledVersion } else { '?' }), $(if ($plan.Template.Version) { $plan.Template.Version } else { '?' }))
            if ($plan.Paths) {
                $plan.BackupInfo = Get-BackupInfo -Root (Get-BackupRoot -Plan $plan)
                & $add 'Info' 'Sicherung' ("pg_dump + config.php nach {0}\<Zeit> - vorhanden: {1}" -f (Get-BackupRoot -Plan $plan), $plan.BackupInfo.Text)
            }
        } else {
            & $add 'Info' 'Modus' "Einrichtung wiederholen (Programmcode bleibt, Version $($plan.InstalledVersion))"
        }
        & $add 'Ok' 'config.php' "vorhanden - bleibt unverändert, nur fehlende app.key/app.key_previous/mail.redirect_to werden nachgetragen ($(Join-Path $plan.ProgDir 'config.php'))"
        if ($inst.Instance.InServicesJson -and $inst.Instance.ServicesUrl -ne $inst.Url) {
            & $add 'Info' 'services.json' ("url '{0}' wird an app.url der config.php angeglichen: '{1}'" -f $inst.Instance.ServicesUrl, $inst.Url)
        }
    } else {
        & $add 'Info' 'Modus' ("Neuinstallation{0}" -f $(if ($plan.Template.Version) { ", Version $($plan.Template.Version)" } else { '' }))
    }

    # --- PHP-Version und Module (nach requirements der Vorlage) -------------
    if ($php) {
        try {
            $pi = Get-PhpInfo -Exe $php
            $min = [version]$plan.Template.PhpMin
            if ($pi.Version -and $pi.Version -ge $min) { & $add 'Ok' 'php.exe' "$php (PHP $($pi.Text))" }
            elseif ($pi.Version) { & $add 'Error' 'php.exe' "PHP $($pi.Version) ist zu alt - die Vorlage braucht mindestens $min." }
            else { & $add 'Error' 'php.exe' "$php antwortet nicht: $($pi.Text)" }
            foreach ($le in $pi.LoadErrors) { & $add 'Warn' 'PHP' $le }
            $need = @(@($plan.Template.Extensions) + @($inst.Service.PhpModules) | Select-Object -Unique)
            $missing = @($need | Where-Object { $pi.Modules -notcontains $_ })
            if ($missing.Count -eq 0) { & $add 'Ok' 'PHP-Module' ("alle {0} geladen ({1})" -f $need.Count, ($need -join ', ')) }
            else { & $add 'Error' 'PHP-Module' ("fehlen: {0} - in der php.ini aktivieren und IIS neu starten." -f ($missing -join ', ')) }
            if ($pi.Modules -notcontains 'gd') { & $add 'Warn' 'PHP-Module' 'gd fehlt - keine Vorschaubilder.' }
            $up = ConvertTo-Megabytes $pi.Upload; $post = ConvertTo-Megabytes $pi.Post
            if (($up -ge 0 -and $up -lt $inst.UploadsMaxMb) -or ($post -ge 0 -and $post -lt $inst.UploadsMaxMb)) {
                & $add 'Warn' 'Upload' ("php.ini: upload_max_filesize {0}, post_max_size {1} - kleiner als die Upload-Grenze ({2} MB)." -f $pi.Upload, $pi.Post, $inst.UploadsMaxMb)
            }
        } catch {
            & $add 'Error' 'php.exe' "$php konnte nicht ausgeführt werden: $($_.Exception.Message)"
        }
    }

    # --- Python (Katalog: "braucht": ["python"]) ------------------------------
    if (@($inst.Service.Needs) -contains 'python') {
        $py = Find-PythonExe
        if (-not $py) { & $add 'Error' 'Python' 'Der Dienst braucht Python - python.exe nicht gefunden (WIPP installiert es optional).' }
        else {
            $example = if ($srcRoot) { Join-Path $srcRoot 'config.example.php' } else { '' }
            if ($isNew -and $example -and (Test-ConfigTemplateKey -ExampleFile $example -Key 'python.exe')) {
                $plan.PythonExe = $py
                & $add 'Ok' 'Python' "$py - wird als python.exe in die config.php eingetragen."
            } else {
                & $add 'Ok' 'Python' "$py$(if ($isNew) { ' (config.example.php hat keinen Schlüssel python.exe - nur geprüft)' } else { '' })"
            }
        }
    }

    # --- PostgreSQL -----------------------------------------------------------
    $pg = Get-PgSettings
    $plan.Pg = $pg
    $psql = if ($pg.Bin) { Join-Path $pg.Bin 'psql.exe' } else { '' }
    if ($psql -and (Test-Path -LiteralPath $psql)) { & $add 'Ok' 'psql.exe' "$psql ($($pg.Source))" }
    else { & $add 'Error' 'psql.exe' 'nicht gefunden - WIPP-Datei postgres.json fehlt; Ordner im Katalog unter einstellungen.psqlBin eintragen.' }
    $tcp = $false
    try { $t = New-Object System.Net.Sockets.TcpClient; $t.Connect('127.0.0.1', [int]$pg.Port); $t.Close(); $tcp = $true } catch { }
    if ($tcp) { & $add 'Ok' 'PostgreSQL' "Port $($pg.Port) antwortet." }
    else { & $add 'Error' 'PostgreSQL' "Port $($pg.Port) antwortet nicht - Dienst gestartet?" }
    if (-not $isNew -and $inst.Instance.Db -and $inst.Instance.Db.Port -and $inst.Instance.Db.Port -ne $pg.Port) {
        & $add 'Warn' 'PostgreSQL' "config.php nutzt Port $($inst.Instance.Db.Port), WIPP meldet $($pg.Port)."
    }
    $pgOk = $false
    if ($tcp -and $psql -and (Test-Path -LiteralPath $psql)) {
        if ([string]::IsNullOrEmpty($Password)) {
            & $add 'Error' 'Superuser' 'Passwort für postgres fehlt (postgres-zugangsdaten.txt gelöscht?) - unten eingeben und "Verbindung testen".'
        } else {
            $t = Test-PgSuperuser -Pg $pg -Password $Password
            if (-not $t.Ok) { & $add 'Error' 'Superuser' "Anmeldung als $($pg.Superuser) fehlgeschlagen: $($t.Message)" }
            elseif ($t.Major -lt $plan.Template.PgMin) { & $add 'Error' 'PostgreSQL' "Version $($t.Version) - die Vorlage braucht mindestens $($plan.Template.PgMin)." }
            else { & $add 'Ok' 'Superuser' $t.Message; $pgOk = $true }
        }
    }
    $bad = @((Test-PgIdentifier $plan.DbName 'Datenbank'), (Test-PgIdentifier $plan.DbUser 'Benutzer') | Where-Object { $_ })
    if ($bad.Count -gt 0) { foreach ($b in $bad) { & $add 'Error' 'Datenbank' $b } }
    elseif ($pgOk) {
        try {
            $s = Get-PgObjectState -Pg $pg -Password $Password -DbName $plan.DbName -Role $plan.DbUser
            if ($isNew) {
                # Neuinstallation: vorhandene Datenbank/Rolle nie stillschweigend uebernehmen
                $resume = Test-ResumeRun -CredFile (Join-Path $script:CredDir ($plan.Ordner + '.txt')) -ProgDir $plan.ProgDir -DbName $plan.DbName -Role $plan.DbUser
                $c = Get-DbCollision -State $s -DbName $plan.DbName -Role $plan.DbUser -Instances $script:Instances -Resume $resume
                $plan.DbResume = $c.Resume
                $plan.DbAdoptNeeded = $c.Adopt
                $plan.DbAdoptText = $c.Confirm
                & $add $c.Level 'Datenbank' $c.Text
            }
            elseif ($s.DbExists -and $s.DbOwner -ne $plan.DbUser) { & $add 'Error' 'Datenbank' "'$($plan.DbName)' gibt es schon, Eigentümer ist '$($s.DbOwner)' statt '$($plan.DbUser)'." }
            elseif ($plan.Mode -eq 'update' -and -not $s.DbExists) { & $add 'Error' 'Datenbank' "'$($plan.DbName)' fehlt - Aktualisieren setzt die bestehende Datenbank voraus." }
            else {
                $txt = "{0} ({1}) / Rolle {2} ({3})" -f $plan.DbName, $(if ($s.DbExists) { 'vorhanden' } else { 'wird angelegt' }), $plan.DbUser, $(if ($s.RoleExists) { 'vorhanden' } else { 'wird angelegt' })
                & $add 'Ok' 'Datenbank' $txt
            }
        } catch { & $add 'Error' 'Datenbank' $_.Exception.Message }
    } else {
        & $add 'Info' 'Datenbank' "$($plan.DbName) / $($plan.DbUser)"
    }

    # --- Datenordner ----------------------------------------------------------
    if (-not $plan.Paths) {
        & $add 'Error' 'Datenordner' 'Pfade unbekannt (php bin\console info nicht lesbar).'
    } else {
        if ($isNew) {
            $dp = Test-DataPaths -Paths $plan.Paths -ProgDir $plan.ProgDir
            foreach ($e in $dp.Errors) { & $add 'Error' 'Datenordner' $e }
            foreach ($h in $dp.Hints) { & $add 'Warn' 'Datenordner' $h }
            if ($dp.Errors.Count -eq 0) {
                $std = Get-DefaultPaths -DataDir $plan.DataDir
                $eigen = @('Data', 'Cache', 'Logs', 'Temp' | Where-Object { $plan.Paths.$_ -ine $std.$_ })
                & $add 'Ok' 'Datenordner' ("{0}\{{Data,Cache,Logs,Temp}}{1}{2}" -f $plan.DataDir, $(if (Test-Path -LiteralPath $plan.DataDir) { ' (vorhanden)' } else { '' }), $(if ($eigen.Count -gt 0) { " - angepasst: $($eigen -join ', ')" } else { '' }))
            }
        } else {
            $fehltP = @('Data', 'Cache', 'Logs', 'Temp' | Where-Object { -not (Test-Path -LiteralPath $plan.Paths.$_) })
            & $add $(if ($fehltP.Count -gt 0) { 'Warn' } else { 'Ok' }) 'Datenordner' ("aus der config.php: Data {0}, Cache {1}, Logs {2}, Temp {3}{4}" -f $plan.Paths.Data, $plan.Paths.Cache, $plan.Paths.Logs, $plan.Paths.Temp, $(if ($fehltP.Count -gt 0) { " - fehlt: $($fehltP -join ', ') (wird angelegt)" } else { '' }))
        }
        $plan.AclDataDirs = @(Get-AclDataDirs -DataDir $plan.DataDir -Paths $plan.Paths)
    }

    # --- services.json, Mandant, Logo ----------------------------------------
    if (Test-Path -LiteralPath $plan.ServicesJson) {
        try { [void](Read-ServicesJson -Path $plan.ServicesJson); & $add 'Ok' 'services.json' "$($plan.ServicesJson) - $($inst.Service.Key)/$($inst.Key) wird ergänzt bzw. angeglichen." }
        catch { & $add 'Warn' 'services.json' "ungültiges JSON - wird nicht verändert: $($_.Exception.Message)" }
    } else {
        & $add 'Ok' 'services.json' "wird angelegt: $($plan.ServicesJson)"
    }
    if ($isNew) {
        $known = Get-KnownTenants -Path $plan.ServicesJson
        $sameName = @($known.Values | Where-Object { $_.Name -eq $inst.Name -and $_.Key -cne $inst.Key })
        if ($sameName.Count -gt 0) {
            & $add 'Warn' 'Mandant' ("'{0}' heißt in {1} '{2}' - gleicher Kunde = gleicher Mandanten-Schlüssel, sonst verliert der App-Switcher den Mandanten." -f $inst.Name, ($sameName[0].Services -join ', '), $sameName[0].Key)
        } elseif ($known.ContainsKey($inst.Key)) {
            & $add 'Ok' 'Mandant' ("'{0}' gibt es schon in {1} - der App-Switcher behält ihn beim Programmwechsel." -f $inst.Key, ($known[$inst.Key].Services -join ', '))
        } else {
            & $add 'Info' 'Mandant' "neuer Mandant '$($inst.Key)' ($($inst.Name))"
        }
    }
    if ($inst.Service.Logo.Error) { & $add 'Warn' 'Logo' $inst.Service.Logo.Error }
    elseif ($inst.Service.Logo.Bytes) { & $add 'Ok' 'Logo' ("{0}, {1:N0} KB -> logos/{2}.{0}" -f $inst.Service.Logo.Ext, ($inst.Service.Logo.Bytes.Length / 1KB), $inst.Service.Key) }

    $blocked = (@($items | Where-Object { $_.Level -eq 'Error' }).Count -gt 0)
    return [pscustomobject]@{ Ok = (-not $blocked); Items = $items.ToArray(); Plan = $plan }
}

# ==============================================================================
# 15) Installationsablauf (Seite 4)
# ==============================================================================

<#
 Schrittplan. Fatal = Abbruch bei Fehler; nicht fatale Schritte (services.json,
 Windows-Aufgabe, Pruefskript) laufen weiter und erscheinen auf "Fertig".
 Die Windows-Aufgabe wird erst nach Ordnern und Rechten angelegt und einmal
 angestossen, danach kommt check.
#>
function Get-StepPlan {
    param([Parameter(Mandatory)]$Plan)
    $s = New-Object System.Collections.Generic.List[object]
    if ($Plan.Mode -eq 'update' -and -not $Plan.SkipBackup) {
        $s.Add(@{ Key = 'backup';  Title = 'Sicherung: pg_dump und config.php'; Fatal = $true })
    }
    $codeTitle = if ($Plan.Mode -eq 'update') { 'Programmcode aktualisieren (robocopy /MIR)' }
                 elseif ($Plan.Source) { 'Programmcode: ZIP -> ' + $Plan.ProgDir }
                 else { 'Programmcode: vorhandener Ordner' }
    $s.Add(@{ Key = 'code';     Title = $codeTitle; Fatal = $true })
    $s.Add(@{ Key = 'folders';  Title = 'Datenordner Data, Cache, Logs, Temp'; Fatal = $true })
    $s.Add(@{ Key = 'iis';      Title = 'IIS: App-Pool, Website, Upload-Grenze'; Fatal = $true })
    $s.Add(@{ Key = 'acl';      Title = 'Rechte: Programm-, Daten-, Gemeinsamer Ordner'; Fatal = $true })
    if ($Plan.Kind -eq 'new' -and $Plan.Inst.Firewall) {
        $s.Add(@{ Key = 'firewall'; Title = 'Firewallregel (im Netzwerk erreichbar)'; Fatal = $true })
    }
    if ($Plan.Mode -ne 'update') {
        $s.Add(@{ Key = 'db';     Title = 'PostgreSQL: Rolle und Datenbank'; Fatal = $true })
        $s.Add(@{ Key = 'config'; Title = 'config.php aus config.example.php'; Fatal = $true })
    }
    if ($Plan.Mode -ne 'install') {
        $s.Add(@{ Key = 'appkey'; Title = 'config.php: app.key nachtragen, falls er fehlt'; Fatal = $false })
    }
    $s.Add(@{ Key = 'migrate';  Title = 'php bin\console migrate'; Fatal = $true })
    if ($Plan.Mode -ne 'update') {
        $s.Add(@{ Key = 'admin';  Title = 'php bin\console user:create (Administrator)'; Fatal = $true })
    }
    $s.Add(@{ Key = 'services'; Title = 'services.json und Logo'; Fatal = $false })
    $s.Add(@{ Key = 'task';     Title = 'Windows-Aufgabe anlegen und anstoßen'; Fatal = $false })
    $s.Add(@{ Key = 'check';    Title = 'php bin\console check'; Fatal = $true })
    $s.Add(@{ Key = 'verify';   Title = 'tools\windows-pruefung.ps1'; Fatal = $false })
    return $s.ToArray()
}

function Set-StepState {
    param([int]$Index, [ValidateSet('Pending', 'Running', 'Done', 'Failed', 'Warn')][string]$State)
    if (-not $script:LvSteps -or $Index -lt 0 -or $Index -ge $script:LvSteps.Items.Count) { return }
    $item = $script:LvSteps.Items[$Index]
    switch ($State) {
        'Pending' { $item.Text = [string][char]0x25CB; $item.ForeColor = [System.Drawing.Color]::Gray }
        'Running' { $item.Text = [string][char]0x25B6; $item.ForeColor = $script:ColAccent }
        'Done'    { $item.Text = [string][char]0x2713; $item.ForeColor = $script:ColOk }
        'Warn'    { $item.Text = [string][char]0x26A0; $item.ForeColor = $script:ColWarn }
        'Failed'  { $item.Text = [string][char]0x2717; $item.ForeColor = $script:ColErr }
    }
    $item.EnsureVisible()
    $script:LvSteps.Invalidate()
    Invoke-UiPump
}

<#
 Fuehrt den Schrittplan aus. Zugangsdaten werden abgelegt, sobald sie
 feststehen (DB-Passwort nach dem DB-Schritt, Initialpasswort direkt nach
 user:create) - ein spaeterer Fehler darf sie nicht verlieren.
#>
function Invoke-Installation {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$Password)
    $inst = $Plan.Inst
    $script:Result = @{
        Success = $false; Error = $null; Plan = $Plan; Display = $inst.Display; Url = $inst.Url
        Local = $(if ($inst.Port -gt 0) { "http://localhost:$($inst.Port)/" } else { $inst.Url })
        ConfigFile = (Join-Path $Plan.ProgDir 'config.php'); ConfigNew = $false
        Db = @{ Name = $Plan.DbName; User = $Plan.DbUser; Password = $null; Source = '' }
        Admin = $null; Migrations = $null; Check = $null; Rows = @(); CredFile = $null; Backup = $null; BackupSkipped = $false; Verify = $null
        AppKey = [pscustomobject]@{ Status = ''; Key = ''; Changed = @(); Backup = ''; Text = '' }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $steps = Get-StepPlan -Plan $Plan
    $i = -1
    $poolStopped = $false
    try {
        Set-Busy $true
        Write-Log ("=== {0}: {1} ===" -f $(switch ($Plan.Mode) { 'update' { 'Aktualisieren' } 'repeat' { 'Einrichtung wiederholen' } default { 'Neu installieren' } }), $inst.Display) 'Step'
        if ($Plan.Mode -eq 'update' -and $Plan.SkipBackup) {
            $script:Result.BackupSkipped = $true
            Write-Log 'Sicherung übersprungen: Der Anwender hat bestätigt, dass eine andere funktionierende Sicherung besteht (z. B. Veeam/VM-Sicherung).' 'Warn'
        }
        if ($Plan.Kind -eq 'new' -and $Plan.AdoptDb) {
            Write-Log ("Vorhandene Datenbank wird übernommen ({0} / Rolle {1}): vom Anwender bestätigt, alte Daten bleiben erhalten." -f $Plan.DbName, $Plan.DbUser) 'Warn'
        }

        # DB-Passwort: vorhandene config.php hat Vorrang, sonst neu. Bei jedem
        # Lauf frisch lesen (php -r, nie per Regex) - nach einem Abbruch hinter
        # dem config-Schritt muss die Rolle das Passwort der config.php bekommen.
        if (Test-Path -LiteralPath $script:Result.ConfigFile) {
            $Plan.ExistingConfig = Read-InstalledConfig -ProgDir $Plan.ProgDir -PhpExe $Plan.PhpExe
            $Plan.DbName = [string]$Plan.ExistingConfig.db.name
            $Plan.DbUser = [string]$Plan.ExistingConfig.db.user
            $script:Result.Db.Name = $Plan.DbName
            $script:Result.Db.User = $Plan.DbUser
        }
        if ($Plan.ExistingConfig -and [string]$Plan.ExistingConfig.db.password) {
            $script:Result.Db.Password = [string]$Plan.ExistingConfig.db.password
            $script:Result.Db.Source = 'aus der vorhandenen config.php'
        } elseif ($Plan.Mode -ne 'update') {
            $script:Result.Db.Password = New-RandomPassword
            $script:Result.Db.Source = 'bei dieser Installation erzeugt'
        }
        Write-Log ("Datenbank {0}, Rolle {1}, Passwort {2}." -f $Plan.DbName, $Plan.DbUser, $script:Result.Db.Source)
        # app.key: nur fuer eine neue config.php; eine vorhandene behaelt ihren
        # (Wiederholen/Aktualisieren: Schritt appkey traegt nur einen fehlenden nach)
        if ($Plan.Mode -eq 'install' -and -not $Plan.ExistingConfig) { $script:Result.AppKey.Key = New-AppKey }

        for ($i = 0; $i -lt $steps.Count; $i++) {
            if ($script:AbortRequested) { throw 'Abgebrochen auf Wunsch des Anwenders (nach dem letzten abgeschlossenen Schritt) - beim nächsten Lauf geht es dort weiter.' }
            $step = $steps[$i]
            Set-StepState $i 'Running'
            Write-Log $step.Title 'Step'
            try {
                $state = 'Done'
                switch ($step.Key) {
                    'backup' {
                        $script:Result.Backup = Backup-Installation -Plan $Plan -Password $Password
                    }
                    'code' {
                        if (-not (Test-Path -LiteralPath $Plan.ProgRoot)) { New-Item -ItemType Directory -Path $Plan.ProgRoot -Force | Out-Null }
                        if ($Plan.Source) {
                            if ($Plan.Mode -eq 'update') { $poolStopped = Stop-ProjectPool -Name $Plan.Ordner }
                            Copy-ProgramCode -Source $Plan.Source.Root -Target $Plan.ProgDir
                            if ($poolStopped) { Start-ProjectPool -Name $Plan.Ordner; $poolStopped = $false }
                        } else {
                            Write-Log "Programmordner bleibt unverändert: $($Plan.ProgDir)" 'Ok'
                        }
                    }
                    'folders'  { New-DataFolders -Plan $Plan }
                    'iis'      { Set-ProjectSite -Plan $Plan }
                    'acl'      { Set-ProjectAcls -Plan $Plan }
                    'firewall' { Set-ProjectFirewallRule -Plan $Plan }
                    'db' {
                        if ($Plan.Kind -eq 'new' -and -not $Plan.DbResume -and -not $Plan.AdoptDb) {
                            Assert-DbNotExisting -Pg $Plan.Pg -Password $Password -DbName $Plan.DbName -Role $Plan.DbUser
                        }
                        # ab hier gehoeren Datenbank und Rolle zu diesem Lauf ("Erneut versuchen")
                        $Plan.DbResume = $true
                        New-ProjectDatabase -Pg $Plan.Pg -Password $Password -DbName $Plan.DbName -Role $Plan.DbUser -DbPassword $script:Result.Db.Password
                        $script:Result.CredFile = Save-InstallCredentials -Plan $Plan -Values @{
                            db_host = $Plan.Pg.Host; db_port = [string]$Plan.Pg.Port; db_name = $Plan.DbName
                            db_benutzer = $Plan.DbUser; db_passwort = $script:Result.Db.Password
                        }
                    }
                    'config' {
                        if (Test-Path -LiteralPath $script:Result.ConfigFile) {
                            Write-Log "config.php vorhanden - wird nicht angetastet: $($script:Result.ConfigFile)"
                        } else {
                            $f = Write-ProjectConfig -Plan $Plan -DbPassword $script:Result.Db.Password -AppKey $script:Result.AppKey.Key
                            $script:Result.ConfigNew = $true
                            Write-Log "Erzeugt: $f (UTF-8 ohne BOM, php -l ohne Fehler)" 'Ok'
                            if ($script:Result.AppKey.Key -and (Test-ConfigTemplateKey -ExampleFile (Join-Path $Plan.ProgDir 'config.example.php') -Key 'app.key')) {
                                $script:Result.AppKey.Status = 'new'
                                Write-Log 'app.key (Schlüssel für Geheimnisse) erzeugt und in die config.php geschrieben.' 'Ok'
                                $script:Result.CredFile = Save-InstallCredentials -Plan $Plan -Values @{ app_key = $script:Result.AppKey.Key }
                            } else {
                                $script:Result.AppKey.Key = ''
                            }
                        }
                    }
                    'appkey' {
                        $k = Update-InstalledConfigKeys -Plan $Plan
                        $script:Result.AppKey = $k
                        switch ($k.Status) {
                            'added' {
                                Write-Log $k.Text 'Ok'
                                $script:Result.CredFile = Save-InstallCredentials -Plan $Plan -Values @{ app_key = $k.Key }
                            }
                            'manual' {
                                Write-Log ($k.Text + ' Ein Schlüssel zum Selbsteintragen steht auf "Fertig".') 'Warn'
                                $rows.Add(@{ Level = 'Warn'; Name = 'app.key'; Text = ($k.Text + ' Schlüssel zum Selbsteintragen: oben unter Zugangsdaten.') })
                                $state = 'Warn'
                            }
                            { $_ -eq 'invalid' -or $_ -eq 'failed' } {
                                Write-Log $k.Text 'Warn'
                                $rows.Add(@{ Level = 'Warn'; Name = 'app.key'; Text = $k.Text })
                                $state = 'Warn'
                            }
                            default { Write-Log $k.Text 'Ok' }
                        }
                    }
                    'migrate' {
                        $m = Invoke-ConsoleMigrate -Plan $Plan
                        $script:Result.Migrations = $m
                        Write-Log $(if ($m.UpToDate) { 'Datenbank war bereits aktuell.' } else { "$($m.Count) Migration(en) ausgeführt." }) 'Ok'
                    }
                    'admin' {
                        # Beim Wiederholen nur, wenn es noch gar kein Konto gibt (z. B.
                        # Abbruch vor user:create) - der Login der ersten Installation
                        # ist SNAIL dann nicht mehr bekannt.
                        $count = if ($Plan.Mode -eq 'repeat') { Get-UserCount -Pg $Plan.Pg -Password $Password -DbName $Plan.DbName } else { 0 }
                        if ($count -gt 0) {
                            Write-Log "$count Benutzerkonto(en) vorhanden - kein neuer Administrator." 'Ok'
                            $script:Result.Admin = @{ Login = ''; Passwort = $null; Existed = $true; Count = $count }
                        } else {
                            $u = Invoke-ConsoleUserCreate -Plan $Plan -Email $inst.Admin.Email
                            $script:Result.Admin = @{ Login = $inst.Admin.Login; Passwort = $u.Passwort; Existed = $u.Existed; Count = 0 }
                            if ($u.Passwort) {
                                $script:Result.CredFile = Save-InstallCredentials -Plan $Plan -Values @{ admin_login = $inst.Admin.Login; admin_initialpasswort = $u.Passwort }
                            }
                            Write-Log $u.Text 'Ok'
                        }
                    }
                    'services' {
                        $sr = Update-ServicesJson -Plan $Plan
                        Write-Log $sr.Text $(if ($sr.Ok) { 'Ok' } else { 'Error' })
                        foreach ($h in $sr.Hints) { Write-Log $h 'Warn'; $rows.Add(@{ Level = 'Warn'; Name = 'services.json'; Text = $h }) }
                        if (-not $sr.Ok) { throw $sr.Text }
                        if ($sr.Hints.Count -gt 0) { $state = 'Warn' }
                    }
                    'task' {
                        $tr = Invoke-TaskScript -Plan $Plan
                        if (-not $tr.Ok) { throw $tr.Text }
                        $firstOk = ($tr.FirstRun -eq 'erster Lauf ohne Fehler')
                        $rows.Add(@{ Level = $(if ($firstOk) { 'Ok' } else { 'Warn' }); Name = 'Windows-Aufgabe'; Text = ($tr.Text + ' - ' + $tr.FirstRun) })
                        if (-not $firstOk) { $state = 'Warn' }
                    }
                    'check' {
                        $c = Invoke-ConsoleCheck -Plan $Plan
                        $script:Result.Check = $c
                        if (-not $c.Ok) {
                            $fehler = @($c.Items | Where-Object { $_.Status -eq 'FEHLER' } | ForEach-Object { $_.Label })
                            throw ("Die Selbstprüfung meldet Fehler (Exit-Code {0}): {1}. Erneut prüfen: php bin\console check" -f $c.ExitCode, $(if ($fehler.Count -gt 0) { $fehler -join '; ' } else { 'siehe Protokoll' }))
                        }
                        Write-Log $(if ($c.Summary) { $c.Summary } else { 'Selbstprüfung ohne Fehler.' }) 'Ok'
                        if (@($c.Items | Where-Object { $_.Status -eq 'WARNUNG' }).Count -gt 0) { $state = 'Warn' }
                    }
                    'verify' {
                        $v = Invoke-WindowsCheck -Plan $Plan
                        $script:Result.Verify = $v
                        if (-not $v.Ran) { throw $v.Text }
                        # Ergebnis erscheint auf "Fertig" (Zusammenfassung und je Punkt)
                        if ($v.Errors -gt 0) { $state = 'Failed' } elseif ($v.Warnings -gt 0) { $state = 'Warn' }
                    }
                }
                Set-StepState $i $state
            } catch {
                if ($step.Fatal) { throw }
                $msg = $_.Exception.Message
                Write-Log $msg 'Error'
                $rows.Add(@{ Level = 'Error'; Name = $step.Title; Text = $msg })
                Set-StepState $i 'Failed'
            }
        }
        $script:Result.Rows = $rows.ToArray()
        $script:Result.Success = $true
        Write-Log ("=== {0} abgeschlossen ===" -f $inst.Display) 'Ok'
        Remove-Staging
        return $true
    } catch {
        if (-not $script:AbortRequested) { Set-StepState $i 'Failed' }
        $script:Result.Rows = $rows.ToArray()
        $script:Result.Error = $_.Exception.Message
        Write-Log $_.Exception.Message $(if ($script:AbortRequested) { 'Warn' } else { 'Error' })
        Write-Log ("=== {0} {1} ===" -f $inst.Display, $(if ($script:AbortRequested) { 'abgebrochen' } else { 'fehlgeschlagen' })) $(if ($script:AbortRequested) { 'Warn' } else { 'Error' })
        return $false
    } finally {
        if ($poolStopped) { try { Start-ProjectPool -Name $Plan.Ordner } catch { } }
        Set-Busy $false
    }
}

# ==============================================================================
# 16) Oberfläche: Grundgerüst
# ==============================================================================

# Alles ab hier läuft in einem Schutzblock: ein unerwarteter Fehler wird mit
# Zeilennummer angezeigt und protokolliert (in der EXE sonst kaum zu finden).
try {

$script:ColDark   = [System.Drawing.Color]::FromArgb(28, 42, 58)
$script:ColAccent = [System.Drawing.Color]::FromArgb(0, 99, 177)
$script:ColGray   = [System.Drawing.Color]::FromArgb(110, 110, 110)
$script:ColOk     = [System.Drawing.Color]::FromArgb(16, 124, 65)
$script:ColWarn   = [System.Drawing.Color]::FromArgb(177, 116, 0)
$script:ColErr    = [System.Drawing.Color]::FromArgb(196, 43, 28)
$script:ColBox    = [System.Drawing.Color]::FromArgb(246, 248, 250)

$fontUi    = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontBig   = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$fontHead  = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$fontMono  = New-Object System.Drawing.Font('Consolas', 9)
$fontSym   = New-Object System.Drawing.Font('Segoe UI Symbol', 9.5)

# Kopf (64) + Fußleiste (56) + Statuszeile (24) = 144, dazu die Innenabstände
# des Inhaltsbereichs (18 oben, 10 unten).
$script:FormW = 980
$script:FormH = 760
$pw = $script:FormW - 48
$ph = $script:FormH - 144 - 28

function New-Ctl {
    param([string]$Type, $Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text = '')
    $c = New-Object $Type
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    if ($W -gt 0 -and $H -gt 0) { $c.Size = New-Object System.Drawing.Size($W, $H) }
    if ($Text) { $c.Text = $Text }
    $Parent.Controls.Add($c)
    return $c
}

function New-Label {
    param($Parent, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Text, $Color = $null, $Font = $null)
    $l = New-Ctl System.Windows.Forms.Label $Parent $X $Y $W $H $Text
    if ($Color) { $l.ForeColor = $Color }
    if ($Font)  { $l.Font = $Font }
    return $l
}

function New-ResultList {
    param($Parent, [int]$Y, [int]$H, [int]$NameWidth = 150)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location      = New-Object System.Drawing.Point(0, $Y)
    $lv.Size          = New-Object System.Drawing.Size($pw, $H)
    $lv.Anchor        = 'Top,Left,Right'
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.HeaderStyle   = 'None'
    $lv.Font          = $fontSym
    $lv.ShowItemToolTips = $true
    [void]$lv.Columns.Add(' ', 30)
    [void]$lv.Columns.Add('Punkt', $NameWidth)
    [void]$lv.Columns.Add('Ergebnis', $pw - 30 - $NameWidth - 24)
    $Parent.Controls.Add($lv)
    return $lv
}

function New-ListBox {
    param($Parent, [int]$Y, [int]$H, [object[]]$Columns)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location      = New-Object System.Drawing.Point(0, $Y)
    $lv.Size          = New-Object System.Drawing.Size($pw, $H)
    $lv.Anchor        = 'Top,Left,Right'
    $lv.View          = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect   = $false
    $lv.HideSelection = $false
    $lv.HeaderStyle   = 'Nonclickable'
    $rest = $pw - 24
    for ($k = 0; $k -lt $Columns.Count; $k += 2) {
        $w = if ($Columns[$k + 1] -gt 0) { $Columns[$k + 1] } else { $rest }
        [void]$lv.Columns.Add($Columns[$k], $w)
        $rest -= $w
    }
    $Parent.Controls.Add($lv)
    return $lv
}

# Text in Zeilen aufteilen, die hoechstens MaxWidth breit sind (Umbruch an
# Leerzeichen; ein zu langes Wort bleibt ganz). -Measure liefert die Breite.
function Split-TextToWidth {
    param([string]$Text, [int]$MaxWidth, [Parameter(Mandatory)][scriptblock]$Measure)
    $lines = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($w in ($Text -split ' ')) {
        $try = if ($cur) { "$cur $w" } else { $w }
        if ($cur -and (& $Measure $try) -gt $MaxWidth) { $lines.Add($cur); $cur = $w } else { $cur = $try }
    }
    $lines.Add($cur)
    return , $lines.ToArray()
}

# Ergebniszeile; ein langer Text geht in Folgezeilen weiter (die Liste kann
# nicht umbrechen, und der Tooltip ragt bei langen Texten aus dem Fenster)
function Add-ResultRow {
    param($List, [string]$Level, [string]$Name, [string]$Text)
    $sym = switch ($Level) { 'Ok' { [char]0x2713 } 'Warn' { [char]0x26A0 } 'Error' { [char]0x2717 } default { [char]0x2139 } }
    $col = switch ($Level) { 'Ok' { $script:ColOk } 'Warn' { $script:ColWarn } 'Error' { $script:ColErr } default { $script:ColGray } }
    $font = $List.Font
    $measure = { param($s) [System.Windows.Forms.TextRenderer]::MeasureText($s, $font).Width }.GetNewClosure()
    $parts = Split-TextToWidth -Text $Text -MaxWidth ($List.Columns[2].Width - 12) -Measure $measure
    for ($k = 0; $k -lt $parts.Count; $k++) {
        $item = New-Object System.Windows.Forms.ListViewItem($(if ($k -eq 0) { [string]$sym } else { '' }))
        [void]$item.SubItems.Add($(if ($k -eq 0) { $Name } else { '' }))
        [void]$item.SubItems.Add($parts[$k])
        $item.ToolTipText = $(if ($parts.Count -eq 1) { $Text } else { '' })   # umbrochen: alles sichtbar
        $item.ForeColor = $col
        $item.UseItemStyleForSubItems = $true
        [void]$List.Items.Add($item)
    }
}

# Beschriftung + Textfeld in einer Zeile
function New-Field {
    param($Parent, [int]$X, [int]$Y, [string]$Caption, [int]$W, [int]$LabelW = 150)
    New-Label $Parent $X ($Y + 3) $LabelW 20 $Caption | Out-Null
    return (New-Ctl System.Windows.Forms.TextBox $Parent ($X + $LabelW + 6) $Y $W 24)
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text            = "$script:AppTitle $script:AppVersion"
$script:Form.ClientSize      = New-Object System.Drawing.Size($script:FormW, $script:FormH)
$script:Form.StartPosition   = 'CenterScreen'
$script:Form.Font            = $fontUi
$script:Form.BackColor       = [System.Drawing.Color]::White
$script:Form.KeyPreview      = $true
$script:Form.AutoScaleMode       = [System.Windows.Forms.AutoScaleMode]::Dpi
$script:Form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)

try {
    if ($script:IsCompiled) {
        $script:AppIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($script:SelfPath)
    } else {
        $icoPath = Join-Path $script:SelfDir 'setup.ico'
        if (Test-Path -LiteralPath $icoPath) { $script:AppIcon = New-Object System.Drawing.Icon($icoPath) }
    }
    if ($script:AppIcon) { $script:Form.Icon = $script:AppIcon }
} catch { }

# --- Kopfzeile (Größe VOR dem Befüllen setzen: Anker rechnen gegen die
#     aktuelle Elterngröße) ------------------------------------------------
$header = New-Object System.Windows.Forms.Panel
$header.Size      = New-Object System.Drawing.Size($script:FormW, 64)
$header.Dock      = 'Top'
$header.BackColor = $script:ColDark
New-Label $header 24 10 300 26 'SNAIL' ([System.Drawing.Color]::White) $fontHead | Out-Null
New-Label $header 26 38 520 18 'Installieren und Aktualisieren von Anwendungen der projektvorlage (IIS, PostgreSQL)' ([System.Drawing.Color]::FromArgb(170, 190, 210)) | Out-Null
$script:LblSteps = New-Label $header ($script:FormW - 450) 24 430 20 '' ([System.Drawing.Color]::FromArgb(170, 190, 210))
$script:LblSteps.TextAlign = 'MiddleRight'
$script:LblSteps.Anchor    = 'Top,Right'

$content = New-Object System.Windows.Forms.Panel
$content.Size      = New-Object System.Drawing.Size($script:FormW, ($script:FormH - 144))
$content.Dock      = 'Fill'
$content.Padding   = New-Object System.Windows.Forms.Padding(24, 18, 24, 10)
$content.BackColor = [System.Drawing.Color]::White

function New-Page {
    $p = New-Object System.Windows.Forms.Panel
    $p.Size    = New-Object System.Drawing.Size($pw, $ph)
    $p.Dock    = 'Fill'
    $p.Visible = $false
    $p.BackColor = [System.Drawing.Color]::White
    $content.Controls.Add($p)
    return $p
}

$footer = New-Object System.Windows.Forms.Panel
$footer.Size      = New-Object System.Drawing.Size($script:FormW, 56)
$footer.Dock      = 'Bottom'
$footer.BackColor = [System.Drawing.Color]::FromArgb(243, 243, 243)
$script:BtnOpenJson = New-Ctl System.Windows.Forms.Button $footer 24 13 170 30 'Katalog öffnen'
$script:BtnOpenLog  = New-Ctl System.Windows.Forms.Button $footer 202 13 150 30 'Protokoll öffnen'
$script:BtnBack     = New-Ctl System.Windows.Forms.Button $footer ($script:FormW - 20 - 110 - 8 - 170) 13 110 30 '< Zurück'
$script:BtnBack.Anchor = 'Top,Right'
$script:BtnNext     = New-Ctl System.Windows.Forms.Button $footer ($script:FormW - 20 - 170) 13 170 30 'Weiter >'
$script:BtnNext.Anchor    = 'Top,Right'
$script:BtnNext.Font      = $fontBold
$script:BtnNext.BackColor = $script:ColAccent
$script:BtnNext.ForeColor = [System.Drawing.Color]::White
$script:BtnNext.FlatStyle = 'Flat'
$script:BtnNext.Add_EnabledChanged({
    $script:BtnNext.BackColor = if ($script:BtnNext.Enabled) { $script:ColAccent } else { [System.Drawing.Color]::FromArgb(200, 205, 210) }
    $script:BtnNext.ForeColor = if ($script:BtnNext.Enabled) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(120, 120, 120) }
})

$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Size      = New-Object System.Drawing.Size($script:FormW, 24)
$statusBar.Dock      = 'Bottom'
$statusBar.BackColor = $script:ColDark
$script:StatusLabel = New-Label $statusBar 12 4 ($script:FormW - 40) 18 'Bereit.' ([System.Drawing.Color]::FromArgb(190, 205, 220))

# ==============================================================================
# 17) Seite 1: Auswahl (installiert / Katalog)
# ==============================================================================

$script:PnlSelect = New-Page
New-Label $script:PnlSelect 0 0 $pw 30 'Auswahl' $script:ColDark $fontHead | Out-Null
$script:LblJsonPath = New-Label $script:PnlSelect 0 34 $pw 18 '' $script:ColGray
$script:LblJsonPath.Anchor = 'Top,Left,Right'
New-Label $script:PnlSelect 0 58 $pw 20 'Auf diesem Server installiert - Einrichtung wiederholen oder aktualisieren' $script:ColDark $fontBold | Out-Null
$script:LvInstalled = New-ListBox $script:PnlSelect 80 196 @('Dienst - Mandant', 270, 'Ordner', 170, 'Port', 60, 'Adresse', 270, 'Version', 0)
New-Label $script:PnlSelect 0 284 $pw 20 'Katalog - neu installieren' $script:ColDark $fontBold | Out-Null
$script:LvCatalog = New-ListBox $script:PnlSelect 306 180 @('Dienst', 260, 'Schlüssel', 160, 'Beschreibung', 0)

$script:BtnReload   = New-Ctl System.Windows.Forms.Button $script:PnlSelect 0 ($ph - 96) 160 30 'Neu einlesen'
$script:BtnTemplate = New-Ctl System.Windows.Forms.Button $script:PnlSelect 168 ($ph - 96) 160 30 'Katalog-Vorlage anlegen'
$script:LblSelErr = New-Label $script:PnlSelect 0 ($ph - 60) $pw 60 '' $script:ColErr
$script:LblSelErr.Anchor = 'Left,Right,Bottom'
$script:SelKind = ''
$script:SelItem = $null

function Update-ProjectList {
    Set-Status 'Lese Katalog und Server ...'
    Read-ProjectJson
    $script:LblJsonPath.Text = "Katalog: $script:JsonPath   |   Programme: $($script:Settings.ProgRoot)"
    $php = Find-PhpExe
    $sites = if (Test-Path -LiteralPath $script:AppCmd) { @(Get-IisSites) } else { @() }
    $script:Instances = @(Get-InstalledInstances -ProgRoot $script:Settings.ProgRoot -PhpExe $php -Catalog $script:Services `
        -Sites $sites -ServicesJson (Join-Path $script:Settings.ProgRoot 'services.json') -CredDir $script:CredDir)
    foreach ($x in $script:Instances) { Write-Log ("Gefunden: {0} ({1}, {2}/{3}, Port {4}){5}" -f $x.Ordner, $x.Display, $x.ServiceKey, $x.Key, $x.Port, $(if ($x.Error) { " - $($x.Error)" } else { '' })) }

    foreach ($lv in @($script:LvInstalled, $script:LvCatalog)) {
        $lv.BeginUpdate(); $lv.Items.Clear()
        if ($lv.SmallImageList) { $lv.SmallImageList.Dispose() }
        $il = New-Object System.Windows.Forms.ImageList
        $il.ColorDepth = 'Depth32Bit'
        $il.ImageSize  = New-Object System.Drawing.Size(24, 24)
        $lv.SmallImageList = $il
    }
    $i = 0
    foreach ($x in $script:Instances) {
        $script:LvInstalled.SmallImageList.Images.Add((Get-ServiceImage -Service $x.Service -Index $i))
        $item = New-Object System.Windows.Forms.ListViewItem($x.Display, $i)
        [void]$item.SubItems.Add($x.Ordner)
        [void]$item.SubItems.Add($(if ($x.Port -gt 0) { [string]$x.Port } else { '-' }))
        [void]$item.SubItems.Add($(if ($x.Error) { $x.Error } else { $x.Url }))
        [void]$item.SubItems.Add($x.Version)
        if ($x.Error) { $item.ForeColor = $script:ColErr }
        $item.Tag = $x
        [void]$script:LvInstalled.Items.Add($item)
        $i++
    }
    $i = 0
    foreach ($s in $script:ServiceList) {
        $script:LvCatalog.SmallImageList.Images.Add((Get-ServiceImage -Service $s -Index $i))
        $n = @($script:Instances | Where-Object { $_.ServiceKey -ceq $s.Key }).Count
        $item = New-Object System.Windows.Forms.ListViewItem($(if ($n -gt 0) { "$($s.Name)  ($n installiert)" } else { $s.Name }), $i)
        [void]$item.SubItems.Add($s.Key)
        [void]$item.SubItems.Add($s.Description)
        $item.Tag = $s
        [void]$script:LvCatalog.Items.Add($item)
        $i++
    }
    $script:LvInstalled.EndUpdate(); $script:LvCatalog.EndUpdate()
    $script:BtnTemplate.Visible = -not (Test-Path -LiteralPath $script:JsonPath)
    $msgs = @($script:JsonErrors)
    if (-not $php) { $msgs = @('php.exe nicht gefunden - vorhandene Installationen lassen sich nicht lesen.') + $msgs }
    $script:LblSelErr.Text = ($msgs | Select-Object -First 4) -join "`r`n"
    foreach ($e in $msgs) { Write-Log $e 'Warn' }
    Set-Status ("{0} Installation(en) auf dem Server, {1} Dienst(e) im Katalog." -f $script:Instances.Count, $script:ServiceList.Count)
    Update-Selection
}

function Update-Selection {
    if ($script:LvInstalled.SelectedItems.Count -gt 0) { $script:SelKind = 'installed'; $script:SelItem = $script:LvInstalled.SelectedItems[0].Tag }
    elseif ($script:LvCatalog.SelectedItems.Count -gt 0) { $script:SelKind = 'catalog'; $script:SelItem = $script:LvCatalog.SelectedItems[0].Tag }
    else { $script:SelKind = ''; $script:SelItem = $null }
    Update-NextState
}

# Weiter von Seite 1: vorhandene Installation -> Pruefen, Katalog -> Angaben
function Open-Selection {
    if ($script:SelKind -eq 'installed') {
        $x = $script:SelItem
        if ($x.Error) { Show-Warn "Diese Installation ist nicht lesbar:`r`n$($x.Error)"; return }
        $script:Target = ConvertTo-InstallTarget -Instance $x
        $script:NewService = $null
        Initialize-CheckInputs
        Show-Page 'check'
    } elseif ($script:SelKind -eq 'catalog') {
        $script:NewService = $script:SelItem
        Initialize-InputPage
        Show-Page 'input'
    }
}

# ==============================================================================
# 18) Seite 2: Angaben für eine Neuinstallation
# ==============================================================================

$script:PnlInput = New-Page
$script:PnlInput.AutoScroll = $true
$script:LblInputHead = New-Label $script:PnlInput 0 0 $pw 30 'Angaben' $script:ColDark $fontHead
New-Label $script:PnlInput 0 43 150 20 'Mandant:' | Out-Null
$script:CmbTenant = New-Ctl System.Windows.Forms.ComboBox $script:PnlInput 156 40 300 24
$script:CmbTenant.DropDownStyle = 'DropDownList'
$script:TxtKey        = New-Field $script:PnlInput 0 70 'Mandanten-Schlüssel:' 180
$script:LblKeyHint    = New-Label $script:PnlInput 342 73 120 20 'a-z, 0-9, _ -' $script:ColGray
$script:TxtTenantName = New-Field $script:PnlInput 0 100 'Mandanten-Name:' 300
$script:TxtUrl        = New-Field $script:PnlInput 0 130 'Öffentliche URL:' 300
New-Label $script:PnlInput 156 156 304 30 'leer = http://localhost:<Port>/. Falls ein Cloudflare Tunnel genutzt wird: die https-Adresse.' $script:ColGray | Out-Null
$script:TxtPort       = New-Field $script:PnlInput 0 190 'Port:' 80
$script:LblPortState  = New-Label $script:PnlInput 244 193 216 20 ''
$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:TxtUpload     = New-Field $script:PnlInput 0 220 'Upload-Grenze (MB):' 80
$script:TxtAdminLogin = New-Field $script:PnlInput 0 250 'Admin-Login:' 180
$script:TxtAdminName  = New-Field $script:PnlInput 0 280 'Admin-Name:' 300
$script:TxtAdminMailN = New-Field $script:PnlInput 0 310 'Admin-E-Mail:' 300
$script:TxtDataDir    = New-Field $script:PnlInput 0 340 'Datenordner:' 210
$script:BtnDataDir    = New-Ctl System.Windows.Forms.Button $script:PnlInput 370 339 30 25 '...'
$script:BtnDetails    = New-Ctl System.Windows.Forms.Button $script:PnlInput 402 339 58 25 'Details'
$script:LblPathsInfo  = New-Label $script:PnlInput 156 366 304 18 '' $script:ColGray
$script:ChkFirewall   = New-Ctl System.Windows.Forms.CheckBox $script:PnlInput 0 390 460 22 'Im Netzwerk erreichbar (Firewallregel anlegen)'
$script:LblFwPreview  = New-Label $script:PnlInput 18 414 444 72 '' $script:ColGray $fontMono

$grpCf = New-Object System.Windows.Forms.GroupBox
$grpCf.Text = ' Cloudflare Access (optional, falls genutzt) '
$grpCf.Location = New-Object System.Drawing.Point(480, 36)
$grpCf.Size = New-Object System.Drawing.Size(($pw - 480), 110)
$script:PnlInput.Controls.Add($grpCf)
$script:TxtCfTeam = New-Field $grpCf 12 22 'Team-Domain:' 260 110
$script:TxtCfAud  = New-Field $grpCf 12 52 'AUD-Tag:' 260 110
$script:ChkCfGuard = New-Ctl System.Windows.Forms.CheckBox $grpCf 128 80 300 22 'Verbindungs-Wächter (guard)'

$grpMail = New-Object System.Windows.Forms.GroupBox
$grpMail.Text = ' E-Mail-Versand (optional) '
$grpMail.Location = New-Object System.Drawing.Point(480, 152)
$grpMail.Size = New-Object System.Drawing.Size(($pw - 480), 236)
$script:PnlInput.Controls.Add($grpMail)
$script:ChkMail       = New-Ctl System.Windows.Forms.CheckBox $grpMail 128 18 300 22 'Mails wirklich senden (mail.enabled)'
$script:TxtMailHost   = New-Field $grpMail 12 44 'SMTP-Server:' 260 110
$script:TxtMailPort   = New-Field $grpMail 12 74 'Port:' 60 110
$script:CmbMailEnc    = New-Ctl System.Windows.Forms.ComboBox $grpMail 264 74 70 24
$script:CmbMailEnc.DropDownStyle = 'DropDownList'
foreach ($e in @('tls', 'ssl', 'none')) { [void]$script:CmbMailEnc.Items.Add($e) }
$script:TxtMailUser   = New-Field $grpMail 12 104 'Benutzer:' 260 110
$script:TxtMailPass   = New-Field $grpMail 12 134 'Passwort:' 260 110
$script:TxtMailPass.UseSystemPasswordChar = $true
$script:TxtMailFrom   = New-Field $grpMail 12 164 'Absender:' 260 110
$script:TxtMailName   = New-Field $grpMail 12 194 'Absendername:' 260 110

$script:TxtDerived = New-Object System.Windows.Forms.TextBox
$script:TxtDerived.Location  = New-Object System.Drawing.Point(480, 396)
$script:TxtDerived.Size      = New-Object System.Drawing.Size(($pw - 480), 90)
$script:TxtDerived.Multiline = $true
$script:TxtDerived.ReadOnly  = $true
$script:TxtDerived.BorderStyle = 'None'
$script:TxtDerived.BackColor = $script:ColBox
$script:TxtDerived.Font      = $fontMono
$script:PnlInput.Controls.Add($script:TxtDerived)
$script:LblInputErr = New-Label $script:PnlInput 0 492 $pw 90 '' $script:ColErr

$script:InputInit = $false
$script:DataDirAuto = $true
$script:PortAuto = $true
$script:InputPortSuggestion = 0

# Eingabeseite fuer den gewaehlten Katalog-Dienst vorbelegen
function Initialize-InputPage {
    $s = $script:NewService
    $script:InputInit = $true
    try {
        $script:LblInputHead.Text = "Angaben: $($s.Name) neu installieren"
        $script:InputSites = if (Test-Path -LiteralPath $script:AppCmd) { @(Get-IisSites) } else { @() }
        $script:InputExcluded = @(Get-ExcludedPortRanges)
        $script:InputFirst = Test-FirstOrdnerFree -ServiceKey $s.Key -ProgRoot $script:Settings.ProgRoot -Sites $script:InputSites
        $script:InputTenants = Get-KnownTenants -Path (Join-Path $script:Settings.ProgRoot 'services.json')
        $script:CmbTenant.Items.Clear()
        [void]$script:CmbTenant.Items.Add('(neuer Mandant)')
        $script:TenantKeys = @('')
        foreach ($t in @($script:InputTenants.Values | Sort-Object Key)) {
            $da = @($script:Instances | Where-Object { $_.ServiceKey -ceq $s.Key -and $_.Key -ceq $t.Key }).Count -gt 0
            [void]$script:CmbTenant.Items.Add(("{0} - {1} (in {2}){3}" -f $t.Key, $t.Name, ($t.Services -join ', '), $(if ($da) { ' - schon installiert' } else { '' })))
            $script:TenantKeys += $t.Key
        }
        $script:CmbTenant.SelectedIndex = 0
        $script:TxtKey.ReadOnly = $false
        $script:TxtKey.Text = $(if (@($script:Instances | Where-Object { $_.ServiceKey -ceq $s.Key }).Count -eq 0 -and $script:InputTenants.Count -eq 0) { 'standard' } else { '' })
        $script:TxtTenantName.Text = ''
        $script:TxtUrl.Text = ''
        $script:InputPortSuggestion = Get-NextFreePort -Start $script:Settings.PortStart -Sites $script:InputSites -Excluded $script:InputExcluded
        $script:TxtPort.Text = $(if ($script:InputPortSuggestion -gt 0) { [string]$script:InputPortSuggestion } else { '' })
        $script:PortAuto = $true
        $script:TxtUpload.Text = [string]$s.UploadsMaxMb
        $script:TxtAdminLogin.Text = 'admin'
        $script:TxtAdminName.Text = 'Administrator'
        $script:TxtAdminMailN.Text = ''
        $script:PathOverride = $null
        $script:DataDirAuto = $true
        $script:ChkFirewall.Checked = $false
        foreach ($c in @($script:TxtCfTeam, $script:TxtCfAud, $script:TxtMailHost, $script:TxtMailUser, $script:TxtMailPass, $script:TxtMailFrom, $script:TxtMailName)) { $c.Text = '' }
        $script:ChkCfGuard.Checked = $false
        $script:ChkMail.Checked = $false
        $script:TxtMailPort.Text = '587'
        $script:CmbMailEnc.SelectedItem = 'tls'
        $script:LblInputErr.Text = ''
    } finally {
        $script:InputInit = $false
    }
    Update-InputDerived
}

# Abgeleitete Namen, Datenordner-Vorschlag, Port-Zustand, Firewall-Vorschau
function Update-InputDerived {
    if ($script:InputInit -or -not $script:NewService) { return }
    $s = $script:NewService
    $key = $script:TxtKey.Text.Trim()
    $ordner = ''
    $o = $null
    # Eine Meldung von "Weiter" gilt nur fuer die Eingaben von damals
    $script:LblInputErr.Text = ''
    if (Test-ServiceKey $key) {
        $o = Resolve-Ordner -ServiceKey $s.Key -InstKey $key -Instances $script:Instances -FirstFree $script:InputFirst.Free -FirstReason $script:InputFirst.Reason
        $ordner = $o.Name
        $db = Get-DefaultDbNames -Ordner $ordner
        $script:TxtDerived.Text = ("Ordner/Site/Pool: {0}`r`n                  ({1})`r`nProgramm : {2}`r`nDatenbank: {3} / Rolle {4}`r`nAufgabe  : \AK\{0} Aufgabenplanung" -f `
            $ordner, $o.Reason, (Join-Path $script:Settings.ProgRoot $ordner), $db.Name, $db.User)
        if ($o.Existing) { $script:TxtDerived.Text = "Schon installiert als $($o.Name) - oben unter 'Auf diesem Server installiert' wählen." }
    } else {
        $script:TxtDerived.Text = 'Mandanten-Schlüssel eingeben (a-z, 0-9, _ und -).'
    }
    if ($script:DataDirAuto) {
        $script:InputInit = $true
        $script:TxtDataDir.Text = $(if ($ordner) { [System.IO.Path]::Combine((Get-DefaultDataRoot), $ordner) } else { '' })
        $script:InputInit = $false
    }
    # Gibt es die Website schon (Abbruch eines frueheren Laufs), gilt ihr Port -
    # SNAIL aendert keine Bindings. Sonst der Vorschlag, solange nicht von Hand geaendert.
    if ($script:PortAuto -and -not ($o -and $o.Existing)) {
        $own = @($script:InputSites | Where-Object { $ordner -and $_.Name -ieq $ordner }) | Select-Object -First 1
        $want = if ($own -and (Get-PortFromBindings $own.Bindings) -gt 0) { Get-PortFromBindings $own.Bindings } else { $script:InputPortSuggestion }
        if ($want -gt 0 -and $script:TxtPort.Text -ne [string]$want) {
            $script:InputInit = $true
            $script:TxtPort.Text = [string]$want
            $script:InputInit = $false
        }
    }
    $script:LblPathsInfo.Text = if ($script:PathOverride) { 'Data/Cache/Logs/Temp einzeln angepasst ("Details")' } else { 'darin Data, Cache, Logs, Temp' }
    $p = 0
    if ([int]::TryParse($script:TxtPort.Text.Trim(), [ref]$p)) {
        $why = Test-PortFree -Port $p -Sites $script:InputSites -Excluded $script:InputExcluded -OwnSite $ordner
        $script:LblPortState.Text = if ($why) { $why } else { 'frei' }
        $script:LblPortState.ForeColor = if ($why) { $script:ColErr } else { $script:ColOk }
        $script:Tip.SetToolTip($script:LblPortState, $script:LblPortState.Text)
    } else {
        $script:LblPortState.Text = 'Zahl 1-65535'
        $script:LblPortState.ForeColor = $script:ColErr
    }
    $script:LblFwPreview.Text = if ($script:ChkFirewall.Checked -and $ordner -and $p -gt 0) { Get-FirewallPreview -Ordner $ordner -Port $p }
        else { "Ohne Häkchen: keine Firewallregel - der Port ist nur auf diesem Server`r`nerreichbar (reicht, falls ein Cloudflare Tunnel auf localhost zeigt)." }
}

function Get-InputValues {
    return @{
        Key = $script:TxtKey.Text; Name = $script:TxtTenantName.Text; Url = $script:TxtUrl.Text; Port = $script:TxtPort.Text
        UploadsMaxMb = $script:TxtUpload.Text; AdminLogin = $script:TxtAdminLogin.Text; AdminName = $script:TxtAdminName.Text
        AdminEmail = $script:TxtAdminMailN.Text; DataDir = $script:TxtDataDir.Text; Paths = $script:PathOverride
        Firewall = $script:ChkFirewall.Checked; CfTeam = $script:TxtCfTeam.Text; CfAud = $script:TxtCfAud.Text; CfGuard = $script:ChkCfGuard.Checked
        MailEnabled = $script:ChkMail.Checked; MailHost = $script:TxtMailHost.Text; MailPort = $script:TxtMailPort.Text
        MailEnc = [string]$script:CmbMailEnc.SelectedItem; MailUser = $script:TxtMailUser.Text; MailPass = $script:TxtMailPass.Text
        MailFrom = $script:TxtMailFrom.Text; MailFromName = $script:TxtMailName.Text
    }
}

# Weiter von "Angaben": Eingaben pruefen, dann Seite "Pruefen"
function Confirm-InputPage {
    $r = New-InstanceInput -Service $script:NewService -Values (Get-InputValues) -Instances $script:Instances `
        -FirstFree $script:InputFirst.Free -FirstReason $script:InputFirst.Reason
    if ($r.Errors.Count -gt 0) {
        $script:LblInputErr.Text = ($r.Errors -join "`r`n")
        return
    }
    $script:LblInputErr.Text = ($r.Hints -join "`r`n")
    $script:Target = $r.Inst
    Initialize-CheckInputs
    Show-Page 'check'
}

# Dialog "Details": Data, Cache, Logs, Temp einzeln
function Show-PathDetails {
    $base = $script:TxtDataDir.Text.Trim()
    $cur = if ($script:PathOverride) { $script:PathOverride } else { Get-DefaultPaths -DataDir $base }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Datenpfade einzeln'
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 220)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = $fontUi
    New-Label $dlg 12 10 596 34 'Pfade absolut, nicht im Programmordner; Temp auf demselben Laufwerk wie Data. Data gehört ins Backup, Cache darf jederzeit gelöscht werden.' $script:ColGray | Out-Null
    $boxes = @{}
    $y = 50
    foreach ($n in @('Data', 'Cache', 'Logs', 'Temp')) {
        $boxes[$n] = New-Field $dlg 12 $y ("paths." + $n.ToLowerInvariant() + ':') 470 100
        $boxes[$n].Text = [string]$cur.$n
        $y += 30
    }
    $ok = New-Ctl System.Windows.Forms.Button $dlg 340 180 80 28 'OK'
    $reset = New-Ctl System.Windows.Forms.Button $dlg 426 180 100 28 'Zurücksetzen'
    $cancel = New-Ctl System.Windows.Forms.Button $dlg 532 180 80 28 'Abbrechen'
    $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'; $reset.DialogResult = 'Retry'
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $res = $dlg.ShowDialog($script:Form)
    if ($res -eq 'OK') {
        $p = [pscustomobject]@{ Data = $boxes['Data'].Text.Trim(); Cache = $boxes['Cache'].Text.Trim(); Logs = $boxes['Logs'].Text.Trim(); Temp = $boxes['Temp'].Text.Trim() }
        $std = Get-DefaultPaths -DataDir $base
        $diff = @('Data', 'Cache', 'Logs', 'Temp' | Where-Object { $p.$_ -ine $std.$_ }).Count -gt 0
        $script:PathOverride = if ($diff) { $p } else { $null }
    } elseif ($res -eq 'Retry') {
        $script:PathOverride = $null
    }
    $dlg.Dispose()
    Update-InputDerived
}

# ==============================================================================
# 19) Seite 3: Prüfen
# ==============================================================================

$script:PnlCheck = New-Page
$script:LblCheckHead = New-Label $script:PnlCheck 0 0 $pw 30 'Prüfen' $script:ColDark $fontHead
$script:LvCheck = New-ResultList $script:PnlCheck 36 232 140

$grpCode = New-Object System.Windows.Forms.GroupBox
$grpCode.Text     = ' Programmcode '
$grpCode.Location = New-Object System.Drawing.Point(0, 276)
$grpCode.Size     = New-Object System.Drawing.Size($pw, 82)
$grpCode.Anchor   = 'Top,Left,Right'
$script:PnlCheck.Controls.Add($grpCode)
$script:RbZip      = New-Ctl System.Windows.Forms.RadioButton $grpCode 12 22 110 22 'ZIP-Datei:'
$script:TxtZip     = New-Ctl System.Windows.Forms.TextBox $grpCode 126 22 560 24
$script:BtnZip     = New-Ctl System.Windows.Forms.Button $grpCode 692 21 40 25 '...'
$script:RbExisting = New-Ctl System.Windows.Forms.RadioButton $grpCode 12 50 674 22 'Vorhandenen Programmordner nutzen'
$script:BtnRecheck = New-Ctl System.Windows.Forms.Button $grpCode ($pw - 170) 20 156 30 'Erneut prüfen'
$script:BtnRecheck.Anchor = 'Top,Right'

$script:GrpBackup = New-Object System.Windows.Forms.GroupBox
$script:GrpBackup.Text     = ' Sicherung vor dem Aktualisieren '
$script:GrpBackup.Location = New-Object System.Drawing.Point(0, 364)
$script:GrpBackup.Size     = New-Object System.Drawing.Size($pw, 72)
$script:GrpBackup.Anchor   = 'Top,Left,Right'
$script:PnlCheck.Controls.Add($script:GrpBackup)
$script:ChkSkipBackup = New-Ctl System.Windows.Forms.CheckBox $script:GrpBackup 12 20 ($pw - 30) 22 'Sicherung überspringen (pg_dump und config.php)'
$script:ChkBackupOk   = New-Ctl System.Windows.Forms.CheckBox $script:GrpBackup 30 44 ($pw - 50) 22 'Ich habe eine andere funktionierende Sicherung (z. B. Veeam/VM-Sicherung).'

# gleicher Platz wie die Sicherung: die gibt es nur beim Aktualisieren, das
# Uebernehmen einer vorhandenen Datenbank nur bei einer Neuinstallation
$script:GrpAdopt = New-Object System.Windows.Forms.GroupBox
$script:GrpAdopt.Text     = ' Vorhandene Datenbank '
$script:GrpAdopt.Location = New-Object System.Drawing.Point(0, 364)
$script:GrpAdopt.Size     = New-Object System.Drawing.Size($pw, 72)
$script:GrpAdopt.Anchor   = 'Top,Left,Right'
$script:GrpAdopt.Visible  = $false
$script:PnlCheck.Controls.Add($script:GrpAdopt)
$script:ChkAdoptDb = New-Ctl System.Windows.Forms.CheckBox $script:GrpAdopt 12 20 ($pw - 30) 22 'Vorhandene Datenbank übernehmen (alte Daten bleiben erhalten)'
New-Label $script:GrpAdopt 30 46 ($pw - 50) 18 'Ohne Häkchen keine Installation. Sonst Datenbank und Rolle in PostgreSQL entfernen oder einen anderen Mandanten-Schlüssel wählen.' $script:ColGray | Out-Null

$grpDb = New-Object System.Windows.Forms.GroupBox
$grpDb.Text     = ' PostgreSQL (Superuser) '
$grpDb.Location = New-Object System.Drawing.Point(0, 442)
$grpDb.Size     = New-Object System.Drawing.Size($pw, 78)
$grpDb.Anchor   = 'Top,Left,Right'
$script:PnlCheck.Controls.Add($grpDb)
New-Label $grpDb 12 27 140 20 'Passwort postgres:' | Out-Null
$script:TxtPgPw    = New-Ctl System.Windows.Forms.TextBox $grpDb 156 24 280 24
$script:TxtPgPw.UseSystemPasswordChar = $true
$script:ChkShowPw  = New-Ctl System.Windows.Forms.CheckBox $grpDb 446 25 90 22 'anzeigen'
$script:BtnTestDb  = New-Ctl System.Windows.Forms.Button $grpDb 540 22 170 28 'Verbindung testen'
$script:LblPwSource = New-Label $grpDb 156 52 ($pw - 170) 18 '' $script:ColGray

$script:LblCheckHint = New-Label $script:PnlCheck 0 ($ph - 62) $pw 60 '' $script:ColGray
$script:LblCheckHint.Anchor = 'Left,Right,Bottom'

# Eingaben auf der Seite "Pruefen" fuer die gewaehlte Installation vorbelegen
function Initialize-CheckInputs {
    $t = $script:Target
    $zip = [string]$t.Service.Zip
    $hasZip = ($zip -and (Test-Path -LiteralPath $zip))
    $script:TxtZip.Text = $zip
    # Neu: ZIP, falls vorhanden - ausser der Programmordner ist schon befuellt.
    # Vorhanden: ohne ZIP = Wiederholen, ZIP = Aktualisieren
    $filled = ($t.Kind -eq 'new' -and (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $script:Settings.ProgRoot $t.Ordner) 'bin') 'console')))
    $script:RbZip.Checked = ($t.Kind -eq 'new' -and [bool]$hasZip -and -not $filled)
    $script:RbExisting.Checked = -not $script:RbZip.Checked
    $script:ChkSkipBackup.Checked = $false
    $script:ChkBackupOk.Checked = $false
    $script:ChkBackupOk.Enabled = $false
    $script:ChkAdoptDb.Checked = $false
    if ([string]::IsNullOrEmpty($script:TxtPgPw.Text)) {
        $saved = Get-SavedSuperuserPassword
        if ($saved) {
            $script:TxtPgPw.Text = $saved
            $script:LblPwSource.Text = "Automatisch gelesen aus: $script:WippPgCred"
        } else {
            $script:LblPwSource.Text = 'Keine WIPP-Zugangsdaten gefunden - Passwort eingeben und "Verbindung testen".'
        }
    }
}

function Invoke-CheckPage {
    $t = $script:Target
    $script:LblCheckHead.Text = "Prüfen: $($t.Display)"
    $script:LvCheck.BeginUpdate()
    $script:LvCheck.Items.Clear()
    $script:LvCheck.EndUpdate()
    Set-Busy $true
    try {
        Set-Status 'Prüfe ...'
        $res = Test-Installation -Target $t -ZipPath $script:TxtZip.Text.Trim() -UseZip $script:RbZip.Checked -Password $script:TxtPgPw.Text
    } catch {
        $res = [pscustomobject]@{ Ok = $false; Plan = $null; Items = @([pscustomobject]@{ Level = 'Error'; Name = 'Prüfung'; Text = $_.Exception.Message }) }
        Write-Log $_.Exception.Message 'Error'
    } finally {
        Set-Busy $false
    }
    if ($script:CloseAfterAbort) { $script:Form.Close(); return }
    $script:LvCheck.BeginUpdate()
    foreach ($it in $res.Items) { Add-ResultRow $script:LvCheck $it.Level $it.Name $it.Text }
    $script:LvCheck.EndUpdate()
    $script:Plan = $res.Plan
    $script:CheckOk = $res.Ok
    $isUpdate = ($res.Plan -and $res.Plan.Mode -eq 'update')
    $script:GrpBackup.Visible = $isUpdate
    if ($isUpdate -and $res.Plan.BackupInfo) { $script:GrpBackup.Text = " Sicherung vor dem Aktualisieren - $($res.Plan.BackupInfo.Text) " }
    # das Haekchen gilt nur fuer genau dieses Pruefergebnis
    $adopt = [bool]($res.Plan -and $res.Plan.DbAdoptNeeded)
    $script:ChkAdoptDb.Checked = $false
    if ($adopt) { $script:ChkAdoptDb.Text = $res.Plan.DbAdoptText }
    $script:GrpAdopt.Visible = $adopt
    if ($res.Plan) { $script:RbExisting.Text = "Vorhandenen Programmordner nutzen: $($res.Plan.ProgDir)" + $(if ($t.Kind -eq 'installed') { ' (= Einrichtung wiederholen; ZIP = Aktualisieren)' } else { '' }) }
    $verb = if ($isUpdate) { 'Aktualisieren' } else { 'Installieren' }
    $script:LblCheckHint.Text = if ($res.Ok -and $adopt) {
        'Datenbank bzw. Rolle gibt es schon (gelb markiert). "Installieren" erst nach dem Häkchen "übernehmen" - die alten Daten bleiben dann erhalten.'
    } elseif ($res.Ok) {
        "Bereit. ""$verb"" führt die Schritte der Reihe nach aus; jeder Schritt ist wiederholbar. Eingaben geändert? Dann ""Erneut prüfen""."
    } else {
        'Rot markierte Punkte verhindern die Installation. Ursache beheben (Angaben mit "Zurück", Katalog mit "Neu einlesen") und "Erneut prüfen".'
    }
    Set-Status $(if ($res.Ok) { 'Prüfung ohne Fehler.' } else { 'Prüfung mit Fehlern.' })
    Update-NextState
}

# Geaenderte Eingaben machen das Pruefergebnis ungueltig
function Set-CheckDirty {
    if ($script:CurrentPage -ne 'check' -or $script:Busy) { return }
    if ($script:CheckOk) {
        $script:CheckOk = $false
        $script:LblCheckHint.Text = 'Eingaben geändert - bitte "Erneut prüfen".'
        Update-NextState
    }
}

# ==============================================================================
# 20) Seite 4: Installation
# ==============================================================================

$script:PnlInstall = New-Page
$script:LblInstHead = New-Label $script:PnlInstall 0 0 $pw 30 'Installation' $script:ColDark $fontHead

$script:LvSteps = New-Object System.Windows.Forms.ListView
$script:LvSteps.Location      = New-Object System.Drawing.Point(0, 40)
$script:LvSteps.Size          = New-Object System.Drawing.Size(350, ($ph - 40 - 76))
$script:LvSteps.View          = 'Details'
$script:LvSteps.HeaderStyle   = 'None'
$script:LvSteps.Font          = $fontSym
$script:LvSteps.FullRowSelect = $true
[void]$script:LvSteps.Columns.Add(' ', 28)
[void]$script:LvSteps.Columns.Add('Schritt', 316)
$script:PnlInstall.Controls.Add($script:LvSteps)

$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Location   = New-Object System.Drawing.Point(362, 40)
$script:LogBox.Size       = New-Object System.Drawing.Size(($pw - 362), ($ph - 40 - 76))
$script:LogBox.Anchor     = 'Top,Left,Right,Bottom'
$script:LogBox.ReadOnly   = $true
$script:LogBox.BackColor  = [System.Drawing.Color]::FromArgb(24, 30, 38)
$script:LogBox.ForeColor  = [System.Drawing.Color]::FromArgb(210, 210, 210)
$script:LogBox.Font       = $fontMono
$script:LogBox.BorderStyle = 'None'
$script:LogBox.WordWrap   = $false
$script:LogBox.ScrollBars = 'Both'
$script:PnlInstall.Controls.Add($script:LogBox)

$script:LblInstallError = New-Label $script:PnlInstall 0 ($ph - 68) $pw 60 '' $script:ColErr $fontBold
$script:LblInstallError.Anchor = 'Left,Right,Bottom'

function Initialize-InstallPage {
    $script:LblInstHead.Text = "{0}: {1}" -f $(switch ($script:Plan.Mode) { 'update' { 'Aktualisieren' } 'repeat' { 'Einrichtung wiederholen' } default { 'Neu installieren' } }), $script:Target.Display
    $script:LblInstallError.Text = ''
    $script:LvSteps.BeginUpdate()
    $script:LvSteps.SelectedItems.Clear()
    $script:LvSteps.Items.Clear()
    foreach ($s in (Get-StepPlan -Plan $script:Plan)) {
        $item = New-Object System.Windows.Forms.ListViewItem([string][char]0x25CB)
        [void]$item.SubItems.Add($s.Title)
        $item.ForeColor = [System.Drawing.Color]::Gray
        [void]$script:LvSteps.Items.Add($item)
    }
    $script:LvSteps.EndUpdate()
    $script:LvSteps.Refresh()
}

# ==============================================================================
# 21) Seite 5: Fertig
# ==============================================================================

$script:PnlFinish = New-Page
$script:LblFinHead = New-Label $script:PnlFinish 0 0 $pw 30 'Fertig' $script:ColDark $fontHead
$script:LblFinText = New-Label $script:PnlFinish 0 36 $pw 36 '' $script:ColGray
$script:LblFinText.Anchor = 'Top,Left,Right'
$script:LblAccHead = New-Label $script:PnlFinish 0 76 $pw 22 'Zugangsdaten und Ablage' $script:ColDark $fontBig
$script:TxtAcc = New-Object System.Windows.Forms.TextBox
$script:TxtAcc.Location  = New-Object System.Drawing.Point(0, 100)
$script:TxtAcc.Size      = New-Object System.Drawing.Size($pw, 80)
$script:TxtAcc.Anchor    = 'Top,Left,Right'
$script:TxtAcc.Multiline = $true
$script:TxtAcc.ReadOnly  = $true
$script:TxtAcc.BorderStyle = 'None'
$script:TxtAcc.BackColor = $script:ColBox
$script:TxtAcc.Font      = New-Object System.Drawing.Font('Consolas', 9.5)
$script:PnlFinish.Controls.Add($script:TxtAcc)
$script:LblAccNote = New-Label $script:PnlFinish 0 184 $pw 34 '' $script:ColGray
$script:LblResHead = New-Label $script:PnlFinish 0 220 $pw 22 'Hinweise' $script:ColDark $fontBig
$script:LvRes = New-ResultList $script:PnlFinish 244 140 260
$script:LblNextSteps = New-Label $script:PnlFinish 0 392 $pw 22 'Nächste Schritte' $script:ColDark $fontBig

$script:FlowFinish = New-Object System.Windows.Forms.FlowLayoutPanel
$script:FlowFinish.Location      = New-Object System.Drawing.Point(0, 418)
$script:FlowFinish.Size          = New-Object System.Drawing.Size($pw, ($ph - 418))
$script:FlowFinish.Anchor        = 'Top,Left,Right,Bottom'
$script:FlowFinish.FlowDirection = 'LeftToRight'
$script:FlowFinish.WrapContents  = $true
$script:FlowFinish.AutoScroll    = $true
$script:PnlFinish.Controls.Add($script:FlowFinish)

function Add-FinishButton {
    param([string]$Text, [scriptblock]$OnClick, [switch]$Accent)
    $b = New-Object System.Windows.Forms.Button
    $b.Size   = New-Object System.Drawing.Size(300, 32)
    $b.Text   = $Text
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 8)
    if ($Accent) {
        $b.BackColor = $script:ColAccent
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatStyle = 'Flat'
        $b.Font      = $fontBold
    }
    $b.Tag = $OnClick
    $b.Add_Click({ & $this.Tag })
    $script:FlowFinish.Controls.Add($b)
}

function Initialize-FinishPage {
    $r = $script:Result
    $plan = $r.Plan
    $script:LblFinHead.Text = "Fertig: $($r.Display)"
    $warnCount = 0
    if ($r.Check) { $warnCount += @($r.Check.Items | Where-Object { $_.Status -eq 'WARNUNG' }).Count }
    $errRows = @($r.Rows | Where-Object { $_.Level -eq 'Error' }).Count
    $script:LblFinText.Text = ("{0} unter {1} (lokal {2}). Selbstprüfung bestanden{3}." -f `
        $(if ($plan.Mode -eq 'update') { 'Aktualisiert' } else { 'Die Anwendung läuft' }), $r.Url, $r.Local,
        $(if ($errRows -gt 0) { " - $errRows Schritt(e) mit Fehlern, siehe unten" } elseif ($warnCount -gt 0) { ' mit Hinweisen, siehe unten' } else { '' }))

    # --- Zugangsdaten (markier- und kopierbar) --------------------------------
    $lines = New-Object System.Collections.Generic.List[string]
    if ($r.Admin) {
        if ($r.Admin.Count -gt 0) { $lines.Add(("Anmeldung  : {0} Benutzerkonto(en) vorhanden - kein neuer Administrator" -f $r.Admin.Count)) }
        else {
            $lines.Add(("Anmeldung  : {0}" -f $r.Admin.Login))
            if ($r.Admin.Passwort) { $lines.Add(("Passwort   : {0}   (Initialpasswort - Wechsel beim ersten Login)" -f $r.Admin.Passwort)) }
            else { $lines.Add("Passwort   : unverändert (Benutzer existierte bereits; Notfall: php bin\console user:password $($r.Admin.Login))") }
        }
    }
    $lines.Add(("Datenbank  : {0}   Rolle: {1}   ({2}:{3})" -f $r.Db.Name, $r.Db.User, $plan.Pg.Host, $plan.Pg.Port))
    if ($plan.Mode -ne 'update' -and $r.Db.Password) { $lines.Add(("DB-Passwort: {0}   ({1})" -f $r.Db.Password, $r.Db.Source)) }
    $ak = $r.AppKey
    switch ($ak.Status) {
        'new'     { $lines.Add(("app.key    : {0}   (bei dieser Installation erzeugt - mit der config.php sichern, im Passwortmanager ablegen)" -f $ak.Key)) }
        'added'   { $lines.Add(("app.key    : {0}   (in die vorhandene config.php nachgetragen - sichern, im Passwortmanager ablegen)" -f $ak.Key)) }
        'present' { $lines.Add('app.key    : vorhanden, unverändert') }
        'invalid' { $lines.Add('app.key    : UNGÜLTIG in der config.php - nicht geändert, siehe Hinweise unten') }
        'failed'  { $lines.Add('app.key    : vorhanden, unverändert (weitere Schlüssel nicht ergänzt, siehe Hinweise unten)') }
        'manual'  {
            $lines.Add('app.key    : NICHT eingetragen - automatisch ging es nicht (siehe Hinweise unten). Vorschlag zum Selbsteintragen:')
            $lines.Add(("             {0}" -f $ak.Key))
            $lines.Add("             Gilt erst, wenn er in der config.php unter 'app' => [ 'key' => '...' ] steht. NUR eintragen, wenn")
            $lines.Add('             app.key dort wirklich fehlt oder leer ist - einen vorhandenen Schlüssel nie ersetzen (Passwörter verloren).')
        }
    }
    if ($ak.Backup) { $lines.Add(("Vorher     : {0}   (config.php vor der Änderung, enthält das DB-Passwort)" -f $ak.Backup)) }
    $lines.Add(("Ordner     : {0}   Daten: {1}" -f $plan.ProgDir, $(if ($plan.DataDir) { $plan.DataDir } else { $plan.Paths.Data })))
    if ($r.Backup) { $lines.Add(("Sicherung  : {0}" -f $r.Backup.Text)) }
    elseif ($r.BackupSkipped) { $lines.Add('Sicherung  : übersprungen (andere Sicherung bestätigt, im Protokoll vermerkt)') }
    $script:TxtAcc.Text = ($lines -join "`r`n")
    $script:TxtAcc.Height = ($lines.Count * 17) + 8
    $y = $script:TxtAcc.Top + $script:TxtAcc.Height + 4

    $notiz = New-Object System.Collections.Generic.List[string]
    if ($plan.Mode -ne 'update') { $notiz.Add($(if ($r.ConfigNew) { 'config.php wurde erzeugt.' } else { 'Die vorhandene config.php wurde übernommen.' })) }
    if ($plan.Mode -eq 'update') { $notiz.Add('Neue Konfigurationsschlüssel ergänzt SNAIL nicht (Ausnahme: app.key, app.key_previous und mail.redirect_to, falls sie fehlen) - die Anwendung läuft mit Standardwerten weiter; Hinweise von check stehen unten ("config.php öffnen").') }
    if ($ak.Backup) { $notiz.Add('Die Kopie der vorherigen config.php ist nur für Administratoren lesbar; SNAIL löscht sie nicht automatisch.') }
    if ($r.CredFile) { $notiz.Add("Zugangsdaten liegen in $($r.CredFile) - nach dem Übertragen in den Passwortmanager löschen.") }
    if ($r.Backup) { $notiz.Add('SNAIL löscht Sicherungen nie automatisch.') }
    $txt = ($notiz -join ' ')
    $size = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $script:LblAccNote.Font, (New-Object System.Drawing.Size($pw, 0)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $script:LblAccNote.Top = $y
    $script:LblAccNote.Text = $txt
    $script:LblAccNote.Height = $size.Height + 4
    $y = $script:LblAccNote.Top + $script:LblAccNote.Height + 10

    # --- Hinweise: Schritte, check, windows-pruefung -------------------------
    $script:LvRes.BeginUpdate()
    $script:LvRes.Items.Clear()
    foreach ($row in $r.Rows) { Add-ResultRow $script:LvRes $row.Level $row.Name $row.Text }
    if ($r.Check) {
        foreach ($it in @($r.Check.Items | Where-Object { $_.Status -eq 'WARNUNG' -or $_.Status -eq 'FEHLER' })) {
            Add-ResultRow $script:LvRes $(if ($it.Status -eq 'FEHLER') { 'Error' } else { 'Warn' }) ('check: ' + $it.Label) $it.Hint
        }
    }
    if ($r.Verify -and $r.Verify.Ran) {
        Add-ResultRow $script:LvRes $(if ($r.Verify.Errors -gt 0) { 'Error' } elseif ($r.Verify.Warnings -gt 0) { 'Warn' } else { 'Ok' }) 'windows-pruefung.ps1' $r.Verify.Text
        foreach ($it in $r.Verify.Items) {
            Add-ResultRow $script:LvRes $(if ($it.Status -eq 'FEHLER') { 'Error' } else { 'Warn' }) ('  ' + $it.Label) $it.Hint
        }
    }
    $script:LvRes.EndUpdate()
    $script:LblResHead.Top = $y
    $script:LvRes.Top = $y + 24
    $script:LvRes.Height = [math]::Max(44, [math]::Min(180, ($script:LvRes.Items.Count * 21) + 8))
    $script:LblResHead.Visible = ($script:LvRes.Items.Count -gt 0)
    $script:LvRes.Visible = ($script:LvRes.Items.Count -gt 0)
    if ($script:LvRes.Visible) { $y = $script:LvRes.Top + $script:LvRes.Height + 10 }

    $script:LblNextSteps.Top = $y
    $script:FlowFinish.Top = $y + 26
    $script:FlowFinish.Height = [math]::Max(80, $ph - $script:FlowFinish.Top)
    $script:FlowFinish.Controls.Clear()
    Add-FinishButton -Accent -Text "Anwendung öffnen: $($r.Url)" -OnClick { Open-InBrowser $script:Result.Url }
    if ($r.Url -ne $r.Local) { Add-FinishButton -Text "Lokal öffnen: $($r.Local)" -OnClick { Open-InBrowser $script:Result.Local } }
    Add-FinishButton -Text 'config.php öffnen' -OnClick { Open-InNotepad $script:Result.ConfigFile }
    if ($r.Verify -and $r.Verify.Report) { Add-FinishButton -Text 'Prüfbericht öffnen' -OnClick { Open-InNotepad $script:Result.Verify.Report } }
    if ($r.CredFile) { Add-FinishButton -Text 'Zugangsdaten-Datei öffnen' -OnClick { Open-InNotepad $script:Result.CredFile } }
    Add-FinishButton -Text 'Zur Auswahl' -OnClick {
        Show-Page 'select'
        Update-ProjectList
    }
}

# ==============================================================================
# 22) Seitensteuerung
# ==============================================================================

$script:Pages = @{ select = $script:PnlSelect; input = $script:PnlInput; check = $script:PnlCheck; install = $script:PnlInstall; finish = $script:PnlFinish }

function Update-StepHeader {
    param([string]$Page)
    $names = @('Auswahl', 'Angaben', 'Prüfen', 'Installation', 'Fertig')
    $order = @('select', 'input', 'check', 'install', 'finish')
    $parts = @()
    for ($i = 0; $i -lt $order.Count; $i++) {
        $n = '{0} {1}' -f ($i + 1), $names[$i]
        if ($order[$i] -eq $Page) { $n = "[ $n ]" }
        $parts += $n
    }
    $script:LblSteps.Text = $parts -join '   '
}

function Update-NextState {
    switch ($script:CurrentPage) {
        'select' {
            $script:BtnNext.Text    = 'Weiter >'
            $script:BtnNext.Enabled = [bool]$script:SelItem -and -not $script:Busy
            $script:BtnBack.Enabled = $false
        }
        'input' {
            $script:BtnNext.Text    = 'Weiter >'
            $script:BtnNext.Enabled = -not $script:Busy
            $script:BtnBack.Enabled = -not $script:Busy
        }
        'check' {
            $isUpdate = ($script:Plan -and $script:Plan.Mode -eq 'update')
            $backupOk = (-not $isUpdate) -or (-not $script:ChkSkipBackup.Checked) -or $script:ChkBackupOk.Checked
            $adoptOk = (-not ($script:Plan -and $script:Plan.DbAdoptNeeded)) -or $script:ChkAdoptDb.Checked
            $script:BtnNext.Text    = if ($isUpdate) { 'Aktualisieren' } else { 'Installieren' }
            $script:BtnNext.Enabled = [bool]$script:CheckOk -and $backupOk -and $adoptOk -and -not $script:Busy
            $script:BtnBack.Enabled = -not $script:Busy
        }
        'install' {
            $script:BtnNext.Text    = 'Erneut versuchen'
            $script:BtnNext.Enabled = -not $script:Busy
            $script:BtnBack.Enabled = -not $script:Busy
        }
        'finish' {
            $script:BtnNext.Text    = 'Schließen'
            $script:BtnNext.Enabled = $true
            $script:BtnBack.Enabled = $false
        }
    }
}

function Show-Page {
    param([string]$Page)
    $script:CurrentPage = $Page
    foreach ($k in $script:Pages.Keys) { $script:Pages[$k].Visible = ($k -eq $Page) }
    Update-StepHeader $Page
    switch ($Page) {
        'select'  { Set-Status 'Installation oder Katalog-Dienst auswählen und auf "Weiter" klicken.' }
        'input'   { Set-Status 'Angaben für die Neuinstallation eintragen.' }
        'check'   { Invoke-CheckPage }
        'install' { Set-Status 'Läuft ...' }
        'finish'  { Initialize-FinishPage; Set-Status 'Fertig.' }
    }
    Update-NextState
}

function Start-Install {
    $t = $script:Target
    $plan = $script:Plan
    if (-not $plan) { return }
    if ($script:CurrentPage -eq 'check') {
        $plan.SkipBackup = ($plan.Mode -eq 'update' -and $script:ChkSkipBackup.Checked)
        if ($plan.SkipBackup -and -not $script:ChkBackupOk.Checked) { Show-Warn 'Sicherung überspringen nur mit Bestätigung einer anderen Sicherung.'; return }
        $plan.AdoptDb = ($plan.DbAdoptNeeded -and $script:ChkAdoptDb.Checked)
        if ($plan.DbAdoptNeeded -and -not $plan.AdoptDb) { Show-Warn 'Datenbank bzw. Rolle gibt es schon - installiert wird nur mit dem Häkchen "übernehmen".'; return }
        $was = switch ($plan.Mode) { 'update' { 'aktualisiert' } 'repeat' { 'erneut eingerichtet' } default { 'neu installiert' } }
        $sich = if ($plan.Mode -ne 'update') { '' } elseif ($plan.SkipBackup) { "`nSicherung: ÜBERSPRUNGEN (andere Sicherung bestätigt)" } else { "`nSicherung: $(Get-BackupRoot -Plan $plan)\<Zeit>" }
        if ($plan.AdoptDb) { $sich += "`nDatenbank: VORHANDENE wird übernommen (alte Daten bleiben erhalten)" }
        $text = ("{0} wird {1}:`n`nOrdner/Site/Pool:  {2}`nProgramm:  {3}`nDaten:     {4}`nPort:      {5}   Adresse: {6}`nDatenbank: {7} (Rolle {8}){9}`n`nJetzt starten?" -f `
            $t.Display, $was, $plan.Ordner, $plan.ProgDir, $(if ($plan.DataDir) { $plan.DataDir } else { $plan.Paths.Data }), $(if ($t.Port -gt 0) { $t.Port } else { '?' }), $t.Url, $plan.DbName, $plan.DbUser, $sich)
        if (-not (Show-Confirm $text 'Starten')) { return }
    }
    $script:AbortRequested = $false
    Show-Page 'install'
    Initialize-InstallPage
    $ok = Invoke-Installation -Plan $plan -Password $script:TxtPgPw.Text
    if ($script:CloseAfterAbort) { $script:Form.Close(); return }
    if ($ok) { Show-Page 'finish' }
    else {
        $script:LblInstallError.Text = $script:Result.Error
        Set-Status 'Fehlgeschlagen - Grund siehe oben und im Protokoll; "Erneut versuchen" macht beim fehlgeschlagenen Schritt weiter.'
        Update-NextState
    }
}

# ==============================================================================
# 23) Ereignisse
# ==============================================================================

$script:LvInstalled.Add_SelectedIndexChanged({
    if ($script:LvInstalled.SelectedItems.Count -gt 0 -and $script:LvCatalog.SelectedItems.Count -gt 0) { $script:LvCatalog.SelectedItems.Clear() }
    Update-Selection
})
$script:LvCatalog.Add_SelectedIndexChanged({
    if ($script:LvCatalog.SelectedItems.Count -gt 0 -and $script:LvInstalled.SelectedItems.Count -gt 0) { $script:LvInstalled.SelectedItems.Clear() }
    Update-Selection
})
$script:LvInstalled.Add_DoubleClick({ Update-Selection; Open-Selection })
$script:LvCatalog.Add_DoubleClick({ Update-Selection; Open-Selection })

$script:BtnReload.Add_Click({ Update-ProjectList })
$script:BtnTemplate.Add_Click({
    if (Test-Path -LiteralPath $script:JsonPath) { Show-Info 'Die Datei existiert bereits.'; return }
    [System.IO.File]::WriteAllText($script:JsonPath, $script:JsonTemplate, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "Vorlage angelegt: $script:JsonPath" 'Ok'
    Open-InNotepad $script:JsonPath
    Update-ProjectList
})
$script:BtnOpenJson.Add_Click({
    if (Test-Path -LiteralPath $script:JsonPath) { Open-InNotepad $script:JsonPath }
    else { Show-Info "Die Datei existiert noch nicht:`r`n$script:JsonPath`r`n`r`nAuf der Startseite kann eine Vorlage angelegt werden." }
})
$script:BtnOpenLog.Add_Click({ Open-InNotepad $script:LogFile })

# Seite "Angaben"
$script:CmbTenant.Add_SelectedIndexChanged({
    if ($script:InputInit) { return }
    $k = $script:CmbTenant.SelectedIndex
    if ($k -le 0) {
        $script:TxtKey.ReadOnly = $false
        $script:TxtKey.Text = ''
        $script:TxtTenantName.Text = ''
    } else {
        $t = $script:InputTenants[$script:TenantKeys[$k]]
        $script:TxtKey.Text = $t.Key
        $script:TxtKey.ReadOnly = $true
        $script:TxtTenantName.Text = $t.Name
    }
    Update-InputDerived
})
$script:TxtKey.Add_TextChanged({ Update-InputDerived })
$script:TxtPort.Add_TextChanged({
    if ($script:InputInit) { return }
    $script:PortAuto = $false
    Update-InputDerived
})
$script:ChkFirewall.Add_CheckedChanged({ Update-InputDerived })
$script:TxtDataDir.Add_TextChanged({
    if ($script:InputInit) { return }
    $script:DataDirAuto = $false
    Update-InputDerived
})
$script:BtnDataDir.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Datenordner dieser Installation (darin entstehen Data, Cache, Logs, Temp)'
    if ($dlg.ShowDialog($script:Form) -eq 'OK') { $script:TxtDataDir.Text = $dlg.SelectedPath }
})
$script:BtnDetails.Add_Click({ Show-PathDetails })

# Seite "Pruefen"
$script:BtnZip.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'ZIP-Dateien (*.zip)|*.zip|Alle Dateien (*.*)|*.*'
    $dir = if ($script:TxtZip.Text) { Split-Path -Parent $script:TxtZip.Text } else { $script:JsonDir }
    if ($dir -and (Test-Path -LiteralPath $dir)) { $dlg.InitialDirectory = $dir }
    if ($dlg.ShowDialog($script:Form) -eq 'OK') { $script:TxtZip.Text = $dlg.FileName; $script:RbZip.Checked = $true }
})
$script:TxtZip.Add_TextChanged({ Set-CheckDirty })
foreach ($c in @($script:RbZip, $script:RbExisting)) { $c.Add_CheckedChanged({ Set-CheckDirty }) }
$script:BtnRecheck.Add_Click({ Invoke-CheckPage })
$script:ChkSkipBackup.Add_CheckedChanged({
    $script:ChkBackupOk.Enabled = $script:ChkSkipBackup.Checked
    if (-not $script:ChkSkipBackup.Checked) { $script:ChkBackupOk.Checked = $false }
    Update-NextState
})
$script:ChkBackupOk.Add_CheckedChanged({ Update-NextState })
$script:ChkAdoptDb.Add_CheckedChanged({ Update-NextState })

$script:ChkShowPw.Add_CheckedChanged({ $script:TxtPgPw.UseSystemPasswordChar = -not $script:ChkShowPw.Checked })
$script:BtnTestDb.Add_Click({
    if ([string]::IsNullOrEmpty($script:TxtPgPw.Text)) { $script:LblPwSource.Text = 'Bitte zuerst ein Passwort eingeben.'; return }
    $t = Test-PgSuperuser -Pg (Get-PgSettings) -Password $script:TxtPgPw.Text
    $script:LblPwSource.Text = $t.Message
    $script:LblPwSource.ForeColor = if ($t.Ok) { $script:ColOk } else { $script:ColErr }
    Write-Log ("Verbindungstest: {0}" -f $t.Message) $(if ($t.Ok) { 'Ok' } else { 'Warn' })
    if ($t.Ok) { Invoke-CheckPage }
})

$script:BtnBack.Add_Click({
    switch ($script:CurrentPage) {
        'input'   { Show-Page 'select' }
        'check'   { if ($script:Target -and $script:Target.Kind -eq 'new') { Show-Page 'input' } else { Show-Page 'select' } }
        'install' { Show-Page 'check' }
    }
})
$script:BtnNext.Add_Click({
    switch ($script:CurrentPage) {
        'select'  { Open-Selection }
        'input'   { Confirm-InputPage }
        'check'   { Start-Install }
        'install' { Start-Install }   # Erneut versuchen - alle Schritte sind wiederholbar
        'finish'  { $script:Form.Close() }
    }
})

# Abbrechen waehrend der Installation: nach dem laufenden Schritt anhalten,
# dann schliessen. Ein laufendes Programm (robocopy, psql ...) wird nicht hart beendet.
$script:Form.Add_FormClosing({
    if ($script:Busy -and -not $script:CloseAfterAbort) {
        if (Show-Confirm 'Es läuft noch ein Schritt. Nach diesem Schritt anhalten und schließen?' 'Abbrechen') {
            $script:AbortRequested = $true
            $script:CloseAfterAbort = $true
            Write-Log 'Abbruch angefordert - halte nach dem laufenden Schritt an.' 'Warn'
        }
        $_.Cancel = $true
        return
    }
    Remove-Staging
})

$script:Form.Controls.Add($content)
$script:Form.Controls.Add($footer)
$script:Form.Controls.Add($statusBar)
$script:Form.Controls.Add($header)

$script:Form.MinimumSize = New-Object System.Drawing.Size(900, 680)
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w  = [math]::Min($script:Form.Width,  [int]($wa.Width  * 0.98))
    $h  = [math]::Min($script:Form.Height, [int]($wa.Height * 0.98))
    if ($w -lt $script:Form.Width -or $h -lt $script:Form.Height) {
        $script:Form.Size = New-Object System.Drawing.Size([math]::Max(900, $w), [math]::Max(680, $h))
    }
} catch { }

# ==============================================================================
# 24) Start
# ==============================================================================

$script:Form.Add_Shown({
    Initialize-SnailDir
    Write-Log "$script:AppTitle $script:AppVersion gestartet." 'Step'
    Write-Log "Protokoll: $script:LogFile"
    Write-Log ("Ausführung: {0}" -f $(if ($script:IsCompiled) { "EXE ($script:SelfPath)" } else { "Skript ($script:SelfPath)" }))
    Write-Log ("WIPP-Schnittstelle: {0}" -f $(if (Test-Path -LiteralPath $script:WippPgJson) { $script:WippDir } else { "nicht gefunden ($script:WippDir) - Suche wie ohne WIPP" }))
    # Reste abgebrochener Laeufe (entpackte ZIPs, pgpass) entfernen
    foreach ($old in @(Get-ChildItem -LiteralPath $script:StagingDir -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    Show-Page 'select'
    Update-ProjectList
    if (-not (Test-Path -LiteralPath $script:JsonPath)) {
        Set-Status 'Kein Katalog (projekte.json) gefunden - mit "Katalog-Vorlage anlegen" starten.'
    }
})

[void]$script:Form.ShowDialog()
$script:Form.Dispose()

} catch {
    $inv  = $_.InvocationInfo
    $text = "Unerwarteter Fehler:`r`n`r`n$($_.Exception.Message)"
    if ($inv -and $inv.ScriptLineNumber) {
        $text += "`r`n`r`nZeile $($inv.ScriptLineNumber): $(([string]$inv.Line).Trim())"
    }
    if ($_.ScriptStackTrace) { $text += "`r`n`r`n$($_.ScriptStackTrace)" }
    try { Write-Log $text 'Error' } catch { }
    [System.Windows.Forms.MessageBox]::Show($text, "$script:AppTitle - Fehler", 'OK', 'Error') | Out-Null
}
