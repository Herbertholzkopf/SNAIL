# SNAIL 7 – Testcheckliste für Windows Server

Was sich unter Linux prüfen ließ, ist geprüft (Parser, PSScriptAnalyzer und `tests/SNAIL.Tests.ps1`:
Katalog, Eingaben, Ports, Datenpfade, `config.php` gegen die echte `config.example.php`,
`services.json` gegen `ServiceDirectory::parse()` der Vorlage, Erkennung der Installationen über
`php bin\console info`, Kollisionen von Datenbank/Rolle und Ordnername, psql-Schritte gegen PostgreSQL 16, Durchlauf ZIP → `config.php` → `migrate`
→ `user:create` → `check`). Hier steht, was nur Windows zeigen kann: Oberfläche, appcmd, icacls,
robocopy, Firewall, Windows-Aufgabe, `windows-pruefung.ps1` unter 5.1, WIPP-Dateien.

Alle Befehle in einer **Windows PowerShell 5.1 als Administrator**. `$pg` meint
`C:\Program Files\PostgreSQL\17\bin`, `$appcmd` meint `& "$env:windir\System32\inetsrv\appcmd.exe"`.
„SNAIL starten“: `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File C:\SNAIL\Projekt-Installer.ps1`.

Verwendete Installationen (Ports = Vorschläge auf einem frischen Server):

| Name | Dienst / Mandant | Ordner | Port |
|---|---|---|---|
| A | `projekt` / `muster` („Muster GmbH“) | `projekt` | 21100 |
| B | `projekt` / `beispiel` („Beispiel AG“) | `projekt-beispiel` | 21101 |
| C | `renate` / `muster` (Vorlage als Renate installiert) | `renate` | 21102 |

## 0 Vorbereitung

| # | Schritt | Erwartet |
|---|---|---|
| 0.1 | VM auf den Checkpoint mit fertigem WIPP zurücksetzen | `Test-Path C:\ProgramData\WIPP\postgres.json`, `php-pfad.txt`, `postgres-zugangsdaten.txt` → `True` |
| 0.2 | SNAIL nach `C:\SNAIL` (mit `projekte.json` und `logos\`); projektvorlage `main` als ZIP („Code → Download ZIP“) als `C:\SNAIL\projektvorlage-main.zip` | Dateien vorhanden, ZIP nicht entpackt |
| 0.3 | `Get-PSDrive -PSProvider FileSystem` | notieren, ob es ein Laufwerk **D:** gibt (für 1.4 und 8) |
| 0.4 | `Get-NetFirewallProfile \| Select Name, Enabled`; `netsh interface ipv4 show excludedportrange protocol=tcp` | Profile notieren; reservierte Bereiche notieren (liegt einer bei 21100–21110, schlägt SNAIL einen Port dahinter vor) |
| 0.5 | Prozess-Mitschnitt in einer **zweiten** Admin-PowerShell: `while ($true) { Get-CimInstance Win32_Process \| ForEach-Object { "$(Get-Date -f HH:mm:ss.fff) $($_.ProcessId) $($_.CommandLine)" } \| Add-Content C:\cmdlines.txt; Start-Sleep -Milliseconds 300 }` | läuft im Hintergrund (für 2.9) |

## 1 Start, Auswahl, Angaben, Prüfen

| # | Schritt | Erwartet |
|---|---|---|
| 1.1 | SNAIL starten | UAC, Fenster „SNAIL 7.2“, Kopf „[ 1 Auswahl ] 2 Angaben 3 Prüfen 4 Installation 5 Fertig“; „Auf diesem Server installiert“ **leer**; Katalog: Projektvorlage, Gertrud, Hildegard, Manfred, Movie-Manager3, Norbert, Olaf, Renate (mit Logos, wo vorhanden). Keine rote Meldung |
| 1.2 | `icacls C:\ProgramData\SNAIL` | nur Administratoren und SYSTEM `(OI)(CI)(F)`, keine geerbten Einträge |
| 1.3 | „Projektvorlage“ wählen → „Weiter“ | Seite „Angaben: Projektvorlage neu installieren“; Mandant „(neuer Mandant)“, Schlüssel `standard`, Port **21100** (bzw. erster freier dahinter) mit grünem „frei“, Upload-Grenze 250, Admin `admin`/`Administrator` |
| 1.4 | Ansehen: Datenordner und Kasten rechts unten | Datenordner `D:\AK\projekt` – **ohne D:** `C:\AKDaten\projekt`; Kasten: „Ordner/Site/Pool: projekt (erste Installation des Dienstes)“, Programm `C:\AK\projekt`, Datenbank `projekt` / Rolle `projekt_user`, Aufgabe `\AK\projekt Aufgabenplanung` |
| 1.5 | Schlüssel `muster`, Name `Muster GmbH`; Port auf `80` ändern | rot „gehört zur Website 'Default Web Site'“; zurück auf den Vorschlag → grün |
| 1.6 | Port auf eine Zahl aus einem reservierten Bereich (0.4) ändern, falls vorhanden | rot „von Windows reserviert (5985)“ (vollständig lesbar, auch als Tooltip); zurück |
| 1.7 | Häkchen „Im Netzwerk erreichbar“ setzen und wieder entfernen | Vorschau zeigt „SNAIL projekt (TCP 21100)“, Profile Domäne/Privat, private Bereiche; ohne Häkchen „keine Firewallregel …“ |
| 1.8 | „Details“ öffnen | Data/Cache/Logs/Temp unter dem Datenordner; „Abbrechen“ |
| 1.9 | Admin-Name `Jörg Müller`, E-Mail `admin@muster.test` → „Weiter“ | Seite „Prüfen: Projektvorlage - Muster GmbH“: ZIP vorbelegt (`C:\SNAIL\projektvorlage-main.zip`); ✓ Administrator, IIS, URL Rewrite, WebDAV „nicht installiert“, Firewall „für alle Profile aktiv“ (sonst ⚠ mit Profilnamen); ✓ Port „21100 frei …“, ✓ Firewallregel „keine …“; ✓ ZIP „… (Projektstamm 'projektvorlage-main' erkannt)“ – ohne Ziffern davor, ✓ Vorlage; ℹ Modus „Neuinstallation, Version …“; ✓ php.exe, PHP-Module, psql.exe, PostgreSQL, Superuser „Verbindung ok, PostgreSQL 17.x“ (Passwort automatisch aus WIPP); ✓ Datenbank „projekt (wird angelegt) / Rolle projekt_user (wird angelegt)“; ✓ Datenordner; ✓ services.json „wird angelegt“; ℹ Mandant „neuer Mandant 'muster' (Muster GmbH)“. Abschnitt „Sicherung“ **nicht** sichtbar |
| 1.10 | Radio „Vorhandenen Programmordner nutzen“ → „Erneut prüfen“ | ✗ Programmordner „C:\AK\projekt existiert nicht - ZIP-Datei wählen.“; zurück auf ZIP, „Erneut prüfen“ |

## 2 Erste Installation (A)

| # | Schritt | Erwartet |
|---|---|---|
| 2.1 | „Installieren“ → Bestätigung | nennt Ordner/Site/Pool `projekt`, Programm, Daten, Port 21100, Adresse `http://localhost:21100/`, Datenbank `projekt` (Rolle `projekt_user`) |
| 2.2 | „Ja“, Durchlauf abwarten | alle Schritte ✓ (⚠ bei `check` erlaubt): Programmcode, Datenordner, IIS, Rechte, PostgreSQL, config.php, migrate, user:create, services.json, Windows-Aufgabe, check, windows-pruefung. Kein Schritt „Firewallregel“ |
| 2.3 | Seite „Fertig“ | „Die Anwendung läuft unter http://localhost:21100/ … Selbstprüfung bestanden“; Anmeldung `admin`, Initialpasswort, DB-Passwort, Ordner; Hinweise: „Windows-Aufgabe '\AK\projekt Aufgabenplanung' eingerichtet - erster Lauf ohne Fehler“, „windows-pruefung.ps1 **0 Fehler** …“ |
| 2.4 | „Anwendung öffnen“, mit `admin` und Initialpasswort anmelden | Passwortwechsel erzwungen; Benutzer-Menü zeigt **„Jörg Müller“ mit Umlauten** (prüft die Übergabe an `php.exe`); App-Switcher zeigt „Projektvorlage“ |
| 2.5 | `$appcmd list apppool projekt /text:*` | `managedRuntimeVersion:""`, `processModel.identityType:"ApplicationPoolIdentity"` |
| 2.6 | `$appcmd list site projekt`, `$appcmd list vdir "projekt/"` | Binding `http/*:21100:`, `physicalPath:C:\AK\projekt\public` |
| 2.7 | `$appcmd list config projekt -section:system.webServer/security/authentication/anonymousAuthentication` und `… -section:system.webServer/security/requestFiltering` | `userName=""`; `maxAllowedContentLength="263192576"` (= 251 MB) oder ein höherer Serverwert; `C:\AK\projekt\public\web.config` ohne `requestLimits` |
| 2.8 | `icacls C:\AK\projekt`, `icacls D:\AK\projekt` (bzw. `C:\AKDaten\projekt`), `icacls C:\AK`, `icacls C:\AK\projekt\config.php` | Programm: Administratoren F, SYSTEM F, `IIS APPPOOL\projekt:(OI)(CI)(RX)`, nichts geerbt; Daten: … `IIS APPPOOL\projekt:(OI)(CI)(M)`; `C:\AK`: Administratoren F, SYSTEM F, `VORDEFINIERT\Benutzer:(OI)(CI)(RX)`; `config.php`: nur geerbt (I) |
| 2.9 | Prozess-Mitschnitt stoppen; `Select-String C:\cmdlines.txt -SimpleMatch '<DB-Passwort>'`, ebenso Superuser- und Initialpasswort | **keine Treffer** |
| 2.10 | `Get-Content C:\AK\projekt\config.php -Encoding Byte -TotalCount 5`; Datei ansehen | `60 63 112 104 112` (kein BOM); `'service' => 'projekt'`, `'installation' => 'muster'`, `'url' => 'http://localhost:21100/'`, `'data' => 'D:\\AK\\projekt\\Data'`, `'max_mb' => 250`, `'name' => ''` bei `session` |
| 2.11 | `php C:\AK\projekt\bin\console check` | `Ergebnis: Alles in Ordnung.` (oder „OK mit Warnungen“), `$LASTEXITCODE` 0; keine Warnung zu services.json oder Aufgabenplanung |
| 2.12 | `Get-Content C:\AK\services.json`; `C:\ProgramData\SNAIL\zugangsdaten\projekt.txt` + `icacls` darauf; neuestes `snail_*.log` nach dem Initialpasswort durchsuchen | services.json: Dienst `projekt`, `installations` als Liste mit `muster` / „Muster GmbH“ / `http://localhost:21100/`, ohne BOM. Zugangsdaten wie auf „Fertig“, nur Administratoren/SYSTEM. Log: „Initiales Passwort: ********“ |
| 2.13 | `Get-NetFirewallRule -Name SNAIL-* -ErrorAction SilentlyContinue` | keine Regel |

## 3 Zweiter Mandant desselben Dienstes (B), gleicher Mandant in zweitem Dienst (C)

| # | Schritt | Erwartet |
|---|---|---|
| 3.1 | „Zur Auswahl“ | oben „Projektvorlage - Muster GmbH“ (Ordner `projekt`, Port 21100, Version); im Katalog „Projektvorlage (1 installiert)“ |
| 3.2 | Katalog „Projektvorlage“ → „Weiter“ | Mandant-Liste enthält „muster - Muster GmbH (in projekt) - schon installiert“; Schlüssel leer; Port-Vorschlag **21101** |
| 3.3 | „muster …“ wählen → „Weiter“ | rote Meldung „… ist für den Mandanten 'muster' schon installiert (projekt) …“; der Port bleibt beim Vorschlag 21101 (springt **nicht** auf 21100) |
| 3.4 | „(neuer Mandant)“ (leert Schlüssel und Name, die rote Meldung verschwindet bei der ersten Änderung), Schlüssel `beispiel`, Name `Beispiel AG`, Häkchen **„Im Netzwerk erreichbar“** → „Weiter“ | Kasten: „projekt-beispiel (weitere Installation ('projekt' ist schon als projekt installiert))“, Datenbank `projekt_beispiel`; Prüfen: ℹ Firewallregel „wird angelegt: SNAIL projekt-beispiel (TCP 21101 …)“; ist das Netzwerk im Profil Öffentlich, zusätzlich ⚠ „Netzwerk im Profil Öffentlich: … - dort greift die Regel nicht …“ |
| 3.5 | „Installieren“ | Schritt „Firewallregel (im Netzwerk erreichbar)“ ✓, alle anderen ✓, windows-pruefung 0 Fehler |
| 3.6 | `Get-NetFirewallRule -Name SNAIL-projekt-beispiel \| Get-NetFirewallPortFilter`; `… \| Get-NetFirewallAddressFilter`; `(Get-NetFirewallRule -Name SNAIL-projekt-beispiel).Profile` | TCP 21101; RemoteAddress mit den privaten Bereichen; `Domain, Private` |
| 3.7 | Von einem anderen Rechner im LAN `http://<Server-IP>:21101/` und `:21100/` | 21101 antwortet (Anmeldeseite), 21100 nicht (keine Regel). Nur im Profil Domäne/Privat – im Profil Öffentlich antwortet auch 21101 nicht (siehe Warnung in 3.4) |
| 3.8 | `C:\AK\services.json` | Dienst `projekt` mit `muster` und `beispiel` in dieser Reihenfolge; eigene Ports in den URLs |
| 3.9 | Beide Anwendungen in zwei Tabs anmelden | Anmeldung gilt nicht über Kreuz; App-Switcher zeigt rechts beide Mandanten |
| 3.10 | Katalog „Renate“ → Mandant „muster - Muster GmbH (in projekt)“ wählen | Schlüssel `muster` fest, Name „Muster GmbH“ übernommen, Port 21102, Kasten `renate` / Datenbank `renate` |
| 3.11 | „Weiter“ → ZIP `C:\SNAIL\projektvorlage-main.zip` per „…“ wählen → „Erneut prüfen“ → „Installieren“ | ✓ Mandant „'muster' gibt es schon in projekt …“, ✓ Logo „png … -> logos/renate.png“; alle Schritte ✓ |
| 3.12 | `C:\AK\logos\renate.png` und `C:\AK\services.json` ansehen; in A über den App-Switcher zu Renate wechseln | Logo-Datei da; Dienst `renate` mit `"logo": "logos/renate.png"` und Installation `muster`; beim Wechsel bleibt der Mandant „Muster GmbH“ ausgewählt, das Logo erscheint |

## 4 Einrichtung wiederholen

| # | Schritt | Erwartet |
|---|---|---|
| 4.1 | Auswahl: „Projektvorlage - Muster GmbH“ (oben) → „Weiter“ | direkt „Prüfen“ (keine Angaben-Seite); Radio „Vorhandenen Programmordner nutzen … (= Einrichtung wiederholen; ZIP = Aktualisieren)“; ℹ Modus „Einrichtung wiederholen …“; ✓ Installation „projekt/muster in C:\AK\projekt, Version …“; ✓ Website „… wird angeglichen, Bindings bleiben.“; ✓ config.php „vorhanden - bleibt unverändert“ |
| 4.2 | Vorher: `$appcmd set site projekt /+bindings.[protocol='http',bindingInformation='*:21199:']`; Hash merken: `Get-FileHash C:\AK\projekt\config.php` | – |
| 4.3 | „Installieren“ | alle Schritte ✓; Protokoll „Website 'projekt' vorhanden - Bindings bleiben unverändert (http/*:21100:,http/*:21199:)“, „1 Benutzerkonto(en) vorhanden - kein neuer Administrator“; „Fertig“: „Die vorhandene config.php wurde übernommen.“ |
| 4.4 | `$appcmd list site projekt`; Hash der `config.php`; Anmeldung mit dem Passwort aus 2.4 | Bindings **beide** noch da; Hash unverändert; Anmeldung klappt |
| 4.5 | Zusatzbinding entfernen: `$appcmd set site projekt /-bindings.[protocol='http',bindingInformation='*:21199:']` | – |

## 5 Aktualisieren

| # | Schritt | Erwartet |
|---|---|---|
| 5.1 | Neuen Stand bauen: ZIP nach `C:\neu` entpacken, in `C:\neu\projektvorlage-main\config\app.php` `'version' => '0.1.1'` setzen, `C:\neu\projektvorlage-main\NEU.txt` anlegen, `Compress-Archive C:\neu\projektvorlage-main C:\SNAIL\projektvorlage-neu.zip` | ZIP mit Zwischenordner |
| 5.2 | `New-Item C:\AK\projekt\ALT.txt`; Hash der `config.php` merken | – |
| 5.3 | Auswahl A → ZIP `C:\SNAIL\projektvorlage-neu.zip` → „Erneut prüfen“ | ℹ Modus „Aktualisieren: … -> 0.1.1 …“, ℹ Sicherung „pg_dump + config.php nach D:\AK\projekt\Sicherung\<Zeit> - vorhanden: noch keine …“; Abschnitt „Sicherung vor dem Aktualisieren“ sichtbar; Schaltfläche „Aktualisieren“ |
| 5.4 | „Aktualisieren“ | Schritte: Sicherung, Programmcode aktualisieren (robocopy /MIR), Datenordner, IIS, Rechte, migrate, services.json, Windows-Aufgabe, check, windows-pruefung – alle ✓; **kein** PostgreSQL-, config.php- oder user:create-Schritt. „Fertig“: Zeile „Sicherung : D:\AK\projekt\Sicherung\<Zeit> (32 KB)“ – Dump und config.php zusammen, wie auf „Prüfen“ (kleine Sicherungen in KB), Hinweis zu neuen Konfigurationsschlüsseln, Schaltfläche „config.php öffnen“ |
| 5.5 | Programmordner prüfen | `NEU.txt` da, `ALT.txt` weg, `src\Support\Config.php` **vorhanden**, `config.php`-Hash unverändert; `icacls C:\AK\projekt\NEU.txt` nur geerbt |
| 5.6 | `icacls D:\AK\projekt\Sicherung`; Inhalt; `& $pg\pg_restore.exe -l <dump>` | nur Administratoren/SYSTEM, keine geerbten Einträge (kein App-Pool); `projekt.dump` und `config.php`; pg_restore listet Tabellen |
| 5.7 | Protokoll | „App-Pool 'projekt' angehalten.“ vor robocopy, „… gestartet.“ danach; robocopy-Exitcode < 8 |
| 5.8 | Anwendung öffnen | Version 0.1.1 auf der Anmeldeseite |
| 5.9 | Erneut aktualisieren (A, gleiche ZIP): Häkchen „Sicherung überspringen“ setzen | „Aktualisieren“ wird **grau** (Hintergrund, nicht nur die Schrift), das zweite Häkchen wird bedienbar |
| 5.10 | „Ich habe eine andere funktionierende Sicherung …“ setzen → „Aktualisieren“ | Bestätigung nennt „Sicherung: ÜBERSPRUNGEN (andere Sicherung bestätigt)“; kein Schritt „Sicherung“; Protokoll „Sicherung übersprungen: Der Anwender hat bestätigt …“; „Fertig“: „Sicherung : übersprungen …“; Prüfen hatte „vorhanden: 1 Sicherung(en), zusammen … MB“ gezeigt |

## 6 Katalog ausgetauscht

| # | Schritt | Erwartet |
|---|---|---|
| 6.1 | SNAIL schließen; `projekte.json` sichern und durch einen Katalog ersetzen, der **nur** `{"format":1,"dienste":[{"key":"olaf","name":"Olaf"}]}` enthält | – |
| 6.2 | SNAIL starten | oben weiterhin A, B, C (Namen aus der `services.json`: „Projektvorlage - Muster GmbH“, „Projektvorlage - Beispiel AG“, „Renate - Muster GmbH“); Katalog nur „Olaf“ |
| 6.3 | B wählen → „Weiter“ → „Installieren“ (wiederholen) | ℹ Katalog „Dienst 'projekt' steht nicht im Katalog - services.json behält Logo, Icon und Beschreibung.“; alle Schritte ✓; `services.json` unverändert bis auf ggf. die url |
| 6.4 | Originale `projekte.json` zurück, „Neu einlesen“ | Katalog wieder vollständig |

## 7 Fehlerfälle und Abbruch

| # | Schritt | Erwartet |
|---|---|---|
| 7.1 | Neuinstallation Projektvorlage, Mandant `abbruch`, Port-Vorschlag; sobald „PostgreSQL: Rolle und Datenbank“ läuft: Fenster schließen (X) → „Nein“ | läuft weiter |
| 7.2 | Erneut X → „Ja“ | laufender Schritt wird fertig, Protokoll „Abbruch angefordert …“, „Abgebrochen auf Wunsch … - beim nächsten Lauf geht es dort weiter“, „=== … abgebrochen ===“ – beide Zeilen als Warnung, nicht Fehler, Fenster schließt; `config.php` gibt es noch nicht |
| 7.3 | SNAIL starten | „projekt-abbruch“ steht **nicht** oben (keine `config.php`); Katalog → Mandant `abbruch` → Kasten `projekt-abbruch`; Prüfen: ✓ Datenbank „(vorhanden) / Rolle (vorhanden) - Fortsetzen nach Abbruch (laut Zugangsdatei dieses Ordners), Passwort der Rolle wird neu gesetzt“ – **kein** Kasten „Vorhandene Datenbank“, kein Häkchen nötig; Port-Vorschlag = Port der schon angelegten Website `projekt-abbruch` mit grünem „frei“; Website „gibt es schon … wird angeglichen, Bindings bleiben“; ✓ Port – **kein** „von Windows reserviert“ (HTTP.sys trägt den Port der laufenden Website in die excludedportrange ein) |
| 7.4 | „Installieren“ (ohne die Website vorher anzuhalten) | alle Schritte ✓, `check` grün |
| 7.5 | Fehler nach der `config.php`: ZIP nach `C:\AK\projekt-fehler` entpacken (Inhalt von `projektvorlage-main` direkt), `database\migrations\9999_kaputt.sql` mit `SELECT kaputt(;` anlegen; Neuinstallation Mandant `fehler` mit „Vorhandenen Programmordner nutzen“ | config.php ✓, `migrate` ✗ rot, Fehlertext nennt die Ursache („… [FEHLER] Migration 9999_kaputt.sql fehlgeschlagen …“, nicht „^“), „Erneut versuchen“ aktiv |
| 7.6 | `9999_kaputt.sql` löschen → „Erneut versuchen“ | Protokoll „Datenbank projekt_fehler, Rolle projekt_fehler_user, Passwort aus der vorhandenen config.php.“; alle Schritte ✓, die Schrittliste links zeigt dabei **alle** Schritte mit Status |
| 7.7 | Datenordner auf `X:\AK\projekt-x` ändern → „Weiter“ | Prüfen: ✗ Datenordner „… Laufwerk von X:\AK\projekt-x\… fehlt oder ist kein Festplattenlaufwerk.“ (kein Absturz) |
| 7.8 | „Details“: Temp auf ein anderes Laufwerk als Data legen bzw. Data in `C:\AK\projekt-x\daten` | ✗ „paths.temp … muss auf demselben Laufwerk liegen …“ bzw. „… liegt im Programmordner …“ |
| 7.8a | Abbruch **nach** der config.php: Neuinstallation Mandant `spaet`, Name „Spät GmbH“, während `user:create` bzw. `services.json` X → „Ja“; SNAIL neu starten | oben „Projektvorlage - Spät GmbH“ (Name aus der Zugangsdatei, nicht der Schlüssel); Wiederholen → `services.json` enthält `"name": "Spät GmbH"` |
| 7.9 | Katalog `projekte.json` im alten Format (Projektliste mit MySQL) neben das Skript legen → „Neu einlesen“ | „Diese projekte.json hat das alte Format …“; Installationen oben werden trotzdem angezeigt. Datei zurück |

## 7a Datenbank-Kollision

Datenbank und Rolle folgen aus dem Ordner (`-` → `_`): Mandant `kol-a` und Mandant `kol_a` ergeben beide `projekt_kol_a` / `projekt_kol_a_user`.

| # | Schritt | Erwartet |
|---|---|---|
| 7a.1 | Neuinstallation Projektvorlage, Mandant `kol-a` → installieren | Ordner `projekt-kol-a`, Datenbank `projekt_kol_a`, alle Schritte ✓ |
| 7a.2 | Neuinstallation Projektvorlage, Mandant `kol_a` → „Weiter“ | Kasten `projekt-kol_a`, Datenbank `projekt_kol_a`; Prüfen: ✗ Datenbank „Datenbank 'projekt_kol_a' und Rolle 'projekt_kol_a_user' gehören zur Installation projekt-kol-a (projekt/kol-a).“, **kein** Kasten „Vorhandene Datenbank“, „Installieren“ grau |
| 7a.3 | `projekt-kol-a` von Hand entfernen: im IIS-Manager Website und App-Pool `projekt-kol-a` löschen, Ordner `C:\AK\projekt-kol-a` und die Aufgabe `\AK\projekt-kol-a Aufgabenplanung` löschen (Datenordner, Datenbank und Zugangsdatei bleiben). SNAIL neu starten, Neuinstallation Mandant `kol_a` | Prüfen: ⚠ Datenbank „… (vorhanden) / Rolle … (vorhanden) - gehört zu keiner erkannten Installation …“; Die lange Meldung geht in Folgezeilen weiter (nicht mit „…“ abgeschnitten). Kasten „Vorhandene Datenbank“ mit Häkchen „Vorhandene Datenbank 'projekt_kol_a' übernehmen (alte Daten bleiben erhalten)“, nicht gesetzt; Hinweis unten nennt das Häkchen; „Installieren“ **grau** |
| 7a.4 | Häkchen setzen, dann „Erneut prüfen“ | mit Häkchen wird „Installieren“ aktiv; nach „Erneut prüfen“ ist das Häkchen wieder leer und „Installieren“ grau |
| 7a.5 | Häkchen setzen → „Installieren“ | Bestätigung nennt „Datenbank: VORHANDENE wird übernommen (alte Daten bleiben erhalten)“; Protokoll ⚠ „Vorhandene Datenbank wird übernommen (projekt_kol_a / Rolle projekt_kol_a_user): vom Anwender bestätigt …“; alle Schritte ✓, Administrator „Benutzer 'admin' war bereits vorhanden“ (Konto aus der alten Datenbank), im Protokoll dazu „Exit-Code 1“ als Info, **keine** Error-Zeile; `check` grün; Fertig-Seite zeigt **kein** neues Initialpasswort |
| 7a.6 | Gleicher Ordner nach Entfernen von Hand: `projekt-kol_a` wie in 7a.3 entfernen (Zugangsdatei `C:\ProgramData\SNAIL\zugangsdaten\projekt-kol_a.txt` **liegen lassen**), Neuinstallation Mandant `kol_a` | ⚠ mit Häkchen wie 7a.3 – **nicht** „Fortsetzen nach Abbruch“ (der Programmordner fehlt bzw. ist neuer als die Zugangsdatei) |
| 7a.7 | Zurück, Mandant `kol-x`; vorher `$appcmd add apppool /name:projekt-kol-x` | Prüfen: ✗ App-Pool „'projekt-kol-x' gibt es schon, ohne Website und Programmordner …“. Danach `$appcmd delete apppool projekt-kol-x` |
| 7a.8 | Aufräumen: `projekt-kol_a` wie in 7a.3 entfernen; `& "$pg\psql.exe" -U postgres -c "DROP DATABASE projekt_kol_a;"`, danach genauso `DROP ROLE projekt_kol_a_user;` (Passwort bei der Abfrage eingeben), Zugangsdateien `projekt-kol-a.txt`/`projekt-kol_a.txt` löschen | – |

## 8 Server ohne D:

| # | Schritt | Erwartet |
|---|---|---|
| 8.1 | Hat die VM **kein** D: (0.3), ist das mit 1.4 und 2.x geprüft: Daten unter `C:\AKDaten\projekt`, `paths.*` in der `config.php` dorthin, `check` „Temp- und Data-Pfad auf demselben Laufwerk“ ✓, Sicherung unter `C:\AKDaten\projekt\Sicherung` | wie beschrieben |
| 8.2 | Hat die VM ein D:: im Katalog `"datenOrdner": "X:\\AK"`, „Neu einlesen“, Katalog Projektvorlage → Mandant `ohned` | Datenordner-Vorschlag `C:\AKDaten\projekt-ohned` |

## 9 Server ohne WIPP-Dateien

| # | Schritt | Erwartet |
|---|---|---|
| 9.1 | SNAIL schließen; `Rename-Item C:\ProgramData\WIPP WIPP.weg` | – |
| 9.2 | SNAIL starten, A wählen | Protokoll „WIPP-Schnittstelle: nicht gefunden …“; Installationen trotzdem erkannt (php.exe über FastCGI/PATH); Prüfen: Passwortfeld leer, „Keine WIPP-Zugangsdaten gefunden …“; ✓ psql.exe „… (gefunden unter C:\Program Files\PostgreSQL)“; ✗ Superuser „Passwort … fehlt“ |
| 9.3 | Passwort eintippen → „Verbindung testen“ | grün, Prüfung läuft neu ohne Fehler; Wiederholen klappt |
| 9.4 | `Rename-Item C:\ProgramData\WIPP.weg WIPP` | wiederhergestellt |

## 10 Prüfskript je Installation und EXE

| # | Schritt | Erwartet |
|---|---|---|
| 10.1 | Je Installation (A, B, C und ggf. abbruch/fehler): `powershell -ExecutionPolicy Bypass -File C:\AK\<Ordner>\tools\windows-pruefung.ps1 -Url http://localhost:<Port>` | jeweils **0 Fehler** (Warnungen notieren) |
| 10.2 | `powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\SNAIL\Build-Projekt-Installer.ps1` | `C:\SNAIL\Projekt-Installer.exe`; Eigenschaften → Details: Produkt „SNAIL …“, Version 7.2.0.0 |
| 10.3 | EXE per Doppelklick, A wiederholen | UAC, Fenster wie 1.1; Lauf ✓, windows-pruefung läuft unter powershell.exe 5.1 |

## Ergebnis festhalten

Bei Abweichungen: Nummer, Bildschirmfoto, neuestes `C:\ProgramData\SNAIL\snail_*.log` und – falls vorhanden – den Prüfbericht aus `C:\ProgramData\SNAIL\pruefberichte\` an die Entwicklung (oder Claude) geben.
