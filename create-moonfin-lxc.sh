#!/usr/bin/env bash
set -Eeuo pipefail

# Moonfin-Kiosk-LXC für Proxmox VE
# Als root auf dem Proxmox-Host starten.
#
# Standard:
#   2 CPU-Kerne, 2048 MB RAM, 512 MB Swap, 10 GB Disk
#
# GID-Zuordnungen:
#   Host 39  -> Container 44   (card1/video)
#   Host 63  -> Container 63   (Audio)
#   Host 993 -> Container 108  (renderD128/render)
#   Host 104 -> Container 2000 (Bluetooth)
#   Host 997 -> Container 2001 (zusätzliche Eingabegruppe)

die() { echo "FEHLER: $*" >&2; exit 1; }
msg() { echo; echo "==> $*"; }

[[ "$(id -u)" -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host starten."
command -v pct >/dev/null || die "pct wurde nicht gefunden."
command -v pvesh >/dev/null || die "pvesh wurde nicht gefunden."
command -v pveam >/dev/null || die "pveam wurde nicht gefunden."
command -v jq >/dev/null || die "jq fehlt auf dem Proxmox-Host. Installiere es mit: apt install jq"

# ---------- Standardwerte ----------
CT_HOSTNAME="moonfin"
CORES="2"
MEMORY="2048"
SWAP="512"
DISK_GB="10"
BRIDGE="vmbr0"
# ---------------------------------

echo
echo "Moonfin-LXC einrichten"
echo "  1) Standardeinstellungen"
echo "  2) Einstellungen manuell eingeben"
echo
read -r -p "Auswahl [1]: " SETUP_MODE
SETUP_MODE="${SETUP_MODE:-1}"

case "$SETUP_MODE" in
    1)
        echo "Verwende Standardeinstellungen."
        ;;
    2)
        read -r -p "Hostname [${CT_HOSTNAME}]: " INPUT
        CT_HOSTNAME="${INPUT:-$CT_HOSTNAME}"

        read -r -p "CPU-Kerne [${CORES}]: " INPUT
        CORES="${INPUT:-$CORES}"

        read -r -p "RAM in MB [${MEMORY}]: " INPUT
        MEMORY="${INPUT:-$MEMORY}"

        read -r -p "Swap in MB [${SWAP}]: " INPUT
        SWAP="${INPUT:-$SWAP}"

        read -r -p "Root-Disk in GB [${DISK_GB}]: " INPUT
        DISK_GB="${INPUT:-$DISK_GB}"

        read -r -p "Netzwerk-Bridge [${BRIDGE}]: " INPUT
        BRIDGE="${INPUT:-$BRIDGE}"
        ;;
    *)
        die "Ungültige Auswahl."
        ;;
esac

[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "CPU-Kerne müssen eine positive ganze Zahl sein."
[[ "$MEMORY" =~ ^[1-9][0-9]*$ ]] || die "RAM muss eine positive ganze Zahl sein."
[[ "$SWAP" =~ ^[0-9]+$ ]] || die "Swap muss eine ganze Zahl sein."
[[ "$DISK_GB" =~ ^[1-9][0-9]*$ ]] || die "Disk-Größe muss eine positive ganze Zahl sein."
[[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || die "Hostname ist ungültig."
[[ -e "/sys/class/net/${BRIDGE}" ]] || die "Bridge ${BRIDGE} existiert nicht."

echo
echo "Einstellungen:"
echo "  Hostname: ${CT_HOSTNAME}"
echo "  CPU:      ${CORES} Kerne"
echo "  RAM:      ${MEMORY} MB"
echo "  Swap:     ${SWAP} MB"
echo "  Disk:     ${DISK_GB} GB"
echo "  Bridge:   ${BRIDGE}"
echo "  DNS:      Werte vom Proxmox-Host"
echo
read -r -p "Container erstellen und einrichten? [J/n]: " CONFIRM
CONFIRM="${CONFIRM:-J}"
[[ "$CONFIRM" =~ ^[JjYy]$ ]] || die "Abgebrochen."

# Nächste freie CT-ID
CTID="$(pvesh get /cluster/nextid)"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "Konnte keine freie CT-ID ermitteln."

# Rootfs-Storage ermitteln
ROOTFS_STORAGE=""
if pvesm status --content rootdir | awk 'NR > 1 {print $1}' | grep -qx "local-lvm"; then
    ROOTFS_STORAGE="local-lvm"
else
    ROOTFS_STORAGE="$(pvesm status --content rootdir | awk 'NR > 1 {print $1; exit}')"
fi
[[ -n "$ROOTFS_STORAGE" ]] || die "Kein Storage für Container-Rootfs gefunden."

# Template-Storage ermitteln
TEMPLATE_STORAGE="$(pvesm status --content vztmpl | awk 'NR > 1 {print $1; exit}')"
[[ -n "$TEMPLATE_STORAGE" ]] || die "Kein Storage für LXC-Templates gefunden."

# Debian-13-Template suchen/herunterladen
msg "Aktualisiere Template-Liste"
pveam update

TEMPLATE="$(pveam available --section system \
    | awk '$2 ~ /^debian-13-standard_/ {print $2}' \
    | sort -V | tail -n 1)"
[[ -n "$TEMPLATE" ]] || die "Debian-13-Standard-Template nicht gefunden."

msg "Lade Template ${TEMPLATE}"
pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"

# Sub-GID-Berechtigungen für die Sonder-GIDs ergänzen
for gid in 39 63 104 993 997; do
    grep -qxF "root:${gid}:1" /etc/subgid 2>/dev/null ||
        echo "root:${gid}:1" >> /etc/subgid
done

msg "Erstelle unprivilegierten Container ${CTID}"

# Absichtlich keine --nameserver- und --searchdomain-Option:
# Proxmox soll die Host-DNS- und Suchdomain-Einstellungen übernehmen.
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --unprivileged 1 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,ip6=auto" \
    --onboot 1 \
    --start 0 \
    --features nesting=1

CONF="/etc/pve/lxc/${CTID}.conf"

# HDMI, DRM, Audio, Eingabegeräte und VT.
# Die begrenzten Device-Freigaben ersetzen keine Host-Desktop-Sitzung.
cat >> "$CONF" <<'LXC_CONFIG'

# GPU/HDMI, Audio, Eingabe und VT7
lxc.cgroup2.devices.allow: c 13:* rwm
lxc.cgroup2.devices.allow: c 4:7 rwm
lxc.cgroup2.devices.allow: c 116:* rwm
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/snd dev/snd none bind,optional,create=dir
lxc.mount.entry: /dev/input dev/input none bind,optional,create=dir
lxc.mount.entry: /dev/tty7 dev/tty7 none bind,optional,create=file

# UID-Standardmapping
lxc.idmap: u 0 100000 65536

# GID-Mapping mit den Geräte-GIDs des Proxmox-Hosts:
# Container 44   -> Host 39
# Container 63   -> Host 63
# Container 108  -> Host 993
# Container 2000 -> Host 104
# Container 2001 -> Host 997
lxc.idmap: g 0 100000 39
lxc.idmap: g 39 100039 5
lxc.idmap: g 44 39 1
lxc.idmap: g 45 100045 18
lxc.idmap: g 63 63 1
lxc.idmap: g 64 100064 44
lxc.idmap: g 108 993 1
lxc.idmap: g 109 100109 1891
lxc.idmap: g 2000 104 1
lxc.idmap: g 2001 997 1
lxc.idmap: g 2002 102002 63534
LXC_CONFIG

msg "Starte Container"
pct start "$CTID"

for _ in $(seq 1 60); do
    pct exec "$CTID" -- true >/dev/null 2>&1 && break
    sleep 2
done
pct exec "$CTID" -- true >/dev/null 2>&1 ||
    die "Container ist nicht erreichbar. Prüfe: pct start ${CTID}"

msg "Installiere Wayland-, Audio- und GPU-Abhängigkeiten"
pct exec "$CTID" -- bash -s <<'CONTAINER_SETUP'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    ca-certificates curl jq dbus \
    cage seatd \
    libgtk-3-0 libegl1 libgl1 libgbm1 \
    mesa-va-drivers intel-media-va-driver vainfo \
    alsa-utils pulseaudio pulseaudio-utils \
    evtest

# Benutzer moonfin mit UID 1000 anlegen.
if ! id moonfin >/dev/null 2>&1; then
    if getent passwd 1000 >/dev/null; then
        echo "UID 1000 ist bereits belegt:"
        getent passwd 1000
        exit 1
    fi
    useradd --create-home --uid 1000 --shell /bin/bash moonfin
fi

# Gruppen passend zu den durchgereichten GIDs sicherstellen.
ensure_gid_group() {
    gid="$1"
    preferred="$2"
    existing="$(getent group "$gid" | cut -d: -f1 || true)"

    if [[ -n "$existing" ]]; then
        echo "$existing"
        return
    fi

    if getent group "$preferred" >/dev/null 2>&1; then
        preferred="${preferred}-mapped"
    fi

    groupadd --gid "$gid" "$preferred"
    echo "$preferred"
}

G_VIDEO="$(ensure_gid_group 44 video)"
G_AUDIO="$(ensure_gid_group 63 audio)"
G_RENDER="$(ensure_gid_group 108 render)"
G_REMOTE_KEYBOARD="$(ensure_gid_group 2000 remote-keyboard)"
G_REMOTE_INPUT="$(ensure_gid_group 2001 remote-input)"

usermod -aG \
"${G_VIDEO},${G_AUDIO},${G_RENDER},${G_REMOTE_KEYBOARD},${G_REMOTE_INPUT}" \
moonfin

# Neueste Linux-Debian-Datei aus dem Moonfin-Core-Release suchen.
RELEASE_API="https://api.github.com/repos/Moonfin-Client/Moonfin-Core/releases/latest"
RELEASE_JSON="$(curl -fsSL "$RELEASE_API")"

DEB_URL="$(printf '%s' "$RELEASE_JSON" | jq -r '
    [.assets[]
     | select(.name | test("\\.deb$"; "i"))
     | select(.name | test("amd64|x86_64"; "i"))]
    | .[0].browser_download_url // empty
')"

# Wenn der Assetname keine Architektur enthält, nur dann eine .deb-Datei
# verwenden, wenn das Release genau eine .deb-Datei anbietet.
if [[ -z "$DEB_URL" ]]; then
    DEB_COUNT="$(printf '%s' "$RELEASE_JSON" | jq '[.assets[] | select(.name | test("\\.deb$"; "i"))] | length')"
    if [[ "$DEB_COUNT" == "1" ]]; then
        DEB_URL="$(printf '%s' "$RELEASE_JSON" | jq -r '
            [.assets[] | select(.name | test("\\.deb$"; "i"))][0].browser_download_url
        ')"
    fi
fi

if [[ -z "$DEB_URL" || "$DEB_URL" == "null" ]]; then
    echo "Kein eindeutiges Moonfin-Linux-.deb im neuesten Release gefunden."
    echo "Release: $RELEASE_API"
    exit 1
fi

echo "Lade Moonfin-Paket: $DEB_URL"
curl -fL "$DEB_URL" -o /tmp/moonfin.deb
apt-get install -y /tmp/moonfin.deb
rm -f /tmp/moonfin.deb

# Ausführbare Moonfin-Datei finden.
MOONFIN_BIN="$(command -v moonfin || true)"
if [[ -z "$MOONFIN_BIN" && -x /usr/lib/moonfin/moonfin ]]; then
    MOONFIN_BIN="/usr/lib/moonfin/moonfin"
fi
if [[ -z "$MOONFIN_BIN" ]]; then
    MOONFIN_BIN="$(find /usr/lib /opt /usr/bin \
        -type f -executable -iname '*moonfin*' -print -quit 2>/dev/null || true)"
fi
[[ -n "$MOONFIN_BIN" ]] || {
    echo "Moonfin wurde installiert, aber die ausführbare Datei wurde nicht gefunden."
    exit 1
}

# Wrapper startet PulseAudio, wählt HDMI und startet Moonfin in Cage.
cat > /usr/local/bin/moonfin-wayland-start <<EOF
#!/bin/sh
set -eu

export HOME=/home/moonfin
export XDG_RUNTIME_DIR=/run/moonfin
export LIBVA_DRIVER_NAME=iHD
export GDK_BACKEND=wayland

pulseaudio --start --exit-idle-time=-1 || true

i=0
until pactl info >/dev/null 2>&1 || [ "\$i" -ge 15 ]; do
    sleep 1
    i=\$((i + 1))
done

if pactl info >/dev/null 2>&1; then
    pactl set-card-profile \
        alsa_card.pci-0000_00_1f.3 output:hdmi-stereo || true
    pactl set-default-sink \
        alsa_output.pci-0000_00_1f.3.hdmi-stereo || true
fi

exec cage -- "${MOONFIN_BIN}" \
    >>/home/moonfin/moonfin-console.log 2>&1
EOF

chmod 0755 /usr/local/bin/moonfin-wayland-start
chown root:root /usr/local/bin/moonfin-wayland-start

# Kiosk-Service auf VT7.
cat > /etc/systemd/system/moonfin-kiosk.service <<EOF
[Unit]
Description=Moonfin Wayland kiosk on HDMI
After=systemd-user-sessions.service sound.target
Wants=sound.target

[Service]
User=moonfin
Group=moonfin
SupplementaryGroups=${G_VIDEO} ${G_AUDIO} ${G_RENDER} ${G_REMOTE_KEYBOARD} ${G_REMOTE_INPUT}
Environment=LIBSEAT_BACKEND=seatd
Environment=LIBVA_DRIVER_NAME=iHD
RuntimeDirectory=moonfin
RuntimeDirectoryMode=0700
TTYPath=/dev/tty7
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=no
StandardInput=tty
Restart=on-failure
RestartSec=3
PAMName=login
ExecStart=/usr/local/bin/moonfin-wayland-start

[Install]
WantedBy=multi-user.target
EOF

systemctl enable seatd.service
systemctl enable moonfin-kiosk.service

chown -R moonfin:moonfin /home/moonfin
CONTAINER_SETUP

msg "Starte Moonfin-Kiosk"
pct exec "$CTID" -- systemctl start moonfin-kiosk.service || true

echo
echo "Container ${CTID} wurde erstellt."
echo "DNS und Suchdomain: Proxmox-Host-Einstellungen"
echo "Ressourcen: ${CORES} CPU, ${MEMORY} MB RAM, ${SWAP} MB Swap, ${DISK_GB} GB Disk"
echo
echo "Status:"
echo "  pct status ${CTID}"
echo "  pct exec ${CTID} -- systemctl status moonfin-kiosk.service"
echo
echo "Moonfin-Log:"
echo "  pct exec ${CTID} -- tail -n 200 /home/moonfin/moonfin-console.log"
