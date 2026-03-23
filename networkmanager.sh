#!/usr/bin/env bash
# =============================================================================
#  networkmanager.sh — MindLink hotspot via NetworkManager
#
#  Uses nmcli's built-in AP mode (ipv4.method shared) which provides DHCP and
#  NAT without needing dnsmasq or dhcpcd.  Never disables NetworkManager, so
#  your SSH session over *another* interface (eth0, USB gadget, etc.) stays up.
#  If you're SSHing over wlan0 itself, connect via eth0 first.
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
MINDLINK_DIR="${MINDLINK_DIR:-/home/pi/mindlink}"
MINDLINK_USER="${MINDLINK_USER:-pi}"
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
info "MindLink  : $MINDLINK_DIR"

# =============================================================================
section "Installing packages"
# =============================================================================

apt-get update -qq
# hostapd/dnsmasq not needed — NM drives the AP and handles DHCP natively
apt-get install -y python3-websockets python3-aiohttp i2c-tools
pip3 install grove.py --break-system-packages --quiet
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
section "Creating NetworkManager hotspot connection"
# =============================================================================

# Delete any stale connection with the same name so we get a clean slate.
# nmcli exits non-zero if the connection doesn't exist; suppress that.
nmcli connection delete "$CON_NAME" 2>/dev/null && info "Removed existing '$CON_NAME' connection" || true

# Create the AP connection.
# ipv4.method shared = NM enables IP forwarding, runs its built-in DHCP server,
# and assigns HOTSPOT_IP as the gateway — all without dnsmasq or hostapd.
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

success "NM connection '$CON_NAME' created"

# =============================================================================
section "Bringing up hotspot"
# =============================================================================

# nmcli up operates only on the NM connection — it does not touch any other
# interface, so your SSH session on eth0/USB survives this step.
nmcli connection up "$CON_NAME"
success "Hotspot up on $IFACE"

# Give the AP a moment to associate before we verify
sleep 3

# Confirm the interface now holds the expected IP
if ip addr show "$IFACE" | grep -q "${HOTSPOT_IP}"; then
    success "$IFACE has IP $HOTSPOT_IP"
else
    warn "$IFACE does not yet show $HOTSPOT_IP — NM may still be settling.  Check: ip addr show $IFACE"
fi

# =============================================================================
section "Installing mindlink.service"
# =============================================================================

cat > /etc/systemd/system/mindlink.service <<EOF
[Unit]
Description=MindLink GSR WebSocket server
# Wait for the NM hotspot connection to be established before starting
After=network-online.target NetworkManager-wait-online.service
Wants=network-online.target

[Service]
Type=simple
User=${MINDLINK_USER}
WorkingDirectory=${MINDLINK_DIR}
ExecStart=/usr/bin/python3 ${MINDLINK_DIR}/mindlink.py ${HOTSPOT_IP}:5000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mindlink
systemctl restart mindlink
success "mindlink.service installed, enabled, and started"

# =============================================================================
section "Verifying services"
# =============================================================================

FAIL=0

# NM manages the AP — check the connection is active, not a separate hostapd svc
if nmcli -t -f NAME,STATE connection show --active | grep -q "^${CON_NAME}:activated"; then
    success "NM hotspot '$CON_NAME' is active"
else
    echo -e "${RED}[FAIL]${RESET}  NM hotspot not active — check: nmcli connection show $CON_NAME"
    FAIL=1
fi

if systemctl is-active --quiet mindlink; then
    success "mindlink is running"
else
    echo -e "${RED}[FAIL]${RESET}  mindlink failed — check: journalctl -u mindlink"
    FAIL=1
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}┌─────────────────────────────────────────┐${RESET}"
    echo -e "${GREEN}${BOLD}│  MindLink is live (NetworkManager)      │${RESET}"
    echo -e "${GREEN}${BOLD}│  Device : ${DEVICE_ID}  │${RESET}"
    echo -e "${GREEN}${BOLD}│  SSID   : ${SSID}                   │${RESET}"
    echo -e "${GREEN}${BOLD}│  Stream : ws://${HOTSPOT_IP}:5000   │${RESET}"
    echo -e "${GREEN}${BOLD}│  HTTP   : http://${HOTSPOT_IP}:5001 │${RESET}"
    echo -e "${GREEN}${BOLD}└─────────────────────────────────────────┘${RESET}"
else
    echo -e "${RED}${BOLD}One or more services failed. Review logs above.${RESET}"
    exit 1
fi
