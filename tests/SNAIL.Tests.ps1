<#
 tests/SNAIL.Tests.ps1  -  FUNKTIONSTESTS FUER SNAIL (Linux oder Windows, PowerShell 7)

 Laedt die Funktionen aus Projekt-Installer.ps1 ueber den Parser (die
 Oberflaeche startet dabei nicht) und prueft sie gegen die echte
 projektvorlage, PHP und PostgreSQL:
   - Kommandozeilen-Maskierung (Rundreise ueber php)
   - config.php aus der echten config.example.php: Escaping, ohne BOM,
     php -l, Ladeversuch, keine fehlenden Schluessel, optional python.exe
   - app.key (7.3): Format gegen SecretBox::parseKey, Neuinstallation,
     Ergaenzen in einer vorhandenen config.php (Text und Datei, Sicherung,
     zweiter Lauf, vorhanden/leer/ungueltig, Fallback, keine Werte in Ausgaben)
   - Katalog (projekte.json im Repository, Vorlage, Fehlerfaelle)
   - Eingaben einer Neuinstallation, Ordnernamen, Datenpfade, Ports
   - Installationen am Server erkennen (php bin\console info, auch mit
     ausgetauschtem Katalog, config.php mit BOM, aelterer Stand ohne db)
   - services.json: Angleichen, Reihenfolge, fremde Felder, Regeln, Lesen mit
     ServiceDirectory::parse() der Vorlage
   - Logos, WIPP-Zugangsdaten, check-Ausgabe
   - PostgreSQL: Superuser per pgpass, Rolle + Datenbank anlegen und
     wiederholen, Anmeldung mit dem SCRAM-Hash, pg_dump nach <Daten>\Sicherung
   - Durchlauf mit der Vorlage aus einer GitHub-ZIP: config.php ->
     migrate -> user:create -> services.json -> check -> Erkennung am Server

 Aufruf:
   pwsh tests/SNAIL.Tests.ps1 -Vorlage ../projektvorlage -PgPassword '<Passwort postgres>' -PgBin /usr/lib/postgresql/18/bin
 Ohne -PgPassword (bzw. $env:SNAIL_PG_PASSWORD) entfallen die PostgreSQL-Tests.
#>
param(
    [string]$Vorlage = (Join-Path $PSScriptRoot '../../projektvorlage'),
    [string]$PgPassword = $env:SNAIL_PG_PASSWORD,
    [string]$PgBin = '/usr/lib/postgresql/16/bin',
    [int]$PgPort = 5432,
    [string]$Php = 'php'
)

$ErrorActionPreference = 'Stop'
$Vorlage = (Resolve-Path $Vorlage).Path
$PhpExe = (Get-Command $Php).Source
$skript = Join-Path $PSScriptRoot '../Projekt-Installer.ps1'

# --- Funktionen laden ----------------------------------------------------------
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $skript).Path, [ref]$tok, [ref]$err)
if ($err.Count -gt 0) { throw "Parserfehler: $($err[0].Message)" }
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach ($v in @('$script:KnownNeeds', '$script:OptionalConfigKeys', '$script:PhpConfigHelpers', '$script:PhpConfigState', '$script:PhpConfigVerify', '$script:ConfigV4Keys')) {
    $a = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $v }, $true)
    . ([scriptblock]::Create($a.Extent.Text))
}
# Stubs fuer alles, was Windows oder die Oberflaeche braucht
function Write-Log { param([string]$Message, [string]$Level = 'Info') if ($env:SNAIL_TEST_VERBOSE) { Write-Host "    [$Level] $Message" } }
function Invoke-UiPump { }
# Unter Windows schuetzt die ACL die pgpass-Datei, unter Linux verlangt libpq 0600
function Protect-AdminOnly { param([string]$Path) if (-not $IsWindows -and (Test-Path -LiteralPath $Path -PathType Leaf)) { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite') } }
function Initialize-SnailDir { if (-not (Test-Path $script:SnailDir)) { New-Item -ItemType Directory -Path $script:SnailDir | Out-Null } }
$script:TestSitePaths = @{}
function Get-IisSitePath { param([string]$Name) return $script:TestSitePaths[$Name] }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('snail-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:FormatVersion = 1
$script:SnailDir   = Join-Path $tmp 'ProgramData/SNAIL'
$script:CredDir    = Join-Path $script:SnailDir 'zugangsdaten'
$script:StagingDir = Join-Path $tmp 'staging'
$script:Settings = [pscustomobject]@{ ProgRoot = 'C:\AK'; DataRoot = 'D:\AK'; Zeitzone = 'Europe/Berlin'; PhpExe = ''; PsqlBin = ''; PgPort = 0; PortStart = 21100 }

# --- Mini-Testrahmen -------------------------------------------------------------
$script:ok = 0; $script:fail = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:ok++; Write-Host "  OK    $Name" }
    catch { $script:fail++; Write-Host "  FEHLER $Name`n         $($_.Exception.Message)`n         $($_.InvocationInfo.PositionMessage -replace "`n", "`n         ")" -ForegroundColor Red }
}
function Assert([bool]$Cond, [string]$Msg = 'Bedingung nicht erfuellt') { if (-not $Cond) { throw $Msg } }
function Assert-Equal($Expected, $Actual, [string]$Msg = '') {
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = ($Expected | ConvertTo-Json -Compress -Depth 5); $a = ($Actual | ConvertTo-Json -Compress -Depth 5)
        if ($e -ne $a) { throw "$Msg erwartet $e, ist $a" }
    } elseif ($Expected -cne $Actual) { throw "$Msg erwartet '$Expected', ist '$Actual'" }
}
function Invoke-Php([string]$Code, [string[]]$Arguments = @()) {
    $r = Invoke-ExeCapture -FilePath $PhpExe -ArgumentList (ConvertTo-CmdArgs (@('-r', $Code) + $Arguments)) -Utf8Output -TimeoutSec 60
    if ($r.ExitCode -ne 0) { throw "php: $($r.Lines -join ' ')" }
    return $r.Output
}

Write-Host "SNAIL-Tests (Vorlage: $Vorlage, PHP: $PhpExe)"

# Katalog aus dem Repository und eine Eingabe fuer eine Neuinstallation
$json = Get-Content (Join-Path $PSScriptRoot '../projekte.json') -Raw | ConvertFrom-Json
$catalog = ConvertFrom-ProjectJson -Json $json -BaseDir (Join-Path $PSScriptRoot '..')
$svc = $catalog.Services['projekt']
function New-TestValues([hashtable]$Over = @{}) {
    $v = @{ Key = 'muster'; Name = 'Muster GmbH'; Url = ''; Port = '21100'; UploadsMaxMb = '250'; AdminLogin = 'admin'; AdminName = 'Administrator'
            AdminEmail = ''; DataDir = 'D:\AK\projekt'; Paths = $null; Firewall = $false; CfTeam = ''; CfAud = ''; CfGuard = $false
            MailEnabled = $false; MailHost = ''; MailPort = '587'; MailEnc = 'tls'; MailUser = ''; MailPass = ''; MailFrom = ''; MailFromName = '' }
    foreach ($k in $Over.Keys) { $v[$k] = $Over[$k] }
    return $v
}
function New-TestPlan([string]$ProgDir, [string]$DataDir, $Inst) {
    [pscustomobject]@{
        Inst = $Inst; Kind = 'new'; Mode = 'install'; Ordner = (Split-Path -Leaf $ProgDir); ProgRoot = (Split-Path -Parent $ProgDir); ProgDir = $ProgDir
        DataDir = $DataDir; Paths = (Get-DefaultPaths -DataDir $DataDir); AclDataDirs = @($DataDir)
        ServicesJson = (Join-Path (Split-Path -Parent $ProgDir) 'services.json'); Source = $null; PhpExe = $PhpExe
        Pg = [pscustomobject]@{ Bin = $PgBin; Port = $PgPort; Host = 'localhost'; Superuser = 'postgres' }
        DbName = ''; DbUser = ''; ExistingConfig = $null; Template = $null; SkipBackup = $false; PythonExe = $null
    }
}

# =============================================================================
Write-Host "`n== Kommandozeile"
Test-Case 'ConvertTo-CmdArg: Rundreise ueber php (Leerzeichen, ", Backslash am Ende, leer)' {
    $werte = @('einfach', 'mit Leerzeichen', 'C:\Program Files\PHP\', 'D:\', 'a"b', 'x\"y', '', 'ü ä ß', 'SELECT "x" | y', 'C:\AK\x')
    $out = Invoke-Php 'echo json_encode(array_slice($argv, 1), JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);' $werte
    Assert-Equal $werte @($out | ConvertFrom-Json)
}

# =============================================================================
Write-Host "`n== Katalog (projekte.json)"
Test-Case 'Katalog im Repository: ohne Fehler, Logos als Dateien, keine Installationen' {
    Assert-Equal 0 $catalog.Errors.Count ($catalog.Errors -join ' | ')
    Assert-Equal 'projekt' $catalog.ServiceList[0].Key
    Assert-Equal 250 $svc.UploadsMaxMb
    $olaf = $catalog.Services['olaf']
    Assert-Equal 'png' $olaf.Logo.Ext 'Logo olaf'
    Assert ($olaf.Logo.Source -like '*logos*olaf.png') "Quelle $($olaf.Logo.Source)"
    Assert ($null -eq $json.installationen) 'keine installationen im Katalog'
    Assert-Equal 21100 $catalog.Settings.PortStart
}
Test-Case 'Vorlage aus dem Skript ("Katalog-Vorlage anlegen") ist gueltig' {
    $t = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:JsonTemplate' }, $true)
    $text = $t.Right.Extent.Text -replace "^@'\r?\n", '' -replace "\r?\n'@$", ''
    $r = ConvertFrom-ProjectJson -Json ($text | ConvertFrom-Json) -BaseDir $tmp
    Assert-Equal 0 $r.Errors.Count ($r.Errors -join ' | ')
    Assert-Equal 'C:\AK' $r.Settings.ProgRoot
    Assert-Equal 1 $r.ServiceList.Count
}
Test-Case 'Fehlerfaelle: altes Format, installationen, doppelter key, ungueltige Werte, unbekanntes braucht' {
    $alt = '{"einstellungen":{},"projekte":[{"name":"Manfred","ordner":"manfred","port":1011}]}' | ConvertFrom-Json
    $r = ConvertFrom-ProjectJson -Json $alt -BaseDir $tmp
    Assert ($r.Errors[0] -match 'alte Format') 'altes Format erkannt'
    $j = @'
{ "format": 1, "einstellungen": { "portStart": 80 },
  "dienste": [ { "key": "olaf", "name": "Olaf", "braucht": ["python", "java"], "uploadsMaxMb": 9000 }, { "key": "olaf", "name": "x" }, { "key": "Renate", "name": "R" }, { "key": "x" } ],
  "installationen": [ { "dienst": "olaf", "port": 8081 } ] }
'@ | ConvertFrom-Json
    $r = ConvertFrom-ProjectJson -Json $j -BaseDir $tmp
    Assert-Equal 1 $r.ServiceList.Count 'nur olaf ist gueltig'
    Assert-Equal 25 $r.ServiceList[0].UploadsMaxMb 'ungueltiges uploadsMaxMb -> 25'
    Assert-Equal 'python,java' ($r.ServiceList[0].Needs -join ',')
    Assert-Equal 21100 $r.Settings.PortStart 'portStart 80 abgelehnt'
    Assert-Equal 7 $r.Errors.Count ($r.Errors -join ' | ')
}

# =============================================================================
Write-Host "`n== Eingaben einer Neuinstallation"
Test-Case 'New-InstanceInput: Standardwerte, Ordner = Dienst, Datenbank, URL' {
    $r = New-InstanceInput -Service $svc -Values (New-TestValues)
    Assert-Equal 0 $r.Errors.Count ($r.Errors -join ' | ')
    $i = $r.Inst
    Assert-Equal 'projekt' $i.Ordner; Assert-Equal 'projekt' $i.DbName; Assert-Equal 'projekt_user' $i.DbUser
    Assert-Equal 'http://localhost:21100/' $i.Url
    Assert-Equal 'D:\AK\projekt\Temp' ($i.Paths.Temp -replace '/', '\')
    Assert-Equal 'Projektvorlage - Muster GmbH' $i.Display
    Assert ($null -eq $i.Mail -and $null -eq $i.Cloudflare) 'ohne Mail/Cloudflare'
}
Test-Case 'New-InstanceInput: Fehler (Schluessel, Port, URL, Upload, E-Mail, Mail unvollstaendig, Datenordner)' {
    $r = New-InstanceInput -Service $svc -Values (New-TestValues @{ Key = 'Muster'; Port = '70000'; Url = 'ftp://x'; UploadsMaxMb = '0'; AdminEmail = 'kein'; MailEnabled = $true; DataDir = 'relativ' })
    Assert-Equal 7 $r.Errors.Count ($r.Errors -join ' | ')
}
Test-Case 'New-InstanceInput: Cloudflare, Mail, angepasste Pfade, Hinweis bei halber Cloudflare-Angabe' {
    $p = [pscustomobject]@{ Data = 'E:\Daten\Data'; Cache = 'D:\Cache\projekt'; Logs = 'D:\AK\projekt\Logs'; Temp = 'E:\Daten\Temp' }
    $r = New-InstanceInput -Service $svc -Values (New-TestValues @{ CfTeam = 'muster'; Url = 'https://projekt.muster.de/'; MailHost = 'smtp.x.de'; MailFrom = 'a@x.de'; MailEnabled = $true; MailPass = " p'w "; Paths = $p })
    Assert-Equal 0 $r.Errors.Count ($r.Errors -join ' | ')
    Assert-Equal 1 $r.Hints.Count
    Assert-Equal " p'w " $r.Inst.Mail.Password 'Passwort ungetrimmt'
    Assert-Equal 'E:\Daten\Data' $r.Inst.Paths.Data
    Assert-Equal 'https://projekt.muster.de/' $r.Inst.Url
}
Test-Case 'Resolve-Ordner / New-InstanceInput: zweiter Mandant, schon installiert, Name belegt' {
    $inst = @([pscustomobject]@{ ServiceKey = 'projekt'; Key = 'muster'; Ordner = 'projekt' })
    $r = New-InstanceInput -Service $svc -Values (New-TestValues @{ Key = 'beispiel' }) -Instances $inst
    Assert-Equal 'projekt-beispiel' $r.Inst.Ordner; Assert-Equal 'projekt_beispiel' $r.Inst.DbName
    $r = New-InstanceInput -Service $svc -Values (New-TestValues) -Instances $inst
    Assert ($r.Errors[0] -match 'schon installiert') ($r.Errors -join ' | ')
    Assert-Equal 'projekt-muster' (Resolve-Ordner -ServiceKey 'projekt' -InstKey 'muster' -FirstFree $false -FirstReason 'x').Name
    Assert-Equal 'projekt' (Resolve-Ordner -ServiceKey 'projekt' -InstKey 'muster' -Instances $inst).Name
}
Test-Case 'Test-FirstOrdnerFree: config.php oder fremde Website belegen <dienst>' {
    $root = Join-Path $tmp 'first'
    New-Item -ItemType Directory -Path (Join-Path $root 'olaf') -Force | Out-Null
    Assert (Test-FirstOrdnerFree -ServiceKey 'olaf' -ProgRoot $root).Free 'Ordner ohne config.php ist frei'
    $script:TestSitePaths = @{ 'Olaf' = 'C:\inetpub\olaf\public' }
    $f = Test-FirstOrdnerFree -ServiceKey 'olaf' -ProgRoot $root -Sites @([pscustomobject]@{ Name = 'Olaf'; Bindings = 'http/*:1002:' })
    Assert (-not $f.Free) 'alte MySQL-Site Olaf'; Assert ($f.Reason -match 'inetpub')
    [System.IO.File]::WriteAllText((Join-Path $root 'olaf/config.php'), '<?php return [];')
    Assert (-not (Test-FirstOrdnerFree -ServiceKey 'olaf' -ProgRoot $root).Free) 'config.php'
}
Test-Case 'Get-DbCollision: Namensgleichheit olaf/muster gegen olaf_muster, Rest, Fortsetzen, fremder Eigentuemer' {
    # "-" -> "_": Ordner olaf-muster und olaf_muster ergeben dieselben Namen
    $a = Get-DefaultDbNames 'olaf-muster'; $b = Get-DefaultDbNames 'olaf_muster'
    Assert-Equal $b.Name $a.Name; Assert-Equal $b.User $a.User
    $inst = @([pscustomobject]@{ Ordner = 'olaf_muster'; ServiceKey = 'olaf_muster'; Key = 'standard'; Error = ''
                                 Db = [pscustomobject]@{ Name = 'olaf_muster'; User = 'olaf_muster_user' } })
    $beide = [pscustomobject]@{ RoleExists = $true; DbExists = $true; DbOwner = 'olaf_muster_user' }
    $nichts = [pscustomobject]@{ RoleExists = $false; DbExists = $false; DbOwner = '' }
    $c = Get-DbCollision -State $beide -DbName $a.Name -Role $a.User -Instances $inst
    Assert-Equal 'Error' $c.Level
    Assert-Equal "Datenbank 'olaf_muster' und Rolle 'olaf_muster_user' gehören zur Installation olaf_muster (olaf_muster/standard)." $c.Text
    Assert (-not $c.Adopt) 'kein Uebernehmen bei fremder Installation'
    # auch wenn es die Datenbank (noch) nicht gibt: die andere Installation ist darauf eingerichtet
    Assert-Equal 'Error' (Get-DbCollision -State $nichts -DbName $a.Name -Role $a.User -Instances $inst).Level
    # nur die Rolle gehoert einer anderen Installation; Fortsetzen hilft dagegen nicht
    $c = Get-DbCollision -State $beide -DbName 'olaf_x' -Role 'olaf_muster_user' -Instances $inst -Resume $true
    Assert-Equal 'Error' $c.Level; Assert ($c.Text -like "Rolle 'olaf_muster_user' gehört zur Installation olaf_muster *") $c.Text
    # frei
    $c = Get-DbCollision -State $nichts -DbName 'olaf_neu' -Role 'olaf_neu_user' -Instances $inst
    Assert-Equal 'Ok' $c.Level; Assert (-not $c.Adopt); Assert ($c.Text -match 'wird angelegt') $c.Text
    # Rest einer entfernten Installation: Warnung mit Pflicht-Haekchen
    $rest = [pscustomobject]@{ RoleExists = $true; DbExists = $true; DbOwner = 'olaf_alt_user' }
    $c = Get-DbCollision -State $rest -DbName 'olaf_alt' -Role 'olaf_alt_user' -Instances $inst
    Assert-Equal 'Warn' $c.Level; Assert $c.Adopt; Assert (-not $c.Resume)
    Assert-Equal "Vorhandene Datenbank 'olaf_alt' übernehmen (alte Daten bleiben erhalten)" $c.Confirm
    $c = Get-DbCollision -State ([pscustomobject]@{ RoleExists = $true; DbExists = $false; DbOwner = '' }) -DbName 'olaf_alt' -Role 'olaf_alt_user'
    Assert $c.Adopt 'nur Rolle vorhanden'; Assert ($c.Confirm -match "Rolle 'olaf_alt_user'") $c.Confirm
    $kaputt = @($inst[0], [pscustomobject]@{ Ordner = 'olaf-kaputt'; Error = 'php bin\console info: x'; Db = $null })
    $c = Get-DbCollision -State $rest -DbName 'olaf_alt' -Role 'olaf_alt_user' -Instances $kaputt
    Assert ($c.Adopt -and $c.Text -match 'Nicht lesbar: olaf-kaputt') $c.Text
    # Fortsetzen nach Abbruch desselben Ordners: ohne Haekchen
    $c = Get-DbCollision -State $rest -DbName 'olaf_alt' -Role 'olaf_alt_user' -Instances $inst -Resume $true
    Assert-Equal 'Ok' $c.Level; Assert ($c.Resume -and -not $c.Adopt)
    # Datenbank gehoert einer anderen Rolle
    $c = Get-DbCollision -State ([pscustomobject]@{ RoleExists = $false; DbExists = $true; DbOwner = 'fremd' }) -DbName 'olaf_alt' -Role 'olaf_alt_user' -Resume $true
    Assert-Equal 'Error' $c.Level; Assert ($c.Text -match "Eigentümer ist 'fremd'") $c.Text
}
Test-Case 'Test-ResumeRun: Zugangsdatei desselben Ordners - passend, aelter als der Programmordner, anderer Name, ohne Ordner' {
    $cred = Join-Path $tmp 'resume/zugangsdaten'
    $prog = Join-Path $tmp 'resume/AK/olaf-muster'
    New-Item -ItemType Directory -Path $cred, $prog -Force | Out-Null
    $f = Join-Path $cred 'olaf-muster.txt'
    Assert (-not (Test-ResumeRun -CredFile $f -ProgDir $prog -DbName 'olaf_muster' -Role 'olaf_muster_user')) 'ohne Zugangsdatei'
    [System.IO.File]::WriteAllText($f, "# x`r`ndb_name=olaf_muster`r`ndb_benutzer=olaf_muster_user`r`ndb_passwort=a=b`r`n")
    Assert (Test-ResumeRun -CredFile $f -ProgDir $prog -DbName 'olaf_muster' -Role 'olaf_muster_user') 'Abbruch nach dem Schritt Datenbank'
    Assert (-not (Test-ResumeRun -CredFile $f -ProgDir $prog -DbName 'olaf_muster' -Role 'andere_user')) 'andere Rolle'
    Assert (-not (Test-ResumeRun -CredFile $f -ProgDir $prog -DbName 'olaf' -Role 'olaf_muster_user')) 'anderer DB-Name'
    Assert (-not (Test-ResumeRun -CredFile $f -ProgDir (Join-Path $tmp 'resume/AK/fehlt') -DbName 'olaf_muster' -Role 'olaf_muster_user')) 'ohne Programmordner (von Hand entfernt)'
    # Zugangsdatei einer frueher von Hand entfernten Installation: aelter als der neue Programmordner
    (Get-Item $f).LastWriteTimeUtc = (Get-Item $prog).CreationTimeUtc.AddDays(-30)
    Assert (-not (Test-ResumeRun -CredFile $f -ProgDir $prog -DbName 'olaf_muster' -Role 'olaf_muster_user')) 'alte Zugangsdatei'
}
Test-Case 'Ordnername: olaf + a-b gegen olaf-a + b; Get-IisNameConflicts (fremde Site, fremder/verwaister Pool, Fortsetzen)' {
    $inst = @([pscustomobject]@{ ServiceKey = 'olaf'; Key = 'x'; Ordner = 'olaf' }, [pscustomobject]@{ ServiceKey = 'olaf-a'; Key = 'y'; Ordner = 'olaf-a' })
    $o1 = (Resolve-Ordner -ServiceKey 'olaf' -InstKey 'a-b' -Instances $inst).Name
    $o2 = (Resolve-Ordner -ServiceKey 'olaf-a' -InstKey 'b' -Instances $inst).Name
    Assert-Equal 'olaf-a-b' $o1; Assert-Equal $o1 $o2 'gleicher Ordner'
    Assert-Equal 'olaf-a-b (olaf/a-b)' (Format-InstanceRef ([pscustomobject]@{ Ordner = 'olaf-a-b'; ServiceKey = 'olaf'; Key = 'a-b'; Error = '' }))
    Assert-Equal 'olaf-a-b (nicht lesbar)' (Format-InstanceRef ([pscustomobject]@{ Ordner = 'olaf-a-b'; Error = 'x' }))
    $prog = Join-Path $tmp 'AKn/olaf-a-b'
    $pub = Join-Path $prog 'public'
    Assert-Equal 0 @(Get-IisNameConflicts -Ordner 'olaf-a-b' -ProgDir $prog).Count 'nichts vorhanden'
    $r = @(Get-IisNameConflicts -Ordner 'olaf-a-b' -ProgDir $prog -SiteExists $true -SitePath 'C:\inetpub\olaf' -PoolExists $true -PoolApps @('olaf-a-b/'))
    Assert-Equal 'Website' (($r | ForEach-Object Name) -join ','); Assert ($r[0].Text -match 'inetpub') $r[0].Text
    $r = @(Get-IisNameConflicts -Ordner 'olaf-a-b' -ProgDir $prog -PoolExists $true -PoolApps @('Default Web Site/', 'Default Web Site/x', 'OLAF-A-B/'))
    Assert-Equal 1 $r.Count; Assert-Equal 'App-Pool' $r[0].Name; Assert ($r[0].Text -match 'von Default Web Site genutzt') $r[0].Text
    $r = @(Get-IisNameConflicts -Ordner 'olaf-a-b' -ProgDir $prog -PoolExists $true)
    Assert ($r.Count -eq 1 -and $r[0].Text -match 'ohne Website und Programmordner') 'verwaister Pool'
    # abgebrochener Lauf: Programmordner bzw. eigene Website da, Pool leer oder nur von ihr genutzt
    Assert-Equal 0 @(Get-IisNameConflicts -Ordner 'olaf-a-b' -ProgDir $prog -PoolExists $true -ProgDirExists $true).Count
    Assert-Equal 0 @(Get-IisNameConflicts -Ordner 'olaf-a-b' -ProgDir $prog -SiteExists $true -SitePath $pub.ToUpper() -PoolExists $true -PoolApps @('olaf-a-b/')).Count
}
Test-Case 'Test-DataPaths: absolut, nicht im Programmordner, Temp und Data auf einem Laufwerk' {
    $ja = { param($p) $null -ne $p }
    $ok = Test-DataPaths -Paths (Get-DefaultPaths 'D:\AK\projekt') -ProgDir 'C:\AK\projekt' -DriveTest $ja
    Assert-Equal 0 $ok.Errors.Count ($ok.Errors -join ' | ')
    $bad = Test-DataPaths -Paths ([pscustomobject]@{ Data = 'D:\x\Data'; Cache = 'C:\AK\projekt\cache'; Logs = 'logs'; Temp = 'E:\x\Temp' }) -ProgDir 'C:\AK\projekt' -DriveTest $ja
    Assert-Equal 3 $bad.Errors.Count ($bad.Errors -join ' | ')
    $unc = Test-DataPaths -Paths (Get-DefaultPaths '\\srv\daten\projekt') -ProgDir 'C:\AK\projekt' -DriveTest $ja
    Assert-Equal 0 $unc.Errors.Count; Assert-Equal 4 $unc.Hints.Count
    $nein = Test-DataPaths -Paths (Get-DefaultPaths 'X:\AK\projekt') -ProgDir 'C:\AK\projekt' -DriveTest { param($p) $null -eq $p }
    Assert ($nein.Errors[0] -match 'Laufwerk')
}
Test-Case 'Get-CommonDataDir / Get-AclDataDirs' {
    Assert-Equal 'D:\AK\projekt' (Get-CommonDataDir (Get-DefaultPaths 'D:\AK\projekt'))
    Assert ($null -eq (Get-CommonDataDir (Get-DefaultPaths 'D:'))) 'Laufwerk ist kein Datenordner'
    Assert ($null -eq (Get-CommonDataDir ([pscustomobject]@{ Data = 'D:\a\Data'; Cache = 'E:\c'; Logs = 'D:\a\Logs'; Temp = 'D:\a\Temp' })))
    Assert-Equal 'D:\AK\projekt' ((Get-AclDataDirs -DataDir 'D:\AK\projekt' -Paths (Get-DefaultPaths 'D:\AK\projekt')) -join '|')
    $p = [pscustomobject]@{ Data = 'D:\AK\projekt\Data'; Cache = 'E:\Cache\projekt'; Logs = 'D:\AK\projekt\Logs'; Temp = 'D:\AK\projekt\Temp' }
    Assert-Equal 'D:\AK\projekt|E:\Cache\projekt' ((Get-AclDataDirs -DataDir 'D:\AK\projekt' -Paths $p) -join '|')
    Assert-Equal 4 @(Get-AclDataDirs -DataDir '' -Paths $p).Count
}

# =============================================================================
Write-Host "`n== Ports und Firewall"
$netsh = @('', 'Protokoll tcp Portausschlussbereiche', '', 'Startport    Endport', '----------    --------', '     21105       21204', '     50000       50059     *', '', '* - Verwaltete Portausschlüsse.')
$excluded = ConvertFrom-ExcludedPortOutput $netsh
$sites = @([pscustomobject]@{ Name = 'projekt'; Bindings = 'http/*:21100:,https/*:443:' }, [pscustomobject]@{ Name = 'Default Web Site'; Bindings = 'http/*:80:' })
$listener = { param($p) $p -eq 21101 }
Test-Case 'excludedportrange lesen, Port-Pruefung (IIS, Listener, reserviert, eigene Site)' {
    Assert-Equal 2 $excluded.Count; Assert-Equal 21105 $excluded[0].Start; Assert-Equal 50059 $excluded[1].End
    Assert ((Test-PortFree -Port 21100 -Sites $sites -Excluded $excluded -ListenerTest $listener) -match "Website 'projekt'")
    Assert ((Test-PortFree -Port 21101 -Sites $sites -Excluded $excluded -ListenerTest $listener) -match 'TCP-Listener')
    Assert ((Test-PortFree -Port 21150 -Sites $sites -Excluded $excluded -ListenerTest $listener) -match 'reserviert')
    Assert ($null -eq (Test-PortFree -Port 21102 -Sites $sites -Excluded $excluded -ListenerTest $listener))
    Assert ($null -eq (Test-PortFree -Port 21100 -Sites $sites -Excluded $excluded -OwnSite 'projekt' -ListenerTest { $true })) 'eigene Website zaehlt nicht'
    # HTTP.sys traegt den Port jeder laufenden Website in die excludedportrange ein (Windows-Test 7.3)
    $mitIis = @($excluded) + [pscustomobject]@{ Start = 21100; End = 21100 }
    Assert ($null -eq (Test-PortFree -Port 21100 -Sites $sites -Excluded $mitIis -OwnSite 'projekt' -ListenerTest { $true })) 'eigener Port trotz excludedportrange frei'
    Assert ((Test-PortFree -Port 21100 -Sites $sites -Excluded $mitIis -ListenerTest $listener) -match "Website 'projekt'") 'fremd: Website genannt, nicht reserviert'
    Assert-Equal 'von Windows reserviert (21150)' (Test-PortFree -Port 21150 -Excluded @([pscustomobject]@{ Start = 21150; End = 21150 }) -ListenerTest $listener)
    Assert ($null -ne (Test-PortFree -Port 0 -Sites $sites))
}
Test-Case 'Get-NextFreePort ueberspringt belegte und reservierte Ports' {
    Assert-Equal 21102 (Get-NextFreePort -Start 21100 -Sites $sites -Excluded $excluded -ListenerTest $listener)
    Assert-Equal 21205 (Get-NextFreePort -Start 21105 -Sites $sites -Excluded $excluded -ListenerTest $listener)
    Assert-Equal 21104 (Get-NextFreePort -Start 21100 -Sites $sites -Excluded $excluded -ListenerTest $listener -Skip @(21102, 21103))
}
Test-Case 'Get-DisabledFirewallProfiles: alle aktiv = leere Liste (nicht $null), eines aus, nicht lesbar' {
    function Get-NetFirewallProfile { @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True' }, [pscustomobject]@{ Name = 'Public'; Enabled = 'NotConfigured' }) }
    $r = Get-DisabledFirewallProfiles
    Assert ($null -ne $r) 'leere Liste darf nicht $null werden'; Assert-Equal 0 @($r).Count
    function Get-NetFirewallProfile { @([pscustomobject]@{ Name = 'Domain'; Enabled = 'True' }, [pscustomobject]@{ Name = 'Public'; Enabled = 'False' }) }
    Assert-Equal 'Public' ((Get-DisabledFirewallProfiles) -join ',')
    function Get-NetFirewallProfile { throw 'kein Modul' }
    Assert ($null -eq (Get-DisabledFirewallProfiles)) 'nicht lesbar'
    function Get-NetConnectionProfile { @([pscustomobject]@{ Name = 'Netzwerk'; InterfaceAlias = 'Ethernet'; NetworkCategory = 'Public' }) }
    Assert-Equal 'Netzwerk (Ethernet)' ((Get-PublicNetworks) -join ',')
    function Get-NetConnectionProfile { @([pscustomobject]@{ Name = 'LAN'; InterfaceAlias = 'Ethernet'; NetworkCategory = 'Private' }) }
    $pn = Get-PublicNetworks
    Assert-Equal 0 $pn.Count
}
Test-Case 'Get-PortFromBindings, Firewall-Vorschau' {
    Assert-Equal 21100 (Get-PortFromBindings 'http/*:21100:,https/*:443:')
    Assert-Equal 8080 (Get-PortFromBindings 'https/*:443:,http/10.0.0.1:8080:')
    Assert-Equal 0 (Get-PortFromBindings 'https/*:443:')
    $t = Get-FirewallPreview -Ordner 'projekt' -Port 21100
    Assert ($t -match 'SNAIL projekt \(TCP 21100\)' -and $t -match 'Domäne, Privat')
}

# =============================================================================
Write-Host "`n== config.php"
$example = [System.IO.File]::ReadAllText((Join-Path $Vorlage 'config.example.php'))
Test-Case 'Set-ConfigTemplateValues: alle Schluessel gefunden, nur Literale ersetzt, Kommentare bleiben' {
    $v = [ordered]@{ 'app.name' = "O'Neil & Söhne"; 'db.password' = "it's\geheim'\"; 'paths.data' = 'D:\AK\projekt\Data'; 'db.port' = 6543; 'cloudflare.guard' = $true; 'app.url' = 'https://x.example/' }
    $r = Set-ConfigTemplateValues -Text $example -Values $v
    Assert-Equal 0 $r.Missing.Count 'fehlende Schluessel'
    Assert ($r.Text -match "'password' => 'it\\'s\\\\geheim\\'\\\\',") 'Escaping db.password'
    Assert ($r.Text -match "'data' => 'D:\\\\AK\\\\projekt\\\\Data',") 'Escaping paths.data'
    Assert ($r.Text -match "'guard' => true,") 'bool'
    Assert ($r.Text -match "'port' => 6543,") 'int'
    Assert ($r.Text -match "// Dokumente \(Content-addressed Storage\)") 'Kommentar erhalten'
    Assert ($r.Text -match "'CONFIG_VERSION' => \d+,") 'CONFIG_VERSION unveraendert'
    Assert-Equal (($example -split "`n").Count) (($r.Text -split "`n").Count) 'Zeilenzahl'
}
Test-Case 'Set-ConfigTemplateValues: unbekannter Schluessel wird gemeldet; Steuerzeichen abgelehnt' {
    $r = Set-ConfigTemplateValues -Text $example -Values ([ordered]@{ 'app.gibtsnicht' = 'x'; 'app.name' = 'y' })
    Assert-Equal 'app.gibtsnicht' ($r.Missing -join ',')
    $threw = $false
    try { ConvertTo-PhpLiteral "a`nb" | Out-Null } catch { $threw = $true }
    Assert $threw
}
Test-Case 'Write-ProjectConfig: echte config.example.php -> ohne BOM, php -l, Werte, Abgleich; python.exe optional' {
    $prog = Join-Path $tmp 'cfgtest/projekt'
    New-Item -ItemType Directory -Path $prog -Force | Out-Null
    Copy-Item (Join-Path $Vorlage 'config.example.php') $prog
    $in = (New-InstanceInput -Service $svc -Values (New-TestValues @{ MailHost = 'smtp.muster.de'; MailPort = '465'; MailEnc = 'ssl'; MailUser = 'u'; MailPass = "p'w\x"; MailFrom = 'no@muster.de'; MailEnabled = $true; CfTeam = 't'; CfAud = 'a'; CfGuard = $true })).Inst
    $plan = New-TestPlan $prog (Join-Path $tmp 'cfgdaten/projekt') $in
    $plan.DbName = 'projekt'; $plan.DbUser = 'projekt_user'; $plan.PythonExe = 'C:\Python312\python.exe'
    $file = Write-ProjectConfig -Plan $plan -DbPassword "Ab'c\d"
    Assert ([System.IO.File]::ReadAllBytes($file)[0] -eq [byte][char]'<') 'kein BOM'
    Assert (-not (Test-Path "$file.neu")) 'config.php.neu aufgeraeumt'
    $cfg = Read-InstalledConfig -ProgDir $prog -PhpExe $PhpExe
    Assert-Equal "Ab'c\d" $cfg.db.password
    Assert-Equal "p'w\x" $cfg.mail.password
    Assert-Equal 465 ([int]$cfg.mail.port); Assert-Equal $true $cfg.mail.enabled; Assert-Equal $true $cfg.cloudflare.guard
    Assert-Equal 'Projektvorlage' $cfg.mail.from_name 'mail.from_name = Dienstname'
    Assert-Equal 'Projektvorlage' $cfg.app.name 'app.name = Dienstname ohne Mandant'
    Assert-Equal 'muster' $cfg.app.installation
    Assert-Equal '' $cfg.session.name
    Assert-Equal $plan.Paths.Temp $cfg.paths.temp
    Assert-Equal 250 ([int]$cfg.uploads.max_mb)
    Assert ($null -eq $cfg.python) 'python.exe nicht in der Vorlage -> nicht gesetzt'
    $cmp = Invoke-Php @'
function keys($a, $p = '') { $o = []; foreach ($a as $k => $v) { $o[] = $p . $k; if (is_array($v)) { $o = array_merge($o, keys($v, $p . $k . '.')); } } return $o; }
$e = keys(require $argv[1]); $c = keys(require $argv[2]);
echo json_encode(['fehlt' => array_values(array_diff($e, $c)), 'zuviel' => array_values(array_diff($c, $e))]);
'@ @((Join-Path $prog 'config.example.php'), $file) | ConvertFrom-Json
    Assert-Equal 0 @($cmp.fehlt).Count "fehlende Schluessel: $($cmp.fehlt -join ',')"
    Assert-Equal 0 @($cmp.zuviel).Count "zusaetzliche Schluessel: $($cmp.zuviel -join ',')"
    $threw = $false
    try { Write-ProjectConfig -Plan $plan -DbPassword 'x' | Out-Null } catch { $threw = $_.Exception.Message -match 'existiert bereits' }
    Assert $threw 'vorhandene config.php wird nie ueberschrieben'
    # Vorlage mit python-Abschnitt
    $prog2 = Join-Path $tmp 'cfgtest/py'
    New-Item -ItemType Directory -Path $prog2 -Force | Out-Null
    $ex2 = $example -replace "(?m)^\];\s*$", "    'python' => [`n        'exe' => '',`n    ],`n];"
    [System.IO.File]::WriteAllText((Join-Path $prog2 'config.example.php'), $ex2)
    Assert (Test-ConfigTemplateKey -ExampleFile (Join-Path $prog2 'config.example.php') -Key 'python.exe') 'Schluessel erkannt'
    Assert (-not (Test-ConfigTemplateKey -ExampleFile (Join-Path $Vorlage 'config.example.php') -Key 'python.exe')) 'Vorlage ohne python'
    $plan.ProgDir = $prog2
    Write-ProjectConfig -Plan $plan -DbPassword 'x' | Out-Null
    Assert-Equal 'C:\Python312\python.exe' (Read-InstalledConfig -ProgDir $prog2 -PhpExe $PhpExe).python.exe
}

# =============================================================================
Write-Host "`n== app.key (7.3): erzeugen, nachtragen, nie ueberschreiben"
# config.example.php vor CONFIG_VERSION 4 (Stand v0.37): ohne app.key, app.key_previous, mail.redirect_to
$exampleV3 = (($example -split "`n") | Where-Object { $_ -notmatch "^\s*'(key|key_previous|redirect_to)' =>" }) -join "`n"
$exampleV3 = $exampleV3 -replace "'CONFIG_VERSION' => 4,", "'CONFIG_VERSION' => 3,"
function Test-SecretBoxKey([string]$Key) {
    $code = 'require $argv[1]; require $argv[2]; echo App\Support\SecretBox::parseKey(trim(fgets(STDIN))) === null ? "nein" : "ja";'
    $r = Invoke-ExeCapture -FilePath $PhpExe -ArgumentList (ConvertTo-CmdArgs @('-r', $code, (Join-Path $Vorlage 'src/Support/SecretBoxException.php'), (Join-Path $Vorlage 'src/Support/SecretBox.php'))) -StdIn ($Key + "`n") -Utf8Output -TimeoutSec 60
    return ($r.Output.Trim() -eq 'ja')
}
function New-OldInstall([string]$Name, [string]$ExampleNow = $example, [string]$ExampleThen = $exampleV3) {
    $prog = Join-Path $tmp "appkey/$Name"
    New-Item -ItemType Directory -Path $prog -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $prog 'config.example.php'), $ExampleThen)
    $in = (New-InstanceInput -Service $svc -Values (New-TestValues @{ MailHost = 'smtp.muster.de'; MailPass = "p'w\x"; MailEnabled = $true })).Inst
    $plan = New-TestPlan $prog (Join-Path $tmp "appkeydaten/$Name") $in
    $plan.DbName = 'projekt'; $plan.DbUser = 'projekt_user'; $plan.Mode = 'update'; $plan.Kind = 'installed'
    Write-ProjectConfig -Plan $plan -DbPassword 'GEHEIM-db-123' | Out-Null
    # Update: neuer Programmcode bringt die neue config.example.php
    [System.IO.File]::WriteAllText((Join-Path $prog 'config.example.php'), $ExampleNow)
    return $plan
}
function Get-ConfigJson($Plan) { Invoke-Php 'echo json_encode(require $argv[1], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);' @((Join-Path $Plan.ProgDir 'config.php')) | ConvertFrom-Json }
function Get-Backups($Plan) { @(Get-ChildItem -LiteralPath (Get-BackupRoot -Plan $Plan) -Filter 'config.php.vor-snail-*' -ErrorAction SilentlyContinue) }

Test-Case 'New-AppKey / Test-AppKey: 44 Zeichen Base64 von 32 Byte, SecretBox::parseKey der Vorlage nimmt ihn' {
    $a = New-AppKey; $b = New-AppKey
    Assert-Equal 44 $a.Length; Assert ($a -ne $b) 'zufaellig'
    Assert-Equal 32 ([Convert]::FromBase64String($a)).Length
    Assert (Test-AppKey $a) 'gueltig'
    Assert (Test-SecretBoxKey $a) 'SecretBox::parseKey'
    foreach ($bad in @('', '   ', 'abc', ($a.Substring(0, 43) + 'x'), ([Convert]::ToBase64String((New-Object byte[] 31))), ([Convert]::ToBase64String((New-Object byte[] 33))), ($a.Substring(0, 40) + '!!!='))) {
        Assert (-not (Test-AppKey $bad)) "ungueltig: '$bad'"
    }
    Assert (Test-AppKey (" $a ")) 'Leerzeichen am Rand wie SecretBox (trim)'
}
Test-Case 'Neuinstallation: Write-ProjectConfig setzt app.key; app.key_previous und mail.redirect_to leer; Vorlage ohne app.key weiter installierbar' {
    $prog = Join-Path $tmp 'appkey/neu'
    New-Item -ItemType Directory -Path $prog -Force | Out-Null
    Copy-Item (Join-Path $Vorlage 'config.example.php') $prog
    $in = (New-InstanceInput -Service $svc -Values (New-TestValues)).Inst
    $plan = New-TestPlan $prog (Join-Path $tmp 'appkeydaten/neu') $in
    $plan.DbName = 'projekt'; $plan.DbUser = 'projekt_user'
    $key = New-AppKey
    Write-ProjectConfig -Plan $plan -DbPassword 'x' -AppKey $key | Out-Null
    $cfg = Get-ConfigJson $plan
    Assert-Equal $key $cfg.app.key; Assert-Equal '' $cfg.app.key_previous; Assert-Equal '' $cfg.mail.redirect_to
    Assert-Equal 'present' (Update-InstalledConfigKeys -Plan $plan).Status 'danach: vorhanden, nichts zu tun'
    $prog2 = Join-Path $tmp 'appkey/neu-alt'
    New-Item -ItemType Directory -Path $prog2 -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $prog2 'config.example.php'), $exampleV3)
    $plan.ProgDir = $prog2
    Write-ProjectConfig -Plan $plan -DbPassword 'x' -AppKey $key | Out-Null
    Assert ($null -eq (Get-ConfigJson $plan).app.key) 'Vorlage ohne app.key: nicht gesetzt'
    Assert-Equal 'none' (Update-InstalledConfigKeys -Plan $plan).Status 'Vorlage ohne app.key: nichts zu ergaenzen'
}

Write-Host "  -- Add-ConfigKeys (Text)"
$v4 = [ordered]@{ 'app.key' = 'K' * 43 + '='; 'app.key_previous' = ''; 'mail.redirect_to' = '' }
Test-Case 'Add-ConfigKeys: Schluessel fehlen -> vor dem ] des Bereichs eingefuegt, Einrueckung, Kommentare und alle Zeilen bleiben' {
    $r = Add-ConfigKeys -Text $exampleV3 -Values $v4
    Assert-Equal '' $r.Error
    Assert-Equal 'app.key,app.key_previous,mail.redirect_to' ($r.Changed -join ',')
    $old = $exampleV3 -split "`n"; $new = $r.Text -split "`n"
    Assert-Equal ($old.Count + 5) $new.Count 'je Bereich Kommentar + Schluessel'
    $j = 0
    foreach ($l in $new) { if ($j -lt $old.Count -and $l -ceq $old[$j]) { $j++ } }
    Assert-Equal $old.Count $j 'alle alten Zeilen unveraendert und in Reihenfolge'
    Assert ($r.Text -match "(?m)^        'key' => 'K{43}=',$") 'app.key mit Einrueckung der Nachbarn'
    Assert ($r.Text -match "(?m)^        'redirect_to' => '',\r?\n    \],") 'mail.redirect_to am Ende von mail'
    Assert ($r.Text -match "(?s)'app' => \[.*'key' => 'K.*?\],\s*//.*?'db' => \[") 'app.key im Bereich app'
}
Test-Case "Add-ConfigKeys: 'key' => '' vorhanden -> Literal ersetzt, Kommentar dahinter bleibt, Zeilenzahl gleich" {
    $t = $example -replace "'key' => '',", "'key' => '',   // Schluessel"
    $r = Add-ConfigKeys -Text $t -Values ([ordered]@{ 'app.key' = 'K' * 43 + '=' })
    Assert-Equal '' $r.Error
    Assert-Equal (($t -split "`n").Count) (($r.Text -split "`n").Count)
    Assert ($r.Text -match "'key' => 'K{43}=',   // Schluessel") $r.Text
    Assert ($r.Text -match "'key_previous' => ''") 'key_previous unberuehrt'
}
Test-Case 'Add-ConfigKeys: vorhandener Wert wird nie ersetzt; doppelt, inline, doppelte Anfuehrungszeichen, fehlender Bereich -> Fehler, Text gleich' {
    $t = $example -replace "'key' => '',", "'key' => 'abc',"
    $r = Add-ConfigKeys -Text $t -Values ([ordered]@{ 'app.key' = 'NEU' })
    Assert ($r.Error -match 'schon einen Wert') $r.Error; Assert ($r.Text -ceq $t) 'unveraendert'; Assert ($r.Error -notmatch 'abc|NEU') 'kein Wert in der Meldung'
    $faelle = @{
        doppelt = ($exampleV3 -replace "'name' => 'Projekt',", "'name' => 'Projekt',`n        'key' => '',`n        'key' => '',")
        inline  = "<?php`nreturn [`n    'CONFIG_VERSION' => 3,`n    'app' => ['name' => 'x', 'url' => 'y'],`n];`n"
        dquote  = ($exampleV3 -replace "'name' => 'Projekt',", "'name' => 'Projekt',`n        ""key"" => """",")
        zweimal = ($exampleV3 -replace "(?m)^\];", "    'app' => [`n        'x' => 1,`n    ],`n];")
        ohne    = "<?php`nreturn [`n    'db' => [`n        'host' => 'x',`n    ],`n];`n"
    }
    foreach ($n in $faelle.Keys) {
        $r = Add-ConfigKeys -Text $faelle[$n] -Values ([ordered]@{ 'app.key' = 'NEU' })
        Assert ($r.Error -ne '') "$n`: Fehler erwartet"
        Assert ($r.Text -ceq $faelle[$n]) "$n`: Text unveraendert"
        Assert-Equal 0 @($r.Changed).Count "$n`: nichts geaendert"
    }
}
Test-Case 'Add-ConfigKeys: letzte Zeile ohne Komma, verschachtelter Bereich mit eigenem key, CRLF, leerer Bereich' {
    $t = "<?php`r`nreturn [`r`n    'CONFIG_VERSION' => 3,`r`n    'app' => [`r`n        'name' => 'x',`r`n        'sub' => [`r`n            'key' => '',`r`n        ]`r`n    ],`r`n    'mail' => [`r`n        'host' => 'h' // ohne Komma`r`n    ],`r`n    'leer' => [`r`n    ],`r`n];`r`n"
    $r = Add-ConfigKeys -Text $t -Values ([ordered]@{ 'app.key' = 'A'; 'mail.redirect_to' = ''; 'leer.x' = 1 })
    Assert-Equal '' $r.Error
    Assert (-not ($r.Text -match "(?<!\r)\n")) 'nur CRLF'
    Assert ($r.Text.Contains("            'key' => '',`r`n        ],`r`n")) 'app.sub.key unberuehrt, Komma nach ] ergaenzt'
    Assert ($r.Text.Contains("        'key' => 'A',`r`n    ],")) 'app.key eingefuegt'
    Assert ($r.Text.Contains("'host' => 'h', // ohne Komma")) 'Komma vor dem Kommentar ergaenzt'
    Assert ($r.Text.Contains("    'leer' => [`r`n        // von SNAIL")) 'leerer Bereich: Einrueckung + 4'
    $lint = Invoke-ExeCapture -FilePath $PhpExe -ArgumentList (ConvertTo-CmdArgs @('-r', 'echo json_encode(eval(substr(stream_get_contents(STDIN), 5)));')) -StdIn $r.Text -Utf8Output
    $j = $lint.Output | ConvertFrom-Json
    Assert-Equal 'A' $j.app.key; Assert-Equal '' $j.app.sub.key; Assert-Equal '' $j.mail.redirect_to; Assert-Equal 1 $j.leer.x; Assert-Equal 'h' $j.mail.host
}
Test-Case 'Add-ConfigKeys: CONFIG_VERSION nur von erlaubtem Wert, oberste Ebene wird nie eingefuegt' {
    $r = Add-ConfigKeys -Text $exampleV3 -Values ([ordered]@{ 'CONFIG_VERSION' = 4 }) -Allowed @{ 'CONFIG_VERSION' = @('3') }
    Assert ($r.Text -match "'CONFIG_VERSION' => 4,") 'angehoben'
    $r = Add-ConfigKeys -Text $example -Values ([ordered]@{ 'CONFIG_VERSION' = 4 }) -Allowed @{ 'CONFIG_VERSION' = @('3') }
    Assert ($r.Error -ne '') 'Version 4 ist kein erlaubter alter Wert'
    $r = Add-ConfigKeys -Text "<?php`nreturn [`n    'app' => [`n    ],`n];" -Values ([ordered]@{ 'CONFIG_VERSION' = 4 })
    Assert ($r.Error -match 'oberster Ebene') $r.Error
}

Write-Host "  -- Update-InstalledConfigKeys (Datei, php)"
Test-Case 'Update v0.37 -> v0.39: app.key nachgetragen, Sicherung, CONFIG_VERSION 4, alle anderen Werte gleich; zweiter Lauf aendert nichts' {
    $plan = New-OldInstall 'update'
    $file = Join-Path $plan.ProgDir 'config.php'
    $before = Get-ConfigJson $plan
    $bytes0 = [System.IO.File]::ReadAllBytes($file)
    $r = Update-InstalledConfigKeys -Plan $plan
    Assert-Equal 'added' $r.Status $r.Text
    Assert-Equal 'app.key,app.key_previous,mail.redirect_to,CONFIG_VERSION' ($r.Changed -join ',')
    Assert (Test-SecretBoxKey $r.Key) 'gueltiger Schluessel'
    Assert ($r.Text -notmatch [regex]::Escape($r.Key)) 'Schluessel nicht in der Meldung'
    Assert (-not (Test-Path "$file.neu")) '.neu aufgeraeumt'
    $after = Get-ConfigJson $plan
    Assert-Equal $r.Key $after.app.key; Assert-Equal '' $after.app.key_previous; Assert-Equal '' $after.mail.redirect_to; Assert-Equal 4 $after.CONFIG_VERSION
    foreach ($o in @($before, $after)) { $o.app.PSObject.Properties.Remove('key'); $o.app.PSObject.Properties.Remove('key_previous'); $o.mail.PSObject.Properties.Remove('redirect_to'); $o.PSObject.Properties.Remove('CONFIG_VERSION') }
    Assert-Equal ($before | ConvertTo-Json -Depth 5 -Compress) ($after | ConvertTo-Json -Depth 5 -Compress) 'alle anderen Werte gleich'
    $bk = Get-Backups $plan
    Assert-Equal 1 $bk.Count 'Sicherung'
    Assert ($bk[0].DirectoryName -eq (Get-BackupRoot -Plan $plan)) 'in <Datenordner>\Sicherung'
    Assert-Equal ([Convert]::ToBase64String($bytes0)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($bk[0].FullName))) 'Sicherung = vorheriger Stand'
    Assert-Equal $bk[0].FullName $r.Backup
    # check der Vorlage: keine fehlenden Schluessel, keine Versionswarnung
    $cmp = Invoke-Php 'require $argv[1]; [$c] = App\Support\Config::tryLoad($argv[2]); echo json_encode(App\Support\Config::comparisonMessages($c, $argv[3]));' @((Join-Path $Vorlage 'src/Support/Config.php'), $file, (Join-Path $plan.ProgDir 'config.example.php'))
    Assert-Equal '[]' $cmp.Trim() "Abgleich mit der Vorlage: $cmp"
    # zweiter Lauf
    $bytes1 = [System.IO.File]::ReadAllBytes($file)
    $r2 = Update-InstalledConfigKeys -Plan $plan
    Assert-Equal 'present' $r2.Status; Assert-Equal '' $r2.Key; Assert-Equal 0 @($r2.Changed).Count
    Assert-Equal ([Convert]::ToBase64String($bytes1)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file))) 'zweiter Lauf: Bytes gleich'
    Assert-Equal 1 (Get-Backups $plan).Count 'keine weitere Sicherung'
}
Test-Case 'Vorhandener gueltiger Schluessel bleibt; nur fehlende Nachbarn ergaenzt' {
    $plan = New-OldInstall 'vorhanden'
    $file = Join-Path $plan.ProgDir 'config.php'
    $key = New-AppKey
    $t = [System.IO.File]::ReadAllText($file) -replace "('installation' => '[^']*',)", "`$1`n        'key' => '$key',"
    [System.IO.File]::WriteAllText($file, $t)
    $r = Update-InstalledConfigKeys -Plan $plan
    Assert-Equal 'present' $r.Status $r.Text; Assert-Equal '' $r.Key
    Assert-Equal 'app.key_previous,mail.redirect_to,CONFIG_VERSION' ($r.Changed -join ',')
    Assert-Equal $key (Get-ConfigJson $plan).app.key 'Schluessel unveraendert'
}
Test-Case 'Leerer app.key in einer v4-config.php wird gefuellt; CONFIG_VERSION bleibt 4' {
    $plan = New-OldInstall 'leer' $example $example
    $r = Update-InstalledConfigKeys -Plan $plan
    Assert-Equal 'added' $r.Status $r.Text
    Assert-Equal 'app.key' ($r.Changed -join ',')
    $c = Get-ConfigJson $plan
    Assert-Equal $r.Key $c.app.key; Assert-Equal 4 $c.CONFIG_VERSION
}
Test-Case 'Ungueltiger app.key: nichts geaendert, Warnung, keine Sicherung' {
    $plan = New-OldInstall 'ungueltig' $example $example
    $file = Join-Path $plan.ProgDir 'config.php'
    $t = ([System.IO.File]::ReadAllText($file) -replace "'key' => '',", "'key' => 'kaputt',") -replace "(?m)^\s*'redirect_to' => '',\r?\n", ''
    [System.IO.File]::WriteAllText($file, $t)
    $bytes0 = [System.IO.File]::ReadAllBytes($file)
    $r = Update-InstalledConfigKeys -Plan $plan
    Assert-Equal 'invalid' $r.Status; Assert-Equal '' $r.Key; Assert ($r.Text -match 'ändert nichts') $r.Text
    Assert-Equal ([Convert]::ToBase64String($bytes0)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file))) 'unveraendert (auch redirect_to nicht ergaenzt)'
    Assert-Equal 0 (Get-Backups $plan).Count
}
Test-Case 'Nicht automatisch moeglich (app in einer Zeile): Status manual mit Schluessel zum Selbsteintragen, Datei unveraendert' {
    $plan = New-OldInstall 'manuell'
    $file = Join-Path $plan.ProgDir 'config.php'
    [System.IO.File]::WriteAllText($file, "<?php`nreturn [`n    'CONFIG_VERSION' => 3,`n    'app' => ['name' => 'x', 'service' => 'projekt'],`n    'db' => ['password' => 'GEHEIM'],`n];`n")
    $bytes0 = [System.IO.File]::ReadAllBytes($file)
    $r = Update-InstalledConfigKeys -Plan $plan
    Assert-Equal 'manual' $r.Status $r.Text
    Assert (Test-AppKey $r.Key) 'Vorschlag gueltig'
    Assert ($r.Text -notmatch 'GEHEIM') 'kein Wert in der Meldung'
    Assert-Equal ([Convert]::ToBase64String($bytes0)) ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($file))) 'unveraendert'
    Assert (-not (Test-Path "$file.neu")); Assert-Equal 0 (Get-Backups $plan).Count
}
Test-Case 'config.php mit BOM bleibt mit BOM; CONFIG_VERSION bleibt 3, wenn noch andere Schluessel fehlen' {
    $exV2 = $exampleV3 -replace "(?s)\s*// -+\s*// HTTP-Client.*?'http' => \[.*?\],", ''
    Assert ($exV2 -notmatch "'http' =>") 'Testvorlage ohne http'
    $plan = New-OldInstall 'bom' $example $exV2
    $file = Join-Path $plan.ProgDir 'config.php'
    [System.IO.File]::WriteAllBytes($file, [byte[]](@(0xEF, 0xBB, 0xBF) + [System.IO.File]::ReadAllBytes($file)))
    $r = Update-InstalledConfigKeys -Plan $plan
    Assert-Equal 'added' $r.Status $r.Text
    Assert-Equal 'app.key,app.key_previous,mail.redirect_to' ($r.Changed -join ',') 'ohne CONFIG_VERSION'
    $b = [System.IO.File]::ReadAllBytes($file)
    Assert ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF -and $b[3] -eq [byte][char]'<') 'BOM erhalten'
    Assert-Equal 3 (Read-InstalledConfig -ProgDir $plan.ProgDir -PhpExe $PhpExe).CONFIG_VERSION
}
Test-Case 'PHP-Vergleich nennt nur Schluesselnamen, nie Werte (auch bei Abweichung)' {
    $plan = New-OldInstall 'vergleich'
    $file = Join-Path $plan.ProgDir 'config.php'
    $neu = Join-Path $plan.ProgDir 'anders.php'
    [System.IO.File]::WriteAllText($neu, ([System.IO.File]::ReadAllText($file) -replace 'GEHEIM-db-123', 'ANDERS-db-456'))
    $want = '{"app.key":"' + ('W' * 43) + '="}'
    $j = Invoke-PhpConfigHelper -PhpExe $PhpExe -Code $script:PhpConfigVerify -Arguments @($file, $neu, (Join-Path $plan.ProgDir 'config.example.php')) -StdIn $want
    $txt = $j | ConvertTo-Json -Compress -Depth 5
    Assert (-not $j.ok) 'abweichend'
    Assert (@($j.differs) -contains 'db.password') $txt
    Assert (@($j.wrong) -contains 'app.key') $txt
    Assert ($txt -notmatch 'GEHEIM|ANDERS|WWWW') "keine Werte: $txt"
    $s = Invoke-PhpConfigHelper -PhpExe $PhpExe -Code $script:PhpConfigState -Arguments @($file, (Join-Path $plan.ProgDir 'config.example.php'))
    Assert (($s | ConvertTo-Json -Compress -Depth 5) -notmatch 'GEHEIM|smtp\.muster') 'Zustand ohne Werte'
    Assert-Equal 'missing' $s.keys.'app.key'.state
}
Test-Case 'Zugangsdatei: app_key mit Hinweis' {
    $plan = New-OldInstall 'zugang'
    $k = New-AppKey
    $f = Save-InstallCredentials -Plan $plan -Values @{ app_key = $k }
    Assert-Equal $k (Read-KeyValueFile $f)['app_key']
    Assert (([System.IO.File]::ReadAllText($f)) -match 'Passwortmanager ablegen - ohne ihn sind gespeicherte Passwoerter verloren') 'Hinweis'
}

# =============================================================================
Write-Host "`n== Logos, WIPP-Dateien, check"
Test-Case 'Get-LogoData: PNG-Datei, SVG, Base64, data-URL, zu gross, unbekannt' {
    $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + [byte[]](1..100)
    [System.IO.File]::WriteAllBytes((Join-Path $tmp 'logo.png'), $png)
    $l = Get-LogoData 'logo.png' $tmp; Assert-Equal 'png' $l.Ext; Assert-Equal '' $l.Error
    [System.IO.File]::WriteAllText((Join-Path $tmp 'l.svg'), '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>')
    Assert-Equal 'svg' (Get-LogoData 'l.svg' $tmp).Ext
    Assert-Equal 'png' (Get-LogoData ([Convert]::ToBase64String($png)) $tmp).Ext
    Assert-Equal 'png' (Get-LogoData ('data:image/png;base64,' + [Convert]::ToBase64String($png)) $tmp).Ext
    [System.IO.File]::WriteAllBytes((Join-Path $tmp 'gross.png'), ($png + (New-Object byte[] 1100000)))
    Assert ((Get-LogoData 'gross.png' $tmp).Error -match '1 MB')
    Assert ((Get-LogoData 'fehlt.svg' $tmp).Error -match 'nicht gefunden')
    [System.IO.File]::WriteAllText((Join-Path $tmp 'x.gif'), 'GIF89a....')
    Assert ((Get-LogoData 'x.gif' $tmp).Error -match 'unbekanntes')
}
Test-Case 'Read-KeyValueFile: WIPP-Format (Wert ungetrimmt, = und # im Passwort)' {
    $f = Join-Path $tmp 'postgres-zugangsdaten.txt'
    [System.IO.File]::WriteAllText($f, "# WIPP`r`nformat=1`r`nhost=localhost`r`nport=5432`r`nbenutzer=postgres`r`npasswort=a=b#c d `r`n")
    $h = Read-KeyValueFile $f
    Assert-Equal 'a=b#c d ' $h['passwort']; Assert-Equal '5432' $h['port']
}
Test-Case 'Split-TextToWidth: Umbruch an Leerzeichen, zu langes Wort bleibt ganz, leerer Text' {
    $len = { param($s) $s.Length }
    Assert-Equal @('aaa bbb', 'ccc') (Split-TextToWidth -Text 'aaa bbb ccc' -MaxWidth 7 -Measure $len)
    Assert-Equal @('kurz', 'sehrlangeswort', 'x') (Split-TextToWidth -Text 'kurz sehrlangeswort x' -MaxWidth 6 -Measure $len)
    Assert-Equal @('passt genau') (Split-TextToWidth -Text 'passt genau' -MaxWidth 11 -Measure $len)
    Assert-Equal 1 (Split-TextToWidth -Text '' -MaxWidth 5 -Measure $len).Count
}
Test-Case 'Get-ErrorLine (Migrationsfehler mit ^), Format-Size' {
    $l = @('Führe 1 Migration(en) aus', '  [FEHLER] Migration 9999_kaputt.sql fehlgeschlagen: SQLSTATE[42601]', 'LINE 1: SELECT kaputt(;', '                      ^')
    Assert ((Get-ErrorLine $l) -match '9999_kaputt') (Get-ErrorLine $l)
    Assert-Equal 'Datenbankverbindung weg' (Get-ErrorLine @('Datenbankverbindung weg', '   ^  '))
    Assert-Equal '26 KB' ((Format-Size 25952) -replace '\s', ' ')
    Assert ((Format-Size 5MB) -match '^5[,.]0 MB$') (Format-Size 5MB)
}
Test-Case 'ConvertFrom-CheckOutput: Hinweise und Details werden zugeordnet' {
    $i = ConvertFrom-CheckOutput @('[OK     ] PHP 8.3', '[WARNUNG] services.json', '          Datei fehlt', '          Detail: C:\AK\services.json', '[FEHLER ] Datenbank', 'Ergebnis: FEHLER')
    Assert-Equal 3 $i.Count; Assert-Equal 'WARNUNG' $i[1].Status; Assert-Equal 'Datei fehlt Detail: C:\AK\services.json' $i[1].Hint
}
Test-Case 'Get-DefaultDbNames / Test-PgIdentifier / Test-ServiceKey' {
    $d = Get-DefaultDbNames 'projekt-beispiel'
    Assert-Equal 'projekt_beispiel' $d.Name; Assert-Equal 'projekt_beispiel_user' $d.User
    Assert-Equal 'db_3d' (Get-DefaultDbNames '3d').Name
    Assert ($null -eq (Test-PgIdentifier 'olaf_user'))
    Assert ($null -ne (Test-PgIdentifier 'Olaf')); Assert ($null -ne (Test-PgIdentifier 'pg_x')); Assert ($null -ne (Test-PgIdentifier 'postgres'))
    Assert (Test-ServiceKey 'olaf-2_x'); Assert (-not (Test-ServiceKey '-olaf')); Assert (-not (Test-ServiceKey 'Olaf'))
}

# =============================================================================
Write-Host "`n== services.json"
$sd = Join-Path $Vorlage 'src/Support/ServiceDirectory.php'
function Test-WithVorlage([string]$Path) {
    $code = 'require $argv[1]; $d = json_decode(preg_replace("/^\xEF\xBB\xBF/", "", file_get_contents($argv[2])), true); echo json_encode(App\Support\ServiceDirectory::parse($d), JSON_UNESCAPED_UNICODE);'
    return (Invoke-Php $code @($sd, $Path) | ConvertFrom-Json)
}
$svcA = [pscustomobject]@{ Key = 'olaf'; Name = 'Olaf'; Icon = 'package'; Tone = 'info'; Description = 'Warenwirtschaft' }
Test-Case 'Merge-ServicesJson: neue Datei, zweite Installation, idempotent, Vorlage liest sie' {
    $t = Merge-ServicesJson -Tree $null -Service $svcA -LogoRel 'logos/olaf.svg' -Installation ([pscustomobject]@{ Key = 'muster'; Name = 'Muster GmbH'; Url = 'https://olaf.muster.de/' })
    $t = Merge-ServicesJson -Tree $t -Service $svcA -Installation ([pscustomobject]@{ Key = 'beispiel'; Name = 'Beispiel AG'; Url = 'https://olaf.beispiel.de/' })
    $text1 = ConvertTo-ServicesJsonText $t
    $f = Join-Path $tmp 'services1.json'
    [System.IO.File]::WriteAllText($f, $text1)
    $t2 = Merge-ServicesJson -Tree (Read-ServicesJson $f) -Service $svcA -Installation ([pscustomobject]@{ Key = 'beispiel'; Name = 'Beispiel AG'; Url = 'https://olaf.beispiel.de/' })
    Assert-Equal $text1 (ConvertTo-ServicesJsonText $t2) 'zweiter Lauf aendert nichts'
    $p = Test-WithVorlage $f
    Assert ($null -eq $p.error) "Vorlage: $($p.error)"
    Assert-Equal 2 @($p.services[0].installations).Count
    $e = Get-ServicesEntry -Tree (Read-ServicesJson $f) -ServiceKey 'olaf' -InstKey 'beispiel'
    Assert ($e.Found -and $e.InstName -eq 'Beispiel AG' -and $e.ServiceName -eq 'Olaf') 'Get-ServicesEntry'
}
Test-Case 'Merge-ServicesJson: fremde Eintraege, Felder und Reihenfolge bleiben; Ein-Element-Liste und BOM' {
    $f = Join-Path $tmp 'services2.json'
    $orig = '{"format":1,"kommentar":"von Hand","services":{"key":"renate","name":"Renate","tone":"purple","extra":{"a":1},"installations":{"key":"muster","name":"Muster GmbH","url":"https://renate.muster.de/"}}}'
    [System.IO.File]::WriteAllText($f, $orig, (New-Object System.Text.UTF8Encoding($true)))
    $t = Merge-ServicesJson -Tree (Read-ServicesJson $f) -Service $svcA -Installation ([pscustomobject]@{ Key = 'muster'; Name = 'Muster GmbH'; Url = 'https://olaf.muster.de/' })
    $rules = Test-ServicesJsonRules -Tree $t -BaseDir $tmp
    Assert-Equal 0 $rules.Errors.Count ($rules.Errors -join ' | ')
    $neu = Join-Path $tmp 'services2-neu.json'
    Write-FileAtomic -Path $neu -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-ServicesJsonText $t)))
    Write-FileAtomic -Path $neu -Bytes ((New-Object System.Text.UTF8Encoding($false)).GetBytes((ConvertTo-ServicesJsonText $t)))
    $j = Get-Content $neu -Raw | ConvertFrom-Json
    Assert-Equal 'von Hand' $j.kommentar
    Assert-Equal 'renate,olaf' (($j.services | ForEach-Object key) -join ',') 'Reihenfolge, neuer Dienst hinten'
    Assert-Equal 1 $j.services[0].extra.a 'fremdes Feld'
    Assert ((Get-Content $neu -Raw) -match '"installations":\s*\[') 'Liste bleibt Liste'
    Assert ([System.IO.File]::ReadAllBytes($neu)[0] -eq [byte][char]'{') 'ohne BOM'
    $p = Test-WithVorlage $neu
    Assert ($null -eq $p.error) "Vorlage: $($p.error)"
}
Test-Case 'Merge-ServicesJson: eigene Installation angleichen; Dienst ohne Katalog (nur Name) behaelt Felder' {
    $t = Merge-ServicesJson -Tree $null -Service $svcA -Installation ([pscustomobject]@{ Key = 'muster'; Name = 'Alt'; Url = 'http://localhost:8081/' })
    $t = Merge-ServicesJson -Tree $t -Service $svcA -Installation ([pscustomobject]@{ Key = 'zweit'; Name = 'Z'; Url = 'http://localhost:8082/' })
    $t = Merge-ServicesJson -Tree $t -Service (New-PseudoService -Key 'olaf' -Name 'Olaf') -Installation ([pscustomobject]@{ Key = 'muster'; Name = 'Muster GmbH'; Url = 'https://olaf.muster.de/' })
    $s = $t['services'][0]
    Assert-Equal 'package' $s['icon'] 'Icon bleibt'; Assert-Equal 'Warenwirtschaft' $s['description']
    Assert-Equal 'muster,zweit' (($s['installations'] | ForEach-Object { $_['key'] }) -join ',')
    Assert-Equal 'https://olaf.muster.de/' $s['installations'][0]['url']
}
Test-Case 'Test-ServicesJsonRules: Verstoesse werden gemeldet; unbekanntes Format bleibt unberuehrt' {
    $bad = ConvertTo-OrderedTree ('{"format":1,"services":[{"key":"Olaf","name":"x","installations":[{"key":"a","url":"x"}]},{"key":"b","name":"","tone":"rot","logo":"logos/mein logo.png","installations":[]}]}' | ConvertFrom-Json)
    Assert-Equal 5 (Test-ServicesJsonRules -Tree $bad -BaseDir $tmp).Errors.Count
    $threw = $false
    try { Merge-ServicesJson -Tree (ConvertTo-OrderedTree ('{"format":2,"services":[]}' | ConvertFrom-Json)) -Service $svcA -Installation ([pscustomobject]@{ Key = 'm'; Name = 'm'; Url = 'http://x/' }) | Out-Null } catch { $threw = $true }
    Assert $threw
}

# =============================================================================
Write-Host "`n== ZIP"
$zip = Join-Path $tmp 'projektvorlage-main.zip'
& git -C $Vorlage archive --format=zip --prefix=projektvorlage-main/ -o $zip HEAD
$zip2 = Join-Path $tmp 'doppelt.zip'
& git -C $Vorlage archive --format=zip --prefix=projektvorlage-main/projektvorlage-main/ -o $zip2 HEAD
Test-Case 'Expand-TemplateZip: Zwischenordner (auch doppelt) erkannt, Aufbau, Wiederverwendung, Aufraeumen' {
    $st = Expand-TemplateZip -Zip $zip2
    Assert-Equal 'projektvorlage-main\projektvorlage-main' $st.Inner 'aus den Ordnernamen, nicht per Substring (8.3-Pfade)'
    $d2 = $st.Dir
    $st = Expand-TemplateZip -Zip $zip
    Assert (-not (Test-Path $d2)) 'alter Temp-Ordner geloescht'
    Assert-Equal 'projektvorlage-main' $st.Inner
    Assert-Equal 0 @(Test-TemplateStructure $st.Root).Count
    Assert-Equal $st.Dir (Expand-TemplateZip -Zip $zip).Dir 'gleiche Datei -> nicht erneut entpacken'
    $info = Get-TemplateInfo -Root $st.Root -PhpExe $PhpExe
    Assert-Equal '8.5.0' $info.PhpMin; Assert-Equal 18 $info.PgMin; Assert ($info.Extensions -contains 'pdo_pgsql'); Assert ($info.Version -ne '')
}

# =============================================================================
Write-Host "`n== Installationen am Server erkennen"
$st = Expand-TemplateZip -Zip $zip
$ak = Join-Path $tmp 'AK'
function New-FakeInstall([string]$Ordner, [string]$Key, [switch]$Bom) {
    $prog = Join-Path $ak $Ordner
    Copy-Item -Path $st.Root -Destination $prog -Recurse
    $in = (New-InstanceInput -Service $svc -Values (New-TestValues @{ Key = $Key; Name = "Name $Key"; Url = "https://$Key.test/" })).Inst
    $plan = New-TestPlan $prog (Join-Path $tmp "daten/$Ordner") $in
    $plan.DbName = ($Ordner -replace '-', '_'); $plan.DbUser = $plan.DbName + '_user'
    $f = Write-ProjectConfig -Plan $plan -DbPassword 'geheim'
    if ($Bom) { [System.IO.File]::WriteAllBytes($f, ([byte[]](0xEF, 0xBB, 0xBF) + [System.IO.File]::ReadAllBytes($f))) }
    return $plan
}
Test-Case 'Get-InstalledInstances: zwei Mandanten, BOM, ohne config.php / bin\console uebersprungen, aelterer Stand ohne db' {
    New-FakeInstall 'projekt' 'muster' | Out-Null
    New-FakeInstall 'projekt-beispiel' 'beispiel' -Bom | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ak 'logos') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ak 'nur-config') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ak 'nur-config/config.php'), '<?php return [];')
    # aelterer Stand: info ohne db -> Datenbank per php -r aus der config.php
    $alt = Join-Path $ak 'alt'
    New-Item -ItemType Directory -Path (Join-Path $alt 'bin') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $alt 'bin/console'), '<?php echo json_encode(["app" => ["service" => "erwin", "installation" => "muster", "url" => "https://erwin.test/", "name" => "Erwin", "version" => "0.0.9"], "paths" => ["data" => "D:\\AK\\alt\\Data", "cache" => "D:\\AK\\alt\\Cache", "logs" => "D:\\AK\\alt\\Logs", "temp" => "D:\\AK\\alt\\Temp", "services_json" => "C:\\AK\\services.json"], "uploads_max_mb" => 25]);')
    [System.IO.File]::WriteAllText((Join-Path $alt 'config.php'), "<?php return ['db' => ['host' => 'localhost', 'port' => 5432, 'name' => 'olaf', 'user' => 'olaf_user', 'password' => 'x']];")
    $sjf = Join-Path $ak 'services.json'
    [System.IO.File]::WriteAllText($sjf, '{"format":1,"services":[{"key":"projekt","name":"Projektvorlage","installations":[{"key":"muster","name":"Muster GmbH","url":"http://alt/"}]},{"key":"erwin","name":"Erwin (services.json)","installations":[{"key":"muster","name":"Muster GmbH","url":"https://erwin.test/"}]}]}')
    $sites = @([pscustomobject]@{ Name = 'projekt'; Bindings = 'http/*:21100:' }, [pscustomobject]@{ Name = 'PROJEKT-BEISPIEL'; Bindings = 'http/*:21101:,https/*:443:' })
    $found = @(Get-InstalledInstances -ProgRoot $ak -PhpExe $PhpExe -Catalog $catalog.Services -Sites $sites -ServicesJson $sjf)
    Assert-Equal 'alt,projekt,projekt-beispiel' (($found | ForEach-Object Ordner) -join ',') 'gefundene Ordner'
    $a = $found[1]; $b = $found[2]; $o = $found[0]
    Assert-Equal '' $a.Error; Assert-Equal '' $b.Error $b.Error
    Assert-Equal 'muster' $a.Key; Assert-Equal 'Muster GmbH' $a.Name 'Name aus services.json'; Assert-Equal 21100 $a.Port
    Assert-Equal 'projekt' $a.Db.Name 'db aus info'; Assert-Equal 'https://muster.test/' $a.Url
    Assert-Equal 'http://alt/' $a.ServicesUrl
    Assert-Equal 'beispiel' $b.Key; Assert-Equal 'beispiel' $b.Name 'nicht in services.json -> Schluessel'; Assert-Equal 21101 $b.Port 'Site-Name ohne Gross/Klein'
    Assert-Equal 'Projektvorlage - Muster GmbH' $a.Display
    Assert-Equal 'olaf' $o.Db.Name 'Fallback ohne db in info'
    Assert-Equal 'Erwin (services.json)' $o.Service.Name 'nicht im Katalog: Name aus services.json'
    Assert (-not $o.Service.InCatalog)
    # Mandanten-Name aus der Zugangsdatei, wenn er in der services.json fehlt (Abbruch vor dem services.json-Schritt)
    $cred = Join-Path $tmp 'cred'
    New-Item -ItemType Directory -Path $cred -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $cred 'projekt-beispiel.txt'), "# x`r`nmandant_name=Beispiel AG`r`n")
    $mitCred = @(Get-InstalledInstances -ProgRoot $ak -PhpExe $PhpExe -Catalog $catalog.Services -Sites $sites -ServicesJson $sjf -CredDir $cred)
    Assert-Equal 'Beispiel AG' $mitCred[2].Name 'Name aus der Zugangsdatei'
    Assert-Equal 'Muster GmbH' $mitCred[1].Name 'services.json hat Vorrang'
    # Katalog ausgetauscht: Installationen werden trotzdem erkannt
    $leer = @(Get-InstalledInstances -ProgRoot $ak -PhpExe $PhpExe -Catalog @{} -Sites $sites -ServicesJson $sjf)
    Assert-Equal 3 $leer.Count
    Assert-Equal 'Projektvorlage' $leer[1].Service.Name 'Name aus services.json'
    New-Item -ItemType Directory -Path (Join-Path $ak 'logos') -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot '../logos/renate.png') (Join-Path $ak 'logos/erwin.png')
    $tree = Read-ServicesJson $sjf; $tree['services'][1]['logo'] = 'logos/erwin.png'
    [System.IO.File]::WriteAllText($sjf, (ConvertTo-ServicesJsonText $tree))
    $mitLogo = @(Get-InstalledInstances -ProgRoot $ak -PhpExe $PhpExe -Catalog @{} -Sites $sites -ServicesJson $sjf)
    Assert-Equal 'png' $mitLogo[0].Service.Logo.Ext 'Logo aus der services.json fuer die Anzeige'
    $t = ConvertTo-InstallTarget -Instance $a
    Assert-Equal 'installed' $t.Kind; Assert-Equal (Join-Path $tmp 'daten/projekt') $t.DataDir.Replace('\', '/') 'gemeinsamer Datenordner'
    # zweiter Mandant mit diesen Installationen
    $n = New-InstanceInput -Service $svc -Values (New-TestValues @{ Key = 'dritte' }) -Instances $found
    Assert-Equal 'projekt-dritte' $n.Inst.Ordner
    Assert ($n.Inst.OrdnerReason -match '2-mal') $n.Inst.OrdnerReason
}

# =============================================================================
if (-not $PgPassword) {
    Write-Host "`n== PostgreSQL: uebersprungen (ohne -PgPassword)"
} else {
    Write-Host "`n== PostgreSQL ($PgBin, Port $PgPort)"
    $bin = Join-Path $tmp 'pgbin'
    New-Item -ItemType Directory -Path $bin | Out-Null
    foreach ($t in @('psql', 'pg_dump')) { New-Item -ItemType SymbolicLink -Path (Join-Path $bin "$t.exe") -Target (Join-Path $PgBin $t) | Out-Null }
    $pg = [pscustomobject]@{ Bin = $bin; Port = $PgPort; Host = 'localhost'; Superuser = 'postgres' }
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $db = "snailtest_$suffix"; $role = "snailtest_${suffix}_user"

    Test-Case 'Test-PgSuperuser: richtiges und falsches Passwort (pgpass mit : und \)' {
        $t = Test-PgSuperuser -Pg $pg -Password $PgPassword
        Assert $t.Ok $t.Message
        Assert ($t.Major -ge 14) "Major $($t.Major)"
        Assert (-not (Test-PgSuperuser -Pg $pg -Password 'falsch:\x').Ok) 'falsches Passwort muss scheitern'
        Assert (@(Get-ChildItem $script:StagingDir -Filter '*.pgpass').Count -eq 0) 'pgpass-Dateien geloescht'
    }
    Test-Case 'New-ProjectDatabase: anlegen, wiederholen (ALTER ROLE), Anmeldung mit SCRAM-Hash, Eigentuemer' {
        $pw1 = New-RandomPassword
        New-ProjectDatabase -Pg $pg -Password $PgPassword -DbName $db -Role $role -DbPassword $pw1
        $s = Get-PgObjectState -Pg $pg -Password $PgPassword -DbName $db -Role $role
        Assert ($s.RoleExists -and $s.DbExists -and $s.DbOwner -eq $role) ($s | ConvertTo-Json -Compress)
        $pw2 = New-RandomPassword
        New-ProjectDatabase -Pg $pg -Password $PgPassword -DbName $db -Role $role -DbPassword $pw2
        foreach ($case in @(@{ Pw = $pw2; Ok = $true }, @{ Pw = $pw1; Ok = $false })) {
            $env:PGPASSWORD = $case.Pw
            & (Join-Path $PgBin 'psql') -X -w -h 127.0.0.1 -p $PgPort -U $role -d $db -tAc "CREATE TABLE t (x int); DROP TABLE t;" 2>&1 | Out-Null
            $code = $LASTEXITCODE
            Remove-Item Env:PGPASSWORD
            Assert ($case.Ok -eq ($code -eq 0)) "Anmeldung mit Passwort ($($case.Ok)): Exitcode $code"
        }
        Assert-Equal 'UTF8' (Invoke-Psql -Pg $pg -Password $PgPassword -Sql "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname = '$db';").Output.Trim()
        $threw = $false
        try { New-ProjectDatabase -Pg $pg -Password $PgPassword -DbName $db -Role 'postgres_x' -DbPassword 'x' } catch { $threw = $_.Exception.Message -match 'gehört aber' }
        Assert $threw 'fremder Eigentuemer -> Fehler'
        Invoke-Psql -Pg $pg -Password $PgPassword -Sql 'DROP ROLE IF EXISTS postgres_x;' | Out-Null
        Assert-Equal -1 (Get-UserCount -Pg $pg -Password $PgPassword -DbName $db) 'ohne Tabelle users'
    }
    Test-Case 'Rest-Datenbank: Pruefung verlangt Haekchen, Sperre ohne, Uebernahme mit (Daten bleiben), Fortsetzen ohne' {
        $rdb = "snailtest_${suffix}_rest"; $rrole = "snailtest_${suffix}_rest_user"
        try {
            Assert-DbNotExisting -Pg $pg -Password $PgPassword -DbName $rdb -Role $rrole   # nichts da: kein Fehler
            # Rest einer von Hand entfernten Installation, mit Daten
            $alt = New-RandomPassword
            New-ProjectDatabase -Pg $pg -Password $PgPassword -DbName $rdb -Role $rrole -DbPassword $alt
            Invoke-Psql -Pg $pg -Password $PgPassword -Database $rdb -Sql "CREATE TABLE alt (x int); INSERT INTO alt VALUES (42); ALTER TABLE alt OWNER TO ""$rrole"";" | Out-Null
            $s = Get-PgObjectState -Pg $pg -Password $PgPassword -DbName $rdb -Role $rrole
            $c = Get-DbCollision -State $s -DbName $rdb -Role $rrole -Instances @()
            Assert ($c.Level -eq 'Warn' -and $c.Adopt) 'ohne Haekchen keine Installation'
            # ohne Haekchen: der Schritt Datenbank bricht ab, bevor etwas geaendert wird
            $threw = $false
            try { Assert-DbNotExisting -Pg $pg -Password $PgPassword -DbName $rdb -Role $rrole } catch { $threw = $_.Exception.Message -match "Datenbank '$rdb' und Rolle '$rrole' gibt es schon" }
            Assert $threw 'Sperre ohne Haekchen'
            # mit Haekchen: ALTER ROLE, Datenbank bleibt mit ihren Daten
            $neu = New-RandomPassword
            New-ProjectDatabase -Pg $pg -Password $PgPassword -DbName $rdb -Role $rrole -DbPassword $neu
            $env:PGPASSWORD = $neu
            $wert = & (Join-Path $PgBin 'psql') -X -w -h 127.0.0.1 -p $PgPort -U $rrole -d $rdb -tAc 'SELECT x FROM alt;' 2>&1
            $code = $LASTEXITCODE
            Remove-Item Env:PGPASSWORD
            Assert ($code -eq 0 -and "$wert".Trim() -eq '42') "alte Daten mit neuem Passwort lesbar: $code $wert"
            # Fortsetzen nach Abbruch desselben Ordners: Zugangsdatei nach dem Programmordner geschrieben
            $prog = Join-Path $tmp 'rest/AK/rest'
            New-Item -ItemType Directory -Path $prog -Force | Out-Null
            $cf = Join-Path $tmp 'rest/rest.txt'
            [System.IO.File]::WriteAllText($cf, "db_name=$rdb`r`ndb_benutzer=$rrole`r`n")
            $res = Test-ResumeRun -CredFile $cf -ProgDir $prog -DbName $rdb -Role $rrole
            $c = Get-DbCollision -State $s -DbName $rdb -Role $rrole -Instances @() -Resume $res
            Assert ($c.Level -eq 'Ok' -and $c.Resume -and -not $c.Adopt) ($c | ConvertTo-Json -Compress)
        } finally {
            Invoke-Psql -Pg $pg -Password $PgPassword -Sql "DROP DATABASE IF EXISTS ""$rdb"";" -NoThrow | Out-Null
            Invoke-Psql -Pg $pg -Password $PgPassword -Sql "DROP ROLE IF EXISTS ""$rrole"";" -NoThrow | Out-Null
        }
    }

    Write-Host "`n== Durchlauf mit der Vorlage (ZIP -> config.php -> migrate -> user:create -> services.json -> check)"
    $root = Join-Path $tmp 'AK2'
    $prog = Join-Path $root 'projekt'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -Path $st.Root -Destination $prog -Recurse
    $in = (New-InstanceInput -Service $svc -Values (New-TestValues @{ AdminEmail = 'admin@muster.de'; AdminName = 'Jörg Müller' })).Inst
    $plan = New-TestPlan $prog (Join-Path $tmp 'daten2/projekt') $in
    $plan.DbName = $db; $plan.DbUser = $role; $plan.Pg = $pg
    $dbPw = New-RandomPassword
    Test-Case 'Rolle/Datenbank, Datenordner, config.php' {
        New-ProjectDatabase -Pg $pg -Password $PgPassword -DbName $db -Role $role -DbPassword $dbPw
        New-DataFolders -Plan $plan
        foreach ($p in @($plan.DataDir, $plan.Paths.Temp)) { Assert (Test-Path $p) $p }
        $script:DurchlaufKey = New-AppKey
        Write-ProjectConfig -Plan $plan -DbPassword $dbPw -AppKey $script:DurchlaufKey | Out-Null
        Assert-Equal $script:DurchlaufKey (Read-InstalledConfig -ProgDir $prog -PhpExe $PhpExe).app.key 'app.key'
    }
    Test-Case 'migrate (zweimal), user:create (zweimal, Umlaute im Namen), Benutzerzahl' {
        $m = Invoke-ConsoleMigrate -Plan $plan
        Assert ($m.Count -ge 3) "Migrationen: $($m.Count)"
        Assert (Invoke-ConsoleMigrate -Plan $plan).UpToDate 'zweiter Lauf: aktuell'
        Assert-Equal 0 (Get-UserCount -Pg $pg -Password $PgPassword -DbName $db)
        $u = Invoke-ConsoleUserCreate -Plan $plan -Email 'admin@muster.de'
        Assert ($u.Passwort.Length -ge 12) 'Initialpasswort'
        Assert (Invoke-ConsoleUserCreate -Plan $plan).Existed 'zweiter Lauf: vorhanden'
        Assert-Equal 1 (Get-UserCount -Pg $pg -Password $PgPassword -DbName $db)
        Assert-Equal 'Jörg Müller' (Invoke-Psql -Pg $pg -Password $PgPassword -Database $db -Sql 'SELECT display_name FROM users;').Output.Trim() 'Umlaute (unter Linux; Windows: Test 3.9)'
        $script:InitPw = $u.Passwort
    }
    Test-Case 'Zugangsdaten-Datei: Werte, Zusammenfuehren' {
        $f = Save-InstallCredentials -Plan $plan -Values @{ db_name = $db; db_passwort = $dbPw }
        Save-InstallCredentials -Plan $plan -Values @{ admin_login = 'admin'; admin_initialpasswort = $script:InitPw } | Out-Null
        $h = Read-KeyValueFile $f
        Assert-Equal $dbPw $h['db_passwort']; Assert-Equal $script:InitPw $h['admin_initialpasswort']; Assert-Equal 'muster' $h['installation']
    }
    Test-Case 'services.json schreiben, url angleichen, Vorlage liest sie' {
        [System.IO.File]::WriteAllText($plan.ServicesJson, '{"format":1,"services":[{"key":"projekt","name":"Projektvorlage","installations":[{"key":"muster","name":"Muster GmbH","url":"http://falsch/"}]}]}')
        $r = Update-ServicesJson -Plan $plan
        Assert $r.Ok $r.Text
        Assert (@($r.Hints -match 'angeglichen').Count -eq 1) 'Hinweis url'
        $p = Test-WithVorlage $plan.ServicesJson
        Assert ($null -eq $p.error) "Vorlage: $($p.error)"
        Assert-Equal 'http://localhost:21100/' $p.services[0].installations[0].url
    }
    Test-Case 'php bin/console check: Exit 0, services.json ohne Warnung; Erkennung am Server' {
        $c = Invoke-ConsoleCheck -Plan $plan
        $fehler = @($c.Items | Where-Object Status -eq 'FEHLER' | ForEach-Object { "$($_.Label): $($_.Hint)" })
        Assert $c.Ok ("Exit $($c.ExitCode): " + ($fehler -join ' | '))
        $sj = @($c.Items | Where-Object { $_.Label -match 'services\.json|App-Switcher|Dienste' -and $_.Status -ne 'OK' })
        Assert-Equal 0 $sj.Count (($sj | ForEach-Object { "$($_.Label): $($_.Hint)" }) -join ' | ')
        $ak = @($c.Items | Where-Object { $_.Label -match 'app\.key' })
        Assert-Equal 1 $ak.Count 'Zeile app.key in check'
        Assert-Equal 'OK' $ak[0].Status "app.key: $($ak[0].Hint)"
        $cfgw = @($c.Items | Where-Object { $_.Status -ne 'OK' -and $_.Hint -match 'fehlen|CONFIG_VERSION' })
        Assert-Equal 0 $cfgw.Count (($cfgw | ForEach-Object { "$($_.Label): $($_.Hint)" }) -join ' | ')
        $x = @(Get-InstalledInstances -ProgRoot $root -PhpExe $PhpExe -Catalog $catalog.Services -Sites @([pscustomobject]@{ Name = 'projekt'; Bindings = 'http/*:21100:' }) -ServicesJson $plan.ServicesJson)
        Assert-Equal 1 $x.Count
        Assert-Equal $db $x[0].Db.Name 'db aus php bin\console info'
        Assert-Equal $role $x[0].Db.User
        Assert-Equal 'Muster GmbH' $x[0].Name
    }
    Test-Case 'Sicherung nach <Datenordner>\Sicherung (pg_dump + config.php), Anzeige' {
        $b = Backup-Installation -Plan $plan -Password $PgPassword
        Assert ($b.Dir.StartsWith((Join-Path $plan.DataDir 'Sicherung'))) $b.Dir
        Assert ((Get-Item (Join-Path $b.Dir "$db.dump")).Length -gt 1000) 'Dump nicht leer'
        Assert (Test-Path (Join-Path $b.Dir 'config.php')) 'config.php'
        $i = Get-BackupInfo -Root (Get-BackupRoot -Plan $plan)
        Assert-Equal 1 $i.Count; Assert ($i.Bytes -gt 1000)
        $plan2 = [pscustomobject]@{ DataDir = $null; Paths = $plan.Paths }
        Assert-Equal (Get-BackupRoot -Plan $plan) (Get-BackupRoot -Plan $plan2) 'ohne Datenordner: neben Data'
    }
    try {
        Invoke-Psql -Pg $pg -Password $PgPassword -Sql "DROP DATABASE IF EXISTS ""$db"";" | Out-Null
        Invoke-Psql -Pg $pg -Password $PgPassword -Sql "DROP ROLE IF EXISTS ""$role"";" | Out-Null
    } catch { Write-Host "  Aufraeumen: $($_.Exception.Message)" }
}

Remove-Staging
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("`n{0} bestanden, {1} fehlgeschlagen" -f $script:ok, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
