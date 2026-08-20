# SNAIL

## Simple New-project Automation &amp; Installation Launcher


Ein grafischer Installer für Windows Server, der ein vorbereitetes PHP-Projekt in einem Durchgang betriebsbereit macht: IIS-Website anlegen, SQL-Skripte als root ausführen, fehlende Konfigurationsdateien aus ihren Vorlagen erstellen – und am Ende Setup-Adresse und Konfigdateien zum Anklicken anbieten.

Das Besondere: Die Projektliste steckt nicht im Programm, sondern in einer `projekte.json` **neben** der EXE. Ein neues Projekt bedeutet drei Zeilen JSON – die EXE muss nie neu gebaut werden.

Der Installer ist das Gegenstück zum [PHP + IIS Setup-Assistenten](../php-iis-setup): Der eine richtet den Server ein (IIS, PHP, MySQL), der andere bringt die Projekte darauf. Er funktioniert aber auch auf jedem Server, auf dem IIS und MySQL bereits anderweitig eingerichtet sind.

![Projektauswahl](screenshot-auswahl.png)

## Ablauf

1. **Auswahl** – alle Projekte aus der `projekte.json` als Liste mit Symbol, Port und Pfad. Fehlerhafte Einträge werden gesammelt gemeldet statt beim ersten abzubrechen.
2. **Prüfen** – bevor irgendetwas passiert: Projektordner und Docroot vorhanden? `index.php` da? Port frei – und wenn nicht, welche Website belegt ihn? SQL-Dateien auffindbar? `mysql.exe` gefunden? Dazu das root-Passwort (automatisch eingelesen, siehe unten) mit „Verbindung testen“.
3. **Installation** – Schrittliste mit Live-Status: Website anlegen, dann **jede SQL-Datei als eigener Schritt** mit Häkchen oder Kreuz, zuletzt Konfigurationsdateien vorbereiten. Ein fehlgeschlagenes SQL-Skript stoppt die übrigen nicht – am Ende ist der Zustand jeder Datei sichtbar.
4. **Fertig** – Ergebnisübersicht der Datenbank-Skripte, dann die nächsten Schritte als Schaltflächen: Projekt-Setup im Browser öffnen, Website öffnen, jede Konfigurationsdatei im Editor bearbeiten, Protokoll. Danach direkt das nächste Projekt installieren.

## Die projekte.json

Liegt neben der EXE (bzw. dem Skript). Fehlt sie, legt der Installer auf Knopfdruck eine ausgefüllte Vorlage an und öffnet sie im Editor.

```json
{
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
      "icon": "iVBORw0KGgo..."
    },
    {
      "name":    "Olaf",
      "ordner":  "olaf",
      "docroot": "public",
      "port":    8082,
      "sql": [ "datenbank/create-user.sql", "datenbank/schema.sql" ],
      "konfigDateien": [ { "datei": ".env", "vorlage": ".env.example" } ]
    }
  ]
}
```

| Feld | Bedeutung |
|---|---|
| `name` | Anzeigename und zugleich IIS-Sitename |
| `ordner` | relativ zu `wwwroot` oder absoluter Pfad |
| `docroot` | leer = Projektordner selbst; sonst Unterordner wie `public` |
| `port` | HTTP-Port der Website |
| `sql` | Dateien in Ausführungsreihenfolge, relativ zum Projektordner. Als Objekt mit `datenbank`, falls das Skript kein `USE` enthält |
| `setupUrl` | optional; wird nach der Installation als Schaltfläche angeboten |
| `konfigDateien` | optional; einfacher Pfad oder `{ "datei", "vorlage" }` |
| `icon` | optional; PNG als Base64, erscheint in der Projektliste |

In `setupUrl` und `konfigDateien` funktionieren die Platzhalter `{port}`, `{name}` und `{ordner}`.

**Konfigurationsvorlagen:** Fehlt eine eingetragene Konfigdatei, sucht der Installer automatisch nach `<datei>.example`, `.dist`, `.sample` sowie dem Muster `config.example.php` und kopiert die Vorlage bei der Installation an die richtige Stelle – eine vorhandene Datei wird dabei **nie** überschrieben. Heißt die Vorlage anders, hilft das explizite Feld `vorlage`.

**Icons:** Ein PNG (ideal 64×64 bis 256×256) wird mit diesem Einzeiler zu Base64:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\pfad\logo.png')) | Set-Clipboard
```

Projekte ohne Icon bekommen automatisch ein farbiges Kästchen mit dem Anfangsbuchstaben.

## root-Passwort

Für die SQL-Skripte meldet sich der Installer als `root` an. Das Passwort wird automatisch aus der vom Setup-Assistenten erzeugten Datei `C:\ProgramData\PHP-IIS-Setup\mysql-zugangsdaten.txt` gelesen – gezielt die Zeile, die zum root-Konto gehört. Ist die Datei bereits gelöscht, wird das Passwort von Hand eingegeben; „Verbindung testen“ prüft es vor der Installation. Aus der `my.ini` lässt es sich übrigens nicht lesen: MySQL speichert Passwörter ausschließlich gehasht.

Übergeben wird das Passwort nie auf der Kommandozeile (dort könnte es jeder in der Prozessliste mitlesen), sondern über eine temporäre `defaults-extra-file`, die sofort danach gelöscht wird.

## Voraussetzungen

- Windows Server 2022/2025 (oder Windows 11 Pro für Entwicklung und Test)
- IIS mit `appcmd.exe` und ein laufender MySQL-Server – z. B. eingerichtet mit dem PHP + IIS Setup-Assistenten
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

- **Der komplette IIS-Dialog „Website hinzufügen“ ist ein Befehl:** `appcmd add site /name:"renate" /physicalPath:"…" /bindings:http/*:8081:` – das `*` entspricht „Keine zugewiesen“, der leere Teil nach dem letzten Doppelpunkt dem Hostnamen. „Website sofort starten“ ist Standardverhalten; der Installer startet trotzdem explizit nach, damit ein Fehlschlag (etwa ein Portkonflikt) sofort mit Ursache gemeldet wird statt still liegenzubleiben.
- **Wiederholbar:** „Erneut versuchen“ erkennt die im ersten Anlauf angelegte Website (gleicher Name und Port) und verwendet sie weiter. Beim bewussten Ersetzen wird nur die IIS-Website entfernt – der Projektordner bleibt unangetastet.
- **Portprüfung zweistufig:** erst gegen die Bindings aller IIS-Websites (mit Nennung der Konfliktsite), dann gegen alle aktiven TCP-Listener des Systems.
- **SQL mit `--default-character-set=utf8mb4`**, Dateien werden als UTF-8 gelesen; Warnungen von `mysql.exe` landen im Protokoll, auch wenn der Exitcode 0 ist.
- Jeder Lauf schreibt ein Protokoll nach `C:\ProgramData\PHP-IIS-Setup\projekt_JJJJMMTT_HHMMSS.log`.

## Dateien

| Datei | Zweck |
|---|---|
| `Projekt-Installer.ps1` | der Installer selbst |
| `projekte.json` | Projektliste (Vorlage: `projekte.beispiel.json`) |
| `Build-Projekt-Installer.ps1` | erzeugt die verteilbare EXE (PS2EXE) |
| `New-Icon.ps1` | wandelt ein PNG in eine `.ico` für die EXE |

Das Skript ist **UTF-8 mit BOM** gespeichert – Kodierung beim Bearbeiten beibehalten. Die `projekte.json` wird als UTF-8 gelesen; Umlaute in Projektnamen sind damit kein Problem.

## Sicherheitshinweise

- Die SQL-Skripte laufen mit root-Rechten – nur Skripte aus vertrauenswürdiger Quelle in die `projekte.json` eintragen.
- `mysql-zugangsdaten.txt` enthält Klartextpasswörter; nach dem Übertragen in einen Passwortmanager löschen. Der Installer funktioniert danach mit manueller Eingabe weiter.