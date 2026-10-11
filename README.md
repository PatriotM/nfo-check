# size_check.sh

Schneller, sicherer **post-check für glFTPD**, der hochgeladene `.nfo`- und `.m3u`-Dateien prüft:
Größe, echte Textdatei statt umbenannter Binärdatei, keine Skript-Inhalte. Treffer werden
(optional) gelöscht und über den Sitebot in den IRC-Channel gemeldet.

Einzeldatei-Skript in reinem Bash, alle Einstellungen stehen oben im Skript, keine externe
Konfigurationsdatei.

- Version: **1.1.1**
- Läuft im glFTPD-chroot, benötigt nur `bash`, `stat` und `rm`

---

## Features

- **Größenlimit** (Standard 600 KB) und Mindestgröße pro Dateityp
- **Erkennung umbenannter Dateien** über Magic Bytes (EXE, ZIP, RAR, 7z, gzip/bz2, MP3, FLAC, OGG, RIFF, MP4, MKV, PDF, Bilder, ELF)
- **NUL-Byte-Test** und **Steuerzeichen-Anteil** (CP437-NFOs mit Block-Grafik bleiben erlaubt)
- **Zeilenstruktur-Prüfung** (große Datei ohne Zeilenumbruch wird abgelehnt)
- **Skript-/Web-Inhalte** (Shebang, `<?php`, `<html`, `<script`, `javascript:`) werden abgelehnt
- **m3u-Prüfung**: gültiger Aufbau, Zeilenlänge begrenzt, URL-Einträge per Default abgelehnt
- **IRC-Ausgabe** über einen Eintrag in der `glftpd.log` (Tag `FILECHECK`)
- **Report-Modus** (`DELETE_FILE=0`): nur melden, nichts löschen

## Prüfreihenfolge

Günstig nach teuer, Abbruch beim ersten Treffer:

1. Endung, Dateiname, Symlink-Schutz
2. Größe (min/max)
3. Dateikopf (Magic Bytes)
4. NUL-Bytes im ersten Block
5. Anteil an Steuerzeichen
6. Zeilenstruktur
7. Skript-/Web-Inhalte
8. m3u-Struktur

Geprüft wird nur der Anfang der Datei (Standard 8 KB), einmalig eingelesen.

---

## Installation

```bash
cp size_check.sh /glftpd/bin/size_check.sh
chmod 755 /glftpd/bin/size_check.sh
```

Im chroot müssen vorhanden sein: `bash` (**≥ 4.4**), `stat`, `rm` samt benötigter Libraries.
Alle anderen Funktionen sind Bash-Builtins (keine weiteren Forks, keine Temp-Dateien).

### Einbindung in glFTPD

**Variante A: eigener post-check**

```
cscript STOR post /bin/size_check.sh
```

**Variante B: in eine bestehende Kette einbauen**

Wird bereits ein anderes post-check-Skript verwendet (z. B. `mkv_check.sh`, das danach
`zipscript-c` aufruft), muss `size_check.sh` aus diesem Skript heraus aufgerufen werden, weil
pro Typ nur ein `cscript` greift. Direkt vor der ersten Dateiprüfung einfügen:

```bash
PATH_SIZE_CHECK="/bin/size_check.sh"

case "${1,,}" in
  *.nfo|*.m3u)
    if [[ -x $PATH_SIZE_CHECK ]]; then
      "$PATH_SIZE_CHECK" "$1" "$2" "$3"
      sc_rc=$?
      (( sc_rc != 0 )) && exit $sc_rc
    fi
    ;;
esac
```

Aufruf durch glFTPD: `$1` = Dateiname, `$2` = Pfad, `$3` = CRC.

---

## Konfiguration

Alle Einstellungen stehen im Block `KONFIGURATION` am Anfang des Skripts.

| Variable | Standard | Beschreibung |
|---|---|---|
| `CHECK_EXT` | `"m3u nfo"` | Zu prüfende Endungen (klein geschrieben) |
| `MAX_KB` | `600` | Maximalgröße in KB (1 KB = 1024 Byte) |
| `MIN_BYTES_NFO` | `16` | Mindestgröße `.nfo` in Byte |
| `MIN_BYTES_M3U` | `4` | Mindestgröße `.m3u` in Byte |
| `SCAN_BYTES` | `8192` | Bytes vom Dateianfang, die geprüft werden |
| `MAX_CTRL_PCT` | `2` | Max. Anteil Steuerzeichen im Block (Prozent) |
| `NOBREAK_BYTES` | `2048` | Ab so vielen Bytes ohne Zeilenumbruch verdächtig |
| `BLOCK_SCRIPTS` | `1` | Shebang/PHP/HTML/Script-Inhalte ablehnen |
| `M3U_ALLOW_URLS` | `0` | `0` = m3u mit URLs (`://`) ablehnen |
| `M3U_MAX_LINES` | `500` | Max. geprüfte Zeilen pro m3u |
| `M3U_MAX_LINE_LEN` | `1024` | Max. Länge einer m3u-Zeile |
| `DELETE_FILE` | `1` | `1` = löschen (Exit 2), `0` = nur melden (Exit 0) |
| `GLLOG` | `/ftp-data/logs/glftpd.log` | Pfad der glFTPD-Logdatei (aus Sicht des chroot) |
| `LOG_TAG` | `FILECHECK` | Tag, den der Sitebot auswertet |
| `ANNOUNCE` | `1` | IRC-Ausgabe über den Sitebot aktiv |
| `USER_MSG` | `1` | Meldung auch an den Uploader im FTP-Client |

---

## Exit-Codes

glFTPD wertet den Exit-Code des post-check-Skripts aus:

| Code | Bedeutung |
|---|---|
| `0` | Datei in Ordnung (oder Report-Modus): Credit und Stats, Datei bleibt |
| `2` | Datei abgelehnt: kein Credit, keine Stats, Datei wird entfernt |

Bei `DELETE_FILE=0` beendet sich das Skript auch bei einem Treffer mit `0`, damit glFTPD die
Datei nicht selbst löscht. Das Skript meldet dann nur.

---

## IRC-Ausgabe (Sitebot)

Bei einem Treffer schreibt das Skript eine Zeile in die `glftpd.log`:

```
Sun Oct 11 12:00:00 2026 FILECHECK: "FILECHECK: /site/MP3/Release/release.nfo - Binaerdatei erkannt: ZIP - von user/group - geloescht"
```

Einstellungen in der `dZSbot.conf`:

```tcl
set variables(FILECHECK) "%msg"
set chanlist(FILECHECK) "#deinchannel"
set disable(FILECHECK) 0
```

Je nach Bot-Setup zusätzlich `FILECHECK` in `msgtypes(DEFAULT)` aufnehmen und ein
Announce-Template im Theme anlegen.

---

## Sicherheit

- Alles, was ins Log geschrieben wird, läuft durch eine Zeichen-Whitelist
  (`A-Za-z0-9._()+,@=:/ -`). Anführungszeichen, `$`, `[ ]`, `{ }`, `\`, Zeilenumbrüche und
  Steuerzeichen werden zu `_`. Damit sind Log-, IRC- und Tcl-Injection über Dateinamen,
  User- oder Gruppennamen nicht möglich.
- Kein `eval`, keine unquotierten Expansions, `rm` immer mit `--`.
- Dateinamen mit `/` oder führendem `-` werden ignoriert.
- Symlinks werden nie verfolgt. Der Link selbst wird entfernt, das Ziel bleibt unberührt.
- Gehärtete Umgebung: `BASH_ENV`, `ENV`, `CDPATH` entfernt, festes `PATH`, `LC_ALL=C`, `umask 077`.

## Performance

- Fremde Endungen beenden das Skript sofort.
- Pro Prüfung nur ein `stat`, der Dateianfang wird genau einmal per Builtin eingelesen.
- Zeitstempel und m3u-Zeilen werden ohne zusätzliche Prozesse verarbeitet.
- Gemessen etwa 6 ms pro Lauf auf einem Testsystem, der Großteil davon ist der Bash-Start.

---

## Tests

Das Skript lässt sich ohne glFTPD testen, indem `GLLOG` und `PATH` auf ein lokales Verzeichnis
zeigen:

```bash
printf 'PK\x03\x04abcdefghijkl' > fake.nfo
USER=test GROUP=grp bash size_check.sh fake.nfo "$PWD" CRC; echo "rc=$?"
```

Erwartet: Meldung `Binaerdatei erkannt: ZIP`, Exit-Code `2` und eine `FILECHECK`-Zeile im Log.
Direkt im chroot: `chroot /glftpd /bin/size_check.sh test.nfo /site/PFAD CRC`.

## Fehlersuche

| Problem | Ursache / Lösung |
|---|---|
| Skript wird nicht ausgeführt | Vorhandenen post-check prüfen (Variante B), `chmod 755`, Datei liegt in `/glftpd/bin` |
| Datei wird trotz `DELETE_FILE=0` gelöscht | Version < 1.1.1 (Exit 2 löst das Löschen durch glFTPD aus) |
| Keine IRC-Meldung | `FILECHECK` in `chanlist`, ggf. `msgtypes(DEFAULT)` und Theme prüfen; `GLLOG`-Pfad aus Sicht des chroot |
| Fehler beim Start im chroot | Bash ≥ 4.4 sowie `stat` und `rm` mit Libraries fehlen |

## Hinweise

- UTF-16-NFOs (enthalten NUL-Bytes) werden bewusst abgelehnt.
- Die Magic-Byte-Liste und die Heuristiken sind konfigurierbar bzw. im Skript leicht erweiterbar.
