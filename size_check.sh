#!/bin/bash
# =============================================================================
# size_check.sh - prueft .m3u / .nfo Uploads (glFTPD post-check)
# Version : 1.1.1
# Aenderung 1.1.1: DELETE_FILE=0 -> Exit 0 (glFTPD loescht sonst bei Exit 2 selbst)
# Aenderung 1.1.0: Log-Tag TURGEN -> FILECHECK, Sitebot-Einstellungen im Kopf
# Aenderung 1.0.0: Groessen-, Inhalts- und Binaerpruefung, Injection-Schutz
#
# Einbindung in glftpd.conf:
#   cscript STOR post /bin/size_check.sh
#
# Aufruf durch glFTPD: $1 = Dateiname, $2 = Pfad, $3 = CRC
# Benoetigt im chroot (/glftpd/bin): bash (>= 4.4), stat, rm
# Alles andere sind Bash-Builtins (keine weiteren Forks, keine Temp-Dateien).
#
# Sitebot-Einstellungen (dZSbot.conf) fuer die IRC-Ausgabe:
#   set variables(FILECHECK) "%msg"
#   set chanlist(FILECHECK) "#deinchannel"
#   set disable(FILECHECK) 0
# Je nach Bot-Setup ggf. zusaetzlich: FILECHECK in msgtypes(DEFAULT) aufnehmen
# und ein Announce-Template im Theme anlegen.
#
# Log-Format (glftpd.log):
#   Sun Oct 11 12:00:00 2026 FILECHECK: "FILECHECK: <pfad>/<datei> - <grund> - von user/group - <aktion>"
#
# Pruefreihenfolge (guenstig -> teuer, Abbruch beim ersten Treffer):
#   1. Endung / Dateiname / Symlink-Schutz
#   2. Groesse (min/max)
#   3. Dateikopf (Magic Bytes) auf bekannte Binaerformate
#   4. NUL-Bytes im ersten Block
#   5. Anteil an Steuerzeichen (CP437-NFOs mit Bytes >= 0x80 bleiben erlaubt)
#   6. Zeilenstruktur (keine riesige Datei ohne Zeilenumbruch)
#   7. Skript-/Web-Inhalte (Shebang, <?php, <script ...)
#   8. m3u: Struktur der Eintraege
# =============================================================================

# ------------------------------ KONFIGURATION --------------------------------
VERSION="1.1.1"                         # Skriptversion
CHECK_EXT="m3u nfo"                     # zu pruefende Endungen (klein geschrieben)
MAX_KB=600                              # Maximalgroesse in KB (1 KB = 1024 Byte)
MIN_BYTES_NFO=16                        # Mindestgroesse .nfo in Byte
MIN_BYTES_M3U=4                         # Mindestgroesse .m3u in Byte
SCAN_BYTES=8192                         # so viele Bytes vom Dateianfang werden geprueft
MAX_CTRL_PCT=2                          # max. Anteil Steuerzeichen im Block in Prozent
NOBREAK_BYTES=2048                      # ab so vielen Bytes ohne Zeilenumbruch -> verdaechtig
BLOCK_SCRIPTS=1                         # 1 = Shebang/PHP/HTML/Script-Inhalte ablehnen
M3U_ALLOW_URLS=0                        # 0 = m3u mit URLs (://) ablehnen
M3U_MAX_LINES=500                       # max. Zeilen, die pro m3u geprueft werden
M3U_MAX_LINE_LEN=1024                   # max. Laenge einer m3u-Zeile
DELETE_FILE=1                           # 1 = abgelehnte Datei loeschen (Exit 2), 0 = nur melden (Exit 0, Datei bleibt)
GLLOG="/ftp-data/logs/glftpd.log"       # Pfad innerhalb des chroot
LOG_TAG="FILECHECK"                     # Tag in der glftpd.log, den dein Sitebot auswertet
ANNOUNCE=1                              # 1 = IRC-Ausgabe ueber den Sitebot aktiv
USER_MSG=1                              # 1 = Meldung auch an den Uploader im FTP-Client
# -----------------------------------------------------------------------------

# --- Umgebung haerten --------------------------------------------------------
unset BASH_ENV ENV CDPATH IFS
export LC_ALL=C                         # Byte-Semantik, kein Locale-Verhalten
PATH=/bin
umask 077

# Erlaubte Zeichen fuer alles, was ins glftpd.log geschrieben wird. Bewusst ohne
# Anfuehrungszeichen, $ [ ] { } \ und Steuerzeichen -> keine Log-/IRC-/Tcl-Injection.
SAFE='[^A-Za-z0-9._()+,@=:/ -]'
# Steuerzeichen, die in Text nicht vorkommen (erlaubt: \t \n \v \f \r, 0x1A, ESC)
CTRL=$'[^\x01-\x08\x0e-\x19\x1c-\x1f\x7f]'

clean() {                               # $1 = Variablenname; ersetzt unsichere Zeichen
    local -n _r=$1
    _r=${_r//$SAFE/_}
    _r=${_r:0:200}
}

reject() {                              # $1 = Grund (nur eigene, feste Texte)
    local reason=$1 action f d u g ts
    if (( DELETE_FILE )); then
        rm -f -- "$file"
        action="geloescht"
    else
        action="nicht geloescht"
    fi
    f=$file; d=${dir:-}; u=${USER:-unknown}; g=${GROUP:-NoGroup}
    clean f; clean d; clean u; clean g
    if (( ANNOUNCE )); then
        printf -v ts '%(%a %b %e %T %Y)T' -1
        printf '%s %s: "FILECHECK: %s/%s - %s - von %s/%s - %s"\n' \
            "$ts" "$LOG_TAG" "$d" "$f" "$reason" "$u" "$g" "$action" >> "$GLLOG"
    fi
    (( USER_MSG )) && echo "550 ${f}: ${reason} (${action})."
    # glFTPD loescht die Datei selbst bei Exit-Code 2 (und gibt keinen Credit).
    # Darum bei "nur melden" (DELETE_FILE=0) mit 0 beenden -> Datei bleibt erhalten.
    if (( DELETE_FILE )); then exit 2; fi
    exit 0
}

# --- 1. Eingabe pruefen ------------------------------------------------------
file=$1
dir=${2:-$PWD}
[[ -n $file ]] || exit 0
[[ $file == */* || $file == -* || $file != *.* ]] && exit 0   # nie an fremden Pfaden/Optionen arbeiten

ext=${file##*.}
ext=${ext,,}
match=0
for e in $CHECK_EXT; do
    [[ $ext == "$e" ]] && { match=1; break; }
done
(( match )) || exit 0

# Datei suchen (falls cwd nicht das Upload-Verzeichnis ist)
if [[ ! -e $file && ! -L $file && -n ${2:-} && -d $2 ]]; then
    cd -- "$2" 2>/dev/null || exit 0
fi

# Symlinks nie folgen: Link entfernen, nicht das Ziel
[[ -L $file ]] && reject "Symlink nicht erlaubt"
[[ -f $file && -r $file ]] || exit 0

# --- 2. Groesse --------------------------------------------------------------
size=$(stat -c %s -- "$file" 2>/dev/null) || exit 0
[[ $size =~ ^[0-9]+$ ]] || exit 0

max=$(( MAX_KB * 1024 ))
if [[ $ext == m3u ]]; then min=$MIN_BYTES_M3U; else min=$MIN_BYTES_NFO; fi

if (( size > max )); then
    reject "zu gross: $(( size / 1024 )) KB > ${MAX_KB} KB"
fi
(( size < min )) && reject "zu klein: ${size} Byte"

# --- Anfang der Datei einmalig einlesen (reiner Builtin, keine Temp-Datei) ---
want=$(( size < SCAN_BYTES ? size : SCAN_BYTES ))
data=
IFS= read -r -N "$want" data < "$file" 2>/dev/null || :
len=${#data}

# --- 3. Magic Bytes ----------------------------------------------------------
case ${data:0:12} in
    MZ*)                                            reject "Binaerdatei erkannt: EXE/DLL" ;;
    PK$'\x03\x04'*|PK$'\x05\x06'*)                  reject "Binaerdatei erkannt: ZIP" ;;
    Rar!*)                                          reject "Binaerdatei erkannt: RAR" ;;
    7z$'\xBC\xAF'*)                                 reject "Binaerdatei erkannt: 7z" ;;
    $'\x1f\x8b'*|BZh*)                              reject "Binaerdatei erkannt: Archiv" ;;
    ID3*|$'\xFF\xFB'*|$'\xFF\xF3'*|$'\xFF\xF2'*)    reject "Binaerdatei erkannt: MP3" ;;
    fLaC*)                                          reject "Binaerdatei erkannt: FLAC" ;;
    OggS*)                                          reject "Binaerdatei erkannt: OGG" ;;
    RIFF*)                                          reject "Binaerdatei erkannt: RIFF" ;;
    ????ftyp*)                                      reject "Binaerdatei erkannt: MP4" ;;
    $'\x1A\x45\xDF\xA3'*)                           reject "Binaerdatei erkannt: MKV" ;;
    %PDF*)                                          reject "Binaerdatei erkannt: PDF" ;;
    $'\x89'PNG*|GIF8*|$'\xFF\xD8\xFF'*)             reject "Binaerdatei erkannt: Bild" ;;
    $'\x7F'ELF*)                                    reject "Binaerdatei erkannt: ELF" ;;
esac

# --- 4. NUL-Bytes (read verwirft NULs -> weniger Zeichen als erwartet) -------
(( len < want )) && reject "Binaerdatei erkannt: NUL-Bytes"

# --- 5. Steuerzeichen-Anteil -------------------------------------------------
bad=${data//$CTRL/}                      # uebrig bleiben nur die unerlaubten Zeichen
(( ${#bad} * 100 > len * MAX_CTRL_PCT )) && reject "kein Text: zu viele Steuerzeichen"

# --- 6. Zeilenstruktur -------------------------------------------------------
if (( len >= NOBREAK_BYTES )) && [[ $data != *$'\n'* && $data != *$'\r'* ]]; then
    reject "kein Text: keine Zeilenumbrueche"
fi

# --- 7. Skript-/Web-Inhalte --------------------------------------------------
if (( BLOCK_SCRIPTS )); then
    low=${data,,}
    case $low in
        '#!'*|'<?php'*|'<?xml'*|'<html'*|'<!doctype'*|'@echo off'*)
            reject "Skript/Markup statt Text erkannt" ;;
        *'<script'*|*'<?php'*|*'<iframe'*|*'javascript:'*)
            reject "eingebetteter Skript-Inhalt erkannt" ;;
    esac
fi

# --- 8. m3u-Struktur (ohne Here-String -> keine Temp-Datei im chroot) --------
if [[ $ext == m3u ]]; then
    rest=$data; n=0; entries=0; header=0
    while [[ -n $rest ]] && (( n++ < M3U_MAX_LINES )); do
        if [[ $rest == *$'\n'* ]]; then
            line=${rest%%$'\n'*}; rest=${rest#*$'\n'}
        else
            line=$rest; rest=
        fi
        line=${line%$'\r'}
        [[ -z $line ]] && continue
        if [[ $line == '#EXTM3U'* ]]; then header=1; continue; fi
        [[ $line == '#'* ]] && continue
        (( entries++ ))
        (( ${#line} > M3U_MAX_LINE_LEN )) && reject "m3u: Zeile zu lang"
        (( ! M3U_ALLOW_URLS )) && [[ $line == *'://'* ]] && reject "m3u: URL-Eintrag nicht erlaubt"
    done
    (( header || entries )) || reject "keine gueltige m3u"
fi

exit 0
