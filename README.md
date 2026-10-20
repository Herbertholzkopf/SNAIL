# SNAIL

## Simple New-project Automation &amp; Installation Launcher

Ein grafischer Assistent für Windows Server, der Anwendungen auf Basis der **projektvorlage** (PHP 8.3+, IIS, PostgreSQL, `config.php`) **installiert und aktualisiert**: Programmcode aus der GitHub-ZIP, Datenordner, IIS-App-Pool und Website, gehärtete Ordnerrechte, optional eine Firewallregel, PostgreSQL-Rolle und Datenbank, `config.php`, Migrationen, erster Administrator, Eintrag in der `services.json` (App-Switcher), Windows-Aufgabe – und zum Schluss die Selbstprüfung der Anwendung und das Prüfskript der Vorlage.

Den Server richtet vorher **[WIPP](../WIPP)** ein (IIS, PHP, PostgreSQL, pgAdmin, optional Python). SNAIL liest dessen Schnittstellendateien unter `C:\ProgramData\WIPP` und funktioniert ohne sie auch auf einem anders eingerichteten Server. Der Vertrag zwischen SNAIL und den Anwendungen steht in der projektvorlage unter `docs/03-installation-betrieb.md`.

SNAIL 7 ist nur für die projektvorlage (PostgreSQL, `config.php`); MySQL und `.env` gibt es nicht mehr. Entfernen von Installationen gehört bewusst nicht zum Umfang.

## Katalog und Server

| | Woher | Inhalt |
|---|---|---|
| **Katalog** | `projekte.json` neben der EXE – wird mit SNAIL ausgeliefert, wächst mit jedem neuen Programm und wird bei jedem SNAIL-Update mitkopiert | welche Programme es gibt (`dienste`): Name, Icon, Farbe, Logo, Beschreibung, vorgeschlagene ZIP, Upload-Grenze, zusätzliche PHP-Module, `braucht` |
| **Installationen** | vom Server: jeder Ordner `C:\AK\<Ordner>` mit `config.php` **und** `bin\console` → `php bin\console info` | Dienst (`app.service`), Mandant (`app.installation`), Adresse, Pfade, Datenbank (ohne Passwort), Upload-Grenze, Version. Port aus dem IIS-Binding der gleichnamigen Website, Mandanten-Name aus der `services.json` |

Es gibt keine zusätzliche Zustandsdatei: Wird der Katalog ausgetauscht, erkennt SNAIL die Installationen trotzdem (fehlt ein Dienst im Katalog, gilt sein Name aus der `services.json` bzw. `app.name`). Mehrere Mandanten desselben Programms auf einem Server – mit eigenem Port und eigener öffentlicher Adresse – sind der Normalfall.

## Ablauf

1. **Auswahl** – zwei Bereiche: „Auf diesem Server installiert“ (Dienst – Mandant, Ordner, Port, Adresse, Version) und „Katalog – neu installieren“.
2. **Angaben** (nur Neuinstallation) – siehe [Eingabeseite](#eingabeseite).
3. **Prüfen** – bevor irgendetwas geändert wird: Administrator, IIS/appcmd, URL Rewrite, WebDAV (Warnung), Windows-Firewall aktiv (Warnung), PHP-Version und -Module nach `requirements` der Vorlage, Python (falls `braucht`), psql, PostgreSQL erreichbar und Superuser-Anmeldung, Programmcode nach Vorlage aufgebaut, Port frei, Datenpfade, Datenbank, `services.json`, Mandanten-Schlüssel, Logo. Eingaben: ZIP-Datei oder vorhandener Programmordner, beim Aktualisieren die Sicherung, Superuser-Passwort (mit „Verbindung testen“).
4. **Installation** – Schrittliste mit Live-Status und Protokoll daneben. Jeder Schritt ist wiederholbar; „Erneut versuchen“ macht dort weiter, wo es geklemmt hat.
5. **Fertig** – Zugangsdaten zum Kopieren, Sicherung (Ort, Größe), Hinweise von `php bin\console check`, Ergebnis von `tools\windows-pruefung.ps1`; Schaltflächen: Anwendung öffnen, lokal öffnen, `config.php` öffnen, Prüfbericht, Zugangsdaten-Datei, zurück zur Auswahl.

| Auswahl | Programmcode | Modus |
|---|---|---|
| Katalog | ZIP (oder ein schon befüllter Ordner ohne `config.php`) | **Neuinstallation** |
| Installiert | vorhandener Ordner | **Einrichtung wiederholen** – alles angleichen, Code bleibt |
| Installiert | ZIP | **Aktualisieren** |

### Eingabeseite

| Feld | Vorschlag | Hinweis |
|---|---|---|
| Mandant | Auswahl der Schlüssel aus der `services.json` + „neuer Mandant“ | **gleicher Kunde in mehreren Diensten = gleicher Schlüssel**, sonst verliert der App-Switcher den Mandanten beim Programmwechsel. Schlüssel, die für diesen Dienst schon installiert sind, sind markiert |
| Mandanten-Schlüssel | `standard` bei der allerersten Installation, sonst leer | `app.installation`: `a-z`, `0-9`, `_`, `-`, erstes Zeichen Buchstabe oder Ziffer, max. 64 |
| Mandanten-Name | aus der `services.json` beim gewählten Schlüssel | Anzeige im App-Switcher; steht zusätzlich in der Zugangsdatei, damit er einen Abbruch vor dem `services.json`-Schritt übersteht |
| Öffentliche URL | leer = `http://localhost:<port>/` | `app.url` und `url` in der `services.json`; falls ein Cloudflare Tunnel genutzt wird, die `https://…`-Adresse |
| Port | nächster freie ab `einstellungen.portStart` (21100); gibt es die Website schon (abgebrochener Lauf), deren Port | frei heißt: in keinem IIS-Binding, kein TCP-Listener, nicht in `netsh interface ipv4 show excludedportrange protocol=tcp`. HTTP.sys trägt den Port jeder laufenden Website dort ein – der Port der eigenen Website zählt deshalb nicht als reserviert. Änderbar, die Eingabe wird genauso geprüft |
| Upload-Grenze (MB) | aus dem Katalog (`uploadsMaxMb`, Standard 25) | `uploads.max_mb` und IIS-Grenze der Website |
| Admin-Login, -Name, -E-Mail | `admin`, `Administrator`, leer | die E-Mail braucht die Cloudflare-SSO-Anmeldung |
| Datenordner | `D:\AK\<Ordner>`; ohne D: (oder kein Festplattenlaufwerk) `C:\AKDaten\<Ordner>` | darin Data, Cache, Logs, Temp; einzeln änderbar unter „Details“ |
| Im Netzwerk erreichbar | aus | legt eine Firewallregel an (Vorschau auf der Seite) – ohne Häkchen ist der Port nur auf dem Server erreichbar; das reicht, falls ein Cloudflare Tunnel auf `localhost:<port>` zeigt |
| Cloudflare Access | leer | `cloudflare.team_domain`, `.aud`, `.guard` – nur falls genutzt |
| E-Mail-Versand | aus | `mail.*`; das Passwort landet nur in der `config.php` |

Ordner/Site/App-Pool, Programmordner, Datenbank und Windows-Aufgabe werden daneben **angezeigt, nicht eingegeben** – sie folgen aus Dienst und Mandanten-Schlüssel.

### Schritte

| Schritt | Neuinstallation / Wiederholen | Aktualisieren |
|---|---|---|
| Sicherung | – | `pg_dump -Fc` + Kopie der `config.php` nach `<Datenordner>\Sicherung\<Zeit>\` (nur Administratoren/SYSTEM). Abwählbar nur mit dem Pflicht-Häkchen „Ich habe eine andere funktionierende Sicherung (z. B. Veeam/VM-Sicherung)“ – steht im Protokoll |
| Programmcode | ZIP in einen Temp-Ordner außerhalb von `C:\AK` entpacken, Projektstamm erkennen (Ordner mit `bin\console` und `public\index.php`, auch bei doppelter Verschachtelung), mit `robocopy /MIR` nach `C:\AK\<Ordner>`, Temp-Ordner löschen | App-Pool anhalten, `robocopy /MIR … /XF C:\AK\<Ordner>\config.php` (voller Pfad!), App-Pool starten |
| Datenordner | Data, Cache, Logs, Temp anlegen | fehlende ergänzen (Pfade aus der `config.php`) |
| IIS | App-Pool (kein verwalteter Code, ApplicationPoolIdentity), Website auf `<Ordner>\public`, Binding `http *:<port>:` **nur beim Anlegen**, anonyme Anfragen als App-Pool-Benutzer (`userName=""`), Upload-Grenze je Website (`/commit:apphost`) | angleichen – **Bindings einer vorhandenen Website fasst SNAIL nie an** |
| Rechte | Programmordner, Datenordner, `C:\AK` (siehe [Rechte](#rechte)) | angleichen |
| Firewall | nur auf Wunsch: Regel `SNAIL <Ordner> (TCP <port>)` | – |
| PostgreSQL | Rolle und Datenbank (siehe [PostgreSQL](#postgresql)) | – |
| `config.php` | aus `config.example.php`; eine vorhandene wird **nie** überschrieben | – (bleibt) |
| `migrate` | `php bin\console migrate` | ebenso |
| Administrator | `php bin\console user:create <login> "<Name>" admin [email]`, Initialpasswort wird angezeigt und abgelegt. Beim Wiederholen nur, wenn es noch **kein** Benutzerkonto gibt | – |
| `services.json` | Dienst und Installation ergänzen/angleichen, Logo nach `C:\AK\logos\` | ebenso |
| Windows-Aufgabe | `setup\Aufgabenplanung\aufgabe_erstellen.ps1 -ProjektPfad … -PhpExe … -Unbeaufsichtigt` (Exit 0/1/2/3), danach einmal anstoßen (`Start-ScheduledTask`), Ende abwarten (höchstens 2 Minuten), Ergebnis 0 erwartet, sonst Warnung | ebenso |
| `check` | `php bin\console check` – Exit 0 = startklar (Warnungen auf „Fertig“), Exit 1 = Einrichtung fehlgeschlagen | ebenso; neue Konfigurationsschlüssel meldet `check` als Hinweis |
| Prüfskript | `tools\windows-pruefung.ps1 -Url http://localhost:<port>` unter **Windows PowerShell 5.1**, Bericht nach `C:\ProgramData\SNAIL\pruefberichte\` | ebenso |

`services.json`, Windows-Aufgabe und Prüfskript halten die Installation nicht an: Scheitern sie, steht der Grund rot auf „Fertig“. Alle anderen Schritte bauen aufeinander auf und brechen bei einem Fehler ab. **Neue Konfigurationsschlüssel** nach einem Update ergänzt SNAIL nicht selbst – die Anwendung läuft mit Standardwerten weiter (Vorlage, `docs/04`), `check` nennt sie, „Fertig“ bietet „config.php öffnen“.

## Namen und Ordner

| | Erste Installation eines Dienstes | Jede weitere desselben Dienstes |
|---|---|---|
| `<Ordner>` | `<dienst>` (z. B. `olaf`) | `<dienst>-<installation>` (z. B. `olaf-beispiel`) |
| Programm | `C:\AK\olaf` | `C:\AK\olaf-beispiel` |
| Daten (Vorschlag) | `D:\AK\olaf\{Data,Cache,Logs,Temp}` | `D:\AK\olaf-beispiel\…` |
| IIS-Site, App-Pool | `olaf` | `olaf-beispiel` |
| Windows-Aufgabe | `\AK\olaf Aufgabenplanung` | `\AK\olaf-beispiel Aufgabenplanung` |
| Datenbank / Rolle | `olaf` / `olaf_user` | `olaf_beispiel` / `olaf_beispiel_user` |

„Erste Installation“ entscheiden die am Server gefundenen Installationen: Gibt es den Dienst schon, wird es `<dienst>-<installation>`. Ist der Dienst noch nicht installiert, aber `C:\AK\<dienst>` trotzdem belegt (dort liegt eine `config.php`, oder eine fremde IIS-Website heißt so, z. B. eine alte Site `Olaf` aus `C:\inetpub`), ebenfalls.

## Der Katalog (projekte.json)

```json
{
  "format": 1,
  "einstellungen": {
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
      "key": "olaf",
      "name": "Olaf",
      "icon": "package",
      "tone": "info",
      "logo": "logos/olaf.svg",
      "description": "Warenwirtschaft",
      "zip": "olaf-main.zip",
      "uploadsMaxMb": 250,
      "phpModule": [],
      "braucht": ["python"]
    }
  ]
}
```

**`einstellungen`** (alles optional)

| Feld | Standard | Bedeutung |
|---|---|---|
| `programmOrdner` | `C:\AK` | Programme; dort liegen auch `services.json` und `logos\` |
| `datenOrdner` | `D:\AK` | Vorschlag für den Datenordner (`<datenOrdner>\<Ordner>`); fehlt das Laufwerk: `C:\AKDaten` |
| `zeitzone` | `Europe/Berlin` | `app.timezone` |
| `portStart` | `21100` | ab hier schlägt SNAIL den nächsten freien Port vor (1024–65535) |
| `phpExe` | leer | übersteuert `php-pfad.txt` von WIPP (Datei oder Ordner) |
| `psqlBin` | leer | übersteuert `bin` aus `postgres.json` (Ordner mit `psql.exe`, `pg_dump.exe`) |
| `postgresPort` | `0` | übersteuert `port` aus `postgres.json` (0 = automatisch, ohne WIPP 5432) |

**`dienste[]`**

| Feld | Pflicht | Bedeutung |
|---|---|---|
| `key` | ja | `app.service` und Schlüssel in der `services.json`: `a-z`, `0-9`, `_`, `-`, erstes Zeichen Buchstabe oder Ziffer, max. 64 |
| `name` | ja | Anzeigename, `app.name` (ohne Mandant), `mail.from_name` |
| `icon`, `tone`, `description` | – | für die `services.json` (Icon aus dem Designsystem; `tone`: `info`, `success`, `warning`, `danger`, `primary`, `purple`, `amber`, `muted`, `neutral`) |
| `logo` | – | Bilddatei neben der `projekte.json` (z. B. `logos/olaf.svg`), wird mit SNAIL ausgeliefert; svg, png, webp, jpg, höchstens 1 MB, Format am Inhalt erkannt (Base64 geht auch). SNAIL kopiert es nach `C:\AK\logos\<dienst>.<ext>` |
| `zip` | – | vorgeschlagene ZIP-Datei (relativ zur `projekte.json`); auf „Prüfen“ per Dateidialog änderbar |
| `uploadsMaxMb` | – | Vorschlag für die Upload-Grenze (1–4000, Standard 25) |
| `phpModule` | – | zusätzliche PHP-Module über `requirements.extensions` der Vorlage hinaus |
| `braucht` | – | `["python"]`: SNAIL prüft, dass `python.exe` vorhanden ist (PATH, Registry; WIPP installiert es optional), und trägt den Pfad als `python.exe` in die `config.php` ein, **wenn** die `config.example.php` des Projekts diesen Schlüssel hat. Die Skripte laufen über den Aufgabenplaner der Anwendung (`tasks:run`), nicht als eigene Windows-Aufgaben |

Eine `projekte.json` im alten Format (Projektliste mit MySQL) lehnt SNAIL mit einem Hinweis ab; ein Feld `installationen` wird ignoriert und gemeldet.

## config.php

SNAIL schreibt die `config.php` aus der `config.example.php` der Vorlage per **Textersetzung**: Zeile für Zeile wird der Bereich (`'db' => [`) verfolgt und nur das Literal hinter `'schlüssel' =>` ersetzt – Kommentare, Reihenfolge und `CONFIG_VERSION` bleiben wie in der Vorlage. In `'…'` werden nur `\` und `'` maskiert (Vertrag: nur Literale). Fehlt ein Pflichtschlüssel, bricht der Schritt mit Namen ab; optionale Schlüssel (`python.exe`) werden nur gesetzt, wenn die Vorlage sie hat.

Gesetzt werden `app.name`, `app.url`, `app.timezone`, `app.service`, `app.installation`, `db.host/port/name/user/password`, `paths.data/cache/logs/temp/services_json` (absolut), `uploads.max_mb`, `mail.from_name` und – falls angegeben – `cloudflare.*`, `mail.*`, `python.exe`. `session.name` bleibt leer (die Anwendung bildet `<service>_<installation>_session`).

Geschrieben wird **UTF-8 ohne BOM** (`[IO.File]::WriteAllText` mit `UTF8Encoding($false)`) zuerst nach `config.php.neu`, dann `php -l`, dann umbenannt. Eine vorhandene `config.php` wird nie überschrieben und nur über PHP gelesen (`php bin\console info`; das DB-Passwort nur wenn nötig per `php -r`), nie per Regex.

## PostgreSQL

| | |
|---|---|
| `psql.exe`, Port | `einstellungen.psqlBin`/`postgresPort` → `C:\ProgramData\WIPP\postgres.json` (`bin`, `port`) → Suche unter `C:\Program Files\PostgreSQL\<Version>\bin`, Port 5432 |
| Superuser-Passwort | `C:\ProgramData\WIPP\postgres-zugangsdaten.txt` (Format von WIPP: Wert nach dem ersten `=`, ungetrimmt); fehlt die Datei, Eingabe auf „Prüfen“ mit „Verbindung testen“ |
| Übergabe | SQL über die **Standardeingabe** an `psql -f -`; das Superuser-Passwort steht nur in einer temporären **pgpass-Datei** (ACL nur Administratoren/SYSTEM, `PGPASSFILE` nur für den Kindprozess, sofort gelöscht). Nie auf der Kommandozeile |
| Rolle | `CREATE ROLE <benutzer> LOGIN PASSWORD '…'` – das Passwort geht als **SCRAM-SHA-256-Hash** zum Server (wie bei WIPP). Rolle vorhanden → `ALTER ROLE … PASSWORD` mit dem Passwort der vorhandenen `config.php` (bzw. dem neuen, das gleich hineingeschrieben wird) |
| Datenbank | `CREATE DATABASE <name> OWNER <benutzer> ENCODING 'UTF8' TEMPLATE template0`. Vorhanden mit richtigem Eigentümer → nichts zu tun; mit anderem → Fehler auf „Prüfen“ |
| Vorhanden bei einer Neuinstallation | wird **nie stillschweigend** übernommen (siehe unten) |
| Passwort | 24 Zeichen aus Buchstaben und Ziffern (ohne Verwechsler) |

**Kollisionen bei einer Neuinstallation.** Datenbank- und Rollenname folgen aus dem Ordner (`-` → `_`), deshalb können zwei Ordner dieselben Namen ergeben (`olaf-muster` und `olaf_muster` → `olaf_muster` / `olaf_muster_user`), und nach einer von Hand entfernten Installation bleibt ihre Datenbank oft liegen. „Prüfen“ gleicht deshalb ab, sobald es Datenbank **oder** Rolle schon gibt bzw. eine Installation sie nutzt:

| Lage | Ergebnis |
|---|---|
| Eine erkannte Installation (`db.name`/`db.user` aus `php bin\console info`) nutzt die Datenbank oder Rolle – auch wenn es sie gerade nicht gibt | ✗ „Datenbank/Rolle '<name>' gehört zur Installation <Ordner> (<dienst>/<mandant>).“ |
| Datenbank gehört einer anderen Rolle | ✗ wie bisher |
| Fortsetzen eines abgebrochenen Laufs **desselben** Ordners: Programmordner da (ohne `config.php`), die Zugangsdatei `zugangsdaten\<Ordner>.txt` nennt dieselbe Datenbank und Rolle und ist nicht älter als der Programmordner | ✓ ohne Rückfrage, Passwort der Rolle wird neu gesetzt. Eine alte Zugangsdatei einer von Hand entfernten Installation ist älter als der neu angelegte Ordner und zählt nicht |
| Vorhanden, aber keiner erkannten Installation zugeordnet | ⚠ und Pflicht-Häkchen „Vorhandene Datenbank übernehmen (alte Daten bleiben erhalten)“ (nur Rolle: „Vorhandene Rolle … übernehmen“). Ohne Häkchen bleibt „Installieren“ grau; erst damit `ALTER ROLE` und Weiterverwendung, im Protokoll als Warnung vermerkt. Nicht lesbare Installationen werden in der Meldung genannt |

Der Schritt „PostgreSQL: Rolle und Datenbank“ prüft das bei einer Neuinstallation noch einmal und bricht ab, ohne etwas zu ändern, wenn inzwischen etwas vorhanden ist, das weder bestätigt noch als Fortsetzen erkannt wurde.

Genauso für den **Ordnernamen** (zugleich Site und App-Pool), der ebenfalls zusammenfallen kann (Dienst `olaf` + Mandant `a-b` und Dienst `olaf-a` + Mandant `b` → `olaf-a-b`): Gehört der Ordner einer erkannten Installation, zeigt eine gleichnamige Website woandershin, nutzt eine andere Website den gleichnamigen App-Pool oder gibt es den App-Pool ohne Website und ohne Programmordner → ✗ auf „Prüfen“.

## services.json

`C:\AK\services.json` (Vertrag in `docs/03` der Vorlage) legt SNAIL an und pflegt sie:

- Beim Installieren **und** Aktualisieren genau den eigenen Dienst bzw. die eigene Installation (Zuordnung über `key`) ergänzen oder angleichen: `services[].key/name/icon/tone/description` aus dem Katalog, `logo` als `logos/<dienst>.<ext>`, `installations[].key/name/url` aus der Eingabe (neu) bzw. aus `app.url` der `config.php` (vorhanden; eine abweichende `url` wird angeglichen und gemeldet). Felder, die der Katalog nicht setzt – auch bei einem Dienst, der gar nicht im Katalog steht –, bleiben stehen.
- Alle anderen Einträge (auch von Hand ergänzte, mit eigenen Feldern) bleiben unverändert, die Reihenfolge bleibt, Neues kommt ans Ende.
- Vor dem Schreiben prüft SNAIL die Regeln aus `docs/03` (Schlüssel, Eindeutigkeit, `name`, `tone`, `url` mit `http(s)://` ohne Leerzeichen, Logo-Pfad svg/png/webp/jpg ohne Leerzeichen, höchstens 1 MB). Bei einem Verstoß – oder wenn die vorhandene Datei kein gültiges JSON bzw. ein anderes `format` hat – wird **nicht** geschrieben, der Grund steht auf „Fertig“.
- Schreiben: `ConvertTo-Json -Depth 5 -InputObject` (Listen mit einem Eintrag bleiben Listen), UTF-8 ohne BOM, erst `services.json.neu`, dann ersetzen. Das Logo genauso, und nur wenn es sich geändert hat.

## Rechte

Wie `docs/03` „Ordner härten“ – mit SIDs statt Gruppennamen (`*S-1-5-32-544` Administratoren, `*S-1-5-18` SYSTEM, `*S-1-5-32-545` Benutzer):

```powershell
icacls "C:\AK\<Ordner>" /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "IIS AppPool\<Ordner>:(OI)(CI)RX"
icacls "D:\AK\<Ordner>" /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "IIS AppPool\<Ordner>:(OI)(CI)M"
icacls "C:\AK"          /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX"
```

Reihenfolge: erst anonyme Anfragen auf den App-Pool-Benutzer stellen (sonst 401.3), dann Programm- und Datenordner, zuletzt `C:\AK`. Liegen Data/Cache/Logs/Temp nicht unter einem gemeinsamen Datenordner, bekommt jeder Pfad die Datenrechte einzeln. `<Datenordner>\Sicherung` hat eigene Rechte (nur Administratoren/SYSTEM). Die `config.php` entsteht erst nach dem Härten. Unterordner von `C:\AK`, die noch Rechte erben, nennt das Protokoll als Warnung. Ein Sicherungsprogramm, das nicht als SYSTEM oder Administrator läuft, braucht auf dem Datenordner zusätzlich Leserechte.

## Firewall

Die Website bindet `*:<port>`; „nur lokal“ heißt: **keine** Firewallregel – das reicht, wenn ein Cloudflare Tunnel (falls genutzt) auf `localhost:<port>` zeigt. „Prüfen“ warnt, wenn die Windows-Firewall nicht für alle Profile aktiv ist, und – bei gewählter Regel – wenn ein Netzwerk im Profil Öffentlich ist (dort greift die Regel nicht). Mit „Im Netzwerk erreichbar“ legt SNAIL bei der Neuinstallation eine Regel an (wie WIPP „Lokales Netzwerk“): Name `SNAIL <Ordner> (TCP <port>)` (intern `SNAIL-<Ordner>`), eingehend, TCP `<port>`, Profile Domäne und Privat, Remote-Adressen 10/8, 172.16/12, 192.168/16, fc00::/7, fe80::/10. Vorhandene Regeln fasst SNAIL beim Wiederholen/Aktualisieren nicht an.

## Ablage

| Ort | Inhalt |
|---|---|
| `C:\ProgramData\SNAIL\snail_JJJJMMTT_HHMMSS.log` | Protokoll je Lauf (ohne Passwörter – die Zeile mit dem Initialpasswort wird geschwärzt) |
| `C:\ProgramData\SNAIL\zugangsdaten\<Ordner>.txt` | Adresse, Datenbank, DB-Passwort, Admin-Login und Initialpasswort – abgelegt, sobald der Wert feststeht. **Nach dem Übertragen in den Passwortmanager löschen** |
| `C:\ProgramData\SNAIL\pruefberichte\<Ordner>_<Zeit>.txt` | Bericht von `tools\windows-pruefung.ps1` |
| `<Datenordner>\Sicherung\<Zeit>\` | `pg_dump` und `config.php` vor einem Update. SNAIL löscht sie nie, „Prüfen“ zeigt Anzahl und Größe. Der Data-Ordner gehört in die reguläre Sicherung |

`C:\ProgramData\SNAIL` und `Sicherung` sind nur für Administratoren und SYSTEM lesbar.

## Voraussetzungen

- Windows Server 2022/2025, eingerichtet mit **WIPP** (IIS mit CGI, URL Rewrite 2, PHP 8.3+ NTS mit `pdo_pgsql` usw., PostgreSQL ab 14) – oder gleichwertig von Hand; dann `phpExe`/`psqlBin` im Katalog setzen
- Administratorrechte; SNAIL fordert sie beim Start selbst an
- Windows PowerShell 5.1 (im System enthalten), .NET Framework ≥ 4.7.2 (SCRAM-Hash)
- Programmcode der Anwendung als ZIP (GitHub „Download ZIP“; der Zwischenordner `<repo>-<branch>\` wird erkannt)

## Verwendung

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Projekt-Installer.ps1
```

Als EXE (PS2EXE, eine Datei, Doppelklick, UAC-Abfrage):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Projekt-Installer.ps1
```

Neben die EXE gehören `projekte.json`, der Ordner `logos\` und gern die ZIP-Dateien. Ein eigenes Symbol erzeugt `New-Icon.ps1` aus einem PNG.

## Dateien

| Datei | Zweck |
|---|---|
| `Projekt-Installer.ps1` | SNAIL selbst (UTF-8 mit BOM, CRLF – beim Bearbeiten beibehalten) |
| `projekte.json` | Katalog: Testdienst `projekt` (die Vorlage selbst) und die Programme aus SNAIL 5, noch ohne ZIP |
| `logos/` | Logos des Katalogs |
| `Build-Projekt-Installer.ps1` | erzeugt die verteilbare EXE |
| `New-Icon.ps1` | wandelt ein PNG in eine `.ico` |
| `PSScriptAnalyzerSettings.psd1` | Regeln für die statische Prüfung |
| `tests/SNAIL.Tests.ps1` | Funktionstests (Linux oder Windows, PowerShell 7) |
| `docs/windows-test.md` | Testcheckliste für eine Windows-Server-VM |

## Tests

Unter Linux geprüft (PowerShell 7, PHP 8.3, PostgreSQL 16): Parser und PSScriptAnalyzer ohne Befund, dazu `tests/SNAIL.Tests.ps1` – lädt die Funktionen über den Parser (die Oberfläche startet nicht) und prüft gegen die echte projektvorlage:

- Kommandozeilen-Maskierung als Rundreise über `php`
- Katalog: Datei im Repository (Logos als Dateien), eingebaute Vorlage, Fehlerfälle, altes Format
- Eingaben: Standardwerte, Fehlerfälle, Cloudflare/Mail, angepasste Pfade, zweiter Mandant (`<dienst>-<installation>`), schon installiert, belegter Name; Datenpfade (absolut, nicht im Programmordner, Temp/Data auf einem Laufwerk, UNC); Ports (IIS-Binding, Listener, `excludedportrange`, nächster freier); Firewall-Vorschau
- `config.php` aus der echten `config.example.php`: Escaping, ohne BOM, `php -l`, Ladeversuch, Schlüssel-Abgleich, optionaler Schlüssel `python.exe`
- Installationen am Server: zwei Mandanten, `config.php` mit BOM, Ordner ohne `config.php`/`bin\console`, älterer Stand ohne `db` in `info`, ausgetauschter Katalog
- `services.json`: neu, angleichen, fremde Einträge/Felder/Reihenfolge, Ein-Element-Liste und BOM, Regelverstöße – und Lesen mit `ServiceDirectory::parse()` der Vorlage
- ZIP mit einfachem und doppeltem Zwischenordner
- Kollisionen: Namensgleichheit `olaf`/`muster` gegen `olaf_muster`, Rolle einer anderen Installation, Rest-Datenbank (Häkchen, nur Rolle, nicht lesbare Installation), Fortsetzen nach Abbruch (Zugangsdatei passend, älter, anderer Name, ohne Ordner), Ordnername `olaf` + `a-b` gegen `olaf-a` + `b`, fremde Website, fremder und verwaister App-Pool
- PostgreSQL: Superuser über pgpass (Passwort mit `:` und `\`), Rolle + Datenbank anlegen und wiederholen, Anmeldung mit dem SCRAM-Hash, fremder Eigentümer, Benutzerzahl; Rest-Datenbank: Sperre ohne Häkchen, Übernahme mit (alte Daten mit neuem Passwort lesbar), Fortsetzen ohne
- Durchlauf: Rolle/Datenbank → `config.php` → `migrate` → `user:create` (Umlaute im Namen) → `services.json` (url angleichen) → `check` mit Exit 0 → Erkennung am Server über `info` → Sicherung nach `<Datenordner>\Sicherung`

```sh
pwsh tests/SNAIL.Tests.ps1 -Vorlage ../projektvorlage -PgPassword '<postgres>' -PgBin /usr/lib/postgresql/16/bin
pwsh -c "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
```

Was nur Windows zeigen kann (Oberfläche, appcmd, icacls, robocopy, Firewall, Windows-Aufgabe, Prüfskript unter 5.1), steht in `docs/windows-test.md`.

## Was intern passiert

- **appcmd statt WebAdministration** – das Modul lädt nicht überall zuverlässig und gar nicht unter PowerShell 7. Argumente für appcmd bleiben wie bisher (`/userName:""` muss unverändert ankommen); alle anderen Programme bekommen ihre Argumente nach den Regeln von `CommandLineToArgvW` maskiert.
- **Programme ohne Fenster** über `System.Diagnostics.Process`, Ausgabe von `php.exe`/`psql` als UTF-8, Standardeingabe als UTF-8 ohne BOM direkt in den Datenstrom, immer geschlossen.
- **Upload-Grenze** je Website `uploads.max_mb + 1 MB` (Rahmen einer multipart-Anfrage); ein höherer gültiger Wert wird nie gesenkt. Nicht in `public\web.config` – die überschreibt jedes Update.
- **Prüfen vor Ändern:** Die ZIP wird schon auf „Prüfen“ entpackt, damit Aufbau und `requirements` (`php_min`, `postgres_min`, `extensions` aus `config/app.php`) feststehen, bevor etwas angelegt wird.
- **Pfade ohne Laufwerksprüfung** (`[IO.Path]::Combine` statt `Join-Path`): ein Datenordner auf einem fehlenden Laufwerk wird gemeldet statt abzustürzen.
- **Abbrechen:** „Fenster schließen“ während eines Schritts hält nach diesem Schritt an und schließt dann; ein laufendes Programm wird nicht hart beendet. Beim nächsten Lauf ist jeder Schritt wiederholbar; das DB-Passwort kommt dann aus der schon geschriebenen `config.php`.

## Sicherheitshinweise

- SNAIL legt Datenbanken mit Superuser-Rechten an und führt Skripte der Vorlage (`aufgabe_erstellen.ps1`, `windows-pruefung.ps1`) als Administrator aus – nur Programmcode aus vertrauenswürdiger Quelle installieren.
- `C:\ProgramData\SNAIL\zugangsdaten\` und `C:\ProgramData\WIPP\postgres-zugangsdaten.txt` enthalten Klartextpasswörter: nach dem Übertragen in den Passwortmanager löschen. SNAIL fragt das Superuser-Passwort dann von Hand ab.
