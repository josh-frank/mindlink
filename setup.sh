#!/usr/bin/env bash
# =============================================================================
#  setup.sh — MindLink auto-detector
#  Sniffs whether this Pi uses NetworkManager, dhcpcd, or systemd-networkd
#  and delegates to the appropriate setup script.
#
#  Usage:
#    sudo bash setup.sh [--dry-run]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── Dry-run flag ──────────────────────────────────────────────────────────────
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# =============================================================================
section "Detecting network manager"
# =============================================================================

# Strategy: prefer whichever manager is *active*.  If multiple are somehow
# active (misconfigured Pi), NetworkManager > dhcpcd > networkd.
NM_ACTIVE=0
DHCPCD_ACTIVE=0
NETWORKD_ACTIVE=0

systemctl is-active --quiet NetworkManager    2>/dev/null && NM_ACTIVE=1       || true
systemctl is-active --quiet dhcpcd            2>/dev/null && DHCPCD_ACTIVE=1   || true
systemctl is-active --quiet systemd-networkd  2>/dev/null && NETWORKD_ACTIVE=1 || true

# Also check if binaries are installed, even if services aren't running yet
NM_INSTALLED=0
DHCPCD_INSTALLED=0
command -v nmcli  &>/dev/null && NM_INSTALLED=1
command -v dhcpcd &>/dev/null && DHCPCD_INSTALLED=1

if   [[ $NM_ACTIVE       -eq 1 ]]; then
    BACKEND="networkmanager"
    info "Detected: NetworkManager (active service)"
elif [[ $DHCPCD_ACTIVE   -eq 1 ]]; then
    BACKEND="dhcpcd"
    info "Detected: dhcpcd (active service)"
elif [[ $NETWORKD_ACTIVE -eq 1 ]]; then
    BACKEND="networkd"
    info "Detected: systemd-networkd (active service)"
elif [[ $NM_INSTALLED    -eq 1 ]]; then
    BACKEND="networkmanager"
    warn "NetworkManager installed but not active — assuming NM backend"
elif [[ $DHCPCD_INSTALLED -eq 1 ]]; then
    BACKEND="dhcpcd"
    warn "dhcpcd installed but not active — assuming dhcpcd backend"
else
    error "Could not detect a network manager (tried NetworkManager, dhcpcd, systemd-networkd)."
fi

# =============================================================================
section "Selecting setup script"
# =============================================================================

case "$BACKEND" in
    networkmanager)
        TARGET="$SCRIPT_DIR/networkmanager.sh"
        [[ -f "$TARGET" ]] || error "networkmanager.sh not found in $SCRIPT_DIR"
        ;;
    dhcpcd)
        TARGET="$SCRIPT_DIR/dhcpcd.sh"
        [[ -f "$TARGET" ]] || error "dhcpcd.sh not found in $SCRIPT_DIR"
        ;;
    networkd)
        TARGET="$SCRIPT_DIR/networkd.sh"
        [[ -f "$TARGET" ]] || error "networkd.sh not found in $SCRIPT_DIR"
        ;;
esac

info "Will run: $TARGET"

if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo -e "${YELLOW}${BOLD}Dry-run mode — no changes made.${RESET}"
    echo -e "  Backend detected : ${BOLD}${BACKEND}${RESET}"
    echo -e "  Would execute    : ${BOLD}${TARGET}${RESET}"
    echo ""
    echo "Run without --dry-run to apply."
    exit 0
fi

# =============================================================================
section "Delegating to $TARGET"
# =============================================================================

exec bash "$TARGET" "$@"
