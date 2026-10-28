#!/usr/bin/env bash
set -Eeuo pipefail
trap 'report_error' ERR
IFS=$'\n\t'

VERSION="0.6.0"

DEFAULT_HOSTNAME="moonfin"
DEFAULT_CORES=2
DEFAULT_MEMORY=2048
DEFAULT_SWAP=512
DEFAULT_DISK=10
PREFERRED_TEMPLATE_STORAGE="local"
PREFERRED_ROOT_STORAGE="pve-data"
PREFERRED_BRIDGE="vmbr0"

die() {
    whiptail --title "Moonfin Helper – Fehler" \
        --msgbox "$1" 12 76 || true
    exit 1
}

report_error() {
    local exit_code=$?
    local line="${BASH_LINENO[0]:-unbekannt}"

    trap - ERR

    echo "FEHLER: Skript abgebrochen (Exit-Code ${exit_code}, Zeile ${line})." >&2
    echo "Bitte CT-Konfiguration und Storage prüfen, bevor du erneut startest." >&2

    exit "$exit_code"
}

command -v whiptail >/dev/null 2>&1 || {
    echo "whiptail fehlt. Installiere es mit: apt-get update && apt-get install -y whiptail"
    exit 1
}

[[ $EUID -eq 0 ]] || {
    echo "Bitte als root auf dem Proxmox-Host ausführen."
    exit 1
}

[[ -d /etc/pve/lxc ]] || {
    echo "Dieses Skript muss auf einem Proxmox-VE-Host laufen."
    exit 1
}

# Liefert aktive Storages für den verlangten Inhaltstyp.
get_storages() {
    local content="$1"
    pvesm status -content "$content" |
        awk 'NR > 1 && $3 == "active" {print $1}'
}

# Wählt einen geeigneten Storage aus.
# Bevorzugten Storage verwenden, wenn er tatsächlich geeignet ist.
select_storage() {
    local content="$1"
    local title="$2"
    local preferred="$3"
    local storage details selected default_storage=""
    local -a menu=()
    local -a storages=()

    mapfile -t storages < <(get_storages "$content")

    ((${#storages[@]} > 0)) ||
        die "Kein aktiver Storage unterstützt '$content'."

    for storage in "${storages[@]}"; do
        if [[ "$storage" == "$preferred" ]]; then
            default_storage="$storage"
            break
        fi
    done

    # Falls der bevorzugte Storage fehlt, den ersten geeigneten nehmen.
    [[ -n "$default_storage" ]] || default_storage="${storages[0]}"

    for storage in "${storages[@]}"; do
        details="$(pvesm status |
            awk -v s="$storage" '
                NR > 1 && $1 == s {
                    gib = $6 / 1048576
                    printf "%s – %.1f GiB frei", $2, gib
                }
            ')"
        local state="OFF"
        [[ "$storage" == "$default_storage" ]] && state="ON"

        menu+=("$storage" "${details:-Storage}" "$state")
    done

    selected="$(whiptail \
        --title "$title" \
        --radiolist "Bitte einen geeigneten Storage auswählen:" \
        18 78 8 "${menu[@]}" \
        3>&1 1>&2 2>&3)" || exit 0

    [[ -n "$selected" ]] || die "Kein Storage ausgewählt."
    printf '%s' "$selected"
}

# Ermittelt vorhandene Linux-Bridge-Interfaces.
get_bridges() {
    ip -o link show type bridge |
        awk -F': ' '{print $2}' |
        sed 's/@.*//' |
        grep -Ev '^(fwbr|fwpr|fwln)[0-9]' |
        sort -u
}

select_bridge() {
    local preferred="$1"
    local bridge selected default_bridge=""
    local -a bridges=()
    local -a menu=()

    mapfile -t bridges < <(get_bridges)

    ((${#bridges[@]} > 0)) ||
        die "Keine vorhandene Linux-Bridge gefunden. Bitte zuerst eine Bridge auf Proxmox konfigurieren."

    for bridge in "${bridges[@]}"; do
        if [[ "$bridge" == "$preferred" ]]; then
            default_bridge="$bridge"
            break
        fi
    done

    [[ -n "$default_bridge" ]] || default_bridge="${bridges[0]}"

    for bridge in "${bridges[@]}"; do
        local state="OFF"
        [[ "$bridge" == "$default_bridge" ]] && state="ON"
        menu+=("$bridge" "Linux-Bridge" "$state")
    done

    selected="$(whiptail \
        --title "Netzwerk-Bridge" \
        --radiolist "Bridge für den Moonfin-Container:" \
        15 72 6 "${menu[@]}" \
        3>&1 1>&2 2>&3)" || exit 0

    [[ -n "$selected" ]] || die "Keine Netzwerk-Bridge ausgewählt."
    printf '%s' "$selected"
}

whiptail --title "Moonfin LXC Helper v${VERSION}" \
    --msgbox "Dieser Assistent erstellt einen unprivilegierten Debian-13-LXC als Grundlage für Moonfin.

Standardwerte:
CPU: 2 Kerne
RAM: 2048 MB
Swap: 512 MB
Root-Disk: 10 GB

Storage und Netzwerk werden auf diesem Proxmox-Host erkannt.

Der Container wird in diesem Schritt erstellt, aber noch nicht gestartet. Moonfin, HDMI und Xorg werden später eingerichtet." 18 76

if whiptail --title "Konfiguration" \
    --yesno "Möchtest du die Standardwerte verwenden?

Nein öffnet die erweiterten Einstellungen." 10 72; then
    HOSTNAME="$DEFAULT_HOSTNAME"
    CORES="$DEFAULT_CORES"
    MEMORY="$DEFAULT_MEMORY"
    SWAP="$DEFAULT_SWAP"
    DISK="$DEFAULT_DISK"
else
    HOSTNAME="$(whiptail --title "Hostname" \
        --inputbox "Hostname des Containers:" 10 70 \
        "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3)" || exit 0

    CORES="$(whiptail --title "CPU" \
        --inputbox "Anzahl CPU-Kerne:" 10 70 \
        "$DEFAULT_CORES" 3>&1 1>&2 2>&3)" || exit 0

    MEMORY="$(whiptail --title "Arbeitsspeicher" \
        --inputbox "RAM in MB:" 10 70 \
        "$DEFAULT_MEMORY" 3>&1 1>&2 2>&3)" || exit 0

    SWAP="$(whiptail --title "Swap" \
        --inputbox "Swap in MB:" 10 70 \
        "$DEFAULT_SWAP" 3>&1 1>&2 2>&3)" || exit 0

    DISK="$(whiptail --title "Root-Disk" \
        --inputbox "Root-Disk in GB:" 10 70 \
        "$DEFAULT_DISK" 3>&1 1>&2 2>&3)" || exit 0
fi

[[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] ||
    die "Ungültiger Hostname."

[[ "$CORES" =~ ^[1-9][0-9]*$ ]] ||
    die "CPU-Kerne müssen eine positive ganze Zahl sein."

[[ "$MEMORY" =~ ^[1-9][0-9]*$ ]] ||
    die "RAM muss eine positive ganze Zahl sein."

[[ "$SWAP" =~ ^[0-9]+$ ]] ||
    die "Swap muss eine nichtnegative ganze Zahl sein."

[[ "$DISK" =~ ^[1-9][0-9]*$ ]] ||
    die "Disk-Größe muss eine positive ganze Zahl sein."

TEMPLATE_STORAGE="$(
    select_storage vztmpl "Debian-Template-Storage" \
        "$PREFERRED_TEMPLATE_STORAGE"
)"

ROOT_STORAGE="$(
    select_storage rootdir "Container-Rootfs-Storage" \
        "$PREFERRED_ROOT_STORAGE"
)"

BRIDGE="$(select_bridge "$PREFERRED_BRIDGE")"

whiptail --title "Debian-Template" \
    --infobox "Aktualisiere die Proxmox-Template-Liste ..." 8 65

pveam update ||
    die "Die Proxmox-Template-Liste konnte nicht aktualisiert werden."

TEMPLATE="$(
    pveam available --section system |
        awk '$2 ~ /^debian-13-standard_.*_amd64\.tar\.zst$/ {print $2}' |
        sort -V |
        tail -n 1
)"

[[ -n "$TEMPLATE" ]] ||
    die "Kein Debian-13-amd64-Standardtemplate gefunden."

TEMPLATE_VOLID="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

# Prüfen, ob der Template-Storage aktiv ist.
if ! pvesm status -content vztmpl |
    awk -v s="$TEMPLATE_STORAGE" \
        'NR > 1 && $1 == s && $3 == "active" {found=1} END {exit !found}'; then
    die "Template-Storage '$TEMPLATE_STORAGE' ist nicht mehr aktiv."
fi

# Freien Speicherplatz des Template-Storages prüfen.
TEMPLATE_FREE_KIB="$(
    pvesm status |
        awk -v s="$TEMPLATE_STORAGE" \
            'NR > 1 && $1 == s {print $6}'
)"

[[ "$TEMPLATE_FREE_KIB" =~ ^[0-9]+$ ]] ||
    die "Der freie Speicherplatz von '$TEMPLATE_STORAGE' konnte nicht ermittelt werden."

# Das Template benötigt derzeit etwa 130 MB; 512 MiB Reserve einplanen.
TEMPLATE_REQUIRED_KIB=$((512 * 1024))

if ! pvesm list "$TEMPLATE_STORAGE" --content vztmpl |
    awk -v wanted="$TEMPLATE_VOLID" '$1 == wanted {found=1} END {exit !found}'; then
    if (( TEMPLATE_FREE_KIB < TEMPLATE_REQUIRED_KIB )); then
        die "Auf '$TEMPLATE_STORAGE' ist zu wenig freier Speicherplatz für den Template-Download vorhanden."
    fi
fi

# Nächste freie CT-ID ermitteln.
CTID="$(pvesh get /cluster/nextid)" ||
    die "Die nächste freie CT-ID konnte nicht ermittelt werden."

[[ "$CTID" =~ ^[0-9]+$ ]] ||
    die "Proxmox lieferte eine ungültige CT-ID."

# Noch keine Änderungen an Template oder Container vornehmen.
if ! whiptail --title "Zusammenfassung" \
    --yesno "Bitte Einstellungen prüfen:

CT-ID: $CTID
Hostname: $HOSTNAME
Template: $TEMPLATE
Template-Storage: $TEMPLATE_STORAGE
Rootfs-Storage: $ROOT_STORAGE
CPU: $CORES Kerne
RAM: $MEMORY MB
Swap: $SWAP MB
Root-Disk: $DISK GB
Bridge: $BRIDGE
Unprivilegiert: Ja
Autostart: Nein

Bei Bestätigung wird bei Bedarf das Template heruntergeladen und der Container erstellt." \
    22 78; then
    exit 0
fi

# Prüfen, ob das gewählte Template bereits im Ziel-Storage vorhanden ist.
if ! pvesm list "$TEMPLATE_STORAGE" --content vztmpl |
    awk -v wanted="$TEMPLATE_VOLID" \
        '$1 == wanted {found=1} END {exit !found}'
then
    if ! whiptail --title "Template herunterladen" \
        --yesno "Das ausgewählte Template fehlt im Storage '$TEMPLATE_STORAGE'.

Template:
$TEMPLATE

Jetzt herunterladen?" 13 76; then
        exit 0
    fi

    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" ||
        die "Der Template-Download ist fehlgeschlagen."
fi

# CT-ID unmittelbar vor der Erstellung erneut ermitteln.
NEW_CTID="$(pvesh get /cluster/nextid)" ||
    die "Die freie CT-ID konnte nicht erneut ermittelt werden."

[[ "$NEW_CTID" =~ ^[0-9]+$ ]] ||
    die "Proxmox lieferte eine ungültige CT-ID."

if [[ "$NEW_CTID" != "$CTID" ]]; then
    if ! whiptail --title "CT-ID geändert" \
        --yesno "Die nächste freie CT-ID hat sich geändert.

Bisher: $CTID
Jetzt: $NEW_CTID

Mit der neuen ID fortfahren?" 12 72; then
        exit 0
    fi
    CTID="$NEW_CTID"
fi

# Unmittelbare Prüfung vor pct create.
if [[ -e "/etc/pve/lxc/${CTID}.conf" ]] ||
   pct status "$CTID" >/dev/null 2>&1; then
    die "CT-ID $CTID ist inzwischen belegt. Bitte Helper erneut starten."
fi

# Prüfen, ob das ausgewählte Rootfs-Storage aktiv ist.
if ! pvesm status -content rootdir |
    awk -v s="$ROOT_STORAGE" \
        'NR > 1 && $1 == s && $3 == "active" {found=1} END {exit !found}'; then
    die "Rootfs-Storage '$ROOT_STORAGE' ist nicht mehr aktiv."
fi

# Freien Platz des Rootfs-Storages prüfen.
ROOT_FREE_KIB="$(
    pvesm status |
        awk -v s="$ROOT_STORAGE" \
            'NR > 1 && $1 == s {print $6}'
)"

[[ "$ROOT_FREE_KIB" =~ ^[0-9]+$ ]] ||
    die "Der freie Speicherplatz von '$ROOT_STORAGE' konnte nicht ermittelt werden."

ROOT_REQUIRED_KIB=$((DISK * 1024 * 1024))
if (( ROOT_FREE_KIB < ROOT_REQUIRED_KIB )); then
    die "Auf '$ROOT_STORAGE' ist nicht genug freier Speicherplatz für die ausgewählte Root-Disk von ${DISK} GB verfügbar."
fi

whiptail --title "Container-Erstellung" \
    --infobox "Erstelle den unprivilegierten Debian-Container CT $CTID ..." 8 70

pct create "$CTID" "$TEMPLATE_VOLID" \
    --hostname "$HOSTNAME" \
    --arch amd64 \
    --ostype debian \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${ROOT_STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=dhcp,type=veth" \
      --features nesting=1 \
    --unprivileged 1 \
    --onboot 0 ||
    die "Die Erstellung von CT $CTID ist fehlgeschlagen."

# Ergebnis der Erstellung verifizieren.
if [[ ! -e "/etc/pve/lxc/${CTID}.conf" ]]; then
    die "pct create meldete Erfolg, aber die CT-Konfiguration fehlt."
fi

if ! pct config "$CTID" >/dev/null 2>&1; then
    die "Die Konfiguration von CT $CTID kann nicht gelesen werden."
fi

if pct status "$CTID" 2>/dev/null | grep -q 'status: running'; then
    die "CT $CTID läuft unerwartet. Bitte Zustand prüfen."
fi

whiptail --title "Basis-Container erstellt" \
    --msgbox "Der Debian-13-Basiscontainer wurde erstellt.

CT-ID: $CTID
Hostname: $HOSTNAME
Template-Storage: $TEMPLATE_STORAGE
Rootfs-Storage: $ROOT_STORAGE
Bridge: $BRIDGE

Der Container ist noch ausgeschaltet.
Autostart nach Proxmox-Neustart ist deaktiviert.
