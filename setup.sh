#!/usr/bin/env bash
# =============================================================================
#  setup.sh — Turn a Raspberry Pi Zero 2 into a MindLink GSR data appliance
#  Creates a Wi-Fi hotspot and auto-starts the mindlink.py WebSocket server
#  SSID: MindLink | Subnet: 192.168.4.0/24 | Gateway: 192.168.4.1
#
#  Install:
#    curl -sL https://raw.githubusercontent.com/josh-frank/mindlink/master/setup.sh | sudo bash
# =============================================================================
set -euo pipefail

# ── Load .env if present ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a && source "$SCRIPT_DIR/.env" && set +a
    echo "[INFO]  Loaded config from .env"
else
    echo "[WARN]  No .env found — using env vars or defaults"
    echo "[WARN]  Copy .env.example to .env and fill in your values"
fi

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ── Must run as root ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Please run as root:  sudo bash setup.sh"

# =============================================================================
#  CONFIGURATION  — edit these before running, or pass as env vars:
#    SSID=MyNet PASSPHRASE=secret sudo bash setup.sh
# =============================================================================
SSID="${SSID:-MindLink}"
PASSPHRASE="${PASSPHRASE:-}"           # required — no default
IFACE="${IFACE:-wlan0}"
HOTSPOT_IP="192.168.4.1"
DHCP_START="192.168.4.2"
DHCP_END="192.168.4.20"
DHCP_LEASE="24h"
CHANNEL="${CHANNEL:-6}"                # 2.4 GHz channel (1, 6, or 11 recommended)
MINDLINK_DIR="${MINDLINK_DIR:-/home/pi/mindlink}"
MINDLINK_USER="${MINDLINK_USER:-pi}"
# =============================================================================

section "Preflight checks"

# Require passphrase — no silent default
[[ -n "$PASSPHRASE" ]] \
    || error "PASSPHRASE is not set. Run:  PASSPHRASE=yourpassphrase sudo bash setup.sh"
[[ ${#PASSPHRASE} -ge 8 ]] \
    || error "PASSPHRASE must be at least 8 characters."

# Check mindlink.py is where we expect it
[[ -f "$MINDLINK_DIR/mindlink.py" ]] \
    || error "mindlink.py not found at $MINDLINK_DIR/mindlink.py — set MINDLINK_DIR= to override."

# Check the interface exists
ip link show "$IFACE" &>/dev/null \
    || error "Interface '$IFACE' not found. Is the Wi-Fi adapter present?"

# Print device ID so the operator can record it
DEVICE_ID=$(grep "^Serial" /proc/cpuinfo | awk '{print $3}' || echo "unknown")
info "Device ID : $DEVICE_ID"
info "Interface : $IFACE"
info "SSID      : $SSID"
info "Hotspot IP: $HOTSPOT_IP"
info "DHCP pool : $DHCP_START – $DHCP_END ($DHCP_LEASE leases)"
info "MindLink  : $MINDLINK_DIR"

# =============================================================================
section "Installing packages"
# =============================================================================

apt-get update -qq
apt-get install -y hostapd dnsmasq python3-websockets python3-aiohttp
success "packages installed"

# Unmask hostapd (Raspberry Pi OS ships it masked by default)
systemctl unmask hostapd

# =============================================================================
section "Stopping services before configuration"
# =============================================================================

systemctl stop hostapd dnsmasq mindlink 2>/dev/null || true

# =============================================================================
section "Configuring hostapd  (/etc/hostapd/hostapd.conf)"
# =============================================================================

cat > /etc/hostapd/hostapd.conf <<EOF
# ── Interface ────────────────────────────────────────────────────────────────
interface=${IFACE}
driver=nl80211

# ── Wi-Fi identity ───────────────────────────────────────────────────────────
ssid=${SSID}
country_code=US           # change to your ISO 3166-1 alpha-2 country code

# ── Radio settings (802.11g + n on 2.4 GHz — best for Pi Zero 2) ────────────
hw_mode=g
channel=${CHANNEL}
ieee80211n=1
ht_capab=[HT40][SHORT-GI-20][SHORT-GI-40]

# ── Security (WPA2-Personal / AES) ──────────────────────────────────────────
auth_algs=1
wpa=2
wpa_passphrase=${PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

# ── Misc ─────────────────────────────────────────────────────────────────────
wmm_enabled=1
ignore_broadcast_ssid=0
EOF

sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd

success "hostapd configured"

# =============================================================================
section "Configuring dnsmasq  (/etc/dnsmasq.conf)"
# =============================================================================

[[ -f /etc/dnsmasq.conf.bak ]] || cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
info "Original dnsmasq.conf backed up to /etc/dnsmasq.conf.bak"

cat > /etc/dnsmasq.conf <<EOF
# ── dnsmasq config generated by MindLink setup.sh ────────────────────────────
interface=${IFACE}
bind-interfaces
server=8.8.8.8
domain-needed
bogus-priv
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_LEASE}
EOF

success "dnsmasq configured"

# =============================================================================
section "Assigning static IP to ${IFACE}  (/etc/dhcpcd.conf)"
# =============================================================================

DHCPCD_CONF=/etc/dhcpcd.conf

if grep -q "interface ${IFACE}" "$DHCPCD_CONF" 2>/dev/null; then
    warn "Static IP block for ${IFACE} already present in dhcpcd.conf — skipping."
else
    cat >> "$DHCPCD_CONF" <<EOF

# ── Hotspot static IP added by MindLink setup.sh ─────────────────────────────
interface ${IFACE}
static ip_address=${HOTSPOT_IP}/24
nohook wpa_supplicant
EOF
    success "Static IP ${HOTSPOT_IP}/24 configured for ${IFACE}"
fi

# =============================================================================
section "Installing mindlink.service"
# =============================================================================

cat > /etc/systemd/system/mindlink.service <<EOF
[Unit]
Description=MindLink GSR WebSocket server
After=network.target

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
success "mindlink.service installed and enabled"

# =============================================================================
section "Enabling and starting services"
# =============================================================================

systemctl enable hostapd dnsmasq
systemctl restart dhcpcd
systemctl start hostapd dnsmasq mindlink

# =============================================================================
section "Verifying services"
# =============================================================================

FAIL=0
for svc in hostapd dnsmasq mindlink; do
    if systemctl is-active --quiet "$svc"; then
        success "$svc is running"
    else
        echo -e "${RED}[FAIL]${RESET}  $svc failed to start — check: journalctl -u $svc"
        FAIL=1
    fi
done

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}┌─────────────────────────────────────────────────────┐${RESET}"
    echo -e "${GREEN}${BOLD}│  MindLink is live                                   │${RESET}"
    echo -e "${GREEN}${BOLD}│  Device : ${DEVICE_ID}              │${RESET}"
    echo -e "${GREEN}${BOLD}│  SSID   : ${SSID}                              │${RESET}"
    echo -e "${GREEN}${BOLD}│  Stream : ws://${HOTSPOT_IP}:5000              │${RESET}"
    echo -e "${GREEN}${BOLD}└─────────────────────────────────────────────────────┘${RESET}"
else
    echo -e "${RED}${BOLD}One or more services failed. Review logs above.${RESET}"
    exit 1
fi
