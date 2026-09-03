<#
================================================================================
 Projekt-Installer  -  Version 2.0
================================================================================
 Richtet ein Projekt, das auf der gemeinsamen Projektvorlage (PHP auf IIS +
 MySQL) aufbaut, in einem Durchgang betriebsbereit ein. Weil alle Projekte
 dieselbe Struktur haben, kennt der Installer den Ablauf selbst - in der
 Projektliste stehen nur noch Name, Ordner, Port und Datenbankname:

   1. IIS: eigener Anwendungspool + Website (physischer Pfad = <Projekt>\public),
      anonyme Anmeldung laeuft unter der Pool-Identitaet, und genau diese
      Identitaet bekommt Aenderungsrechte auf <Projekt>\var - sonst nirgends
   2. MySQL: Datenbank und Datenbank-Benutzer anlegen (als root)
   3. .env aus der .env.example erzeugen (APP_KEY, SESSION_NAME, DB-Zugang ...)
   4. php bin\console migrate        - Tabellen ueber die Projekt-Konsole
   5. php bin\console user:create    - erster Administrator, Passwort wird angezeigt
   6. Setup-Skripte des Projekts (Windows-Aufgaben), falls vorhanden
   7. php bin\console check          - Abschlusskontrolle; Exit-Code 1 = fehlgeschlagen
   8. Anwendung im Browser oeffnen  - einen /install- oder /setup-Ordner gibt es
      nicht mehr, die Startseite prueft sich selbst

 Die Projektliste liegt als projekte.json NEBEN dieser Datei (bzw. neben der
 EXE) und wird beim Start gelesen. Neue Projekte = nur JSON ergaenzen, die EXE
 muss nicht neu erzeugt werden. Fehlt die Datei, bietet der Assistent an, eine
 kommentierte Vorlage zu erstellen.

 AUFBAU DER projekte.json
 ------------------------
 {
   "einstellungen": {
     "projektOrdner": "C:\\inetpub",   // Basisordner fuer relative Projektordner
     "mysqlBin":  "",                  // leer = mysql.exe automatisch suchen
     "mysqlPort": 3306,
     "phpExe":    "",                  // leer = php.exe automatisch suchen (s. unten)
     "pythonExe": "",                  // nur fuer Setup-Skripte, die Python brauchen
     "phpModule": ["pdo_mysql", "mbstring", "openssl", "json", "ctype", "fileinfo", "session"]
   },                                  // Basissatz der Vorlage (config/app.php -> requirements)
   "projekte": [
     {
       "name":    "Manfred",            // Anzeigename, IIS-Sitename, Pool-Name, APP_NAME
       "ordner":  "manfred",            // relativ zu projektOrdner oder absoluter Pfad
       "port":    1011,
       "url":     "http://localhost:{port}/",   // optional; wird APP_URL (Standard genau so)
       "datenbank": {                   // optional; Standard: <ordner> und <ordner>_user
         "name":     "manfred",
         "benutzer": "manfred_user"
       },
       "phpModule": ["gd"],             // optional: ZUSAETZLICH zum Basissatz
       "admin": {                       // optional: erster Benutzer (user:create)
         "login": "admin",
         "name":  "Administrator",
         "email": ""                    // fuer Cloudflare-SSO; auch im Assistenten eingebbar
       },
       "skripte": [                     // optional: Windows-Aufgaben einrichten
         {
           "datei":          "setup/aufgabe.ps1",
           "titel":          "Aufgabe einrichten",
           "beschreibung":   "Erklaerung fuer den Anwender",
           "optional":       true,      // false = laeuft immer mit
           "vorausgewaehlt": true,      // nur bei optional=true
           "alsAdmin":       true       // nur dokumentarisch
         }
       ],
       "icon": "iVBORw0KGgo..."         // optional: PNG als Base64
     }
   ]
 }

 Platzhalter in url: {port}, {name}, {ordner}

 Ein Icon als Base64 erzeugt dieser Einzeiler (PNG, ideal 64x64 bis 256x256):
   [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\pfad\logo.png')) | Set-Clipboard

 WAS DIE VORLAGE IM PROJEKTORDNER VORAUSSETZT
   public\index.php, public\web.config, bin\console, .env.example,
   database\migrations\*.sql, var\  (siehe README der Vorlage)

 php.exe
 -------
 Wird in dieser Reihenfolge gesucht: einstellungen.phpExe, die vom PHP+IIS-
 Setup-Assistenten geschriebene Datei C:\ProgramData\PHP-IIS-Setup\php-pfad.txt,
 die in IIS registrierte FastCGI-Anwendung (php-cgi.exe -> php.exe daneben),
 PATH (auch der maschinenweite aus der Registry), C:\Program Files\PHP.

 ROOT-PASSWORT
 -------------
 Wird automatisch aus der vom Setup-Assistenten erzeugten Datei
 C:\ProgramData\PHP-IIS-Setup\mysql-zugangsdaten.txt gelesen (die my.ini
 enthaelt kein Passwort). Ist die Datei geloescht, wird das Passwort im
 Assistenten von Hand eingegeben. Es wird nie auf der Kommandozeile uebergeben,
 sondern ueber eine temporaere defaults-extra-file an mysql.exe gereicht.

 ERZEUGTE ZUGANGSDATEN
 ---------------------
 Datenbank-Passwort und das Initialpasswort des Administrators landen unter
 C:\ProgramData\PHP-IIS-Setup\projekt-zugangsdaten\<ordner>.txt (nur fuer
 Administratoren und SYSTEM lesbar). Bei einer erneuten Installation wird das
 Datenbank-Passwort von dort - bzw. aus einer vorhandenen .env - wieder
 verwendet, damit Datenbank und .env zusammenpassen.

 ALS EXE VERTEILEN (PS2EXE)
 --------------------------
   Install-Module ps2exe -Scope CurrentUser
   Invoke-ps2exe .\Projekt-Installer.ps1 .\Projekt-Installer.exe `
       -noConsole -requireAdmin -STA -x64 -title 'Projekt-Installer' -version '2.0.0.0'
   (oder Build-Projekt-Installer.ps1 verwenden)

 HINWEISE
   - Diese Datei ist UTF-8 mit BOM gespeichert. Kodierung beim Bearbeiten
     beibehalten, sonst gehen die Umlaute kaputt.
   - Getestet fuer Windows PowerShell 5.1 auf Windows Server 2022/2025.
   - Voraussetzung: IIS, PHP (php.exe erreichbar) und MySQL sind bereits
     eingerichtet (z. B. mit dem PHP + IIS Setup-Assistenten).
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
                    throw 'Die EXE wurde ohne den Schalter -STA erzeugt. Bitte mit "Invoke-ps2exe ... -STA -requireAdmin -noConsole" neu erstellen.'
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
                "Der Installer benötigt Administratorrechte und konnte nicht neu gestartet werden.`r`n`r`n" +
                "$($_.Exception.Message)`r`n`r`n" +
                'Bitte per Rechtsklick "Als Administrator ausführen" starten.',
                'Projekt-Installer', 'OK', 'Warning') | Out-Null
        }
        exit
    }
}

# ==============================================================================
#  1) Konstanten und Zustand
# ==============================================================================

$script:AppTitle   = 'Projekt-Installer'
$script:AppVersion = '2.0'

$script:JsonPath   = Join-Path $script:SelfDir 'projekte.json'
$script:BaseDir    = Join-Path $env:SystemDrive 'inetpub'     # Basisordner der Projekte
$script:AppCmd     = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'

# Gemeinsamer Ordner mit dem PHP + IIS Setup-Assistenten
$script:LogDir     = Join-Path $env:ProgramData 'PHP-IIS-Setup'
$script:LogFile    = Join-Path $script:LogDir ('projekt_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
$script:CredFile   = Join-Path $script:LogDir 'mysql-zugangsdaten.txt'
$script:PhpPathFile = Join-Path $script:LogDir 'php-pfad.txt'   # schreibt der Setup-Assistent
# Je Projekt eine Datei mit den erzeugten Zugangsdaten. Wird bei einer
# erneuten Installation wieder gelesen, damit dasselbe Datenbank-Passwort
# vorgeschlagen wird (Projektordner geloescht, Datenbank neu aufgesetzt).
$script:ProjCredDir = Join-Path $script:LogDir 'projekt-zugangsdaten'

# Basissatz der PHP-Module laut Vorlage (config/app.php -> requirements).
# Ueberschreibbar per einstellungen.phpModule, je Projekt erweiterbar.
$script:PhpModulesBase = @('pdo_mysql', 'mbstring', 'openssl', 'json', 'ctype', 'fileinfo', 'session')
$script:PhpMinVersion  = [version]'8.1.0'

$script:MySqlPort  = 3306
$script:MySqlBin   = ''        # aus JSON, sonst automatische Suche
$script:PhpExe     = ''        # aus JSON, sonst automatische Suche (Find-PhpExe)
$script:PythonExe  = ''        # nur fuer Setup-Skripte

$script:Projects   = @()       # normalisierte Projekte aus der JSON
$script:JsonErrors = @()       # Validierungsmeldungen
$script:Sel        = $null     # ausgewähltes Projekt
$script:Busy       = $false
$script:Result     = @{}
$script:AppIcon    = $null
$script:CurrentPage = 'select'

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
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
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
    foreach ($b in @($script:BtnBack, $script:BtnNext, $script:BtnReload, $script:BtnOpenJson)) {
        if ($b) { $b.Enabled = -not $On }
    }
    if ($script:Form) {
        $script:Form.Cursor = if ($On) { [System.Windows.Forms.Cursors]::AppStarting }
                              else      { [System.Windows.Forms.Cursors]::Default }
    }
    Invoke-UiPump
}

<#
 Startet ein Konsolenprogramm ohne sichtbares Fenster und liefert Ausgabe und
 Exitcode. In einer -noConsole-Exe würde bei "& exe" sonst jedes Mal kurz ein
 schwarzes Fenster aufblitzen. -StdIn geht an die Standardeingabe (mysql.exe).
 -Utf8Output liest die Ausgabe als UTF-8 (php.exe gibt Umlaute und
 Gedankenstriche so aus; ohne den Schalter kaeme die OEM-Codepage zum Zug).
#>
function Invoke-ExeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$StdIn = $null,
        [string]$WorkingDirectory = $null,
        [switch]$Utf8Output,
        [int]$TimeoutSec = 600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $FilePath
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = ($null -ne $StdIn)
    if ($ArgumentList.Count -gt 0) { $psi.Arguments = ($ArgumentList -join ' ') }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
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
        if ($null -ne $StdIn) {
            # UTF-8 ohne BOM direkt in den BaseStream schreiben statt ueber den
            # StreamWriter: der kodiert unter Windows PowerShell (.NET Framework)
            # in der ANSI-Codepage, wodurch Umlaute in SQL-Texten als Fragezeichen
            # oder Ersatzzeichen in der Datenbank landen. ProcessStartInfo hat dafuer
            # zwar StandardInputEncoding, das gibt es aber erst ab .NET Core 2.1 -
            # unter 5.1 wuerde schon das Setzen der Eigenschaft eine Ausnahme werfen.
            # Ueber den BaseStream geht es auf beiden Laufzeiten und umgeht jede
            # Umkodierung. mysql.exe bekommt das passende --default-character-set.
            $enc   = New-Object System.Text.UTF8Encoding($false)
            $bytes = $enc.GetBytes($StdIn)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
            $proc.StandardInput.Close()
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
            Lines    = @((($out + "`n" + $err) -split "`r?`n") | Where-Object { $_ -ne '' })
        }
    } finally {
        $proc.Dispose()
    }
}

function Invoke-AppCmd {
    param([Parameter(Mandatory)][string[]]$Arguments)
    # Argumente mit Leerzeichen für die Kommandozeile quoten
    $quoted = foreach ($a in $Arguments) {
        if ($a -match '\s' -and $a -notmatch '^".*"$') { '"' + $a + '"' } else { $a }
    }
    $r = Invoke-ExeCapture -FilePath $script:AppCmd -ArgumentList @($quoted)
    return [pscustomobject]@{ ExitCode = $r.ExitCode; Output = ($r.Lines -join ' '); Lines = $r.Lines }
}

function Open-InBrowser {
    param([Parameter(Mandatory)][string]$Url)
    try {
        Start-Process $Url -ErrorAction Stop
        Write-Log "Browser geöffnet: $Url" 'Ok'
        return $true
    } catch {
        Write-Log 'Kein Standardbrowser registriert - versuche Edge, dann Internet Explorer.' 'Warn'
        foreach ($exe in @('msedge.exe', 'iexplore.exe')) {
            try { Start-Process $exe -ArgumentList $Url -ErrorAction Stop; return $true } catch { }
        }
        Write-Log "Adresse konnte nicht geöffnet werden: $Url" 'Error'
        return $false
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
function Show-Error { param([string]$Text, [string]$Title = 'Fehler')
    [System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'OK', 'Error') | Out-Null }
function Show-Confirm { param([string]$Text, [string]$Title = 'Bestätigen')
    ([System.Windows.Forms.MessageBox]::Show($script:Form, $Text, $Title, 'YesNo', 'Question') -eq 'Yes') }

# Platzhalter {port}, {name}, {ordner} in Texten aus der JSON ersetzen
function Expand-ProjectText {
    param([string]$Text, $Project)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $Text.Replace('{port}',   [string]$Project.Port).
          Replace('{name}',   [string]$Project.Name).
          Replace('{ordner}', [string]$Project.DirName)
}

# Zugriff auf eine Datei oder einen Ordner auf Administratoren und SYSTEM
# beschraenken - fuer alles, was Passwoerter im Klartext enthaelt.
function Protect-AdminOnly {
    param([Parameter(Mandatory)][string]$Path)
    $isDir = (Get-Item -LiteralPath $Path) -is [System.IO.DirectoryInfo]
    $acl = if ($isDir) { New-Object System.Security.AccessControl.DirectorySecurity }
           else        { New-Object System.Security.AccessControl.FileSecurity }
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {   # Administratoren, SYSTEM
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        if ($isDir) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        } else {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'Allow')))
        }
    }
    $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# ==============================================================================
#  3) projekte.json lesen und prüfen
# ==============================================================================

$script:JsonTemplate = @'
{
  "_doku": "Projektliste fuer den Projekt-Installer. Diese Datei liegt neben der EXE und wird beim Start gelesen. Alle Projekte bauen auf der gemeinsamen Projektvorlage auf (public/, bin/console, .env.example, database/migrations) - deshalb stehen hier nur Name, Ordner, Port und Datenbankname; den Ablauf kennt der Installer selbst. Platzhalter in url: {port} {name} {ordner}. datenbank ist optional (Standard: <ordner> / <ordner>_user), das Passwort wird bei der Installation erzeugt. phpModule je Projekt: ZUSAETZLICH zum Basissatz aus einstellungen.phpModule. admin: Login/Anzeigename/E-Mail des ersten Benutzers (Standard admin / Administrator / leer). Icon: PNG als Base64, Einzeiler: [Convert]::ToBase64String([IO.File]::ReadAllBytes('logo.png')) | Set-Clipboard.",

  "_skripteDoku": "Je Eintrag: datei (relativ zum Projektordner), titel (Anzeige), beschreibung (Erklaerung fuer den Anwender), optional (false = laeuft immer, true = Anwender waehlt aus), vorausgewaehlt (nur bei optional=true), alsAdmin (nur dokumentarisch). Der Installer uebergibt -ProjektPfad, -Unbeaufsichtigt sowie -PhpExe/-PythonExe, aber nur die Parameter, die das jeweilige Skript auch deklariert. Rueckgabe: 0 = eingerichtet, 1 = Fehler, 2 = Rechte fehlen, 3 = Projektordner unklar; 3010 und 1641 gelten als Erfolg mit Neustart-Hinweis.",

  "einstellungen": {
    "projektOrdner": "C:\\inetpub",
    "mysqlBin":  "",
    "mysqlPort": 3306,
    "phpExe":    "",
    "pythonExe": "",
    "phpModule": ["pdo_mysql", "mbstring", "openssl", "json", "ctype", "fileinfo", "session"]
  },

  "projekte": [
    {
      "name":    "Manfred",
      "ordner":  "manfred",
      "port":    1011,
      "url":     "http://localhost:{port}/",
      "datenbank": { "name": "manfred", "benutzer": "manfred_user" },
      "phpModule": [],
      "admin":   { "login": "admin", "name": "Administrator", "email": "" },
      "skripte": [],
      "icon": ""
    }
  ]
}
'@

# Namensregeln von MySQL - wie im Setup-Assistenten
function Test-MySqlUserName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name))       { return 'Benutzername darf nicht leer sein.' }
    if ($Name -cmatch '[A-Z]')                     { return "'$Name': Großbuchstaben sind nicht erlaubt." }
    if ($Name.Length -gt 32)                       { return "'$Name': maximal 32 Zeichen." }
    if ($Name -notmatch '^[a-z0-9_][a-z0-9_.-]*$') { return "'$Name': erlaubt sind Kleinbuchstaben, Ziffern, _ . und -, beginnend mit Buchstabe, Ziffer oder _." }
    return $null
}

function Test-MySqlDbName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Datenbankname darf nicht leer sein.' }
    if ($Name -cmatch '[A-Z]')               { return "Datenbank '$Name': Großbuchstaben sind nicht erlaubt." }
    if ($Name.Length -gt 64)                 { return "Datenbank '$Name': maximal 64 Zeichen." }
    if ($Name -notmatch '^[a-z0-9_$-]+$')    { return "Datenbank '$Name': erlaubt sind Kleinbuchstaben, Ziffern, _ - und `$." }
    return $null
}

<#
 Liest projekte.json, prüft die Einträge und liefert normalisierte Projekte:
   Name, Dir (absoluter Projektordner), DirName (letzter Pfadteil), DocRoot
   (= Dir\public), Port, Url, Db (Name/Benutzer), PhpModules (Basissatz +
   Zusatz), Admin (Login/Name/Email), Skripte, Icon (Image oder $null).
 Fehler landen gesammelt in $script:JsonErrors, damit die Startseite alle
 Probleme auf einmal anzeigen kann statt beim ersten abzubrechen.
#>
function Read-ProjectJson {
    $script:Projects   = @()
    $script:JsonErrors = @()

    if (-not (Test-Path -LiteralPath $script:JsonPath)) {
        $script:JsonErrors += "Die Projektliste wurde nicht gefunden: $script:JsonPath"
        return
    }

    try {
        $raw  = Get-Content -LiteralPath $script:JsonPath -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    } catch {
        $script:JsonErrors += "projekte.json ist kein gültiges JSON: $($_.Exception.Message)"
        return
    }

    # Einstellungen
    $modulesBase = $script:PhpModulesBase
    if ($json.einstellungen) {
        $e = $json.einstellungen
        if ($e.projektOrdner) { $script:BaseDir = [string]$e.projektOrdner }
        elseif ($e.wwwroot)   { $script:BaseDir = [string]$e.wwwroot }      # alter Schluesselname
        if ($e.mysqlBin)  { $script:MySqlBin  = [string]$e.mysqlBin }
        if ($e.mysqlPort) { $script:MySqlPort = [int]$e.mysqlPort }
        if ($e.phpExe)    { $script:PhpExe    = [string]$e.phpExe }
        if ($e.pythonExe) { $script:PythonExe = [string]$e.pythonExe }
        if ($null -ne $e.phpModule) { $modulesBase = @($e.phpModule | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) }
    }

    $list  = @($json.projekte)
    if ($list.Count -eq 0) {
        $script:JsonErrors += 'Die Datei enthält keine Projekte (Feld "projekte" fehlt oder ist leer).'
        return
    }

    $seenNames = @{}
    $seenPorts = @{}
    $idx = 0
    $out = New-Object System.Collections.Generic.List[object]

    foreach ($p in $list) {
        $idx++
        $where = "Projekt $idx" + $(if ($p.name) { " ('$($p.name)')" } else { '' })

        $name = ([string]$p.name).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { $script:JsonErrors += "${where}: Feld 'name' fehlt."; continue }
        if ($seenNames.ContainsKey($name.ToLower())) { $script:JsonErrors += "${where}: Der Name '$name' kommt doppelt vor." }
        $seenNames[$name.ToLower()] = $true
        # Der Name wird IIS-Sitename und Pool-Name: Zeichen, die appcmd stoeren, ausschliessen
        if ($name -match '["/\\:*?<>|]') { $script:JsonErrors += "${where}: Der Name darf keines der Zeichen `" / \ : * ? < > | enthalten."; continue }

        $ordner = ([string]$p.ordner).Trim()
        if ([string]::IsNullOrWhiteSpace($ordner)) { $script:JsonErrors += "${where}: Feld 'ordner' fehlt."; continue }
        $dir = if ([System.IO.Path]::IsPathRooted($ordner)) { $ordner } else { Join-Path $script:BaseDir $ordner }
        $dir = $dir.TrimEnd('\')
        $dirName = [System.IO.Path]::GetFileName($dir)

        $port = 0
        try { $port = [int]$p.port } catch { }
        if ($port -lt 1 -or $port -gt 65535) { $script:JsonErrors += "${where}: 'port' fehlt oder ist ungültig (1-65535)."; continue }
        if ($seenPorts.ContainsKey($port)) { $script:JsonErrors += "${where}: Port $port ist bereits Projekt '$($seenPorts[$port])' zugeordnet." }
        else { $seenPorts[$port] = $name }

        $url = if ($p.url) { [string]$p.url } else { 'http://localhost:{port}/' }

        # Datenbank: Standardnamen aus dem Ordnernamen (wie in der .env.example der Vorlage)
        $dbDefault = ($dirName.ToLower() -replace '[^a-z0-9_$-]', '_')
        $dbName = $dbDefault
        $dbUser = "${dbDefault}_user"
        if ($p.datenbank) {
            if ($p.datenbank.name)     { $dbName = ([string]$p.datenbank.name).Trim() }
            if ($p.datenbank.benutzer) { $dbUser = ([string]$p.datenbank.benutzer).Trim() }
        }
        $err = Test-MySqlDbName -Name $dbName
        if ($err) { $script:JsonErrors += "${where}: $err"; continue }
        $err = Test-MySqlUserName -Name $dbUser
        if ($err) { $script:JsonErrors += "${where}: $err"; continue }

        # PHP-Module: Basissatz plus Zusatz des Projekts
        $mods = New-Object System.Collections.Generic.List[string]
        foreach ($m in @($modulesBase) + @($p.phpModule)) {
            $mt = ([string]$m).Trim()
            if ($mt -and -not ($mods -contains $mt)) { $mods.Add($mt) }
        }

        # Erster Benutzer (user:create)
        $admin = [pscustomobject]@{ Login = 'admin'; Name = 'Administrator'; Email = '' }
        if ($p.admin) {
            if ($p.admin.login) { $admin.Login = ([string]$p.admin.login).Trim() }
            if ($p.admin.name)  { $admin.Name  = ([string]$p.admin.name).Trim() }
            if ($p.admin.email) { $admin.Email = ([string]$p.admin.email).Trim() }
        }

        # Icon aus Base64 (PNG/JPG/BMP); Fehler sind kein Abbruchgrund
        $icon = $null
        if ($p.icon -and ([string]$p.icon).Trim().Length -gt 0) {
            try {
                $bytes = [Convert]::FromBase64String((([string]$p.icon) -replace '\s', ''))
                $ms    = New-Object System.IO.MemoryStream(, $bytes)
                $icon  = [System.Drawing.Image]::FromStream($ms)
            } catch {
                $script:JsonErrors += "${where}: Das Icon konnte nicht gelesen werden (Base64/PNG prüfen) - es wird ein Ersatzsymbol angezeigt."
                $icon = $null
            }
        }

        # Setup-Skripte (PowerShell). "optional" entscheidet, ob der Anwender
        # sie abwaehlen kann; "vorausgewaehlt" nur der Anfangszustand des Hakens.
        $skripte = New-Object System.Collections.Generic.List[object]
        foreach ($s in @($p.skripte)) {
            if ($null -eq $s) { continue }
            $sd = [string]$s.datei
            if ([string]::IsNullOrWhiteSpace($sd)) {
                $script:JsonErrors += "${where}: Ein Skript-Eintrag hat kein Feld 'datei'."
                continue
            }
            $abs = if ([System.IO.Path]::IsPathRooted($sd)) { $sd } else { Join-Path $dir $sd }
            $opt = [bool]$s.optional
            $skripte.Add([pscustomobject]@{
                Datei         = $abs
                Anzeige       = $sd
                Titel         = if ($s.titel) { [string]$s.titel } else { [System.IO.Path]::GetFileName($sd) }
                Beschreibung  = [string]$s.beschreibung
                Optional      = $opt
                # Pflichtskripte laufen immer; optionale starten mit dem Wunsch aus der JSON
                Gewaehlt      = if ($opt) { [bool]$s.vorausgewaehlt } else { $true }
            })
        }

        $out.Add([pscustomobject]@{
            Name        = $name
            Dir         = $dir
            DirName     = $dirName
            DocRoot     = (Join-Path $dir 'public')
            Port        = $port
            Url         = $url
            Db          = [pscustomobject]@{ Name = $dbName; Benutzer = $dbUser }
            PhpModules  = $mods.ToArray()
            Admin       = $admin
            Skripte     = $skripte.ToArray()
            Icon        = $icon
        })
    }

    $script:Projects = $out.ToArray()
}

# Ersatzsymbol: farbiges Quadrat mit dem Anfangsbuchstaben des Projekts
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

# ==============================================================================
#  4) Zugangsdaten: Passwoerter erzeugen, ablegen, wiederfinden
# ==============================================================================

<#
 Das Datenbank-Passwort wird bei der Installation erzeugt und in die .env
 geschrieben. Damit Datenbank und .env auch dann zusammenpassen, wenn nur
 eine Seite neu aufgesetzt wird, gilt diese Reihenfolge:
   1. vorhandene .env im Projektordner  -> deren DB_PASS (und DB_NAME/DB_USER)
   2. Ablage aus einer frueheren Installation (projekt-zugangsdaten\<ordner>.txt)
   3. neu erzeugen
 Das Initialpasswort des Administrators kommt von "user:create" und wird
 nur angezeigt und in derselben Ablage vermerkt (Wechsel beim ersten Login).
#>

# Zufallspasswort. Bewusst nur Buchstaben und Ziffern: der Wert landet in
# SQL-Anweisungen und in der .env - Anfuehrungszeichen, # oder Backslashes
# muesste jede Ebene anders maskieren. 24 Stellen aus 62 Zeichen (~143 Bit).
function New-ProjectPassword {
    param([int]$Length = 24)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $bytes = New-Object byte[] $Length
    $rng   = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

# APP_KEY der Vorlage: 32 Zufallsbytes als 64 Hex-Zeichen
function New-AppKey {
    $bytes = New-Object byte[] 32
    $rng   = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-ProjectCredPath {
    param([Parameter(Mandatory)]$Project)
    # Ordnername statt Anzeigename: der ist eindeutig und dateisystemtauglich
    $safe = $Project.DirName -replace '[^\w\.-]', '_'
    Join-Path $script:ProjCredDir ($safe + '.txt')
}

# Liest die Ablage einer frueheren Installation als Schluessel=Wert-Tabelle
function Read-ProjectCredentials {
    param([Parameter(Mandatory)]$Project)
    $file = Get-ProjectCredPath $Project
    $map  = @{}
    if (-not (Test-Path -LiteralPath $file)) { return $map }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)) {
            if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $map[$Matches[1]] = $Matches[2] }
        }
    } catch {
        Write-Log "Zugangsdaten-Ablage nicht lesbar ($($_.Exception.Message))." 'Warn'
    }
    return $map
}

<#
 Schreibt die Zugangsdaten neben das Protokoll (Ordner nur fuer Administratoren
 und SYSTEM lesbar). Fehler hier duerfen die Installation nicht abbrechen -
 dann stehen die Werte eben nur im Fenster.
#>
function Save-ProjectCredentials {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][hashtable]$Values)
    $file = Get-ProjectCredPath $Project
    try {
        if (-not (Test-Path -LiteralPath $script:ProjCredDir)) {
            [void](New-Item -ItemType Directory -Path $script:ProjCredDir -Force)
        }
        try { Protect-AdminOnly -Path $script:ProjCredDir } catch {
            Write-Log "Rechte auf $script:ProjCredDir konnten nicht eingeschränkt werden: $($_.Exception.Message)" 'Warn'
        }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('# Vom Projekt-Installer erzeugt - bitte nicht von Hand umbenennen.')
        [void]$sb.AppendLine('# Bei einer erneuten Installation wird "passwort" (Datenbank) von hier gelesen.')
        [void]$sb.AppendLine('# Das Admin-Initialpasswort gilt nur bis zum ersten Login (Wechsel erzwungen).')
        [void]$sb.AppendLine(('# Stand: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)))
        [void]$sb.AppendLine(('projekt=' + $Project.Name))
        [void]$sb.AppendLine(('ordner='  + $Project.Dir))
        [void]$sb.AppendLine(('url='     + $Values['url']))
        [void]$sb.AppendLine(('datenbank=' + $Values['datenbank']))
        [void]$sb.AppendLine(('benutzer='  + $Values['benutzer']))
        [void]$sb.AppendLine(('passwort='  + $Values['passwort']))
        if ($Values['admin_login']) {
            [void]$sb.AppendLine(('admin_login=' + $Values['admin_login']))
            if ($Values['admin_initialpasswort']) {
                [void]$sb.AppendLine(('admin_initialpasswort=' + $Values['admin_initialpasswort']))
            } else {
                [void]$sb.AppendLine('# admin_initialpasswort: Benutzer existierte bereits, Passwort unveraendert')
            }
        }
        [System.IO.File]::WriteAllText($file, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "Zugangsdaten abgelegt: $file" 'Ok'
    } catch {
        Write-Log "Zugangsdaten konnten nicht abgelegt werden ($file): $($_.Exception.Message)" 'Warn'
    }
    return $file
}

# ==============================================================================
#  5) .env der Vorlage lesen und schreiben
# ==============================================================================

<#
 Liest eine .env wie Env::parseFile() der Vorlage: #-Zeilen ueberspringen,
 KEY=WERT, Werte in ' oder ", Inline-Kommentar hinter " #" abschneiden.
#>
function Read-EnvFile {
    param([Parameter(Mandatory)][string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($raw in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        $pos = $line.IndexOf('=')
        if ($pos -lt 1) { continue }
        $key = $line.Substring(0, $pos).TrimEnd()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        $val = $line.Substring($pos + 1).TrimStart()
        if ($val -ne '' -and $val[0] -eq '#') { $val = '' }
        elseif ($val -ne '' -and ($val[0] -eq '"' -or $val[0] -eq "'")) {
            $q = $val[0]; $end = $val.IndexOf($q, 1)
            $val = if ($end -lt 0) { $val.Substring(1) } else { $val.Substring(1, $end - 1) }
        } elseif ($val -ne '') {
            $hash = $val.IndexOf(' #')
            if ($hash -ge 0) { $val = $val.Substring(0, $hash) }
            $val = $val.Trim()
        }
        $map[$key] = $val
    }
    return $map
}

# Wert fuer eine .env-Zeile formatieren: Text mit Leerzeichen oder
# Sonderzeichen in doppelte Anfuehrungszeichen (Env::parseFile liest bis zum
# naechsten "), alles andere nackt.
function Format-EnvValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $v = $Value.Replace('"', '')
    if ($v -match '[^A-Za-z0-9_.:/\\@+=-]') { return '"' + $v + '"' }
    return $v
}

<#
 Erzeugt die .env aus der .env.example der Vorlage. Jede Zeile der Vorlage
 bleibt erhalten (Kommentare, Reihenfolge, Erklaerungen); nur die Werte der
 uebergebenen Schluessel werden eingesetzt - ein Inline-Kommentar der Vorlage
 bleibt hinter dem Wert stehen. Schluessel, die in der Vorlage fehlen, werden
 angehaengt. Eine vorhandene .env wird NIE ueberschrieben.
#>
function Write-ProjectEnv {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)][hashtable]$Values)
    $target  = Join-Path $Project.Dir '.env'
    $example = Join-Path $Project.Dir '.env.example'
    if (Test-Path -LiteralPath $target) { throw ".env existiert bereits: $target" }
    if (-not (Test-Path -LiteralPath $example)) { throw ".env.example nicht gefunden: $example" }

    $todo  = @{}
    foreach ($k in $Values.Keys) { $todo[$k] = $true }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($raw in [System.IO.File]::ReadAllLines($example, [System.Text.Encoding]::UTF8)) {
        $m = [regex]::Match($raw, '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
        if (-not $m.Success -or -not $Values.ContainsKey($m.Groups[1].Value)) { $lines.Add($raw); continue }
        $key  = $m.Groups[1].Value
        $rest = $m.Groups[2].Value
        # Inline-Kommentar der Vorlage retten (hinter einem nackten Wert: " #",
        # hinter einem leeren Wert: direkt "#")
        $comment = ''
        $cm = [regex]::Match($rest, '^(?:"[^"]*"|''[^'']*''|[^#]*?)\s*(#.*)$')
        if ($cm.Success) { $comment = $cm.Groups[1].Value }
        $newLine = $key + '=' + (Format-EnvValue $Values[$key])
        if ($comment) { $newLine = $newLine.PadRight(30) + ' ' + $comment }
        $lines.Add($newLine)
        $todo.Remove($key)
    }
    if ($todo.Count -gt 0) {
        $lines.Add('')
        $lines.Add('# Vom Projekt-Installer ergaenzt (in der .env.example nicht vorhanden):')
        foreach ($k in ($todo.Keys | Sort-Object)) { $lines.Add($k + '=' + (Format-EnvValue $Values[$k])) }
    }
    $text = ($lines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $target
}

# ==============================================================================
#  6) IIS: Anwendungspool, Website, Schreibrechte
# ==============================================================================

<#
 Liest die vorhandenen Websites über "appcmd list site".
 Ausgabezeilen sehen so aus:
   SITE "Default Web Site" (id:1,bindings:http/*:80:,state:Started)
#>
function Get-IisSites {
    if (-not (Test-Path $script:AppCmd)) { return @() }
    $r = Invoke-ExeCapture -FilePath $script:AppCmd -ArgumentList @('list', 'site')
    $sites = New-Object System.Collections.Generic.List[object]
    foreach ($line in $r.Lines) {
        if ($line -match '^SITE\s+"(.*)"\s+\(id:(\d+),bindings:(.*),state:([^,)]*)\)') {
            $sites.Add([pscustomobject]@{
                Name     = $Matches[1]
                Id       = [int]$Matches[2]
                Bindings = $Matches[3]
                State    = $Matches[4]
            })
        }
    }
    return $sites.ToArray()
}

function Test-AppPoolExists {
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-AppCmd @('list', 'apppool', "/name:$Name")
    return (@($r.Lines | Where-Object { $_ -match '^APPPOOL\s+"' }).Count -gt 0)
}

# Prüft, ob ein TCP-Port bereits von irgendeinem Prozess belegt ist
function Test-TcpPortInUse {
    param([Parameter(Mandatory)][int]$Port)
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($l in $listeners) { if ($l.Port -eq $Port) { return $true } }
    } catch { }
    return $false
}

<#
 Legt Anwendungspool und Website an. Pool und Site heissen wie das Projekt.
   - Pool ohne .NET-Laufzeit ("Kein verwalteter Code") - PHP laeuft ueber den
     globalen FastCGI-Handler
   - Website: physischer Pfad = <Projekt>\public, Bindung http/*:PORT:
     (IP "Keine zugewiesen", Hostname leer), Anwendungspool = Projektpool
   - Anonyme Anmeldung auf die Pool-Identitaet umstellen (userName leer):
     mit fastcgi.impersonate = 1 arbeitet PHP dann als "IIS AppPool\<Name>" -
     genau das Konto, das anschliessend die Rechte auf var\ bekommt. Der
     Abschnitt ist in IIS gesperrt, deshalb /commit:apphost (Location-Tag in
     der applicationHost.config statt web.config).
#>
function New-ProjectSite {
    param($Project, [bool]$ReplaceExisting)
    $name = $Project.Name

    if (-not (Test-Path -LiteralPath $Project.DocRoot)) {
        throw "Der Website-Pfad existiert nicht: $($Project.DocRoot)"
    }

    if (Test-AppPoolExists -Name $name) {
        Write-Log "Anwendungspool '$name' existiert bereits - wird weiterverwendet." 'Info'
    } else {
        $r = Invoke-AppCmd @('add', 'apppool', "/name:$name", '/managedRuntimeVersion:""', '/enable32BitAppOnWin64:false')
        if ($r.ExitCode -ne 0) { throw "appcmd add apppool fehlgeschlagen: $($r.Output)" }
        Write-Log "Anwendungspool '$name' angelegt (kein verwalteter Code, Identität ApplicationPoolIdentity)." 'Ok'
    }

    $existing = @(Get-IisSites | Where-Object { $_.Name -eq $name })
    $create = $true
    if ($existing.Count -gt 0) {
        # Sonderfall "Erneut versuchen": Die Website stammt aus einem früheren
        # Durchlauf mit demselben Port - dann weiterverwenden statt abbrechen.
        if (-not $ReplaceExisting -and $existing[0].Bindings -like "*:$($Project.Port):*") {
            Write-Log "Website '$name' existiert bereits mit Port $($Project.Port) - wird weiterverwendet." 'Info'
            $create = $false
        } elseif (-not $ReplaceExisting) {
            throw "Eine Website mit dem Namen '$name' existiert bereits (anderer Port). Auf der Seite 'Prüfen' das Ersetzen erlauben oder die Website vorher im IIS-Manager entfernen."
        } else {
            Write-Log "Vorhandene Website '$name' wird entfernt ..." 'Info'
            $r = Invoke-AppCmd @('delete', 'site', "/site.name:$name")
            if ($r.ExitCode -ne 0) { throw "Vorhandene Website konnte nicht entfernt werden: $($r.Output)" }
            Write-Log 'Alte Website entfernt (der Projektordner bleibt unberührt).' 'Ok'
        }
    }

    if ($create) {
        Write-Log ("Lege Website an: {0}  ->  {1}  (Port {2})" -f $name, $Project.DocRoot, $Project.Port) 'Info'
        $r = Invoke-AppCmd @('add', 'site',
            "/name:$name",
            "/physicalPath:$($Project.DocRoot)",
            "/bindings:http/*:$($Project.Port):")
        if ($r.ExitCode -ne 0) { throw "appcmd add site fehlgeschlagen: $($r.Output)" }
        Write-Log 'Website angelegt.' 'Ok'
    }

    # Pool zuweisen und physischen Pfad nachziehen (bei Weiterverwendung koennte
    # die Site noch auf den Projektordner statt auf public\ zeigen)
    $r = Invoke-AppCmd @('set', 'app', "$name/", "/applicationPool:$name")
    if ($r.ExitCode -ne 0) { throw "Anwendungspool konnte nicht zugewiesen werden: $($r.Output)" }
    $r = Invoke-AppCmd @('set', 'vdir', "$name/", "/physicalPath:$($Project.DocRoot)")
    if ($r.ExitCode -ne 0) { throw "Physischer Pfad konnte nicht gesetzt werden: $($r.Output)" }
    Write-Log "Website nutzt Anwendungspool '$name', physischer Pfad $($Project.DocRoot)." 'Ok'

    $r = Invoke-AppCmd @('set', 'config', $name,
        '-section:system.webServer/security/authentication/anonymousAuthentication',
        '/enabled:true', '/userName:""', '/commit:apphost')
    if ($r.ExitCode -ne 0) { throw "Anonyme Anmeldung konnte nicht auf die Pool-Identität gestellt werden: $($r.Output)" }
    Write-Log 'Anonyme Anmeldung läuft unter der Pool-Identität (PHP schreibt als IIS AppPool\' + $name + ').' 'Ok'

    # "Website sofort starten": neu angelegte Sites starten normalerweise von
    # selbst; falls nicht (z. B. Portkonflikt), liefert der Start die Ursache.
    $r = Invoke-AppCmd @('start', 'site', "/site.name:$name")
    if ($r.ExitCode -eq 0) {
        Write-Log 'Website gestartet.' 'Ok'
    } else {
        $state = @(Get-IisSites | Where-Object { $_.Name -eq $name })
        if ($state.Count -gt 0 -and $state[0].State -eq 'Started') {
            Write-Log 'Website läuft bereits.' 'Ok'
        } else {
            throw "Die Website wurde angelegt, konnte aber nicht gestartet werden: $($r.Output)"
        }
    }
}

<#
 Schreibrechte: die Pool-Identitaet "IIS AppPool\<Name>" bekommt
   - Lesen/Ausfuehren auf den Projektordner (PHP muss src/, config/, .env,
     vendor/ lesen; die IIS-Site liefert nur public/ aus)
   - Aendern auf var\ (Cache, Logs) - und bewusst nirgendwo sonst.
 Ein zusaetzliches Recht fuer IUSR ist nicht noetig, weil die anonyme
 Anmeldung der Site auf die Pool-Identitaet zeigt (New-ProjectSite).
#>
function Set-ProjectPermissions {
    param([Parameter(Mandatory)]$Project)
    $account = "IIS AppPool\$($Project.Name)"
    try {
        $id = (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier])
    } catch {
        throw "Das Konto '$account' konnte nicht aufgelöst werden ($($_.Exception.Message)). Existiert der Anwendungspool?"
    }
    $inherit = ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
                [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)

    $var = Join-Path $Project.Dir 'var'
    if (-not (Test-Path -LiteralPath $var)) {
        New-Item -ItemType Directory -Path $var -Force | Out-Null
        Write-Log "Ordner angelegt: $var" 'Ok'
    }

    foreach ($e in @(
        @{ Path = $Project.Dir; Rights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute; Text = 'Lesen/Ausführen' },
        @{ Path = $var;         Rights = [System.Security.AccessControl.FileSystemRights]::Modify;         Text = 'Ändern' }
    )) {
        $acl = Get-Acl -LiteralPath $e.Path
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $id, $e.Rights, $inherit, [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)))
        Set-Acl -LiteralPath $e.Path -AclObject $acl
        Write-Log ("Recht '{0}' für {1} auf {2}" -f $e.Text, $account, $e.Path) 'Ok'
    }

    # Nachkontrolle: wer darf laut Ordner in var\ schreiben?
    $eff = (Get-Acl -LiteralPath $var).Access |
           Where-Object { "$($_.FileSystemRights)" -match 'Modify|FullControl|Write' } |
           ForEach-Object { [string]$_.IdentityReference } | Sort-Object -Unique
    Write-Log ("Schreibberechtigt auf var\: {0}" -f ($eff -join ', '))
}

# ==============================================================================
#  7) MySQL: mysql.exe finden, root-Passwort lesen, Datenbank anlegen
# ==============================================================================

function Find-MySqlExe {
    # 1) Vorgabe aus der JSON
    if ($script:MySqlBin -and (Test-Path -LiteralPath $script:MySqlBin)) { return $script:MySqlBin }
    # 2) PATH
    $cmd = Get-Command mysql.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 3) übliche Installationsorte, neueste Version zuerst
    try {
        $pf = [Environment]::GetFolderPath('ProgramFiles')
        if ($pf) {
            $candidates = @(Get-ChildItem -Path (Join-Path $pf 'MySQL') -Directory -ErrorAction SilentlyContinue |
                            Sort-Object Name -Descending)
            foreach ($d in $candidates) {
                $exe = Join-Path $d.FullName 'bin\mysql.exe'
                if (Test-Path -LiteralPath $exe) { return $exe }
            }
        }
    } catch { }
    return $null
}

<#
 Liest das root-Passwort aus der Zugangsdaten-Datei des Setup-Assistenten.
 Aufbau dort: "Benutzer    : root  (...)" gefolgt von "Passwort    : xyz".
 Wichtig: Nur die Passwort-Zeile nehmen, die zum root-Benutzer gehört -
 unter "--- Weitere Benutzer ---" stehen weitere Paare.
 (Die my.ini enthält kein root-Passwort, daraus lässt sich nichts lesen.)
#>
function Get-SavedRootPassword {
    if (-not (Test-Path -LiteralPath $script:CredFile)) { return $null }
    try {
        $lastUser = ''
        foreach ($line in (Get-Content -LiteralPath $script:CredFile -Encoding UTF8)) {
            if ($line -match '^\s*Benutzer\s*:\s*(\S+)') { $lastUser = $Matches[1]; continue }
            if ($line -match '^\s*Passwort\s*:\s*(.+?)\s*$' -and $lastUser -eq 'root') { return $Matches[1] }
        }
    } catch { }
    return $null
}

<#
 Führt SQL-Text als root aus. Das Passwort geht über eine temporäre
 defaults-extra-file an mysql.exe - nie über die Kommandozeile, die jeder
 in der Prozessliste mitlesen könnte. Die Datei wird sofort danach gelöscht.
#>
function Invoke-MySql {
    param(
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Sql,
        [string]$Database = $null,
        [int]$TimeoutSec = 300
    )
    $exe = Find-MySqlExe
    if (-not $exe) { throw 'mysql.exe wurde nicht gefunden. Pfad in projekte.json unter "einstellungen.mysqlBin" angeben.' }

    $cnf = Join-Path $env:TEMP ("projinst_{0}.cnf" -f ([guid]::NewGuid().ToString('N')))
    # Passwort in doppelte Anführungszeichen, damit Sonderzeichen (#, ;) nicht
    # als Kommentar interpretiert werden; " und \ maskieren.
    $pwEsc = $Password.Replace('\', '\\').Replace('"', '\"')
    $cnfText = "[client]`nuser=root`npassword=`"$pwEsc`"`nhost=127.0.0.1`nport=$script:MySqlPort`n"
    [System.IO.File]::WriteAllText($cnf, $cnfText, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $cmdArgs = @("--defaults-extra-file=`"$cnf`"", '--default-character-set=utf8mb4', '--batch')
        if ($Database) { $cmdArgs += "--database=`"$Database`"" }
        return Invoke-ExeCapture -FilePath $exe -ArgumentList $cmdArgs -StdIn $Sql -TimeoutSec $TimeoutSec
    } finally {
        Remove-Item -LiteralPath $cnf -Force -ErrorAction SilentlyContinue
    }
}

function Test-MySqlRoot {
    param([Parameter(Mandatory)][string]$Password)
    $r = Invoke-MySql -Password $Password -Sql 'SELECT VERSION();' -TimeoutSec 30
    if ($r.ExitCode -eq 0) {
        $ver = ($r.Output -split "`r?`n" | Where-Object { $_ -match '^\d' } | Select-Object -First 1)
        return [pscustomobject]@{ Ok = $true; Version = $ver; Message = "Verbindung ok, MySQL $ver" }
    }
    return [pscustomobject]@{ Ok = $false; Version = $null; Message = ($r.Error.Trim() -split "`r?`n" | Select-Object -First 1) }
}

<#
 Legt Datenbank und Benutzer an - dieselben Anweisungen wie in der
 Installationsanleitung der Vorlage (reference/03-installation-betrieb.md).
 Wiederholbar: IF NOT EXISTS, und ALTER USER setzt das Passwort auch dann,
 wenn der Benutzer schon existierte - so passt er garantiert zur .env.
 Der Benutzer gilt fuer 'localhost': Web- und Datenbankserver sind hier
 dieselbe Maschine, die .env verbindet ueber 127.0.0.1.
 Die Tabellen legt anschliessend "php bin\console migrate" an - NICHT der
 Installer, damit die Buchfuehrung in schema_migrations stimmt.
#>
function New-ProjectDatabase {
    param(
        [Parameter(Mandatory)][string]$RootPassword,
        [Parameter(Mandatory)][string]$DbName,
        [Parameter(Mandatory)][string]$DbUser,
        [Parameter(Mandatory)][string]$DbPass
    )
    $err = Test-MySqlDbName -Name $DbName;   if ($err) { throw $err }
    $err = Test-MySqlUserName -Name $DbUser; if ($err) { throw $err }
    if ($DbPass -notmatch '^[A-Za-z0-9]+$') { throw 'Das Datenbank-Passwort enthält Zeichen, die hier nicht erlaubt sind (nur Buchstaben und Ziffern).' }

    $sql = @"
CREATE DATABASE IF NOT EXISTS ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$DbPass';
ALTER USER '$DbUser'@'localhost' IDENTIFIED WITH caching_sha2_password BY '$DbPass';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost';
FLUSH PRIVILEGES;
"@
    Write-Log ("Datenbank '{0}' und Benutzer '{1}'@'localhost' anlegen ..." -f $DbName, $DbUser) 'Info'
    $r = Invoke-MySql -Password $RootPassword -Sql $sql
    if ($r.ExitCode -ne 0) {
        $e = ($r.Error.Trim() -split "`r?`n" | Select-Object -First 3) -join ' | '
        throw "Datenbank/Benutzer konnten nicht angelegt werden: $e"
    }
    # mysql schreibt Warnungen nach stderr, auch bei Exitcode 0
    if ($r.Error.Trim().Length -gt 0) {
        foreach ($w in ($r.Error.Trim() -split "`r?`n" | Select-Object -First 5)) { Write-Log $w 'Warn' }
    }
    Write-Log ("Datenbank '{0}' vorhanden, Benutzer '{1}' hat Vollzugriff." -f $DbName, $DbUser) 'Ok'
}

# ==============================================================================
#  8) PHP: php.exe finden, Module pruefen, Projekt-Konsole aufrufen
# ==============================================================================

<#
 Sucht php.exe - in dieser Reihenfolge:
   1. einstellungen.phpExe aus der JSON (Datei oder PHP-Ordner)
   2. php-pfad.txt des PHP+IIS-Setup-Assistenten (C:\ProgramData\PHP-IIS-Setup)
   3. die in IIS registrierte FastCGI-Anwendung (php-cgi.exe -> php.exe daneben):
      das ist per Definition das PHP, mit dem die Websites laufen
   4. PATH des Prozesses, dann der maschinenweite PATH aus der Registry
      (der Installer koennte vor einer PATH-Aenderung gestartet worden sein)
   5. C:\Program Files\PHP (Standardordner des Setup-Assistenten)
#>
function Find-PhpExe {
    $cands = New-Object System.Collections.Generic.List[string]
    $addDirOrFile = {
        param([string]$p)
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        $p = $p.Trim().Trim('"')
        if ($p -match '\.exe$') { $cands.Add($p) } else { $cands.Add((Join-Path $p 'php.exe')) }
    }
    & $addDirOrFile $script:PhpExe
    if (Test-Path -LiteralPath $script:PhpPathFile) {
        try {
            foreach ($l in [System.IO.File]::ReadAllLines($script:PhpPathFile)) {
                if ($l.Trim() -and -not $l.Trim().StartsWith('#')) { & $addDirOrFile $l; break }
            }
        } catch { }
    }
    if (Test-Path $script:AppCmd) {
        try {
            $r = Invoke-ExeCapture -FilePath $script:AppCmd -ArgumentList @('list', 'config', '-section:system.webServer/fastCgi') -TimeoutSec 30
            foreach ($m in [regex]::Matches($r.Output, 'fullPath="([^"]+?php-cgi\.exe)"', 'IgnoreCase')) {
                $cands.Add((Join-Path (Split-Path -Parent $m.Groups[1].Value) 'php.exe'))
            }
        } catch { }
    }
    $cmd = Get-Command php.exe -ErrorAction SilentlyContinue
    if ($cmd) { $cands.Add($cmd.Source) }
    try {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        foreach ($d in ($machinePath -split ';')) { if ($d.Trim()) { $cands.Add((Join-Path $d.Trim() 'php.exe')) } }
    } catch { }
    $cands.Add((Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'PHP\php.exe'))

    foreach ($c in $cands) {
        try { if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path } } catch { }
    }
    return $null
}

# Version und geladene Module von php.exe ("php -v", "php -m")
function Get-PhpInfo {
    param([Parameter(Mandatory)][string]$Exe)
    $v = Invoke-ExeCapture -FilePath $Exe -ArgumentList @('-v') -TimeoutSec 60
    $first = ($v.Lines | Select-Object -First 1)
    $version = $null
    if ($first -match 'PHP (\d+\.\d+\.\d+)') { $version = [version]$Matches[1] }
    $m = Invoke-ExeCapture -FilePath $Exe -ArgumentList @('-m') -TimeoutSec 60
    $mods = @($m.Lines | Where-Object { $_ -match '^\w' -and $_ -notmatch '^\[' } | ForEach-Object { $_.Trim().ToLower() })
    $loadErrors = @($m.Lines | Where-Object { $_ -match 'Warning|Unable to load|Fatal' })
    [pscustomobject]@{ Version = $version; VersionText = $first; Modules = $mods; LoadErrors = $loadErrors }
}

<#
 Ruft "php bin\console <Befehl>" im Projektordner auf und schreibt die Ausgabe
 ins Protokoll. Liefert ExitCode und Zeilen. Die Konsole der Vorlage meldet
 Erfolg mit 0 und Fehler mit 1 (Text auf stderr).
#>
function Invoke-Console {
    param(
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSec = 600
    )
    $php = Find-PhpExe
    if (-not $php) { throw 'php.exe wurde nicht gefunden (einstellungen.phpExe in der projekte.json setzen).' }
    $console = Join-Path $Project.Dir 'bin\console'
    if (-not (Test-Path -LiteralPath $console)) { throw "Projekt-Konsole nicht gefunden: $console" }

    $quoted = foreach ($a in @($console) + $Arguments) {
        if ($a -match '\s|^$' -and $a -notmatch '^".*"$') { '"' + $a + '"' } else { $a }
    }
    Write-Log ("php bin\console {0}" -f ($Arguments -join ' ')) 'Info'
    $r = Invoke-ExeCapture -FilePath $php -ArgumentList @($quoted) -WorkingDirectory $Project.Dir -Utf8Output -TimeoutSec $TimeoutSec
    foreach ($l in $r.Lines) { Write-Log ('  ' + $l) $(if ($r.ExitCode -eq 0) { 'Info' } else { 'Warn' }) }
    Write-Log ("Exit-Code {0}" -f $r.ExitCode) $(if ($r.ExitCode -eq 0) { 'Ok' } else { 'Error' })
    return $r
}

# "migrate": Tabellen anlegen bzw. offene Migrationen nachziehen
function Invoke-ConsoleMigrate {
    param([Parameter(Mandatory)]$Project)
    $r = Invoke-Console -Project $Project -Arguments @('migrate')
    if ($r.ExitCode -ne 0) {
        $e = ($r.Lines | Select-Object -Last 1)
        throw "Migrationen fehlgeschlagen (php bin\console migrate): $e"
    }
    $count = @($r.Lines | Where-Object { $_ -match '^\s*\[OK\]' }).Count
    return [pscustomobject]@{ Count = $count; UpToDate = ($r.Lines -join ' ') -match 'Keine offenen Migrationen' }
}

<#
 "user:create": ersten Administrator anlegen. Die Konsole gibt das erzeugte
 Initialpasswort aus ("Initiales Passwort: ..."); beim ersten Login muss es
 gewechselt werden. Existiert der Benutzer schon (erneute Installation), ist
 das kein Fehler - das Passwort bleibt dann unveraendert.
#>
function Invoke-ConsoleUserCreate {
    param([Parameter(Mandatory)]$Project, [string]$Email = '')
    $a = $Project.Admin
    $cmdArgs = @('user:create', $a.Login, $a.Name, 'admin')
    if ($Email) { $cmdArgs += $Email }
    $r = Invoke-Console -Project $Project -Arguments $cmdArgs -TimeoutSec 120
    $all = $r.Lines -join "`n"
    if ($r.ExitCode -eq 0) {
        $pw = $null
        if ($all -match 'Initiales Passwort:\s*(\S+)') { $pw = $Matches[1] }
        if (-not $pw) { throw 'user:create meldet Erfolg, aber kein Initialpasswort in der Ausgabe - bitte Protokoll prüfen.' }
        return [pscustomobject]@{ Ok = $true; Existed = $false; Passwort = $pw; Text = "Benutzer '$($a.Login)' angelegt" }
    }
    if ($all -match 'existiert bereits') {
        Write-Log "Benutzer '$($a.Login)' existiert bereits - Passwort bleibt unverändert (Notfall: php bin\console user:password $($a.Login))." 'Info'
        return [pscustomobject]@{ Ok = $true; Existed = $true; Passwort = $null; Text = "Benutzer '$($a.Login)' war bereits vorhanden" }
    }
    throw "Administrator konnte nicht angelegt werden (php bin\console user:create): $($r.Lines | Select-Object -Last 1)"
}

<#
 "check": komplette Systempruefung der Anwendung (Module, Schreibrechte,
 .env, DB-Verbindung, Migrationsstand, Benutzer). Exit-Code 0 = keine Fehler
 (Warnungen erlaubt), 1 = mindestens ein Fehler. Ausgabezeilen:
   [OK     ] PHP-Modul: pdo_mysql
   [WARNUNG] Konfiguration vollständig
             In der .env fehlen: ...            <- Hinweis, eingerueckt
#>
function Invoke-ConsoleCheck {
    param([Parameter(Mandatory)]$Project)
    $r = Invoke-Console -Project $Project -Arguments @('check') -TimeoutSec 120
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($l in $r.Lines) {
        if ($l -match '^\[(OK|WARNUNG|FEHLER)\s*\]\s*(.*)$') {
            $items.Add([pscustomobject]@{ Status = $Matches[1]; Label = $Matches[2].Trim(); Hint = '' })
        } elseif ($l -match '^\s{6,}(\S.*)$' -and $items.Count -gt 0) {
            $last = $items[$items.Count - 1]
            $last.Hint = ($last.Hint + ' ' + $Matches[1].Trim()).Trim()
        }
    }
    [pscustomobject]@{
        Ok       = ($r.ExitCode -eq 0)
        ExitCode = $r.ExitCode
        Items    = $items.ToArray()
        Summary  = ($r.Lines | Where-Object { $_ -match '^Ergebnis:' } | Select-Object -Last 1)
    }
}

# ==============================================================================
#  9) Prüfung des ausgewählten Projekts (Seite 2)
# ==============================================================================

<#
 Liefert eine Liste von Prüfpunkten (Level Ok/Warn/Error, Name, Text) für das
 ausgewählte Projekt. Fehler blockieren die Installation. Geprueft wird alles,
 was die Vorlage voraussetzt - so scheitert eine Installation an einem
 fehlenden PHP-Modul, BEVOR Website und Datenbank angelegt sind.
#>
function Test-Project {
    param($Project)
    $items = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Level, $Name, $Text)
        $items.Add([pscustomobject]@{ Level = $Level; Name = $Name; Text = $Text })
        Write-Log ("{0,-14}: {1}" -f $Name, $Text) $Level
    }

    Write-Log ("Prüfung für Projekt '{0}'" -f $Project.Name) 'Step'

    if (-not (Test-Path $script:AppCmd)) {
        & $add 'Error' 'IIS' 'appcmd.exe fehlt - IIS ist auf diesem Server nicht installiert.'
    } else {
        & $add 'Ok' 'IIS' 'appcmd.exe gefunden.'
    }

    # --- Projektordner und Pflichtdateien der Vorlage --------------------------
    if (Test-Path -LiteralPath $Project.Dir) {
        & $add 'Ok' 'Projektordner' $Project.Dir
        foreach ($f in @('public\index.php', 'public\web.config', 'bin\console', '.env.example')) {
            if (Test-Path -LiteralPath (Join-Path $Project.Dir $f)) { & $add 'Ok' 'Vorlage' "$f vorhanden" }
            else { & $add 'Error' 'Vorlage' "$f fehlt - der Projektordner entspricht nicht der Projektvorlage." }
        }
        $mig = Join-Path $Project.Dir 'database\migrations'
        $migCount = if (Test-Path -LiteralPath $mig) { @(Get-ChildItem -LiteralPath $mig -Filter '*.sql' -File -ErrorAction SilentlyContinue).Count } else { 0 }
        if ($migCount -gt 0) { & $add 'Ok' 'Migrationen' "$migCount Datei(en) in database\migrations" }
        else { & $add 'Error' 'Migrationen' 'database\migrations enthält keine .sql-Dateien.' }

        $envFile = Join-Path $Project.Dir '.env'
        if (Test-Path -LiteralPath $envFile) {
            $envMap = Read-EnvFile $envFile
            if ($envMap['DB_NAME'] -and $envMap['DB_USER'] -and $envMap['DB_PASS']) {
                & $add 'Ok' '.env' "vorhanden - wird übernommen (DB $($envMap['DB_NAME']), Benutzer $($envMap['DB_USER']))"
            } else {
                & $add 'Error' '.env' 'vorhanden, aber ohne vollständige DB_NAME/DB_USER/DB_PASS - Datei ergänzen oder löschen (wird dann neu erzeugt).'
            }
        } else {
            & $add 'Ok' '.env' "wird aus .env.example erzeugt (DB $($Project.Db.Name), Benutzer $($Project.Db.Benutzer))"
        }
    } else {
        & $add 'Error' 'Projektordner' "$($Project.Dir) existiert nicht."
    }

    # --- Port ------------------------------------------------------------------
    $sites    = @(Get-IisSites)
    $sameName = @($sites | Where-Object { $_.Name -eq $Project.Name })
    $portTag  = ":$($Project.Port):"
    $portSite = @($sites | Where-Object { $_.Bindings -like "*$portTag*" })
    if ($sameName.Count -gt 0) {
        & $add 'Warn' 'Website' "'$($Project.Name)' existiert bereits (Status $($sameName[0].State)) - unten das Ersetzen erlauben."
    }
    $foreign = @($portSite | Where-Object { $_.Name -ne $Project.Name })
    if ($foreign.Count -gt 0) {
        & $add 'Error' 'Port' "Port $($Project.Port) wird schon von Website '$($foreign[0].Name)' benutzt."
    } elseif ($sameName.Count -eq 0 -and (Test-TcpPortInUse -Port $Project.Port)) {
        & $add 'Warn' 'Port' "Port $($Project.Port) ist derzeit von einem anderen Programm belegt - der Start der Website kann fehlschlagen."
    } else {
        & $add 'Ok' 'Port' "$($Project.Port) ist frei."
    }

    # --- PHP: php.exe, Version, Module ------------------------------------------
    $php = Find-PhpExe
    if (-not $php) {
        & $add 'Error' 'php.exe' 'nicht gefunden - Pfad in projekte.json unter einstellungen.phpExe eintragen (oder PHP in den PATH aufnehmen).'
    } else {
        try {
            $info = Get-PhpInfo -Exe $php
            if ($info.Version -and $info.Version -ge $script:PhpMinVersion) {
                & $add 'Ok' 'php.exe' "$php (PHP $($info.Version))"
            } elseif ($info.Version) {
                & $add 'Error' 'php.exe' "PHP $($info.Version) ist zu alt - die Vorlage braucht mindestens $script:PhpMinVersion."
            } else {
                & $add 'Error' 'php.exe' "$php antwortet nicht auf 'php -v': $($info.VersionText)"
            }
            foreach ($le in $info.LoadErrors) { & $add 'Warn' 'PHP' $le }
            $missing = @($Project.PhpModules | Where-Object { $info.Modules -notcontains $_.ToLower() })
            if ($missing.Count -eq 0) {
                & $add 'Ok' 'PHP-Module' ("alle {0} benötigten geladen ({1})" -f $Project.PhpModules.Count, ($Project.PhpModules -join ', '))
            } else {
                & $add 'Error' 'PHP-Module' ("fehlen: {0} - in der php.ini aktivieren (extension=...) und IIS neu starten." -f ($missing -join ', '))
            }
        } catch {
            & $add 'Error' 'php.exe' "$php konnte nicht ausgeführt werden: $($_.Exception.Message)"
        }
    }

    # --- MySQL -------------------------------------------------------------------
    $mysql = Find-MySqlExe
    if ($mysql) { & $add 'Ok' 'mysql.exe' $mysql }
    else { & $add 'Error' 'mysql.exe' 'nicht gefunden - Pfad in projekte.json unter einstellungen.mysqlBin eintragen.' }

    # --- Setup-Skripte -------------------------------------------------------------
    foreach ($s in $Project.Skripte) {
        if (Test-Path -LiteralPath $s.Datei) { & $add 'Ok' 'Skript' $s.Anzeige }
        else { & $add 'Warn' 'Skript' "$($s.Anzeige) nicht gefunden - wird bei der Installation fehlschlagen." }
    }

    $blocked = (@($items | Where-Object { $_.Level -eq 'Error' }).Count -gt 0)
    [pscustomobject]@{ Ok = (-not $blocked); Items = $items.ToArray() }
}

# ==============================================================================
# 10) Installationsablauf (Seite 3)
# ==============================================================================

<#
 Schrittplan - fuer alle Projekte gleich, weil alle auf der Vorlage aufbauen:
   Website (mit Pool und Schreibrechten) -> Datenbank + Benutzer -> .env ->
   migrate -> user:create -> Setup-Skripte -> check.
 Die Abschlusskontrolle kommt bewusst zuletzt: sie sieht dann auch, was die
 Skripte hinterlassen haben.
#>
function Get-StepPlan {
    param($Project)
    $steps = New-Object System.Collections.Generic.List[object]
    $steps.Add(@{ Key = 'site';    Title = 'IIS: Anwendungspool, Website, Rechte auf var\'; Entry = $null })
    $steps.Add(@{ Key = 'db';      Title = 'MySQL: Datenbank und Benutzer anlegen';        Entry = $null })
    $steps.Add(@{ Key = 'env';     Title = '.env aus .env.example erzeugen';                Entry = $null })
    $steps.Add(@{ Key = 'migrate'; Title = 'php bin\console migrate';                       Entry = $null })
    $steps.Add(@{ Key = 'admin';   Title = 'php bin\console user:create (Administrator)';   Entry = $null })
    foreach ($s in $Project.Skripte) {
        if (-not $s.Gewaehlt) { continue }
        $steps.Add(@{ Key = 'ps1'; Title = "Skript: $($s.Titel)"; Entry = $s })
    }
    $steps.Add(@{ Key = 'check';   Title = 'php bin\console check (Abschlusskontrolle)';    Entry = $null })
    return $steps.ToArray()
}

function Set-StepState {
    param([int]$Index, [ValidateSet('Pending', 'Running', 'Done', 'Failed')][string]$State)
    if (-not $script:LvSteps -or $Index -ge $script:LvSteps.Items.Count) { return }
    $item = $script:LvSteps.Items[$Index]
    switch ($State) {
        'Pending' { $item.Text = [char]0x25CB; $item.ForeColor = [System.Drawing.Color]::Gray }          # ○
        'Running' { $item.Text = [char]0x25B6; $item.ForeColor = [System.Drawing.Color]::FromArgb(0, 99, 177) }   # ▶
        'Done'    { $item.Text = [char]0x2713; $item.ForeColor = [System.Drawing.Color]::FromArgb(16, 124, 65) }  # ✓
        'Failed'  { $item.Text = [char]0x2717; $item.ForeColor = [System.Drawing.Color]::FromArgb(196, 43, 28) }  # ✗
    }
    Invoke-UiPump
}

<#
 Fuehrt ein Setup-Skript des Projekts aus (Windows-Aufgaben einrichten).

 Uebergeben wird nur, was das Skript auch deklariert - die Projekte sind
 nicht voellig einheitlich. Get-Command liest dafuer den param()-Block, ohne
 den Rumpf auszufuehren.

 Rueckgabecodes der Projekt-Skripte:
   0 = eingerichtet          2 = Administrator-Rechte fehlen
   1 = unerwarteter Fehler   3 = Projektordner nicht bestimmbar
 Zusaetzlich gelten die Windows-Installer-Erfolgscodes 3010 (Neustart
 noetig) und 1641 (Neustart eingeleitet) als Erfolg - msiexec liefert sie,
 wenn ein Skript IIS-Module nachinstalliert.
#>
function Invoke-ProjectScript {
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)]$Entry)

    if (-not (Test-Path -LiteralPath $Entry.Datei)) {
        throw "Setup-Skript nicht gefunden: $($Entry.Datei)"
    }

    $erlaubt = @()
    try {
        $cmd = Get-Command -Name $Entry.Datei -CommandType ExternalScript -ErrorAction Stop
        $erlaubt = @($cmd.Parameters.Keys)
    } catch {
        # Nicht lesbar: dann nur den Pfad uebergeben statt zu raten
        Write-Log ("Parameter von {0} nicht lesbar ({1}) - Skript wird ohne Argumente gestartet." -f $Entry.Anzeige, $_.Exception.Message) 'Warn'
    }

    $phpExe = Find-PhpExe
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumente = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Entry.Datei + '"'))
    if ($erlaubt -contains 'ProjektPfad')     { $argumente += @('-ProjektPfad', ('"' + $Project.Dir + '"')) }
    if ($erlaubt -contains 'Unbeaufsichtigt') { $argumente += '-Unbeaufsichtigt' }
    if ($erlaubt -contains 'PhpExe'    -and $phpExe)            { $argumente += @('-PhpExe',    ('"' + $phpExe + '"')) }
    if ($erlaubt -contains 'PythonExe' -and $script:PythonExe)  { $argumente += @('-PythonExe', ('"' + $script:PythonExe + '"')) }

    Write-Log ("Starte Skript: {0}" -f $Entry.Anzeige) 'Info'
    $r = Invoke-ExeCapture -FilePath $ps -ArgumentList $argumente -TimeoutSec 900

    foreach ($zeile in @($r.Lines | Select-Object -First 20)) { Write-Log ("  " + $zeile) 'Info' }

    $neustart = $false
    switch ($r.ExitCode) {
        0     { $text = 'eingerichtet' }
        3010  { $text = 'eingerichtet - Neustart erforderlich'; $neustart = $true }
        1641  { $text = 'eingerichtet - Neustart wurde eingeleitet'; $neustart = $true }
        2     { $text = 'Administrator-Rechte fehlen' }
        3     { $text = 'Projektordner nicht bestimmbar' }
        1     { $text = 'Fehler im Skript - siehe Protokoll' }
        default { $text = "unerwarteter Rueckgabewert $($r.ExitCode) - siehe Protokoll" }
    }
    $ok = ($r.ExitCode -eq 0 -or $neustart)
    if (-not $ok) {
        $letzte = @($r.Lines | Where-Object { $_ -match 'FEHLER|Error' } | Select-Object -Last 1)
        if ($letzte) { $text = $text + ': ' + $letzte[0].Trim() }
    }
    Write-Log ("{0}: {1}" -f $Entry.Titel, $text) $(if ($ok) { 'Ok' } else { 'Error' })
    return [pscustomobject]@{ Ok = $ok; Text = $text; Neustart = $neustart; ExitCode = $r.ExitCode }
}

<#
 Führt den Schrittplan aus. Website, Datenbank, .env, migrate und user:create
 bauen aufeinander auf - scheitert einer davon, wird abgebrochen. Setup-Skripte
 halten die Installation nicht auf (Ergebnis je Skript auf der Seite "Fertig").
 Die Abschlusskontrolle entscheidet zuletzt: Exit-Code 1 = Einrichtung
 fehlgeschlagen, auch wenn alle Schritte davor durchliefen.
#>
function Invoke-ProjectInstall {
    $p = $script:Sel
    $url = Expand-ProjectText $p.Url $p
    $script:Result = @{
        Success       = $false
        Error         = $null
        Name          = $p.Name
        Url           = $url
        EnvFile       = (Join-Path $p.Dir '.env')
        EnvNeu        = $false
        Db            = @{ Name = $p.Db.Name; Benutzer = $p.Db.Benutzer; Passwort = $null; Quelle = '' }
        Admin         = $null      # @{ Login; Passwort; Existed }
        Migrationen   = $null
        Check         = $null
        SkriptResults = @()
        CredDatei     = $null
        Neustart      = $false
    }

    $plan          = Get-StepPlan $p
    $skriptResults = New-Object System.Collections.Generic.List[object]
    $skriptFehler  = New-Object System.Collections.Generic.List[string]
    $i = 0
    try {
        Set-Busy $true
        Write-Log ("=== Installation '{0}' gestartet ===" -f $p.Name) 'Step'
        $rootPw = $script:TxtRootPw.Text

        # Datenbank-Zugang festlegen: vorhandene .env hat Vorrang, dann die
        # Ablage einer frueheren Installation, sonst neu erzeugen.
        $envExisting = Read-EnvFile $script:Result.EnvFile
        if ($envExisting.Count -gt 0 -and $envExisting['DB_PASS']) {
            $script:Result.Db.Name     = $envExisting['DB_NAME']
            $script:Result.Db.Benutzer = $envExisting['DB_USER']
            $script:Result.Db.Passwort = $envExisting['DB_PASS']
            $script:Result.Db.Quelle   = 'aus der vorhandenen .env übernommen'
            Write-Log ".env vorhanden - Datenbank-Zugang wird daraus übernommen (DB $($envExisting['DB_NAME']), Benutzer $($envExisting['DB_USER']))." 'Info'
        } else {
            $saved = Read-ProjectCredentials -Project $p
            if ($saved['passwort'] -and $saved['passwort'] -match '^[A-Za-z0-9]+$') {
                $script:Result.Db.Passwort = $saved['passwort']
                $script:Result.Db.Quelle   = 'aus einer früheren Installation wiederverwendet'
                Write-Log "Datenbank-Passwort aus früherer Installation übernommen: $(Get-ProjectCredPath $p)" 'Info'
            } else {
                $script:Result.Db.Passwort = New-ProjectPassword
                $script:Result.Db.Quelle   = 'bei dieser Installation erzeugt'
            }
        }

        for ($i = 0; $i -lt $plan.Count; $i++) {
            $step = $plan[$i]
            Set-StepState $i 'Running'
            switch ($step.Key) {
                'site' {
                    Write-Log 'IIS: Anwendungspool und Website' 'Step'
                    New-ProjectSite -Project $p -ReplaceExisting ([bool]$script:ChkReplace.Checked)
                    Set-ProjectPermissions -Project $p
                    Set-StepState $i 'Done'
                }
                'db' {
                    Write-Log 'MySQL: Datenbank und Benutzer' 'Step'
                    New-ProjectDatabase -RootPassword $rootPw -DbName $script:Result.Db.Name `
                        -DbUser $script:Result.Db.Benutzer -DbPass $script:Result.Db.Passwort
                    Set-StepState $i 'Done'
                }
                'env' {
                    Write-Log 'Konfiguration (.env)' 'Step'
                    if (Test-Path -LiteralPath $script:Result.EnvFile) {
                        Write-Log ".env vorhanden - wird nicht angetastet: $($script:Result.EnvFile)" 'Info'
                    } else {
                        $values = @{
                            'APP_NAME'       = $p.Name
                            'APP_URL'        = $url.TrimEnd('/')
                            'APP_ENV'        = 'production'
                            'APP_DEBUG'      = 'false'
                            'APP_KEY'        = (New-AppKey)
                            'DB_HOST'        = '127.0.0.1'
                            'DB_PORT'        = [string]$script:MySqlPort
                            'DB_NAME'        = $script:Result.Db.Name
                            'DB_USER'        = $script:Result.Db.Benutzer
                            'DB_PASS'        = $script:Result.Db.Passwort
                            'SESSION_NAME'   = (($p.DirName.ToLower() -replace '[^a-z0-9_]', '_') + '_session')
                            'MAIL_FROM_NAME' = $p.Name
                        }
                        $written = Write-ProjectEnv -Project $p -Values $values
                        $script:Result.EnvNeu = $true
                        Write-Log "Erzeugt: $written (APP_KEY und SESSION_NAME gesetzt, DB-Zugang eingetragen)" 'Ok'
                    }
                    Set-StepState $i 'Done'
                }
                'migrate' {
                    Write-Log 'Datenbank-Migrationen' 'Step'
                    $m = Invoke-ConsoleMigrate -Project $p
                    $script:Result.Migrationen = $m
                    Write-Log $(if ($m.UpToDate) { 'Datenbank war bereits aktuell.' } else { "$($m.Count) Migration(en) ausgeführt." }) 'Ok'
                    Set-StepState $i 'Done'
                }
                'admin' {
                    Write-Log 'Erster Benutzer' 'Step'
                    $u = Invoke-ConsoleUserCreate -Project $p -Email ($script:TxtAdminMail.Text.Trim())
                    $script:Result.Admin = @{ Login = $p.Admin.Login; Passwort = $u.Passwort; Existed = $u.Existed }
                    Write-Log $u.Text 'Ok'
                    Set-StepState $i 'Done'
                }
                'ps1' {
                    # Ein fehlgeschlagenes Skript beendet die Installation nicht -
                    # am Ende sieht man, was steht und was nicht.
                    try {
                        $sr = Invoke-ProjectScript -Project $p -Entry $step.Entry
                        $skriptResults.Add(@{ Anzeige = $step.Entry.Titel; Ok = $sr.Ok; Text = $sr.Text })
                        if ($sr.Neustart) { $script:Result.Neustart = $true }
                        if ($sr.Ok) { Set-StepState $i 'Done' }
                        else { $skriptFehler.Add($step.Entry.Titel); Set-StepState $i 'Failed' }
                    } catch {
                        $msg = $_.Exception.Message
                        $skriptResults.Add(@{ Anzeige = $step.Entry.Titel; Ok = $false; Text = $msg })
                        $skriptFehler.Add($step.Entry.Titel)
                        Write-Log $msg 'Error'
                        Set-StepState $i 'Failed'
                    }
                }
                'check' {
                    Write-Log 'Abschlusskontrolle' 'Step'
                    $c = Invoke-ConsoleCheck -Project $p
                    $script:Result.Check = $c
                    if ($c.Ok) {
                        Write-Log $(if ($c.Summary) { $c.Summary } else { 'Systemprüfung ohne Fehler.' }) 'Ok'
                        Set-StepState $i 'Done'
                    } else {
                        Set-StepState $i 'Failed'
                        $fehler = @($c.Items | Where-Object { $_.Status -eq 'FEHLER' } | ForEach-Object { $_.Label })
                        throw ("Die Systemprüfung der Anwendung meldet Fehler (Exit-Code {0}): {1}. Einzelheiten im Protokoll; erneut prüfen mit: php bin\console check" -f `
                            $c.ExitCode, $(if ($fehler.Count -gt 0) { $fehler -join '; ' } else { 'siehe Ausgabe' }))
                    }
                }
            }
        }

        $script:Result.SkriptResults = $skriptResults.ToArray()
        if ($skriptFehler.Count -gt 0) {
            Write-Log (("{0} Setup-Skript(e) fehlgeschlagen: {1}" -f $skriptFehler.Count, ($skriptFehler -join ', '))) 'Warn'
        }
        # Zugangsdaten erst jetzt ablegen - vorher ist nicht sicher, dass sie gelten.
        $script:Result.CredDatei = Save-ProjectCredentials -Project $p -Values @{
            url       = $url
            datenbank = $script:Result.Db.Name
            benutzer  = $script:Result.Db.Benutzer
            passwort  = $script:Result.Db.Passwort
            admin_login           = $script:Result.Admin.Login
            admin_initialpasswort = $script:Result.Admin.Passwort
        }
        $script:Result.Success = $true
        Write-Log ("=== Installation '{0}' abgeschlossen ===" -f $p.Name) 'Ok'
        return $true
    } catch {
        Set-StepState $i 'Failed'
        $script:Result.SkriptResults = $skriptResults.ToArray()
        $script:Result.Error = $_.Exception.Message
        Write-Log $_.Exception.Message 'Error'
        Write-Log ("=== Installation '{0}' fehlgeschlagen ===" -f $p.Name) 'Error'
        return $false
    } finally {
        Set-Busy $false
    }
}

# ==============================================================================
# 11) Oberfläche: Grundgerüst
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

$fontUi    = New-Object System.Drawing.Font('Segoe UI', 9)
$fontBold  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontBig   = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$fontHead  = New-Object System.Drawing.Font('Segoe UI Semibold', 15)
$fontMono  = New-Object System.Drawing.Font('Consolas', 9)
$fontSym   = New-Object System.Drawing.Font('Segoe UI Symbol', 10)

# Ein Ort für alle Maße. Kopf (64) + Fußleiste (56) + Statuszeile (24) = 144,
# dazu die Innenabstände des Inhaltsbereichs (18 oben, 10 unten).
$script:FormW = 900
$script:FormH = 700
$pw = $script:FormW - 48         # nutzbare Breite einer Seite
$ph = $script:FormH - 144 - 28   # nutzbare Höhe einer Seite

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

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text            = $script:AppTitle
$script:Form.ClientSize      = New-Object System.Drawing.Size($script:FormW, $script:FormH)
$script:Form.StartPosition   = 'CenterScreen'
$script:Form.Font            = $fontUi
$script:Form.BackColor       = [System.Drawing.Color]::White
$script:Form.KeyPreview      = $true
$script:Form.AutoScaleMode       = [System.Windows.Forms.AutoScaleMode]::Dpi
$script:Form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)

# Symbol: in der EXE das mit PS2EXE eingebettete, sonst setup.ico daneben
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
#     aktuelle Elterngröße, ein leeres Panel wäre 200x100) -----------------
$header = New-Object System.Windows.Forms.Panel
$header.Size      = New-Object System.Drawing.Size($script:FormW, 64)
$header.Dock      = 'Top'
$header.BackColor = $script:ColDark
New-Label $header 24 10 500 26 $script:AppTitle ([System.Drawing.Color]::White) $fontHead | Out-Null
New-Label $header 26 38 500 18 'Website, Datenbank und Konfiguration für ein Projekt auf Basis der Projektvorlage' ([System.Drawing.Color]::FromArgb(170, 190, 210)) | Out-Null
$script:LblSteps = New-Label $header ($script:FormW - 420) 24 400 20 '' ([System.Drawing.Color]::FromArgb(170, 190, 210))
$script:LblSteps.TextAlign = 'MiddleRight'
$script:LblSteps.Anchor    = 'Top,Right'

# --- Inhaltsbereich -------------------------------------------------------
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

# --- Fußleiste und Statuszeile -------------------------------------------
$footer = New-Object System.Windows.Forms.Panel
$footer.Size      = New-Object System.Drawing.Size($script:FormW, 56)
$footer.Dock      = 'Bottom'
$footer.BackColor = [System.Drawing.Color]::FromArgb(243, 243, 243)
$script:BtnOpenJson = New-Ctl System.Windows.Forms.Button $footer 24 13 170 30 'projekte.json öffnen'
$script:BtnBack     = New-Ctl System.Windows.Forms.Button $footer ($script:FormW - 20 - 110 - 8 - 170) 13 110 30 '< Zurück'
$script:BtnBack.Anchor = 'Top,Right'
$script:BtnNext     = New-Ctl System.Windows.Forms.Button $footer ($script:FormW - 20 - 170) 13 170 30 'Weiter >'
$script:BtnNext.Anchor    = 'Top,Right'
$script:BtnNext.Font      = $fontBold
$script:BtnNext.BackColor = $script:ColAccent
$script:BtnNext.ForeColor = [System.Drawing.Color]::White
$script:BtnNext.FlatStyle = 'Flat'

$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Size      = New-Object System.Drawing.Size($script:FormW, 24)
$statusBar.Dock      = 'Bottom'
$statusBar.BackColor = $script:ColDark
$script:StatusLabel = New-Label $statusBar 12 4 ($script:FormW - 40) 18 'Bereit.' ([System.Drawing.Color]::FromArgb(190, 205, 220))

# ==============================================================================
# 12) Seite 1: Projekt auswählen
# ==============================================================================

$script:PnlSelect = New-Page
New-Label $script:PnlSelect 0 0 $pw 30 'Projekt auswählen' $script:ColDark $fontHead | Out-Null
$script:LblJsonPath = New-Label $script:PnlSelect 0 34 $pw 18 '' $script:ColGray
$script:LblJsonPath.Anchor = 'Top,Left,Right'

$script:LvProjects = New-Object System.Windows.Forms.ListView
$script:LvProjects.Location      = New-Object System.Drawing.Point(0, 58)
$script:LvProjects.Size          = New-Object System.Drawing.Size($pw, ($ph - 58 - 92))
$script:LvProjects.Anchor        = 'Top,Left,Right'
$script:LvProjects.View          = 'Details'
$script:LvProjects.FullRowSelect = $true
$script:LvProjects.MultiSelect   = $false
$script:LvProjects.HideSelection = $false
$script:LvProjects.HeaderStyle   = 'Nonclickable'
[void]$script:LvProjects.Columns.Add('Projekt', 220)
[void]$script:LvProjects.Columns.Add('Port', 70)
[void]$script:LvProjects.Columns.Add('Projektordner', $pw - 220 - 70 - 200 - 8)
[void]$script:LvProjects.Columns.Add('Datenbank / Benutzer', 200)
$script:PnlSelect.Controls.Add($script:LvProjects)

$script:BtnReload   = New-Ctl System.Windows.Forms.Button $script:PnlSelect 0 ($ph - 84) 160 30 'Liste neu laden'
$script:BtnTemplate = New-Ctl System.Windows.Forms.Button $script:PnlSelect 168 ($ph - 84) 160 30 'Vorlage anlegen'
$script:LblSelErr = New-Label $script:PnlSelect 0 ($ph - 46) $pw 46 '' $script:ColErr
$script:LblSelErr.Anchor = 'Left,Right,Bottom'

<#
 Füllt die Projektliste inklusive Symbolen. Base64-Icons aus der JSON werden
 auf 28x28 gebracht; ohne Icon gibt es ein farbiges Buchstabenkästchen.
 Die ImageList bestimmt in der Detailansicht zugleich die Zeilenhöhe.
#>
function Update-ProjectList {
    Read-ProjectJson

    $script:LblJsonPath.Text = "Projektliste: $script:JsonPath"
    $script:LvProjects.BeginUpdate()
    $script:LvProjects.Items.Clear()

    if ($script:LvProjects.SmallImageList) { $script:LvProjects.SmallImageList.Dispose() }
    $il = New-Object System.Windows.Forms.ImageList
    $il.ColorDepth = 'Depth32Bit'
    $il.ImageSize  = New-Object System.Drawing.Size(28, 28)
    $script:LvProjects.SmallImageList = $il

    $i = 0
    foreach ($p in $script:Projects) {
        $img = if ($p.Icon) { $p.Icon } else { New-LetterIcon -Name $p.Name -Index $i }
        $il.Images.Add($img)
        $item = New-Object System.Windows.Forms.ListViewItem($p.Name, $i)
        [void]$item.SubItems.Add([string]$p.Port)
        [void]$item.SubItems.Add($p.Dir)
        [void]$item.SubItems.Add(("{0} / {1}" -f $p.Db.Name, $p.Db.Benutzer))
        $item.Tag = $p
        [void]$script:LvProjects.Items.Add($item)
        $i++
    }
    $script:LvProjects.EndUpdate()

    $script:BtnTemplate.Visible = -not (Test-Path -LiteralPath $script:JsonPath)
    if ($script:JsonErrors.Count -gt 0) {
        $script:LblSelErr.Text = ($script:JsonErrors | Select-Object -First 3) -join '   '
        foreach ($e in $script:JsonErrors) { Write-Log $e 'Warn' }
    } else {
        $script:LblSelErr.Text = ''
    }
    Set-Status ("{0} Projekt(e) geladen." -f $script:Projects.Count)
    Update-NextState
}

# ==============================================================================
# 13) Seite 2: Prüfen
# ==============================================================================

$script:PnlCheck = New-Page
$script:LblCheckHead = New-Label $script:PnlCheck 0 0 $pw 30 'Prüfen' $script:ColDark $fontHead

$script:LvCheck = New-Object System.Windows.Forms.ListView
$script:LvCheck.Location      = New-Object System.Drawing.Point(0, 40)
$script:LvCheck.Size          = New-Object System.Drawing.Size($pw, 240)
$script:LvCheck.Anchor        = 'Top,Left,Right'
$script:LvCheck.View          = 'Details'
$script:LvCheck.FullRowSelect = $true
$script:LvCheck.HeaderStyle   = 'None'
$script:LvCheck.Font          = $fontSym
[void]$script:LvCheck.Columns.Add(' ', 34)
[void]$script:LvCheck.Columns.Add('Punkt', 130)
[void]$script:LvCheck.Columns.Add('Ergebnis', $pw - 34 - 130 - 8)
$script:PnlCheck.Controls.Add($script:LvCheck)

$script:ChkReplace = New-Ctl System.Windows.Forms.CheckBox $script:PnlCheck 0 286 $pw 22 'Vorhandene IIS-Website gleichen Namens ersetzen (der Projektordner bleibt unberührt)'

$grpDb = New-Object System.Windows.Forms.GroupBox
$grpDb.Text     = ' Datenbank (root) und erster Benutzer '
$grpDb.Location = New-Object System.Drawing.Point(0, 312)
$grpDb.Size     = New-Object System.Drawing.Size($pw, 138)
$grpDb.Anchor   = 'Top,Left,Right'
$script:PnlCheck.Controls.Add($grpDb)

New-Label $grpDb 16 28 110 20 'root-Passwort:' | Out-Null
$script:TxtRootPw = New-Ctl System.Windows.Forms.TextBox $grpDb 130 25 300 24
$script:TxtRootPw.UseSystemPasswordChar = $true
$script:ChkShowPw = New-Ctl System.Windows.Forms.CheckBox $grpDb 440 26 90 22 'anzeigen'
$script:BtnTestDb = New-Ctl System.Windows.Forms.Button $grpDb 540 24 170 27 'Verbindung testen'
$script:LblPwSource = New-Label $grpDb 130 54 ($pw - 150) 18 '' $script:ColGray
$script:LblDbTest   = New-Label $grpDb 130 74 ($pw - 150) 18 '' $script:ColGray
New-Label $grpDb 16 102 110 20 'Admin-E-Mail:' | Out-Null
$script:TxtAdminMail = New-Ctl System.Windows.Forms.TextBox $grpDb 130 99 300 24
$script:LblAdminHint = New-Label $grpDb 440 102 ($pw - 460) 20 'optional - nötig für die Cloudflare-SSO-Anmeldung (user:create)' $script:ColGray

# Auswahl der Setup-Skripte. Nur sichtbar, wenn das Projekt welche hat -
# die Seite wird dafuer in Load-CheckPage neu angeordnet. Pflichtskripte
# stehen mit gesetztem Haken drin und lassen sich nicht abwaehlen.
$script:GrpSkripte = New-Object System.Windows.Forms.GroupBox
$script:GrpSkripte.Text     = ' Setup-Skripte '
$script:GrpSkripte.Location = New-Object System.Drawing.Point(0, 188)
$script:GrpSkripte.Size     = New-Object System.Drawing.Size($pw, 92)
$script:GrpSkripte.Anchor   = 'Top,Left,Right'
$script:GrpSkripte.Visible  = $false
$script:PnlCheck.Controls.Add($script:GrpSkripte)

$script:ClbSkripte = New-Object System.Windows.Forms.CheckedListBox
$script:ClbSkripte.Location      = New-Object System.Drawing.Point(12, 20)
$script:ClbSkripte.Size          = New-Object System.Drawing.Size(($pw - 24), 64)
$script:ClbSkripte.Anchor        = 'Top,Left,Right'
$script:ClbSkripte.CheckOnClick  = $true
$script:ClbSkripte.BorderStyle   = 'None'
$script:ClbSkripte.IntegralHeight = $false
$script:GrpSkripte.Controls.Add($script:ClbSkripte)

# Pflichtskripte duerfen nicht abgewaehlt werden - der Haken springt zurueck.
$script:ClbSkripte.Add_ItemCheck({
    param($sender, $e)
    $eintrag = $script:SkriptAuswahl[$e.Index]
    if (-not $eintrag.Optional -and $e.NewValue -ne 'Checked') {
        $e.NewValue = 'Checked'
    }
})

$script:LblCheckHint = New-Label $script:PnlCheck 0 ($ph - 66) $pw 60 '' $script:ColGray
$script:LblCheckHint.Anchor = 'Left,Right,Bottom'

function Load-CheckPage {
    $p = $script:Sel
    $script:LblCheckHead.Text = "Prüfen: $($p.Name)"
    $script:LvCheck.BeginUpdate()
    $script:LvCheck.Items.Clear()

    $res = Test-Project $p
    foreach ($it in $res.Items) {
        $sym = switch ($it.Level) { 'Ok' { [char]0x2713 } 'Warn' { [char]0x26A0 } 'Error' { [char]0x2717 } default { [char]0x2139 } }
        $col = switch ($it.Level) { 'Ok' { $script:ColOk } 'Warn' { $script:ColWarn } 'Error' { $script:ColErr } default { $script:ColGray } }
        $item = New-Object System.Windows.Forms.ListViewItem([string]$sym)
        [void]$item.SubItems.Add($it.Name)
        [void]$item.SubItems.Add($it.Text)
        $item.ForeColor    = $col
        $item.UseItemStyleForSubItems = $true
        [void]$script:LvCheck.Items.Add($item)
    }
    $script:LvCheck.EndUpdate()
    $script:CheckOk = $res.Ok

    # Setup-Skripte anbieten. Pflichtskripte stehen fest angehakt in derselben
    # Liste, damit der Anwender sieht, was ohnehin laeuft.
    $script:SkriptAuswahl = @($p.Skripte)
    $hatSkripte = ($script:SkriptAuswahl.Count -gt 0)
    $script:GrpSkripte.Visible = $hatSkripte
    if ($hatSkripte) {
        $script:ClbSkripte.BeginUpdate()
        $script:ClbSkripte.Items.Clear()
        foreach ($s in $script:SkriptAuswahl) {
            $text = if ($s.Optional) { $s.Titel } else { $s.Titel + '   (immer)' }
            [void]$script:ClbSkripte.Items.Add($text, [bool]$s.Gewaehlt)
        }
        $script:ClbSkripte.EndUpdate()
        # Seite umbauen: die Pruefliste wird kuerzer, darunter die Skripte.
        $script:LvCheck.Height    = 140
        $script:GrpSkripte.Top    = 188
    } else {
        $script:LvCheck.Height    = 240
    }
    $script:ChkReplace.Top = 286
    $grpDb.Top             = 312

    # Ersetzen-Kästchen nur anbieten, wenn es etwas zu ersetzen gibt
    $exists = (@(Get-IisSites | Where-Object { $_.Name -eq $p.Name }).Count -gt 0)
    $script:ChkReplace.Visible = $exists
    if (-not $exists) { $script:ChkReplace.Checked = $false }

    if ([string]::IsNullOrEmpty($script:TxtRootPw.Text)) {
        $saved = Get-SavedRootPassword
        if ($saved) {
            $script:TxtRootPw.Text = $saved
            $script:LblPwSource.Text = "Automatisch gelesen aus: $script:CredFile"
        } else {
            $script:LblPwSource.Text = 'Keine gespeicherten Zugangsdaten gefunden - Passwort bitte eingeben (die my.ini enthält kein Passwort).'
        }
    }
    $script:LblDbTest.Text = ''
    $script:TxtAdminMail.Text = [string]$p.Admin.Email
    $script:LblAdminHint.Text = "optional - für Cloudflare-SSO; Login '$($p.Admin.Login)', Anzeigename '$($p.Admin.Name)'"

    $script:LblCheckHint.Text = if ($res.Ok) {
        '"Installieren" legt Pool und Website an, dann Datenbank + Benutzer, .env, Migrationen, den ersten Administrator und prüft zum Schluss die Anwendung (php bin\console check).'
    } else {
        'Rot markierte Punkte verhindern die Installation. Ursache beheben und mit "Zurück" / "Weiter" erneut prüfen.'
    }
    Update-NextState
}

# ==============================================================================
# 14) Seite 3: Installation
# ==============================================================================

$script:PnlInstall = New-Page
$script:LblInstHead = New-Label $script:PnlInstall 0 0 $pw 30 'Installation' $script:ColDark $fontHead

$script:LvSteps = New-Object System.Windows.Forms.ListView
$script:LvSteps.Location      = New-Object System.Drawing.Point(0, 40)
$script:LvSteps.Size          = New-Object System.Drawing.Size(330, ($ph - 40 - 76))
$script:LvSteps.View          = 'Details'
$script:LvSteps.HeaderStyle   = 'None'
$script:LvSteps.Font          = $fontSym
$script:LvSteps.FullRowSelect = $true
[void]$script:LvSteps.Columns.Add(' ', 30)
[void]$script:LvSteps.Columns.Add('Schritt', 290)
$script:PnlInstall.Controls.Add($script:LvSteps)

$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Location   = New-Object System.Drawing.Point(342, 40)
$script:LogBox.Size       = New-Object System.Drawing.Size(($pw - 342), ($ph - 40 - 76))
$script:LogBox.Anchor     = 'Top,Left,Right,Bottom'
$script:LogBox.ReadOnly   = $true
$script:LogBox.BackColor  = [System.Drawing.Color]::FromArgb(24, 30, 38)
$script:LogBox.ForeColor  = [System.Drawing.Color]::FromArgb(210, 210, 210)
$script:LogBox.Font       = $fontMono
$script:LogBox.BorderStyle = 'None'
$script:LogBox.WordWrap   = $false
$script:LogBox.ScrollBars = 'Both'
$script:PnlInstall.Controls.Add($script:LogBox)

$script:LblInstallError = New-Label $script:PnlInstall 0 ($ph - 68) $pw 40 '' $script:ColErr $fontBold
$script:LblInstallError.Anchor = 'Left,Right,Bottom'
$script:BtnInstallLog = New-Ctl System.Windows.Forms.Button $script:PnlInstall 0 ($ph - 28) 170 28 'Protokolldatei öffnen'
$script:BtnInstallLog.Anchor = 'Left,Bottom'

function Load-InstallPage {
    $script:LblInstHead.Text = "Installation: $($script:Sel.Name)"
    $script:LblInstallError.Text = ''
    $script:LvSteps.Items.Clear()
    foreach ($s in (Get-StepPlan $script:Sel)) {
        $item = New-Object System.Windows.Forms.ListViewItem([string][char]0x25CB)
        [void]$item.SubItems.Add($s.Title)
        $item.ForeColor = [System.Drawing.Color]::Gray
        [void]$script:LvSteps.Items.Add($item)
    }
}

# ==============================================================================
# 15) Seite 4: Fertig
# ==============================================================================

$script:PnlFinish = New-Page
$script:LblFinHead = New-Label $script:PnlFinish 0 0 $pw 30 'Fertig' $script:ColDark $fontHead
$script:LblFinText = New-Label $script:PnlFinish 0 38 $pw 36 '' $script:ColGray
$script:LblFinText.Anchor = 'Top,Left,Right'

# Zugangsdaten: Anmeldung an der Anwendung und Datenbank-Zugang der .env.
# Werte in fester Schrift (leichter abzutippen), Hinweis darunter in der
# normalen Schrift - dessen Hoehe wird gemessen, damit nichts abgeschnitten wird.
$script:LblAccHead = New-Label $script:PnlFinish 0 80 $pw 22 'Zugangsdaten' $script:ColDark $fontBig
$script:LblAccInfo = New-Label $script:PnlFinish 0 104 $pw 60 '' $script:ColDark
$script:LblAccInfo.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$script:LblAccNote = New-Label $script:PnlFinish 0 170 $pw 34 '' $script:ColGray

# Ergebnis der Abschlusskontrolle (nur Warnungen; Fehler haetten die
# Installation abgebrochen) und der Setup-Skripte: je eine Zeile mit Symbol.
$script:LblResHead = New-Label $script:PnlFinish 0 80 $pw 22 'Hinweise der Systemprüfung' $script:ColDark $fontBig
$script:LvRes = New-Object System.Windows.Forms.ListView
$script:LvRes.Location      = New-Object System.Drawing.Point(0, 106)
$script:LvRes.Size          = New-Object System.Drawing.Size($pw, 80)
$script:LvRes.Anchor        = 'Top,Left,Right'
$script:LvRes.View          = 'Details'
$script:LvRes.HeaderStyle   = 'None'
$script:LvRes.Font          = $fontSym
$script:LvRes.FullRowSelect = $true
[void]$script:LvRes.Columns.Add(' ', 34)
[void]$script:LvRes.Columns.Add('Punkt', 300)
[void]$script:LvRes.Columns.Add('Ergebnis', $pw - 34 - 300 - 8)
$script:PnlFinish.Controls.Add($script:LvRes)

$script:LblNextSteps = New-Label $script:PnlFinish 0 92 $pw 22 'Nächste Schritte' $script:ColDark $fontBig

# FlowLayoutPanel: nimmt beliebig viele Schaltflächen auf
$script:FlowFinish = New-Object System.Windows.Forms.FlowLayoutPanel
$script:FlowFinish.Location      = New-Object System.Drawing.Point(0, 120)
$script:FlowFinish.Size          = New-Object System.Drawing.Size($pw, ($ph - 120 - 60))
$script:FlowFinish.Anchor        = 'Top,Left,Right,Bottom'
$script:FlowFinish.FlowDirection = 'TopDown'
$script:FlowFinish.WrapContents  = $true
$script:FlowFinish.AutoScroll    = $true
$script:PnlFinish.Controls.Add($script:FlowFinish)

$script:LblFinNote = New-Label $script:PnlFinish 0 ($ph - 52) $pw 46 '' $script:ColGray
$script:LblFinNote.Anchor = 'Left,Right,Bottom'

function Add-FinishButton {
    param([string]$Text, [scriptblock]$OnClick, [switch]$Accent)
    $b = New-Object System.Windows.Forms.Button
    $b.Size   = New-Object System.Drawing.Size(400, 32)
    $b.Text   = $Text
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 8)
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

function Load-FinishPage {
    $r = $script:Result
    $script:LblFinHead.Text = "Fertig: $($r.Name)"
    $script:LblFinText.Text = "Die Anwendung läuft unter $($r.Url) und hat die Systemprüfung bestanden" +
        $(if ($r.Check -and (@($r.Check.Items | Where-Object { $_.Status -eq 'WARNUNG' }).Count -gt 0)) { ' (mit Warnungen, siehe unten).' } else { '.' })

    # --- Zugangsdaten -----------------------------------------------------------
    $y = 80
    $lines = New-Object System.Collections.Generic.List[string]
    $notiz = New-Object System.Collections.Generic.List[string]
    if ($r.Admin) {
        $lines.Add(("Anmeldung :  {0}" -f $r.Admin.Login))
        if ($r.Admin.Passwort) {
            $lines.Add(("Passwort  :  {0}   (Initialpasswort - Wechsel beim ersten Login)" -f $r.Admin.Passwort))
        } else {
            $lines.Add("Passwort  :  unverändert (Benutzer existierte bereits; Notfall: php bin\console user:password $($r.Admin.Login))")
        }
    }
    $lines.Add(("Datenbank :  {0}   Benutzer: {1}" -f $r.Db.Name, $r.Db.Benutzer))
    $lines.Add(("DB-Passw. :  {0}   ({1})" -f $r.Db.Passwort, $r.Db.Quelle))
    $script:LblAccHead.Top    = $y
    $script:LblAccInfo.Top    = $y + 26
    $script:LblAccInfo.Text   = ($lines -join [Environment]::NewLine)
    $script:LblAccInfo.Height = ($lines.Count * 17) + 4
    $y = $script:LblAccInfo.Top + $script:LblAccInfo.Height

    $notiz.Add($(if ($r.EnvNeu) { 'Die .env wurde erzeugt (APP_KEY, SESSION_NAME, Datenbank-Zugang).' } else { 'Die vorhandene .env wurde übernommen.' }))
    if ($r.CredDatei) { $notiz.Add('Alle Werte hinterlegt in: ' + $r.CredDatei) }
    if ($r.Neustart)  { $notiz.Add('Ein Setup-Skript meldet: Windows muss neu gestartet werden, damit alles vollständig greift.') }
    $hinweisText = ($notiz -join ' ')
    $prop = New-Object System.Drawing.Size($pw, 0)
    $size = [System.Windows.Forms.TextRenderer]::MeasureText($hinweisText, $script:LblAccNote.Font, $prop, [System.Windows.Forms.TextFormatFlags]::WordBreak)
    $script:LblAccNote.Top    = $y + 6
    $script:LblAccNote.Text   = $hinweisText
    $script:LblAccNote.Height = $size.Height + 4
    $y = $script:LblAccNote.Top + $script:LblAccNote.Height + 14

    # --- Warnungen der Systempruefung + Ergebnis der Setup-Skripte ---------------
    $rows = New-Object System.Collections.Generic.List[object]
    if ($r.Check) {
        foreach ($it in @($r.Check.Items | Where-Object { $_.Status -ne 'OK' })) {
            $rows.Add(@{ Ok = $false; Warn = ($it.Status -eq 'WARNUNG'); Name = $it.Label; Text = $it.Hint })
        }
    }
    foreach ($e in @($r.SkriptResults)) {
        $rows.Add(@{ Ok = $e.Ok; Warn = $false; Name = ('Skript: ' + $e.Anzeige); Text = $e.Text })
    }
    if ($rows.Count -gt 0) {
        $script:LblResHead.Visible = $true
        $script:LvRes.Visible  = $true
        $script:LblResHead.Top = $y
        $script:LvRes.Top      = $y + 26
        $script:LvRes.BeginUpdate()
        $script:LvRes.Items.Clear()
        foreach ($e in $rows) {
            $sym = if ($e.Ok) { [char]0x2713 } elseif ($e.Warn) { [char]0x26A0 } else { [char]0x2717 }
            $item = New-Object System.Windows.Forms.ListViewItem([string]$sym)
            [void]$item.SubItems.Add($e.Name)
            [void]$item.SubItems.Add([string]$e.Text)
            $item.ForeColor = if ($e.Ok) { $script:ColOk } elseif ($e.Warn) { $script:ColWarn } else { $script:ColErr }
            $item.UseItemStyleForSubItems = $true
            [void]$script:LvRes.Items.Add($item)
        }
        $script:LvRes.EndUpdate()
        $script:LvRes.Height = [math]::Min(110, ($rows.Count * 22) + 8)
        $y = $script:LvRes.Top + $script:LvRes.Height + 14
    } else {
        $script:LblResHead.Visible = $false
        $script:LvRes.Visible  = $false
    }

    # --- "Nächste Schritte" und die Schaltflächen unter die Übersicht schieben ---
    $script:LblNextSteps.Top = $y
    $script:FlowFinish.Top    = $y + 28
    $script:FlowFinish.Height = [math]::Max(60, $ph - $script:FlowFinish.Top - 56)

    $script:FlowFinish.Controls.Clear()
    Add-FinishButton -Accent -Text "Anwendung öffnen: $($r.Url)" -OnClick { Open-InBrowser $script:Result.Url | Out-Null }
    Add-FinishButton -Text 'Konfiguration bearbeiten (.env)' -OnClick { Open-InNotepad $script:Result.EnvFile }
    Add-FinishButton -Text 'Protokolldatei öffnen' -OnClick { Open-InNotepad $script:LogFile }
    Add-FinishButton -Text 'Weiteres Projekt installieren' -OnClick {
        $script:Sel = $null
        $script:LvProjects.SelectedItems.Clear()
        Show-Page 'select'
    }

    $script:LblFinNote.Text = 'Hinweis: Beim ersten Login erzwingt die Anwendung einen Passwortwechsel. E-Mail-Versand und weitere Einstellungen stehen in der .env (Erklärungen in der .env.example).'
}

# ==============================================================================
# 16) Seitensteuerung
# ==============================================================================

$script:Pages = @{ select = $script:PnlSelect; check = $script:PnlCheck; install = $script:PnlInstall; finish = $script:PnlFinish }

function Update-StepHeader {
    param([string]$Page)
    $names = @('Auswahl', 'Prüfen', 'Installation', 'Fertig')
    $order = @('select', 'check', 'install', 'finish')
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
            $script:BtnNext.Enabled = ($script:LvProjects.SelectedItems.Count -gt 0)
            $script:BtnBack.Enabled = $false
        }
        'check' {
            $script:BtnNext.Text    = 'Installieren'
            $script:BtnNext.Enabled = [bool]$script:CheckOk
            $script:BtnBack.Enabled = $true
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
        'select'  { Set-Status 'Projekt auswählen und auf "Weiter" klicken.' }
        'check'   { Load-CheckPage; Set-Status 'Prüfergebnis kontrollieren, dann "Installieren".' }
        'install' { Set-Status 'Installation läuft ...' }
        'finish'  { Load-FinishPage; Set-Status 'Fertig.' }
    }
    Update-NextState
}

function Start-Install {
    $p = $script:Sel
    if ([string]::IsNullOrEmpty($script:TxtRootPw.Text)) {
        Show-Warn 'Bitte zuerst das root-Passwort eingeben (Feld "Datenbank").'
        return
    }
    $mail = $script:TxtAdminMail.Text.Trim()
    if ($mail -and $mail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        Show-Warn "Die Admin-E-Mail '$mail' sieht nicht wie eine E-Mail-Adresse aus. Feld leeren oder korrigieren."
        return
    }
    $text = "Projekt '{0}' wird eingerichtet:`n`nWebsite:    {0} (Port {1})`nPfad:       {2}`nDatenbank:  {3} (Benutzer {4})`nAdmin:      {5}{6}`n`nJetzt starten?" -f `
        $p.Name, $p.Port, $p.DocRoot, $p.Db.Name, $p.Db.Benutzer, $p.Admin.Login, $(if ($mail) { " <$mail>" } else { '' })
    if (-not (Show-Confirm $text 'Installation starten')) { return }

    # Haken aus der Liste in die Projektdaten uebernehmen
    if ($script:SkriptAuswahl) {
        for ($k = 0; $k -lt $script:SkriptAuswahl.Count; $k++) {
            $script:SkriptAuswahl[$k].Gewaehlt = $script:ClbSkripte.GetItemChecked($k)
        }
    }

    Show-Page 'install'
    Load-InstallPage
    $ok = Invoke-ProjectInstall
    if ($ok) {
        Show-Page 'finish'
    } else {
        $script:LblInstallError.Text = $script:Result.Error
        Update-NextState
    }
}

# ==============================================================================
# 17) Ereignisse
# ==============================================================================

$script:LvProjects.Add_SelectedIndexChanged({
    if ($script:LvProjects.SelectedItems.Count -gt 0) {
        $script:Sel = $script:LvProjects.SelectedItems[0].Tag
    } else {
        $script:Sel = $null
    }
    Update-NextState
})
$script:LvProjects.Add_DoubleClick({
    if ($script:Sel) { Show-Page 'check' }
})

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

$script:ChkShowPw.Add_CheckedChanged({ $script:TxtRootPw.UseSystemPasswordChar = -not $script:ChkShowPw.Checked })
$script:BtnTestDb.Add_Click({
    if ([string]::IsNullOrEmpty($script:TxtRootPw.Text)) { $script:LblDbTest.Text = 'Bitte zuerst ein Passwort eingeben.'; $script:LblDbTest.ForeColor = $script:ColWarn; return }
    $script:BtnTestDb.Enabled = $false
    $script:LblDbTest.Text = 'Verbindung wird geprüft ...'
    $script:LblDbTest.ForeColor = $script:ColGray
    Invoke-UiPump
    try {
        $t = Test-MySqlRoot -Password $script:TxtRootPw.Text
        $script:LblDbTest.Text = $t.Message
        $script:LblDbTest.ForeColor = if ($t.Ok) { $script:ColOk } else { $script:ColErr }
        Write-Log ("Verbindungstest: {0}" -f $t.Message) $(if ($t.Ok) { 'Ok' } else { 'Warn' })
    } catch {
        $script:LblDbTest.Text = $_.Exception.Message
        $script:LblDbTest.ForeColor = $script:ColErr
    } finally {
        $script:BtnTestDb.Enabled = $true
    }
})

$script:BtnInstallLog.Add_Click({ Open-InNotepad $script:LogFile })

$script:BtnBack.Add_Click({
    switch ($script:CurrentPage) {
        'check'   { Show-Page 'select' }
        'install' { Show-Page 'check' }
    }
})
$script:BtnNext.Add_Click({
    switch ($script:CurrentPage) {
        'select'  { if ($script:Sel) { Show-Page 'check' } }
        'check'   { Start-Install }
        'install' { Start-Install }   # Erneut versuchen (alles idempotent bzw. ersetzbar)
        'finish'  { $script:Form.Close() }
    }
})

$script:Form.Add_FormClosing({
    if ($script:Busy) {
        if (-not (Show-Confirm 'Die Installation läuft noch. Wirklich abbrechen?')) { $_.Cancel = $true }
    }
})

# Reihenfolge ist wichtig: WinForms dockt von hinten nach vorne.
$script:Form.Controls.Add($content)
$script:Form.Controls.Add($footer)
$script:Form.Controls.Add($statusBar)
$script:Form.Controls.Add($header)

# Auf kleinen Konsolen oder bei hoher Skalierung nicht über den sichtbaren
# Bereich hinauswachsen - sonst wäre die Fußleiste nicht erreichbar.
$script:Form.MinimumSize = New-Object System.Drawing.Size(820, 620)
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w  = [math]::Min($script:Form.Width,  [int]($wa.Width  * 0.98))
    $h  = [math]::Min($script:Form.Height, [int]($wa.Height * 0.98))
    if ($w -lt $script:Form.Width -or $h -lt $script:Form.Height) {
        $script:Form.Size = New-Object System.Drawing.Size([math]::Max(820, $w), [math]::Max(620, $h))
    }
} catch { }

# ==============================================================================
# 18) Start
# ==============================================================================

$script:Form.Add_Shown({
    Write-Log "$script:AppTitle $script:AppVersion gestartet." 'Step'
    Write-Log "Protokoll: $script:LogFile"
    Write-Log ("Ausführung: {0}" -f $(if ($script:IsCompiled) { "EXE ($script:SelfPath)" } else { "Skript ($script:SelfPath)" }))
    Update-ProjectList
    Show-Page 'select'
    if (-not (Test-Path -LiteralPath $script:JsonPath)) {
        Set-Status 'Keine projekte.json gefunden - mit "Vorlage anlegen" starten.'
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
