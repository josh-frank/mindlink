#!/usr/bin/env bash
# =============================================================================
#  dhcpcd.sh — MindLink hotspot via dhcpcd + hostapd + dnsmasq
#
#  Supports Bullseye (native dhcpcd) and Bookworm+ (dhcpcd manually overriding
#  NetworkManager).  Detects OS version and pip capability automatically.
#
#  Assumes NetworkManager is NOT running (or not installed).  Writes all
#  configs and enables all services, then reboots.  Nothing is started live —
#  the Pi comes up cleanly on the next boot with the hotspot already active.
#  Safe to run over wlan0 SSH: your session stays up for the whole script.
#
#  Usage:
#    cp .env.example .env && nano .env
#    sudo bash dhcpcd.sh
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

[[ $EUID -eq 0 ]] || error "Please run as root:  sudo bash dhcpcd.sh"

# =============================================================================
#  CONFIGURATION  (override via .env or environment)
# =============================================================================
SSID="${SSID:-MindLink}"
PASSPHRASE="${PASSPHRASE:-}"
IFACE="${IFACE:-wlan0}"
HOTSPOT_IP="192.168.4.1"
DHCP_START="192.168.4.2"
DHCP_END="192.168.4.20"
DHCP_LEASE="24h"
CHANNEL="${CHANNEL:-6}"
MINDLINK_DIR="${MINDLINK_DIR:-/home/${SUDO_USER:-pi}/mindlink}"
MINDLINK_USER="${MINDLINK_USER:-${SUDO_USER:-pi}}"
# =============================================================================

# =============================================================================
#  OS & CAPABILITY DETECTION
# =============================================================================
OS_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-unknown}")
info "OS codename: $OS_CODENAME"

# --break-system-packages was introduced in pip 23.x (Bookworm+); not on Bullseye
PIP_FLAGS=""
pip3 install --help 2>&1 | grep -q -- "--break-system-packages" \
    && PIP_FLAGS="--break-system-packages"

# =============================================================================
section "Preflight checks"
# =============================================================================

[[ -n "$PASSPHRASE" ]] \
    || error "PASSPHRASE is not set.  Edit .env or run:  PASSPHRASE=yourpassphrase sudo bash dhcpcd.sh"
[[ ${#PASSPHRASE} -ge 8 ]] \
    || error "PASSPHRASE must be at least 8 characters."
[[ -f "$MINDLINK_DIR/mindlink.py" ]] \
    || error "mindlink.py not found at $MINDLINK_DIR — set MINDLINK_DIR= to override."
ip link show "$IFACE" &>/dev/null \
    || error "Interface '$IFACE' not found.  Is the Wi-Fi adapter present?"

# On non-Bullseye systems, warn if NetworkManager is still present — the caller
# should have disabled it before running this script.
if [[ "$OS_CODENAME" != "bullseye" ]] && command -v nmcli &>/dev/null; then
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        error "NetworkManager is active. Disable it first:\n         sudo systemctl disable --now NetworkManager\n       Then re-run this script."
    else
        warn "NetworkManager is installed but inactive — proceeding (dhcpcd will take over on reboot)."
    fi
fi

# On Bullseye, NM shouldn't be present at all, but guard anyway.
if [[ "$OS_CODENAME" == "bullseye" ]] && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    error "NetworkManager is active. This script requires dhcpcd only.\n       Run setup.sh for auto-detection, or disable NM first:\n         sudo systemctl disable --now NetworkManager"
fi

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

# On Bullseye, hostapd's apt postinstall tries to start the service, fails
# (wlan0 is busy), and masks itself.  Pre-unmask so apt's postinstall is a
# no-op rather than a mask operation.
if [[ "$OS_CODENAME" == "bullseye" ]]; then
    systemctl unmask hostapd 2>/dev/null || true
fi

apt-get update -qq
apt-get install -y hostapd dnsmasq dhcpcd5 python3-websockets python3-aiohttp i2c-tools rfkill

# Always unmask after apt in case the postinstall masked it anyway.
systemctl unmask hostapd
pip3 install grove.py $PIP_FLAGS --quiet
sudo -u "$MINDLINK_USER" pip3 install grove.py $PIP_FLAGS --quiet
success "Packages installed"

# =============================================================================
section "Unblocking WiFi radio"
# =============================================================================

# Some images soft-block WiFi on first boot via rfkill.  Unblock it now and
# persist via a oneshot service so it runs before hostapd on every boot.
rfkill unblock wifi
cat > /etc/systemd/system/rfkill-unblock-wifi.service <<EOF
[Unit]
Description=Unblock WiFi rfkill on boot
Before=hostapd.service dhcpcd.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock wifi
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable rfkill-unblock-wifi
success "WiFi rfkill unblocked and persisted"

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
section "Neutralising wpa_supplicant client config"
# =============================================================================

WPA_CONF=/etc/wpa_supplicant/wpa_supplicant.conf
if [[ -f "$WPA_CONF" ]]; then
    cp "$WPA_CONF" "${WPA_CONF}.bak"
    echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev" > "$WPA_CONF"
    echo "update_config=1" >> "$WPA_CONF"
    info "wpa_supplicant.conf neutralised (backup at ${WPA_CONF}.bak)"
else
    info "No wpa_supplicant.conf found — nothing to neutralise"
fi

# =============================================================================
section "Writing dhcpcd static IP"
# =============================================================================

DHCPCD_CONF=/etc/dhcpcd.conf
MARKER="# ── MindLink hotspot"

if grep -q "$MARKER" "$DHCPCD_CONF" 2>/dev/null; then
    warn "MindLink block already present in dhcpcd.conf — skipping append."
else
    cat >> "$DHCPCD_CONF" <<EOF

${MARKER} ──────────────────────────────────────────────
interface ${IFACE}
static ip_address=${HOTSPOT_IP}/24
nohook wpa_supplicant
EOF
    success "Static IP ${HOTSPOT_IP}/24 written to dhcpcd.conf"
fi

# =============================================================================
section "Configuring hostapd"
# =============================================================================

cat > /etc/hostapd/hostapd.conf <<EOF
interface=${IFACE}
driver=nl80211
ssid=${SSID}
country_code=US
hw_mode=g
channel=${CHANNEL}
ieee80211n=1
ht_capab=[HT20][SHORT-GI-20]
auth_algs=1
wpa=2
wpa_passphrase=${PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wmm_enabled=1
ignore_broadcast_ssid=0
EOF

sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd
success "hostapd configured"

# =============================================================================
section "Configuring dnsmasq"
# =============================================================================

[[ -f /etc/dnsmasq.conf.bak ]] || cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak

cat > /etc/dnsmasq.conf <<EOF
interface=${IFACE}
bind-interfaces
server=8.8.8.8
domain-needed
bogus-priv
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
EOF

success "dnsmasq configured"

# =============================================================================
section "Installing mindlink.service"
# =============================================================================

cat > /etc/systemd/system/mindlink.service <<EOF
[Unit]
Description=MindLink GSR WebSocket server
After=hostapd.service dnsmasq.service

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

# =============================================================================
section "Fixing dnsmasq startup ordering"
# =============================================================================

# dnsmasq starts before wlan0 is fully up and fails with "unknown interface".
# This drop-in makes dnsmasq wait for hostapd (and therefore wlan0) first.
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/wait-for-hostapd.conf <<EOF
[Unit]
After=hostapd.service
Wants=hostapd.service
EOF

systemctl daemon-reload
success "mindlink.service and dnsmasq ordering written"

# =============================================================================
section "Enabling services (will start on reboot)"
# =============================================================================

systemctl enable dhcpcd hostapd dnsmasq mindlink
success "dhcpcd, hostapd, dnsmasq, mindlink enabled"

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
