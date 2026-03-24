#!/usr/bin/env bash
# =============================================================================
#  networkmanager.sh — MindLink hotspot via NetworkManager
#
#  Writes the NM AP connection and mindlink.service, then reboots.
#  Nothing is brought up live — the Pi comes up cleanly on the next boot
#  with the hotspot already active.
#  Safe to run over wlan0 SSH: your session stays up for the whole script.
#
#  Usage:
#    cp .env.example .env && nano .env
#    sudo bash networkmanager.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a && source "$SCRIPT_DIR/.env" && set +a
fi

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

[[ $EUID -eq 0 ]] || error "Please run as root:  sudo bash networkmanager.sh"

# =============================================================================
#  CONFIGURATION  (override via .env or environment)
# =============================================================================
SSID="${SSID:-MindLink}"
PASSPHRASE="${PASSPHRASE:-}"
IFACE="${IFACE:-wlan0}"
HOTSPOT_IP="192.168.4.1"
CHANNEL="${CHANNEL:-6}"
CON_NAME="${CON_NAME:-mindlink-hotspot}"
MINDLINK_DIR="${MINDLINK_DIR:-/home/${SUDO_USER:-pi}/mindlink}"
MINDLINK_USER="${MINDLINK_USER:-${SUDO_USER:-pi}}"
# =============================================================================

# =============================================================================
section "Preflight checks"
# =============================================================================

[[ -n "$PASSPHRASE" ]] \
    || error "PASSPHRASE is not set.  Edit .env or run:  PASSPHRASE=yourpassphrase sudo bash networkmanager.sh"
[[ ${#PASSPHRASE} -ge 8 ]] \
    || error "PASSPHRASE must be at least 8 characters."
[[ -f "$MINDLINK_DIR/mindlink.py" ]] \
    || error "mindlink.py not found at $MINDLINK_DIR — set MINDLINK_DIR= to override."
ip link show "$IFACE" &>/dev/null \
    || error "Interface '$IFACE' not found.  Is the Wi-Fi adapter present?"
command -v nmcli &>/dev/null \
    || error "nmcli not found — is NetworkManager installed?"
systemctl is-active --quiet NetworkManager \
    || error "NetworkManager is not running.  Run setup.sh for auto-detection."

DEVICE_ID=$(grep "^Serial" /proc/cpuinfo | awk '{print $3}' || echo "unknown")
info "Device    : $DEVICE_ID"
info "Interface : $IFACE"
info "SSID      : $SSID"
info "Hotspot IP: $HOTSPOT_IP"
info "User      : $MINDLINK_USER"
info "MindLink  : $MINDLINK_DIR"

# =============================================================================
section "Installing packages"
# =============================================================================

apt-get update -qq
# hostapd/dnsmasq not needed — NM drives the AP and handles DHCP natively
apt-get install -y python3-websockets python3-aiohttp i2c-tools
pip3 install grove.py --break-system-packages --quiet
# Also install for the service user in case their env differs from root's
sudo -u "$MINDLINK_USER" pip3 install grove.py --break-system-packages --quiet
success "Packages installed"

# =============================================================================
section "Enabling I2C and checking Grove HAT"
# =============================================================================

raspi-config nonint do_i2c 0
success "I2C enabled"

if i2cdetect -y -a 1 | grep -q "04"; then
    success "Grove HAT detected at 0x04"
else
    warn "Grove HAT not detected — check later with: i2cdetect -y -a 1"
fi

# =============================================================================
section "Writing NetworkManager hotspot connection"
# =============================================================================

# Delete any stale connection with the same name so we get a clean slate.
nmcli connection delete "$CON_NAME" 2>/dev/null \
    && info "Removed existing '$CON_NAME' connection" || true

# Create the AP connection.
# ipv4.method shared = NM enables IP forwarding, runs its built-in DHCP server,
# and assigns HOTSPOT_IP as the gateway — all without dnsmasq or hostapd.
# autoconnect yes = NM brings this up automatically on every boot.
# We do NOT call `nmcli connection up` here — that would yank wlan0 away from
# your current network and drop your SSH session.  The reboot handles it.
nmcli connection add \
    type wifi \
    ifname "$IFACE" \
    con-name "$CON_NAME" \
    autoconnect yes \
    ssid "$SSID" \
    -- \
    wifi.mode ap \
    wifi.band bg \
    wifi.channel "$CHANNEL" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$PASSPHRASE" \
    ipv4.method shared \
    ipv4.addresses "${HOTSPOT_IP}/24"

nmcli connection modify "$CON_NAME" autoconnect yes
nmcli connection modify "$CON_NAME" connection.autoconnect-priority 100

success "NM connection '$CON_NAME' written (will activate on reboot)"

# Prevent any existing client (station) connections from fighting the AP on boot.
# We iterate all wifi connections except our new hotspot and disable autoconnect.
# This is safe to run over SSH — nothing is brought down live.
section "Disabling autoconnect on existing WiFi client connections"
while IFS= read -r con; do
    [[ "$con" == "$CON_NAME" ]] && continue
    nmcli connection modify "$con" autoconnect no 2>/dev/null \
        && info "Disabled autoconnect: $con" || true
    # Also write directly to the keyfile in case NM ignores the modify
    # (netplan-managed connections are sometimes protected from nmcli writes)
    KEYFILE=$(nmcli -t -f connection.id,connection.filename connection show "$con" \
        | awk -F: '/connection.filename/{print $2}')
    if [[ -n "$KEYFILE" && -f "$KEYFILE" ]]; then
        sed -i 's/^autoconnect=.*/autoconnect=false/' "$KEYFILE" 2>/dev/null \
            || true
        grep -q "^autoconnect=" "$KEYFILE" \
            || echo "autoconnect=false" >> "$KEYFILE"
        info "Patched keyfile directly: $KEYFILE"
    fi
done < <(nmcli -t -f NAME,TYPE connection show | awk -F: '$2=="wifi"{print $1}')
# Reload so NM picks up the keyfile changes
nmcli connection reload

# =============================================================================
section "Installing mindlink.service"
# =============================================================================

cat > /etc/systemd/system/mindlink.service <<EOF
[Unit]
Description=MindLink GSR WebSocket server
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
User=${MINDLINK_USER}
WorkingDirectory=${MINDLINK_DIR}
ExecStart=/usr/bin/python3 ${MINDLINK_DIR}/mindlink.py 0.0.0.0:5000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mindlink
success "mindlink.service written and enabled (will start on reboot)"

# =============================================================================
section "Ready — reboot to apply"
# =============================================================================

PAD=41
print_row() { printf "│ %-${PAD}s │\n" "$1"; }

echo ""
echo -e "${GREEN}${BOLD}┌$(printf '─%.0s' $(seq 1 $((PAD+2))))┐${RESET}"
print_row "All configs written, services enabled"
print_row ""
print_row "  Device : ${DEVICE_ID}"
print_row "  User   : ${MINDLINK_USER}"
print_row "  SSID   : ${SSID}"
print_row "  Stream : ws://${HOTSPOT_IP}:5000"
print_row "  HTTP   : http://${HOTSPOT_IP}:5001"
echo -e "${GREEN}${BOLD}└$(printf '─%.0s' $(seq 1 $((PAD+2))))┘${RESET}"
echo ""
echo -e "After reboot, connect to Wi-Fi SSID ${BOLD}${SSID}${RESET} and verify:"
echo -e "  ws stream : ${CYAN}ws://${HOTSPOT_IP}:5000${RESET}"
echo -e "  http feed : ${CYAN}http://${HOTSPOT_IP}:5001${RESET}"
echo -e "  service   : ${CYAN}journalctl -u mindlink -f${RESET}"
echo ""

read -r -p "Reboot now? [y/N] " REPLY
if [[ "${REPLY,,}" == "y" ]]; then
    info "Rebooting..."
    reboot
else
    warn "Skipping reboot — run 'sudo reboot' when ready."
fi
