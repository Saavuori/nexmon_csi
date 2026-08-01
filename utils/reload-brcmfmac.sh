#!/bin/sh
#
# Reload the Broadcom Wi-Fi driver so the chip re-downloads its firmware.
#
# Installing a firmware image does nothing on its own: the chip only reads it
# while the driver attaches. Which modules have to move to make that happen
# depends on the kernel, and getting it wrong fails in opposite directions:
#
#   up to 6.1   one brcmfmac module does everything. 'modprobe -r brcmfmac_wcc'
#               exits non-zero here because that module does not exist.
#   6.2 onward  firmware selection lives in per-vendor modules - brcmfmac_wcc
#               for the 43455 on a Raspberry Pi, plus brcmfmac_bca and
#               brcmfmac_cyw. They depend on brcmfmac, so brcmfmac cannot be
#               removed until they are out of the way.
#
# Raspberry Pi OS bookworm shipped 6.1 and later moved to 6.6 and 6.12, so both
# layouts are in the field on hardware this project supports - a Pi 5 may be
# running either. Rather than key off the version, look at what is loaded.
#
# Reloading also resets everything that was configured at runtime: the CSI
# extractor stops, power save comes back on, and any monitor interface is gone.

set -e

IFACE=wlan0
TIMEOUT=10

usage() {
    cat <<EOF
Usage: $0 [-i iface] [-t seconds]

Reload the brcmfmac driver so the Wi-Fi chip re-reads its firmware, then report
which firmware came up.

  -i iface      interface to wait for after the reload (default: $IFACE)
  -t seconds    how long to wait for it to reappear (default: $TIMEOUT)
  -h, --help    print this message
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -i) IFACE=$2; shift 2 ;;
        -t) TIMEOUT=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "error: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "error: must be run as root" >&2; exit 1; }

# lsmod reports module names with underscores regardless of the file name, so
# brcmfmac-wcc.ko shows up as brcmfmac_wcc.
module_loaded() {
    lsmod | awk -v m="$1" '$1 == m { hit = 1 } END { exit !hit }'
}

vendor_modules() {
    lsmod | awk '$1 ~ /^brcmfmac_/ { print $1 }'
}

# The vendor modules have to go first; each 'modprobe -r' also drops brcmfmac
# once nothing references it any more, which is fine - the check below is what
# decides whether anything is still left to unload.
for module in $(vendor_modules); do
    echo "unloading $module"
    modprobe -r "$module" || {
        echo "error: could not unload $module" >&2
        echo "something is still using the driver - stop wpa_supplicant/NetworkManager on $IFACE and retry" >&2
        exit 1
    }
done

if module_loaded brcmfmac; then
    echo "unloading brcmfmac"
    modprobe -r brcmfmac || {
        echo "error: could not unload brcmfmac" >&2
        exit 1
    }
fi

echo "loading brcmfmac"
modprobe brcmfmac

# The SDIO probe and the firmware download are asynchronous, so the interface
# is not back the instant modprobe returns.
waited=0
while [ "$waited" -lt "$TIMEOUT" ]; do
    if [ -e "/sys/class/net/$IFACE" ]; then
        break
    fi
    sleep 1
    waited=$((waited + 1))
done

if [ ! -e "/sys/class/net/$IFACE" ]; then
    echo "warning: $IFACE did not reappear within ${TIMEOUT}s" >&2
    echo "check 'dmesg | tail' - a firmware that fails to load leaves no interface behind" >&2
    exit 1
fi

# The firmware banner is the only direct evidence of which image the chip
# actually took. The nexmon build advertises itself in that string, so this
# distinguishes "the image was installed" from "the image is running".
banner=$(dmesg 2>/dev/null | grep -i 'brcmfmac.*Firmware:' | tail -n 1 || true)
if [ -n "$banner" ]; then
    echo "firmware: ${banner#*Firmware: }"
else
    echo "firmware: could not read the banner from dmesg"
fi
