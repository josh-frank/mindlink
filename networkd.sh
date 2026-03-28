#!/usr/bin/env bash
# =============================================================================
#  networkd.sh — MindLink hotspot via systemd-networkd + hostapd + dnsmasq
#
#  Targets Ubuntu Jammy (and similar) which use systemd-networkd + wpa_supplicant
#  + netplan, with no NetworkManager.
#
#  Unlike the NM path, systemd-networkd does not drive the AP radio or run a
#  DHCP server itself — so we use hostapd for the radio and dnsmasq for DHCP,
#  same as the dhcpcd path.  Netplan is disabled for wlan0 so it stops
#  regenerating client configs on every boot.
#
#  Nothing is started live — the Pi comes up cleanly on next boot.
#  Safe to run over wlan0 SSH: your session stays up for the whole script.
#
#  Usage:
#    cp .env.example .env && nano .env
#    sudo bash networkd.sh
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

[[ $EUID -eq 0 ]] || error "Please run as root:  sudo bash networkd.sh"

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
section "Preflight checks"
# =============================================================================

[[ -n "$PASSPHRASE" ]] \
    || error "PASSPHRASE is not set.  Edit .env or export PASSPHRASE= before running."
[[ ${#PASSPHRASE} -ge 8 ]] \
    || error "PASSPHRASE must be at least 8 characters."
[[ -f "$MINDLINK_DIR/mindlink.py" ]] \
    || error "mindlink.py not found at $MINDLINK_DIR — set MINDLINK_DIR= to override."
ip link show "$IFACE" &>/dev/null \
    || error "Interface '$IFACE' not found.  Is the Wi-Fi adapter present?"
systemctl is-active --quiet systemd-networkd \
    || error "systemd-networkd is not running."

DEVICE_ID=$(grep "^Serial" /proc/cpuinfo | awk '{print $3}' || echo "unknown")
info "Device    : $DEVICE_ID"
info "Interface : $IFACE"
info "SSID      : $SSID"
info "Hotspot IP: $HOTSPOT_IP"
info "User      : $MINDLINK_USER"
info "MindLink  : $MINDLINK_DIR"

# =============================================================================
section "Neutering wpa_supplicant BEFORE package install"
# =============================================================================
# Do this first — before apt touches anything — so wpa_supplicant can't race
# hostapd on the very first reboot.  Mask (not just disable) so systemd
# ignores the unit entirely, even if another package tries to re-enable it.

systemctl stop    wpa_supplicant                   2>/dev/null || true
systemctl stop    "wpa_supplicant@${IFACE}"        2>/dev/null || true
systemctl disable wpa_supplicant                   2>/dev/null || true
systemctl disable "wpa_supplicant@${IFACE}"        2>/dev/null || true
systemctl mask    wpa_supplicant                   2>/dev/null || true
systemctl mask    "wpa_supplicant@${IFACE}"        2>/dev/null || true

WPA_CONF=/etc/wpa_supplicant/wpa_supplicant.conf
if [[ -f "$WPA_CONF" ]]; then
    cp "$WPA_CONF" "${WPA_CONF}.bak"
    printf 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\nupdate_config=1\n' \
        > "$WPA_CONF"
    info "wpa_supplicant.conf neutralised (backup at ${WPA_CONF}.bak)"
else
    info "No wpa_supplicant.conf found — nothing to neutralise"
fi
success "wpa_supplicant masked"

# =============================================================================
section "Installing packages"
# =============================================================================

# hostapd drives the AP radio; dnsmasq serves DHCP to clients.
# systemd-networkd handles the static IP on wlan0.
# rfkill unblocks the radio if soft-blocked on first boot.

# PRE-UNMASK hostapd before apt-get update (not just before install).
# On some Ubuntu images the apt postinstall for hostapd tries to start it,
# finds wlan0 busy/unconfigured, fails, and re-masks the unit.  Unmasking
# before apt means any postinstall start-attempt is a no-op (unit is unmasked
# but not yet enabled) rather than resulting in a mask operation.
systemctl unmask hostapd 2>/dev/null || true

# systemd-resolved listens on port 53 and will cause dnsmasq to fail on
# install.  Disable it now so apt's postinstall can start dnsmasq cleanly.
systemctl disable --now systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf

# DEBIAN_FRONTEND=noninteractive suppresses any postinstall prompts or
# service-management dialogs that could interfere.
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    hostapd dnsmasq \
    python3-websockets python3-aiohttp python3-yaml \
    i2c-tools rfkill

# Unmask again — belt-and-suspenders in case the postinstall re-masked it.
systemctl unmask hostapd 2>/dev/null || true

# --break-system-packages needed on Jammy+ where pip is externally managed
PIP_FLAGS=""
pip3 install --help 2>&1 | grep -q -- "--break-system-packages" \
    && PIP_FLAGS="--break-system-packages"

pip3 install grove.py aiohttp-cors $PIP_FLAGS --quiet
sudo -u "$MINDLINK_USER" pip3 install grove.py aiohttp-cors $PIP_FLAGS --quiet
success "Packages installed"

# =============================================================================
section "Unblocking WiFi radio"
# =============================================================================

rfkill unblock wifi
cat > /etc/systemd/system/rfkill-unblock-wifi.service <<EOF
[Unit]
Description=Unblock WiFi rfkill on boot
# Must run before hostapd tries to claim the radio
Before=hostapd.service wpa_supplicant.service

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

if command -v raspi-config &>/dev/null; then
    raspi-config nonint do_i2c 0
else
    BOOT_CONFIG=""
    [[ -f /boot/firmware/config.txt ]] && BOOT_CONFIG=/boot/firmware/config.txt
    [[ -z "$BOOT_CONFIG" && -f /boot/config.txt ]] && BOOT_CONFIG=/boot/config.txt
    if [[ -n "$BOOT_CONFIG" ]]; then
        if grep -q "^dtparam=i2c_arm=" "$BOOT_CONFIG"; then
            sed -i 's/^dtparam=i2c_arm=.*/dtparam=i2c_arm=on/' "$BOOT_CONFIG"
        else
            echo "dtparam=i2c_arm=on" >> "$BOOT_CONFIG"
        fi
        info "I2C enabled via $BOOT_CONFIG"
    else
        warn "Could not find boot config — enable I2C manually: add 'dtparam=i2c_arm=on' to your boot config"
    fi
fi
success "I2C enabled"

if i2cdetect -y -a 1 | grep -q "04"; then
    success "Grove HAT detected at 0x04"
else
    warn "Grove HAT not detected — check later with: i2cdetect -y -a 1"
fi

# =============================================================================
section "Disabling netplan management of wlan0"
# =============================================================================

# Netplan regenerates networkd config files on every boot from /etc/netplan/*.yaml.
# Patch out any reference to $IFACE so it stops regenerating client configs.

NETPLAN_DIR="/etc/netplan"
PATCHED=0

for yaml in "$NETPLAN_DIR"/*.yaml "$NETPLAN_DIR"/*.yml; do
    [[ -f "$yaml" ]] || continue
    if grep -q "$IFACE" "$yaml" 2>/dev/null; then
        cp "$yaml" "${yaml}.bak"
        info "Backed up: $yaml → ${yaml}.bak"
        python3 - "$yaml" "$IFACE" <<'PYEOF'
import sys, yaml as _yaml

path, iface = sys.argv[1], sys.argv[2]
with open(path) as f:
    doc = _yaml.safe_load(f) or {}

wifis = doc.get("network", {}).get("wifis", {})
if iface in wifis:
    del wifis[iface]
if not wifis:
    doc.get("network", {}).pop("wifis", None)

with open(path, "w") as f:
    _yaml.dump(doc, f, default_flow_style=False)
PYEOF
        PATCHED=1
        info "Removed $IFACE from netplan yaml: $yaml"
    fi
done

if [[ $PATCHED -eq 1 ]]; then
    netplan generate 2>&1 | sed 's/^/  [netplan] /' || true
    success "Netplan regenerated without $IFACE"
else
    info "No netplan yaml referenced $IFACE — nothing to patch"
fi

# =============================================================================
section "Writing systemd-networkd static IP for $IFACE"
# =============================================================================

# ConfigureWithoutCarrier=yes: networkd assigns the IP even before hostapd
# has brought the radio up, avoiding a startup race.
# KeepConfiguration=static: networkd does not tear down the address if the
# link disappears briefly (e.g. during hostapd restart).
cat > /etc/systemd/network/10-mindlink-ap.network <<EOF
[Match]
Name=${IFACE}

[Network]
Address=${HOTSPOT_IP}/24
ConfigureWithoutCarrier=yes

[Link]
KeepConfiguration=static
EOF

success "networkd static IP written"

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

# Point /etc/default/hostapd at our config file (needed on Debian-family images
# that ship with DAEMON_CONF commented out).
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd 2>/dev/null || true

# Final unmask — do this AFTER writing the config so the unit is fully ready.
systemctl unmask hostapd 2>/dev/null || true
success "hostapd configured and unmasked"

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
section "Fixing dnsmasq startup ordering"
# =============================================================================

# dnsmasq must start after hostapd has brought wlan0 up as an AP, otherwise
# it tries to bind to 192.168.4.1 on an interface that doesn't have that IP
# yet and fails with "unknown interface".
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/wait-for-hostapd.conf <<EOF
[Unit]
After=hostapd.service
Wants=hostapd.service
EOF

success "dnsmasq ordering drop-in written"

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
section "Installing hostapd-watchdog (catches silent AP failures)"
# =============================================================================

# On Ubuntu/networkd, hostapd occasionally starts before the nl80211 driver is
# fully ready and exits 0 without actually bringing up the AP.  This lightweight
# watchdog fires 15 s after hostapd starts and restarts it if wlan0 is not in
# AP mode (IFF operstate UP with a BSS).  One retry is usually enough.
cat > /etc/systemd/system/hostapd-watchdog.service <<EOF
[Unit]
Description=Restart hostapd if AP mode not established
After=hostapd.service
Requires=hostapd.service

[Service]
Type=oneshot
# Wait 15 s for hostapd to fully initialise, then check AP mode
ExecStartPre=/bin/sleep 15
ExecStart=/bin/bash -c '
    if ! iw dev ${IFACE} info 2>/dev/null | grep -q "type AP"; then
        echo "hostapd-watchdog: AP mode not active — restarting hostapd" | systemd-cat -t hostapd-watchdog
        systemctl restart hostapd
    else
        echo "hostapd-watchdog: AP mode confirmed on ${IFACE}" | systemd-cat -t hostapd-watchdog
    fi
'
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hostapd dnsmasq mindlink hostapd-watchdog
success "hostapd, dnsmasq, mindlink, hostapd-watchdog enabled"

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
echo -e "  watchdog  : ${CYAN}journalctl -t hostapd-watchdog${RESET}"
echo ""

read -r -p "Reboot now? [y/N] " REPLY
if [[ "${REPLY,,}" == "y" ]]; then
    info "Rebooting..."
    reboot
else
    warn "Skipping reboot — run 'sudo reboot' when ready."
fi
