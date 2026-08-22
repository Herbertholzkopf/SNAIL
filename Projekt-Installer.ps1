<#
================================================================================
 Projekt-Installer  -  Version 1.0
================================================================================
 Richtet ein vorbereitetes PHP-Projekt auf diesem Server ein:
   1. IIS-Website anlegen (Name, Pfad, Port aus der Projektliste)
   2. SQL-Skripte des Projekts als root ausführen (Benutzer/Datenbank, Tabellen)
   3. Setup-Adresse und Konfigurationsdateien zum Nachbearbeiten anbieten

 Die Projektliste liegt als projekte.json NEBEN dieser Datei (bzw. neben der
 EXE) und wird beim Start gelesen. Neue Projekte = nur JSON ergänzen, die EXE
 muss nicht neu erzeugt werden. Fehlt die Datei, bietet der Assistent an, eine
 kommentierte Vorlage zu erstellen.

 AUFBAU DER projekte.json
 ------------------------
 {
   "einstellungen": {
     "wwwroot":   "C:\\inetpub\\wwwroot",   // Basisordner für relative Projektordner
     "mysqlBin":  "",                        // leer = mysql.exe automatisch suchen
     "mysqlPort": 3306
   },
   "projekte": [
     {
       "name":    "Renate",                 // Anzeigename und IIS-Sitename
       "ordner":  "renate",                 // relativ zu wwwroot oder absoluter Pfad
       "docroot": "",                       // ""=Projektordner selbst, sonst z. B. "public"
       "port":    8081,
       "sql": [                             // Reihenfolge = Ausführungsreihenfolge
         "sql/01-benutzer-und-datenbank.sql",
         { "datei": "sql/02-tabellen.sql", "datenbank": "renate" }
       ],
       "setupUrl": "http://localhost:{port}/setup.php",  // optional
       "konfigDateien": [                   // optional, relativ zum Projekt
         "config/config.php",               // einfacher Pfad: Vorlage wird gesucht
         { "datei": ".env", "vorlage": ".env.example" }   // oder Vorlage explizit
       ],
       "datenbank": {                       // optional: wird am Ende angezeigt
         "benutzer": "renate_user",
         "passwort": "12345678",
         "name":     "renate",
         "hinweis":  "freier Zusatztext"    // optional
       },
       "skripte": [                         // optional - NOCH NICHT IMPLEMENTIERT
         {
           "datei":          "setup/aufgabe.ps1",
           "titel":          "Aufgabe einrichten",
           "beschreibung":   "Erklaerung fuer den Anwender",
           "optional":       true,          // false = laeuft immer mit
           "vorausgewaehlt": true,          // nur bei optional=true
           "alsAdmin":       true
         }
       ],
       "icon": "iVBORw0KGgo..."             // optional: PNG als Base64
     }
   ]
 }

 Platzhalter in setupUrl und konfigDateien: {port}, {name}, {ordner}

 Ein Icon als Base64 erzeugt dieser Einzeiler (PNG, ideal 64x64 bis 256x256):
   [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\pfad\logo.png')) | Set-Clipboard

 ROOT-PASSWORT
 -------------
 Wird automatisch aus der vom Setup-Assistenten erzeugten Datei
 C:\ProgramData\PHP-IIS-Setup\mysql-zugangsdaten.txt gelesen (die my.ini
 enthält kein Passwort). Ist die Datei gelöscht, wird das Passwort im
 Assistenten von Hand eingegeben. Es wird nie auf der Kommandozeile übergeben,
 sondern über eine temporäre defaults-extra-file an mysql.exe gereicht.

 ALS EXE VERTEILEN (PS2EXE)
 --------------------------
   Install-Module ps2exe -Scope CurrentUser
   Invoke-ps2exe .\Projekt-Installer.ps1 .\Projekt-Installer.exe `
       -noConsole -requireAdmin -STA -x64 -title 'Projekt-Installer' -version '1.0.0.0'
   (oder Build-Projekt-Installer.ps1 verwenden)

 HINWEISE
   - Diese Datei ist UTF-8 mit BOM gespeichert. Kodierung beim Bearbeiten
     beibehalten, sonst gehen die Umlaute kaputt.
   - Getestet für Windows PowerShell 5.1 auf Windows Server 2022/2025.
   - Voraussetzung: IIS und MySQL sind bereits eingerichtet (z. B. mit dem
     PHP + IIS Setup-Assistenten).
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
$script:AppVersion = '1.0'

$script:JsonPath   = Join-Path $script:SelfDir 'projekte.json'
$script:WwwRoot    = Join-Path (Join-Path $env:SystemDrive 'inetpub') 'wwwroot'
$script:AppCmd     = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'

# Gemeinsamer Ordner mit dem PHP + IIS Setup-Assistenten
$script:LogDir     = Join-Path $env:ProgramData 'PHP-IIS-Setup'
$script:LogFile    = Join-Path $script:LogDir ('projekt_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
$script:CredFile   = Join-Path $script:LogDir 'mysql-zugangsdaten.txt'

$script:MySqlPort  = 3306
$script:MySqlBin   = ''        # aus JSON, sonst automatische Suche

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
#>
function Invoke-ExeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$StdIn = $null,
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
            # in der ANSI-Codepage, wodurch Umlaute in SQL-Dateien als Fragezeichen
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
          Replace('{ordner}', [string]$Project.Dir)
}

# ==============================================================================
#  3) projekte.json lesen und prüfen
# ==============================================================================

$script:JsonTemplate = @'
{
  "_doku": "Projektliste fuer den Projekt-Installer. Diese Datei liegt neben der EXE und wird beim Start gelesen. Platzhalter in setupUrl und konfigDateien: {port} {name} {ordner}. Icon: PNG als Base64, Einzeiler: [Convert]::ToBase64String([IO.File]::ReadAllBytes('logo.png')) | Set-Clipboard. konfigDateien: einfacher Pfad oder { datei, vorlage } - fehlt die Datei, wird sie bei der Installation aus der Vorlage kopiert; ohne Angabe werden <datei>.example, <datei>.dist und config.example.php-Muster automatisch gesucht.",

  "einstellungen": {
    "wwwroot":   "C:\\inetpub\\wwwroot",
    "mysqlBin":  "",
    "mysqlPort": 3306
  },

  "projekte": [
    {
      "name":    "Renate",
      "ordner":  "renate",
      "docroot": "",
      "port":    8081,
      "sql": [
        "sql/01-benutzer-und-datenbank.sql",
        { "datei": "sql/02-tabellen.sql", "datenbank": "renate" }
      ],
      "setupUrl": "http://localhost:{port}/setup.php",
      "konfigDateien": [ "config/config.php" ],
      "icon": ""
    },
    {
      "name":    "Olaf",
      "ordner":  "olaf",
      "docroot": "public",
      "port":    8082,
      "sql": [
        "datenbank/create-user.sql",
        "datenbank/schema.sql"
      ],
      "konfigDateien": [ { "datei": ".env", "vorlage": ".env.example" } ]
    }
  ]
}
'@

<#
 Liest projekte.json, prüft die Einträge und liefert normalisierte Projekte:
   Name, Dir (absoluter Projektordner), DocRoot (absoluter IIS-Pfad), Port,
   Sql (Liste aus @{Datei=<absolut>; Datenbank=<string|null>}),
   SetupUrl, ConfigFiles (absolute Pfade), Icon (Image oder $null)
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
    if ($json.einstellungen) {
        $e = $json.einstellungen
        if ($e.wwwroot)   { $script:WwwRoot  = [string]$e.wwwroot }
        if ($e.mysqlBin)  { $script:MySqlBin = [string]$e.mysqlBin }
        if ($e.mysqlPort) { $script:MySqlPort = [int]$e.mysqlPort }
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

        $name = [string]$p.name
        if ([string]::IsNullOrWhiteSpace($name)) { $script:JsonErrors += "${where}: Feld 'name' fehlt."; continue }
        if ($seenNames.ContainsKey($name.ToLower())) { $script:JsonErrors += "${where}: Der Name '$name' kommt doppelt vor." }
        $seenNames[$name.ToLower()] = $true

        $ordner = [string]$p.ordner
        if ([string]::IsNullOrWhiteSpace($ordner)) { $script:JsonErrors += "${where}: Feld 'ordner' fehlt."; continue }
        $dir = if ([System.IO.Path]::IsPathRooted($ordner)) { $ordner } else { Join-Path $script:WwwRoot $ordner }

        $docSub = [string]$p.docroot
        $doc = if ([string]::IsNullOrWhiteSpace($docSub)) { $dir }
               elseif ([System.IO.Path]::IsPathRooted($docSub)) { $docSub }
               else { Join-Path $dir $docSub }

        $port = 0
        try { $port = [int]$p.port } catch { }
        if ($port -lt 1 -or $port -gt 65535) { $script:JsonErrors += "${where}: 'port' fehlt oder ist ungültig (1-65535)."; continue }
        if ($seenPorts.ContainsKey($port)) { $script:JsonErrors += "${where}: Port $port ist bereits Projekt '$($seenPorts[$port])' zugeordnet." }
        else { $seenPorts[$port] = $name }

        # SQL-Einträge: einfacher Dateiname oder Objekt { datei, datenbank }
        $sql = New-Object System.Collections.Generic.List[object]
        foreach ($s in @($p.sql)) {
            if ($null -eq $s) { continue }
            $file = $null; $db = $null
            if ($s -is [string]) { $file = $s }
            elseif ($s.datei)    { $file = [string]$s.datei; if ($s.datenbank) { $db = [string]$s.datenbank } }
            if (-not $file) { $script:JsonErrors += "${where}: Ein SQL-Eintrag hat kein Feld 'datei'."; continue }
            $abs = if ([System.IO.Path]::IsPathRooted($file)) { $file } else { Join-Path $dir $file }
            $sql.Add(@{ Datei = $abs; Anzeige = $file; Datenbank = $db })
        }

        # Konfig-Einträge: einfacher Pfad oder Objekt { datei, vorlage }.
        # "vorlage" ist eine Beispieldatei (config.php.example), die kopiert
        # wird, falls die eigentliche Datei noch fehlt.
        $cfg = New-Object System.Collections.Generic.List[object]
        foreach ($c in @($p.konfigDateien)) {
            if ($null -eq $c) { continue }
            $file = $null; $tpl = $null
            if ($c -is [string]) { $file = $c }
            elseif ($c.datei)    { $file = [string]$c.datei; if ($c.vorlage) { $tpl = [string]$c.vorlage } }
            if ([string]::IsNullOrWhiteSpace($file)) { $script:JsonErrors += "${where}: Ein Konfig-Eintrag hat kein Feld 'datei'."; continue }
            if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path $dir $file }
            if ($tpl -and -not [System.IO.Path]::IsPathRooted($tpl)) { $tpl = Join-Path $dir $tpl }
            $cfg.Add(@{ Datei = $file; Vorlage = $tpl })
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

        # Datenbank-Zugangsdaten: rein informativ, werden am Ende angezeigt.
        # Sie stammen aus den SQL-Skripten des Projekts - der Installer legt
        # nichts davon selbst an und prueft sie auch nicht.
        $db = $null
        if ($p.datenbank) {
            $db = [pscustomobject]@{
                Name     = [string]$p.datenbank.name
                Benutzer = [string]$p.datenbank.benutzer
                Passwort = [string]$p.datenbank.passwort
                Hinweis  = [string]$p.datenbank.hinweis
            }
        }

        $out.Add([pscustomobject]@{
            Name        = $name
            Dir         = $dir
            DocRoot     = $doc
            Port        = $port
            Sql         = $sql.ToArray()
            SetupUrl    = [string]$p.setupUrl
            ConfigFiles = $cfg.ToArray()
            Datenbank   = $db
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

<#
 Sucht die Beispieldatei zu einer (noch fehlenden) Konfigurationsdatei.
 Erst die explizite Angabe aus der JSON, dann die üblichen Muster:
   config.php.example / config.php.dist   (angehängt)
   config.example.php / config.dist.php   (vor der Endung)
 Liefert den Pfad der ersten existierenden Vorlage oder $null.
#>
function Find-ConfigTemplate {
    param([Parameter(Mandatory)][string]$Target, [string]$Explicit = $null)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        return $null
    }
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($suffix in @('.example', '.dist', '.sample')) {
        $cands.Add($Target + $suffix)
        $ext  = [System.IO.Path]::GetExtension($Target)
        if ($ext) {
            $base = $Target.Substring(0, $Target.Length - $ext.Length)
            $cands.Add($base + $suffix + $ext)     # config.example.php
        }
    }
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

# ==============================================================================
#  4) IIS: Websites lesen und anlegen
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
 Legt die IIS-Website an. Entspricht dem Dialog "Website hinzufügen":
   Sitename         -> /name
   Physischer Pfad  -> /physicalPath
   Typ http, IP "Keine zugewiesen", Hostname leer -> /bindings:http/*:PORT:
   "Website sofort starten" -> Standardverhalten; zur Sicherheit "start site"
 Anwendungspool wird nicht angegeben -> DefaultAppPool (für PHP über den
 globalen FastCGI-Handler ohne Bedeutung).
#>
function New-ProjectSite {
    param($Project, [bool]$ReplaceExisting)

    $existing = @(Get-IisSites | Where-Object { $_.Name -eq $Project.Name })
    if ($existing.Count -gt 0) {
        # Sonderfall "Erneut versuchen": Die Website stammt aus einem früheren
        # Durchlauf mit demselben Port - dann weiterverwenden statt abbrechen.
        if (-not $ReplaceExisting -and $existing[0].Bindings -like "*:$($Project.Port):*") {
            Write-Log "Website '$($Project.Name)' existiert bereits mit Port $($Project.Port) - wird weiterverwendet." 'Info'
            $r = Invoke-AppCmd @('start', 'site', "/site.name:$($Project.Name)")
            $state = @(Get-IisSites | Where-Object { $_.Name -eq $Project.Name })
            if ($state.Count -gt 0 -and $state[0].State -eq 'Started') { Write-Log 'Website läuft.' 'Ok'; return }
            throw "Die vorhandene Website konnte nicht gestartet werden: $($r.Output)"
        }
        if (-not $ReplaceExisting) {
            throw "Eine Website mit dem Namen '$($Project.Name)' existiert bereits (anderer Port). Auf der Seite 'Prüfen' das Ersetzen erlauben oder die Website vorher im IIS-Manager entfernen."
        }
        Write-Log "Vorhandene Website '$($Project.Name)' wird entfernt ..." 'Info'
        $r = Invoke-AppCmd @('delete', 'site', "/site.name:$($Project.Name)")
        if ($r.ExitCode -ne 0) { throw "Vorhandene Website konnte nicht entfernt werden: $($r.Output)" }
        Write-Log 'Alte Website entfernt (der Projektordner bleibt unberührt).' 'Ok'
    }

    if (-not (Test-Path -LiteralPath $Project.DocRoot)) {
        throw "Der Website-Pfad existiert nicht: $($Project.DocRoot)"
    }

    Write-Log ("Lege Website an: {0}  ->  {1}  (Port {2})" -f $Project.Name, $Project.DocRoot, $Project.Port) 'Info'
    $r = Invoke-AppCmd @('add', 'site',
        "/name:$($Project.Name)",
        "/physicalPath:$($Project.DocRoot)",
        "/bindings:http/*:$($Project.Port):")
    if ($r.ExitCode -ne 0) { throw "appcmd add site fehlgeschlagen: $($r.Output)" }
    Write-Log 'Website angelegt.' 'Ok'

    # "Website sofort starten": neu angelegte Sites starten normalerweise von
    # selbst; falls nicht (z. B. Portkonflikt), liefert der Start die Ursache.
    $r = Invoke-AppCmd @('start', 'site', "/site.name:$($Project.Name)")
    if ($r.ExitCode -eq 0) {
        Write-Log 'Website gestartet.' 'Ok'
    } else {
        $state = @(Get-IisSites | Where-Object { $_.Name -eq $Project.Name })
        if ($state.Count -gt 0 -and $state[0].State -eq 'Started') {
            Write-Log 'Website läuft bereits.' 'Ok'
        } else {
            throw "Die Website wurde angelegt, konnte aber nicht gestartet werden: $($r.Output)"
        }
    }
}

# ==============================================================================
#  5) MySQL: mysql.exe finden, Passwort lesen, Skripte ausführen
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
        $args = @("--defaults-extra-file=`"$cnf`"", '--default-character-set=utf8mb4', '--batch')
        if ($Database) { $args += "--database=`"$Database`"" }
        return Invoke-ExeCapture -FilePath $exe -ArgumentList $args -StdIn $Sql -TimeoutSec $TimeoutSec
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

function Invoke-MySqlScriptFile {
    param(
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)]$Entry     # @{ Datei; Anzeige; Datenbank }
    )
    if (-not (Test-Path -LiteralPath $Entry.Datei)) { throw "SQL-Datei nicht gefunden: $($Entry.Datei)" }
    $sql = Get-Content -LiteralPath $Entry.Datei -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($sql)) { Write-Log "$($Entry.Anzeige): Datei ist leer - übersprungen." 'Warn'; return }

    $dbInfo = if ($Entry.Datenbank) { " (Datenbank: $($Entry.Datenbank))" } else { '' }
    Write-Log ("Führe aus: {0}{1}" -f $Entry.Anzeige, $dbInfo) 'Info'
    $r = Invoke-MySql -Password $Password -Sql $sql -Database $Entry.Datenbank
    if ($r.ExitCode -ne 0) {
        $err = ($r.Error.Trim() -split "`r?`n" | Select-Object -First 3) -join ' | '
        throw "Fehler in $($Entry.Anzeige): $err"
    }
    # mysql schreibt Warnungen nach stderr, auch bei Exitcode 0
    if ($r.Error.Trim().Length -gt 0) {
        foreach ($w in ($r.Error.Trim() -split "`r?`n" | Select-Object -First 5)) { Write-Log $w 'Warn' }
    }
    Write-Log ("{0} ausgeführt." -f $Entry.Anzeige) 'Ok'
}

# ==============================================================================
#  6) Prüfung des ausgewählten Projekts (Seite 2)
# ==============================================================================

<#
 Liefert eine Liste von Prüfpunkten (Level Ok/Warn/Error, Name, Text) für das
 ausgewählte Projekt. Fehler blockieren die Installation.
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

    if (Test-Path -LiteralPath $Project.Dir) {
        & $add 'Ok' 'Projektordner' $Project.Dir
    } else {
        & $add 'Error' 'Projektordner' "$($Project.Dir) existiert nicht."
    }

    if ($Project.DocRoot -ne $Project.Dir) {
        if (Test-Path -LiteralPath $Project.DocRoot) { & $add 'Ok' 'Docroot' $Project.DocRoot }
        else { & $add 'Error' 'Docroot' "$($Project.DocRoot) existiert nicht." }
    }
    if (Test-Path -LiteralPath (Join-Path $Project.DocRoot 'index.php')) {
        & $add 'Ok' 'index.php' 'vorhanden'
    } else {
        & $add 'Warn' 'index.php' "nicht in $($Project.DocRoot) gefunden - Startseite prüfen."
    }

    # Portlage: eigene Site gleichen Namens ist ok (wird ersetzt), fremde nicht
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

    foreach ($s in $Project.Sql) {
        if (Test-Path -LiteralPath $s.Datei) { & $add 'Ok' 'SQL' $s.Anzeige }
        else { & $add 'Error' 'SQL' "$($s.Anzeige) nicht gefunden ($($s.Datei))" }
    }
    if ($Project.Sql.Count -eq 0) { & $add 'Warn' 'SQL' 'Keine SQL-Dateien eingetragen - der Datenbankschritt entfällt.' }

    if ($Project.Sql.Count -gt 0) {
        $exe = Find-MySqlExe
        if ($exe) { & $add 'Ok' 'mysql.exe' $exe }
        else { & $add 'Error' 'mysql.exe' 'nicht gefunden - Pfad in projekte.json unter einstellungen.mysqlBin eintragen.' }
    }

    foreach ($c in $Project.ConfigFiles) {
        $target = Expand-ProjectText $c.Datei $Project
        $tplRaw = Expand-ProjectText $c.Vorlage $Project
        if (Test-Path -LiteralPath $target) {
            & $add 'Ok' 'Konfig' $target
            continue
        }
        $tpl = Find-ConfigTemplate -Target $target -Explicit $tplRaw
        if ($tpl) {
            & $add 'Ok' 'Konfig' "$([System.IO.Path]::GetFileName($target)) fehlt noch - wird bei der Installation aus '$([System.IO.Path]::GetFileName($tpl))' erstellt."
        } elseif ($tplRaw) {
            & $add 'Error' 'Konfig' "Weder $target noch die angegebene Vorlage $tplRaw sind vorhanden."
        } else {
            & $add 'Warn' 'Konfig' "$target noch nicht vorhanden (entsteht eventuell erst beim Setup)."
        }
    }

    $blocked = (@($items | Where-Object { $_.Level -eq 'Error' }).Count -gt 0)
    [pscustomobject]@{ Ok = (-not $blocked); Items = $items.ToArray() }
}

# ==============================================================================
#  7) Installationsablauf (Seite 3)
# ==============================================================================

<#
 Schrittplan: Website, jede SQL-Datei einzeln (damit die Schrittliste und die
 Ergebnisübersicht pro Datei ein Häkchen oder Kreuz zeigen können) und zum
 Schluss das Anlegen fehlender Konfigurationsdateien aus ihren Vorlagen.
#>
function Get-StepPlan {
    param($Project)
    $steps = New-Object System.Collections.Generic.List[object]
    $steps.Add(@{ Key = 'site'; Title = 'IIS-Website anlegen'; Entry = $null })
    foreach ($s in $Project.Sql) {
        $steps.Add(@{ Key = 'sql'; Title = "SQL: $($s.Anzeige)"; Entry = $s })
    }
    if ($Project.ConfigFiles.Count -gt 0) {
        $steps.Add(@{ Key = 'cfg'; Title = 'Konfigurationsdateien vorbereiten'; Entry = $null })
    }
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
 Legt fehlende Konfigurationsdateien aus ihren Vorlagen an. Vorhandene Dateien
 werden nie überschrieben. Liefert die Liste der Zieldateien für die Seite
 "Fertig" (dort öffnen die Schaltflächen dann die echte Datei).
#>
function Initialize-ConfigFiles {
    param($Project)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Project.ConfigFiles) {
        $target = Expand-ProjectText $c.Datei $Project
        $out.Add($target)
        if (Test-Path -LiteralPath $target) {
            Write-Log "Konfig vorhanden: $target"
            continue
        }
        $tpl = Find-ConfigTemplate -Target $target -Explicit (Expand-ProjectText $c.Vorlage $Project)
        if ($tpl) {
            # File::Copy mit overwrite=$false statt Copy-Item: Copy-Item ueberschreibt
            # standardmaessig (-Force steuert nur Schreibschutz/versteckte Dateien), waehrend
            # File::Copy eine vorhandene Datei im Dateisystem selbst ablehnt. Damit kann auch
            # eine Datei, die zwischen Test-Path und Kopie entsteht, nicht verlorengehen.
            try {
                [System.IO.File]::Copy($tpl, $target, $false)
                Write-Log ("Aus Vorlage erstellt: {0}  (Quelle: {1})" -f $target, [System.IO.Path]::GetFileName($tpl)) 'Ok'
            } catch [System.IO.IOException] {
                Write-Log ("Konfig war bereits vorhanden, Vorlage nicht kopiert: {0}" -f $target) 'Warn'
            } catch {
                Write-Log ("Vorlage konnte nicht kopiert werden: {0} -> {1} ({2})" -f $tpl, $target, $_.Exception.Message) 'Warn'
            }
        } else {
            Write-Log "Keine Vorlage für $target gefunden - Datei entsteht eventuell erst beim Projekt-Setup." 'Warn'
        }
    }
    return $out.ToArray()
}

<#
 Führt den Schrittplan aus. SQL-Dateien werden alle abgearbeitet, auch wenn
 eine davon fehlschlägt - so zeigt die Schrittliste am Ende für jede Datei
 Häkchen oder Kreuz, statt beim ersten Fehler stehen zu bleiben. Schlägt
 dagegen schon das Anlegen der Website fehl, wird abgebrochen.
 Jedes SQL-Ergebnis landet zusätzlich in $script:Result.SqlResults für die
 Übersicht auf der Seite "Fertig".
#>
function Invoke-ProjectInstall {
    $p = $script:Sel
    $script:Result = @{
        Success    = $false
        Error      = $null
        SiteUrl    = "http://localhost:$($p.Port)/"
        SetupUrl   = (Expand-ProjectText $p.SetupUrl $p)
        Configs    = @($p.ConfigFiles | ForEach-Object { Expand-ProjectText $_.Datei $p })
        SqlResults = @()
        Name       = $p.Name
        Datenbank  = $p.Datenbank
    }
    $plan       = Get-StepPlan $p
    $sqlResults = New-Object System.Collections.Generic.List[object]
    $failed     = New-Object System.Collections.Generic.List[string]
    $i = 0
    try {
        Set-Busy $true
        Write-Log ("=== Installation '{0}' gestartet ===" -f $p.Name) 'Step'
        $pw = $script:TxtRootPw.Text

        for ($i = 0; $i -lt $plan.Count; $i++) {
            $step = $plan[$i]
            Set-StepState $i 'Running'
            switch ($step.Key) {
                'site' {
                    Write-Log 'IIS-Website anlegen' 'Step'
                    New-ProjectSite -Project $p -ReplaceExisting ([bool]$script:ChkReplace.Checked)
                    Set-StepState $i 'Done'
                }
                'sql' {
                    try {
                        Invoke-MySqlScriptFile -Password $pw -Entry $step.Entry
                        $sqlResults.Add(@{ Anzeige = $step.Entry.Anzeige; Ok = $true; Text = 'ausgeführt' })
                        Set-StepState $i 'Done'
                    } catch {
                        $msg = $_.Exception.Message
                        $sqlResults.Add(@{ Anzeige = $step.Entry.Anzeige; Ok = $false; Text = $msg })
                        $failed.Add($step.Entry.Anzeige)
                        Write-Log $msg 'Error'
                        Set-StepState $i 'Failed'
                    }
                }
                'cfg' {
                    Write-Log 'Konfigurationsdateien' 'Step'
                    $script:Result.Configs = @(Initialize-ConfigFiles $p)
                    Set-StepState $i 'Done'
                }
            }
        }

        $script:Result.SqlResults = $sqlResults.ToArray()
        if ($failed.Count -gt 0) {
            $script:Result.Error = ("{0} von {1} SQL-Skripten fehlgeschlagen: {2}. Einzelheiten in der Schrittliste und im Protokoll." -f `
                $failed.Count, @($p.Sql).Count, ($failed -join ', '))
            Write-Log ("=== Installation '{0}' mit Fehlern beendet ===" -f $p.Name) 'Error'
            return $false
        }
        $script:Result.Success = $true
        Write-Log ("=== Installation '{0}' abgeschlossen ===" -f $p.Name) 'Ok'
        return $true
    } catch {
        Set-StepState $i 'Failed'
        $script:Result.SqlResults = $sqlResults.ToArray()
        $script:Result.Error = $_.Exception.Message
        Write-Log $_.Exception.Message 'Error'
        return $false
    } finally {
        Set-Busy $false
    }
}
# ==============================================================================
#  8) Oberfläche: Grundgerüst
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
$script:FormH = 640
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
New-Label $header 26 38 500 18 'IIS-Website und Datenbank für ein vorbereitetes Projekt' ([System.Drawing.Color]::FromArgb(170, 190, 210)) | Out-Null
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
#  9) Seite 1: Projekt auswählen
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
[void]$script:LvProjects.Columns.Add('Projekt', 240)
[void]$script:LvProjects.Columns.Add('Port', 70)
[void]$script:LvProjects.Columns.Add('Website-Pfad', $pw - 240 - 70 - 130 - 8)
[void]$script:LvProjects.Columns.Add('Datenbank', 130)
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
        [void]$item.SubItems.Add($p.DocRoot)
        [void]$item.SubItems.Add($(if ($p.Sql.Count -gt 0) { "$($p.Sql.Count) SQL-Datei(en)" } else { '-' }))
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
# 10) Seite 2: Prüfen
# ==============================================================================

$script:PnlCheck = New-Page
$script:LblCheckHead = New-Label $script:PnlCheck 0 0 $pw 30 'Prüfen' $script:ColDark $fontHead

$script:LvCheck = New-Object System.Windows.Forms.ListView
$script:LvCheck.Location      = New-Object System.Drawing.Point(0, 40)
$script:LvCheck.Size          = New-Object System.Drawing.Size($pw, 176)
$script:LvCheck.Anchor        = 'Top,Left,Right'
$script:LvCheck.View          = 'Details'
$script:LvCheck.FullRowSelect = $true
$script:LvCheck.HeaderStyle   = 'None'
$script:LvCheck.Font          = $fontSym
[void]$script:LvCheck.Columns.Add(' ', 34)
[void]$script:LvCheck.Columns.Add('Punkt', 130)
[void]$script:LvCheck.Columns.Add('Ergebnis', $pw - 34 - 130 - 8)
$script:PnlCheck.Controls.Add($script:LvCheck)

$script:ChkReplace = New-Ctl System.Windows.Forms.CheckBox $script:PnlCheck 0 226 $pw 22 'Vorhandene IIS-Website gleichen Namens ersetzen (der Projektordner bleibt unberührt)'

$grpDb = New-Object System.Windows.Forms.GroupBox
$grpDb.Text     = ' Datenbank (root) '
$grpDb.Location = New-Object System.Drawing.Point(0, 256)
$grpDb.Size     = New-Object System.Drawing.Size($pw, 108)
$grpDb.Anchor   = 'Top,Left,Right'
$script:PnlCheck.Controls.Add($grpDb)

New-Label $grpDb 16 28 110 20 'root-Passwort:' | Out-Null
$script:TxtRootPw = New-Ctl System.Windows.Forms.TextBox $grpDb 130 25 300 24
$script:TxtRootPw.UseSystemPasswordChar = $true
$script:ChkShowPw = New-Ctl System.Windows.Forms.CheckBox $grpDb 440 26 90 22 'anzeigen'
$script:BtnTestDb = New-Ctl System.Windows.Forms.Button $grpDb 540 24 170 27 'Verbindung testen'
$script:LblPwSource = New-Label $grpDb 130 54 ($pw - 150) 18 '' $script:ColGray
$script:LblDbTest   = New-Label $grpDb 130 76 ($pw - 150) 20 '' $script:ColGray

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

    # Ersetzen-Kästchen nur anbieten, wenn es etwas zu ersetzen gibt
    $exists = (@(Get-IisSites | Where-Object { $_.Name -eq $p.Name }).Count -gt 0)
    $script:ChkReplace.Visible = $exists
    if (-not $exists) { $script:ChkReplace.Checked = $false }

    # Datenbankteil nur zeigen, wenn SQL-Dateien anstehen
    $grpDb.Visible = ($p.Sql.Count -gt 0)
    if ($p.Sql.Count -gt 0 -and [string]::IsNullOrEmpty($script:TxtRootPw.Text)) {
        $saved = Get-SavedRootPassword
        if ($saved) {
            $script:TxtRootPw.Text = $saved
            $script:LblPwSource.Text = "Automatisch gelesen aus: $script:CredFile"
        } else {
            $script:LblPwSource.Text = 'Keine gespeicherten Zugangsdaten gefunden - Passwort bitte eingeben (die my.ini enthält kein Passwort).'
        }
    }
    $script:LblDbTest.Text = ''

    $script:LblCheckHint.Text = if ($res.Ok) {
        'Alles bereit. "Installieren" legt die Website an' + $(if ($p.Sql.Count -gt 0) { ' und führt danach die SQL-Skripte aus.' } else { '.' })
    } else {
        'Rot markierte Punkte verhindern die Installation. Ursache beheben und mit "Zurück" / "Weiter" erneut prüfen.'
    }
    Update-NextState
}

# ==============================================================================
# 11) Seite 3: Installation
# ==============================================================================

$script:PnlInstall = New-Page
$script:LblInstHead = New-Label $script:PnlInstall 0 0 $pw 30 'Installation' $script:ColDark $fontHead

$script:LvSteps = New-Object System.Windows.Forms.ListView
$script:LvSteps.Location      = New-Object System.Drawing.Point(0, 40)
$script:LvSteps.Size          = New-Object System.Drawing.Size(300, ($ph - 40 - 76))
$script:LvSteps.View          = 'Details'
$script:LvSteps.HeaderStyle   = 'None'
$script:LvSteps.Font          = $fontSym
$script:LvSteps.FullRowSelect = $true
[void]$script:LvSteps.Columns.Add(' ', 30)
[void]$script:LvSteps.Columns.Add('Schritt', 260)
$script:PnlInstall.Controls.Add($script:LvSteps)

$script:LogBox = New-Object System.Windows.Forms.RichTextBox
$script:LogBox.Location   = New-Object System.Drawing.Point(312, 40)
$script:LogBox.Size       = New-Object System.Drawing.Size(($pw - 312), ($ph - 40 - 76))
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
# 12) Seite 4: Fertig
# ==============================================================================

$script:PnlFinish = New-Page
$script:LblFinHead = New-Label $script:PnlFinish 0 0 $pw 30 'Fertig' $script:ColDark $fontHead
$script:LblFinText = New-Label $script:PnlFinish 0 38 $pw 36 '' $script:ColGray
$script:LblFinText.Anchor = 'Top,Left,Right'

# Ergebnis der Datenbank-Skripte: eine Zeile pro Datei mit Häkchen/Kreuz.
# Wird in Load-FinishPage befüllt und in der Höhe an die Anzahl angepasst;
# die Elemente darunter rücken entsprechend nach.
$script:LblSqlRes = New-Label $script:PnlFinish 0 80 $pw 22 'Datenbank-Skripte' $script:ColDark $fontBig
$script:LvSqlRes = New-Object System.Windows.Forms.ListView
$script:LvSqlRes.Location      = New-Object System.Drawing.Point(0, 106)
$script:LvSqlRes.Size          = New-Object System.Drawing.Size($pw, 80)
$script:LvSqlRes.Anchor        = 'Top,Left,Right'
$script:LvSqlRes.View          = 'Details'
$script:LvSqlRes.HeaderStyle   = 'None'
$script:LvSqlRes.Font          = $fontSym
$script:LvSqlRes.FullRowSelect = $true
[void]$script:LvSqlRes.Columns.Add(' ', 34)
[void]$script:LvSqlRes.Columns.Add('Datei', 300)
[void]$script:LvSqlRes.Columns.Add('Ergebnis', $pw - 34 - 300 - 8)
$script:PnlFinish.Controls.Add($script:LvSqlRes)

# Datenbank-Zugangsdaten: was in die Konfigurationsdatei des Projekts gehoert.
# Werte in fester Schrift (leichter abzutippen), Zusatzhinweis darunter in der
# normalen Schrift - dessen Hoehe wird gemessen, damit nichts abgeschnitten wird.
$script:LblDbHead = New-Label $script:PnlFinish 0 86 $pw 22 'Datenbank-Zugang' $script:ColDark $fontBig
$script:LblDbInfo = New-Label $script:PnlFinish 0 110 $pw 60 '' $script:ColDark
$script:LblDbInfo.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$script:LblDbNote = New-Label $script:PnlFinish 0 170 $pw 34 '' $script:ColGray

$script:LblNextSteps = New-Label $script:PnlFinish 0 92 $pw 22 'Nächste Schritte' $script:ColDark $fontBig

# FlowLayoutPanel: nimmt beliebig viele Schaltflächen auf (Setup-URL und
# Konfigurationsdateien unterscheiden sich je Projekt)
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
    $script:LblFinText.Text = "Die Website läuft unter $($r.SiteUrl)" +
        $(if ($r.SetupUrl) { " - als Nächstes das Setup des Projekts aufrufen und die aufgeführten Dateien prüfen." }
          elseif (@($r.Configs).Count -gt 0) { " - bitte noch die aufgeführten Konfigurationsdateien prüfen." }
          else { "." })

    # SQL-Ergebnisübersicht: pro Datei Häkchen oder Kreuz
    $sqlRes = @($r.SqlResults)
    $y = 80
    if ($sqlRes.Count -gt 0) {
        $script:LblSqlRes.Visible = $true
        $script:LvSqlRes.Visible  = $true
        $script:LblSqlRes.Top = $y
        $script:LvSqlRes.Top  = $y + 26
        $script:LvSqlRes.BeginUpdate()
        $script:LvSqlRes.Items.Clear()
        foreach ($e in $sqlRes) {
            $sym = if ($e.Ok) { [char]0x2713 } else { [char]0x2717 }
            $item = New-Object System.Windows.Forms.ListViewItem([string]$sym)
            [void]$item.SubItems.Add($e.Anzeige)
            [void]$item.SubItems.Add($e.Text)
            $item.ForeColor = if ($e.Ok) { $script:ColOk } else { $script:ColErr }
            $item.UseItemStyleForSubItems = $true
            [void]$script:LvSqlRes.Items.Add($item)
        }
        $script:LvSqlRes.EndUpdate()
        $script:LvSqlRes.Height = [math]::Min(120, ($sqlRes.Count * 22) + 8)
        $y = $script:LvSqlRes.Top + $script:LvSqlRes.Height + 14
    } else {
        $script:LblSqlRes.Visible = $false
        $script:LvSqlRes.Visible  = $false
    }

    # Datenbank-Zugangsdaten anzeigen - nur wenn die Installation geklappt hat
    # und in der JSON etwas hinterlegt ist. Die Werte stammen aus den
    # SQL-Skripten des Projekts; genau sie gehoeren in dessen Konfigurationsdatei.
    $db = $r.Datenbank
    if ($r.Success -and $db -and ($db.Benutzer -or $db.Name)) {
        $lines = New-Object System.Collections.Generic.List[string]
        if ($db.Name)     { $lines.Add(("Datenbank :  {0}" -f $db.Name)) }
        if ($db.Benutzer) { $lines.Add(("Benutzer  :  {0}" -f $db.Benutzer)) }
        if ($db.Passwort) { $lines.Add(("Passwort  :  {0}" -f $db.Passwort)) }

        $script:LblDbHead.Visible = $true
        $script:LblDbInfo.Visible = $true
        $script:LblDbHead.Top    = $y
        $script:LblDbInfo.Top    = $y + 26
        $script:LblDbInfo.Text   = ($lines -join [Environment]::NewLine)
        $script:LblDbInfo.Height = ($lines.Count * 17) + 4
        $y = $script:LblDbInfo.Top + $script:LblDbInfo.Height

        if ($db.Hinweis) {
            # Hoehe messen statt schaetzen - der Hinweis ist oft mehrzeilig.
            $prop = New-Object System.Drawing.Size($pw, 0)
            $size = [System.Windows.Forms.TextRenderer]::MeasureText(
                        [string]$db.Hinweis, $script:LblDbNote.Font, $prop,
                        [System.Windows.Forms.TextFormatFlags]::WordBreak)
            $script:LblDbNote.Visible = $true
            $script:LblDbNote.Top     = $y + 6
            $script:LblDbNote.Text    = [string]$db.Hinweis
            $script:LblDbNote.Height  = $size.Height + 4
            $y = $script:LblDbNote.Top + $script:LblDbNote.Height
        } else {
            $script:LblDbNote.Visible = $false
        }
        $y += 14
    } else {
        $script:LblDbHead.Visible = $false
        $script:LblDbInfo.Visible = $false
        $script:LblDbNote.Visible = $false
    }

    # "Nächste Schritte" und die Schaltflächen unter die Übersicht schieben
    $script:LblNextSteps.Top = $y
    $script:FlowFinish.Top    = $y + 28
    $script:FlowFinish.Height = [math]::Max(60, $ph - $script:FlowFinish.Top - 56)

    $script:FlowFinish.Controls.Clear()
    if ($r.SetupUrl) {
        Add-FinishButton -Accent -Text "Projekt-Setup öffnen: $($r.SetupUrl)" -OnClick { Open-InBrowser $script:Result.SetupUrl | Out-Null }
    }
    Add-FinishButton -Text "Website öffnen: $($r.SiteUrl)" -OnClick { Open-InBrowser $script:Result.SiteUrl | Out-Null }
    foreach ($c in @($r.Configs)) {
        $cLocal = $c   # Wert für den Klick festhalten (Schleifenvariable!)
        Add-FinishButton -Text ("Bearbeiten: {0}" -f $cLocal) -OnClick ([scriptblock]::Create("Open-InNotepad '$($cLocal.Replace("'","''"))'"))
    }
    Add-FinishButton -Text 'Protokolldatei öffnen' -OnClick { Open-InNotepad $script:LogFile }
    Add-FinishButton -Text 'Weiteres Projekt installieren' -OnClick {
        $script:Sel = $null
        $script:LvProjects.SelectedItems.Clear()
        Show-Page 'select'
    }

    $script:LblFinNote.Text = 'Hinweis: Die SQL-Skripte haben Datenbank und Benutzer angelegt. Dieselben Zugangsdaten müssen in der Konfigurationsdatei des Projekts eingetragen sein - das Passwort danach in der Datenbank ändern.'
}

# ==============================================================================
# 13) Seitensteuerung
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
    if ($p.Sql.Count -gt 0 -and [string]::IsNullOrEmpty($script:TxtRootPw.Text)) {
        Show-Warn 'Bitte zuerst das root-Passwort eingeben (Feld "Datenbank").'
        return
    }
    $sqlText = if ($p.Sql.Count -gt 0) { "`nSQL-Skripte: $($p.Sql.Count)" } else { "`nSQL-Skripte: keine" }
    if (-not (Show-Confirm ("Projekt '{0}' wird eingerichtet:`n`nWebsite:  {0} (Port {1})`nPfad:     {2}{3}`n`nJetzt starten?" -f $p.Name, $p.Port, $p.DocRoot, $sqlText) 'Installation starten')) { return }

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
# 14) Ereignisse
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
$script:Form.MinimumSize = New-Object System.Drawing.Size(820, 560)
try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w  = [math]::Min($script:Form.Width,  [int]($wa.Width  * 0.98))
    $h  = [math]::Min($script:Form.Height, [int]($wa.Height * 0.98))
    if ($w -lt $script:Form.Width -or $h -lt $script:Form.Height) {
        $script:Form.Size = New-Object System.Drawing.Size([math]::Max(820, $w), [math]::Max(560, $h))
    }
} catch { }

# ==============================================================================
# 15) Start
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