# SNAIL

## Simple New-project Automation &amp; Installation Launcher

Ein grafischer Installer für Windows Server, der ein Projekt auf Basis der gemeinsamen **Projektvorlage** (PHP auf IIS + MySQL) in einem Durchgang betriebsbereit macht: IIS-Anwendungspool und Website anlegen, Datenbank und Datenbank-Benutzer erzeugen, die `.env` aus der `.env.example` schreiben, Migrationen und den ersten Administrator über die Projekt-Konsole anlegen, die Anwendung sich selbst prüfen lassen – und am Ende die Anwendung öffnen.

Weil alle Projekte denselben Aufbau haben, kennt der Installer den Ablauf selbst. Die Projektliste steckt nicht im Programm, sondern in einer `projekte.json` **neben** der EXE – ein neues Projekt sind wenige Zeilen JSON (Name, Ordner, Port, Datenbankname), die EXE muss nie neu gebaut werden.

Der Installer ist das Gegenstück zum [PHP + IIS Setup-Assistenten (WIMP)](../WIMP): Der eine richtet den Server ein (IIS, PHP, MySQL), der andere bringt die Projekte darauf. Er funktioniert aber auch auf jedem Server, auf dem IIS, PHP und MySQL bereits anderweitig eingerichtet sind.

## Ablauf

1. **Auswahl** – alle Projekte aus der `projekte.json` als Liste mit Symbol, Port, Projektordner und Datenbank. Fehlerhafte Einträge werden gesammelt gemeldet statt beim ersten abzubrechen.
2. **Prüfen** – bevor irgendetwas passiert: Projektordner vorhanden und nach Vorlage aufgebaut (`public\index.php`, `public\web.config`, `bin\console`, `.env.example`, `database\migrations\*.sql`)? Port frei – und wenn nicht, welche Website belegt ihn? `php.exe` gefunden, Version ≥ 8.1, alle benötigten PHP-Module geladen? `mysql.exe` gefunden? Dazu das root-Passwort (automatisch eingelesen, siehe unten) mit „Verbindung testen“ und optional die E-Mail-Adresse des Administrators (für die Cloudflare-SSO-Anmeldung der Vorlage).
3. **Installation** – Schrittliste mit Live-Status und Protokoll daneben:
   1. IIS: eigener Anwendungspool (kein verwalteter Code) + Website mit physischem Pfad `<Projekt>\public`; die anonyme Anmeldung läuft unter der Pool-Identität, und genau diese (`IIS AppPool\<Name>`) bekommt Änderungsrechte auf `var\` – und bewusst nirgendwo sonst (Projektordner nur Lesen).
   2. MySQL: `CREATE DATABASE` / `CREATE USER` / `GRANT` als root – dieselben Anweisungen wie in der Installationsanleitung der Vorlage. Tabellen legt der Installer **nicht** selbst an.
   3. `.env` aus der `.env.example` erzeugen: `APP_NAME`, `APP_URL`, `APP_KEY` (64 zufällige Hex-Zeichen), `SESSION_NAME` (`<ordner>_session`), `DB_*`, `MAIL_FROM_NAME`. Kommentare und Reihenfolge der Vorlage bleiben erhalten; eine vorhandene `.env` wird nie überschrieben.
   4. `php bin\console migrate` – die Tabelle `schema_migrations` führt Buch, damit das erste Update später nur das Neue ausführt.
   5. `php bin\console user:create admin "Administrator" admin [email]` – das ausgegebene Initialpasswort wird angezeigt (Wechsel beim ersten Login erzwungen).
   6. Setup-Skripte des Projekts (Windows-Aufgaben), falls in der JSON eingetragen.
   7. `php bin\console check` – komplette Systemprüfung der Anwendung. Exit-Code 1 markiert die Einrichtung als fehlgeschlagen, Warnungen sind erlaubt und erscheinen auf der letzten Seite.
4. **Fertig** – Zugangsdaten (Anmeldung, Datenbank), Warnungen der Systemprüfung, Ergebnis der Setup-Skripte und die nächsten Schritte als Schaltflächen: Anwendung öffnen, `.env` bearbeiten, Protokoll. Danach direkt das nächste Projekt installieren.

Alles ist wiederholbar: „Erneut versuchen“ erkennt vorhandenen Pool und Website, `IF NOT EXISTS`/`ALTER USER` halten die Datenbank konsistent, eine vorhandene `.env` wird übernommen (und ihr `DB_PASS` für die Datenbank verwendet), `migrate` führt nur Offenes aus, ein bereits vorhandener Admin ist kein Fehler.

## Die projekte.json

Liegt neben der EXE (bzw. dem Skript). Fehlt sie, legt der Installer auf Knopfdruck eine ausgefüllte Vorlage an und öffnet sie im Editor.

```json
{
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
      "phpModule": ["gd"],
      "admin":   { "login": "admin", "name": "Administrator", "email": "" },
      "skripte": [],
      "icon": "iVBORw0KGgo..."
    }
  ]
}
```

| Feld | Bedeutung |
|---|---|
| `name` | Anzeigename – zugleich IIS-Sitename, Name des Anwendungspools und `APP_NAME` |
| `ordner` | relativ zu `einstellungen.projektOrdner` (Standard `C:\inetpub`) oder absoluter Pfad. Die Website zeigt immer auf `<ordner>\public` |
| `port` | HTTP-Port der Website |
| `url` | optional; wird `APP_URL` und am Ende geöffnet. Standard `http://localhost:{port}/` |
| `datenbank` | optional; Standard `<ordner>` und `<ordner>_user`. Das Passwort wird bei der Installation erzeugt |
| `phpModule` | optional; PHP-Module **zusätzlich** zum Basissatz aus `einstellungen.phpModule` (der Basissatz entspricht `requirements` in `config/app.php` der Vorlage) |
| `admin` | optional; Login, Anzeigename und E-Mail des ersten Benutzers. Die E-Mail lässt sich auch auf der Seite „Prüfen“ eingeben |
| `skripte` | optional; PowerShell-Skripte für die Windows-Aufgabenplanung (siehe `_skripteDoku` in der JSON) |
| `icon` | optional; PNG als Base64, erscheint in der Projektliste |

In `url` funktionieren die Platzhalter `{port}`, `{name}` und `{ordner}`.

**Icons:** Ein PNG (ideal 64×64 bis 256×256) wird mit diesem Einzeiler zu Base64:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\pfad\logo.png')) | Set-Clipboard
```

Projekte ohne Icon bekommen automatisch ein farbiges Kästchen mit dem Anfangsbuchstaben.

**Was die Vorlage im Projektordner voraussetzt:** `public\index.php`, `public\web.config`, `bin\console`, `.env.example`, `database\migrations\*.sql`. Projekte, deren Repository noch nicht auf die Vorlage umgestellt ist, meldet die Seite „Prüfen“ mit genau diesen Punkten als Fehler.

## php.exe

`bin\console` braucht `php.exe`. Der Installer sucht in dieser Reihenfolge: `einstellungen.phpExe` (Datei oder Ordner), die vom Setup-Assistenten geschriebene `C:\ProgramData\PHP-IIS-Setup\php-pfad.txt`, die in IIS registrierte FastCGI-Anwendung (`php-cgi.exe` → `php.exe` daneben – das ist per Definition das PHP der Websites), der PATH des Prozesses, der maschinenweite PATH aus der Registry und zuletzt `C:\Program Files\PHP`.

## root-Passwort

Für das Anlegen von Datenbank und Benutzer meldet sich der Installer als `root` an. Das Passwort wird automatisch aus der vom Setup-Assistenten erzeugten Datei `C:\ProgramData\PHP-IIS-Setup\mysql-zugangsdaten.txt` gelesen – gezielt die Zeile, die zum root-Konto gehört. Ist die Datei bereits gelöscht, wird das Passwort von Hand eingegeben; „Verbindung testen“ prüft es vor der Installation. Aus der `my.ini` lässt es sich übrigens nicht lesen: MySQL speichert Passwörter ausschließlich gehasht.

Übergeben wird das Passwort nie auf der Kommandozeile (dort könnte es jeder in der Prozessliste mitlesen), sondern über eine temporäre `defaults-extra-file`, die sofort danach gelöscht wird.

## Erzeugte Zugangsdaten

Datenbank-Passwort und Admin-Initialpasswort liegen nach der Installation unter `C:\ProgramData\PHP-IIS-Setup\projekt-zugangsdaten\<ordner>.txt` (Ordner nur für Administratoren und SYSTEM lesbar). Bei einer erneuten Installation desselben Projekts gilt für das Datenbank-Passwort: vorhandene `.env` → Ablage → neu erzeugen. So passen Datenbank und `.env` auch dann zusammen, wenn nur eine der beiden Seiten neu aufgesetzt wurde.

## Voraussetzungen

- Windows Server 2022/2025 (oder Windows 11 Pro für Entwicklung und Test)
- IIS mit `appcmd.exe` und URL Rewrite Module 2, PHP 8.1+ (`php.exe` erreichbar) und ein laufender MySQL-Server – z. B. eingerichtet mit dem PHP + IIS Setup-Assistenten
- Administratorrechte; der Installer fordert sie beim Start selbst an
- Windows PowerShell 5.1 (im System enthalten)

## Verwendung

### Als Skript

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Projekt-Installer.ps1
```

### Als EXE

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Projekt-Installer.ps1
```

Baut mit [PS2EXE](https://github.com/MScholtes/PS2EXE) eine einzelne `Projekt-Installer.exe` (UAC-Abfrage beim Doppelklick, kein Konsolenfenster). Liegt eine `setup.ico` daneben, wird sie eingebettet – erzeugen lässt sie sich mit `New-Icon.ps1` aus einem PNG. Wichtig für die Verteilung: **`projekte.json` muss mit neben die EXE.**

## Was intern passiert

- **Der komplette IIS-Dialog „Website hinzufügen“ ist ein Befehl:** `appcmd add site /name:"manfred" /physicalPath:"…\public" /bindings:http/*:1011:` – das `*` entspricht „Keine zugewiesen“, der leere Teil nach dem letzten Doppelpunkt dem Hostnamen. Dazu `add apppool` ohne .NET-Laufzeit und `set app … /applicationPool`.
- **Anonyme Anmeldung = Pool-Identität.** Mit `fastcgi.impersonate = 1` (Standard des Setup-Assistenten) arbeitet PHP unter dem anonymen Konto. Der Installer stellt es pro Website auf die Pool-Identität um (`anonymousAuthentication /userName:"" /commit:apphost` – der Abschnitt ist in IIS gesperrt, deshalb der Location-Tag in der `applicationHost.config`). Damit ist `IIS AppPool\<Name>` das einzige Konto, das Schreibrechte braucht.
- **Rechte nur auf `var\`.** Die Pool-Identität bekommt Lesen/Ausführen auf den Projektordner und Ändern auf `var\`. `.env`, `src\`, `config\` bleiben Nur-Lesen; die Website zeigt ohnehin nur auf `public\`.
- **Tabellen über die Projekt-Konsole, nicht per SQL-Datei.** Würde der Installer die Migrations-SQLs selbst einspielen, wüsste `schema_migrations` nichts davon und das erste Update wollte alles erneut anlegen. Deshalb nur `CREATE DATABASE`/`CREATE USER`/`GRANT` durch den Installer, alles Weitere durch `php bin\console migrate`.
- **Admin-Passwort aus der Konsole.** Ein statisches SQL kann keinen Administrator anlegen, weil das Passwort pro Installation zufällig und als bcrypt-Hash entstehen muss – `user:create` erledigt das und gibt das Initialpasswort aus.
- **Portprüfung zweistufig:** erst gegen die Bindings aller IIS-Websites (mit Nennung der Konfliktsite), dann gegen alle aktiven TCP-Listener des Systems.
- **Ausgabe von `php.exe` als UTF-8** gelesen, damit Umlaute und Gedankenstriche der Konsole im Protokoll stimmen; SQL geht als UTF-8 mit `--default-character-set=utf8mb4` an `mysql.exe`.
- Jeder Lauf schreibt ein Protokoll nach `C:\ProgramData\PHP-IIS-Setup\projekt_JJJJMMTT_HHMMSS.log`.

## Dateien

| Datei | Zweck |
|---|---|
| `Projekt-Installer.ps1` | der Installer selbst |
| `projekte.json` | Projektliste – die echten Projekte; fehlt sie, legt der Installer per Schaltfläche eine Vorlage an |
| `Build-Projekt-Installer.ps1` | erzeugt die verteilbare EXE (PS2EXE) |
| `New-Icon.ps1` | wandelt ein PNG in eine `.ico` für die EXE |

Das Skript ist **UTF-8 mit BOM** gespeichert – Kodierung beim Bearbeiten beibehalten. Die `projekte.json` wird als UTF-8 gelesen; Umlaute in Projektnamen sind damit kein Problem.

## Sicherheitshinweise

- Der Installer legt Datenbanken und Benutzer mit root-Rechten an und führt die in der `projekte.json` eingetragenen Setup-Skripte erhöht aus – nur Projekte aus vertrauenswürdiger Quelle eintragen.
- `mysql-zugangsdaten.txt` enthält Klartextpasswörter; nach dem Übertragen in einen Passwortmanager löschen. Der Installer funktioniert danach mit manueller Eingabe weiter.
- Die Ablage unter `projekt-zugangsdaten\` enthält das Datenbank-Passwort und das Admin-Initialpasswort im Klartext (nur Administratoren/SYSTEM). Das Initialpasswort verliert beim ersten Login seine Gültigkeit.
