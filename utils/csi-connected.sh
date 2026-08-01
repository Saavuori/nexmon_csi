#!/bin/sh
#
# Configure the Nexmon CSI extractor on a Raspberry Pi without losing the
# Wi-Fi association.
#
# The regular setup procedure kills wpa_supplicant, forces the chip onto the
# channel passed to makecsiparams and switches to monitor mode, all of which
# tear down an existing connection. Instead this script derives the channel
# from the running association, tells the extractor to stay on it
# (makecsiparams -k) and only disables the power save modes that would
# otherwise make the chip sleep through the frames we want CSI for.
#
# CSI is delivered as UDP packets on the regular interface, so no monitor
# interface is needed and the interface keeps carrying normal traffic.

set -e

IFACE=wlan0
COREMASK=0x1
NSSMASK=0x1
MACS=
BYTE=
DELAY=
ALLOW_SCAN=0
ACTION=start

usage() {
    cat <<EOF
Usage: $0 [options]

Collect CSI while staying associated to an access point.

  -i iface      wireless interface (default: $IFACE)
  -C coremask   bitmask of cores to capture on (default: $COREMASK)
  -N nssmask    bitmask of spatial streams to capture (default: $NSSMASK)
  -m addrs      comma separated list of source MAC addresses to filter for
  -b byte       only collect for frames starting with this byte, e.g. 0x88
  -d delay      delay in us after each CSI operation
  --allow-scan  leave firmware scanning enabled; scans retune the chip and
                interrupt the collection, but roaming and 'iw scan' keep working
  --stop        stop the collection and re-enable scanning
  --status      show the current state and exit
  -h, --help    print this message

Examples:
  $0 -C 0x1 -N 0x1 -b 0x88
  $0 -m 00:11:22:33:44:55
  $0 --stop
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

warn() {
    echo "warning: $*" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        -i) IFACE=$2; shift 2 ;;
        -C) COREMASK=$2; shift 2 ;;
        -N) NSSMASK=$2; shift 2 ;;
        -m) MACS=$2; shift 2 ;;
        -b) BYTE=$2; shift 2 ;;
        -d) DELAY=$2; shift 2 ;;
        --allow-scan) ALLOW_SCAN=1; shift ;;
        --stop) ACTION=stop; shift ;;
        --status) ACTION=status; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument '$1'" ;;
    esac
done

[ "$(id -u)" = "0" ] || die "must be run as root"

for tool in iw nexutil makecsiparams; do
    command -v "$tool" >/dev/null 2>&1 || \
        die "'$tool' not found in PATH (build and install it first)"
done

ip link show "$IFACE" >/dev/null 2>&1 || die "interface '$IFACE' does not exist"

# nexutil hands our parameter block to the firmware through the brcmfmac driver,
# and which transport it uses is fixed when nexutil is compiled. Only one of the
# three works on a driver that is not nexmon's own:
#
#   -DUSE_NETLINK      the default. Needs the netlink socket that only nexmon's
#                      patched brcmfmac creates, otherwise the socket cannot be
#                      opened at all: 'socket error (93: Protocol not supported)'
#   without it         private ioctls that mainline brcmfmac no longer handles,
#                      which answers 'error ret=-1 errno=95'
#   USE_VENDOR_CMD=1   an nl80211 vendor command, which the stock driver serves
#
# Raspberry Pi OS has shipped the stock driver since it moved past kernel 5.10, so
# there nexutil has to be the vendor command build. Picking the wrong one is easy
# to miss because nexutil reports the failure on stderr but still exits 0, which
# is why nothing below trusts its exit status: every write is read back instead.

# nexutil has no "print this get as a number" option: -i only controls how the
# *input* to a set is parsed, and a get is hex dumped unless -r or -R is given.
# Reading the raw bytes and decoding them here avoids parsing column-formatted
# text - the previous version scanned the hexdump for the last field that looked
# like an integer, which is the trailing padding byte, so it reported 0 for
# every possible value and made a successful start look like a failure.
nexutil_get_u16() {
    nexutil -I"$IFACE" -g"$1" -l4 -r 2>/dev/null | od -An -tu2 -N2 | tr -d '[:space:]'
}

nexutil_get_u32_hex() {
    nexutil -I"$IFACE" -g"$1" -l4 -r 2>/dev/null | od -An -tx4 -N4 | tr -d '[:space:]'
}

# WLC_GET_MAGIC (ioctl 0) answers 0x14e46c77 on every Broadcom firmware, so a
# correct answer proves nexutil reached the chip without saying anything about
# which firmware is running. Querying the chanspec cannot do that job: nexutil
# prints 'chanspec: ...' out of its own buffer whether or not the ioctl ever
# got there, so grepping for that word succeeded even against a dead transport.
transport_works() {
    [ "$(nexutil_get_u32_hex 0)" = "14e46c77" ]
}

# ioctl 501 returns csi_collect out of shared memory. Note that a firmware
# *without* the extractor does not fail this in a way nexutil surfaces - it
# hands back the untouched buffer, which reads as a perfectly plausible 0 - so
# this answers "did the extractor take my configuration", not "is the CSI
# firmware running". csi_firmware_state below answers the latter.
csi_collect_state() {
    nexutil_get_u16 501
}

# The banner the driver logs when the chip attaches is the one direct statement
# of which image is running, and the nexmon build marks itself there. dmesg can
# have rotated past it on a long-lived system, hence the third answer.
csi_firmware_state() {
    banner=$(dmesg 2>/dev/null | grep -i 'brcmfmac.*Firmware:' | tail -n 1)
    if [ -z "$banner" ]; then
        echo unknown
    elif echo "$banner" | grep -qi nexmon; then
        echo nexmon
    else
        echo stock
    fi
}

require_firmware_access() {
    if ! transport_works; then
        echo "error: nexutil cannot reach the firmware on $IFACE" >&2
        cat >&2 <<EOF

The nexutil in your PATH speaks a transport this driver does not provide. A stock
brcmfmac - which is what recent Raspberry Pi OS loads - only accepts firmware
commands as nl80211 vendor commands, so nexutil has to be built for those:

  sudo apt install libnl-3-dev libnl-genl-3-dev
  cd \$NEXMON_ROOT/utilities/nexutil
  make clean && make USE_VENDOR_CMD=1 && sudo make install

'make clean' matters: objects left from an earlier build keep the old transport.
Then 'nexutil -I$IFACE -k' has to print a chanspec before this script can work.
EOF
        exit 1
    fi

    case "$(csi_firmware_state)" in
    stock)
        cat >&2 <<EOF
error: $IFACE is running stock firmware, not the nexmon CSI build

Install and activate the CSI firmware, which also reloads the driver so the chip
actually reads it:

  make -f Makefile.rpi install-firmware

Installing the image without reloading changes nothing: the chip only reads its
firmware while the driver attaches.
EOF
        exit 1
        ;;
    unknown)
        warn "could not read the firmware banner from dmesg, continuing anyway"
        warn "if no CSI arrives, confirm the CSI firmware is active with 'make -f Makefile.rpi install-firmware'"
        ;;
    esac
}

# Reads "<channel> <bandwidth>" from the running association, e.g. "36 80".
read_chanspec() {
    iw dev "$IFACE" info 2>/dev/null | awk '
        /channel [0-9]+/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "channel") ch = $(i + 1)
                if ($i == "width:")  bw = $(i + 1)
            }
        }
        END { if (ch != "") printf "%s %s\n", ch, (bw == "" ? "20" : bw) }
    '
}

is_connected() {
    iw dev "$IFACE" link 2>/dev/null | grep -q '^Connected to'
}

show_status() {
    echo "interface:  $IFACE"
    if is_connected; then
        echo "connected:  yes ($(iw dev "$IFACE" link | sed -n 's/^\tSSID: //p'))"
    else
        echo "connected:  no"
    fi
    set -- $(read_chanspec)
    echo "channel:    ${1:-unknown} @ ${2:-unknown} MHz"
    chanspec=$(nexutil -I"$IFACE" -k 2>/dev/null | sed 's/^chanspec: *//')
    echo "chanspec:   ${chanspec:-unavailable}"
    if transport_works; then
        echo "nexutil:    reaches the firmware"
        case "$(csi_firmware_state)" in
        nexmon)
            echo "firmware:   nexmon CSI build"
            echo "csi:        $(csi_collect_state)"
            ;;
        stock)
            echo "firmware:   stock, no extractor - run 'make -f Makefile.rpi install-firmware'"
            echo "csi:        unavailable"
            ;;
        *)
            echo "firmware:   unknown, dmesg has no brcmfmac banner left"
            echo "csi:        $(csi_collect_state) (meaningless unless the CSI build is running)"
            ;;
        esac
    else
        echo "nexutil:    cannot reach the driver, rebuild it with USE_VENDOR_CMD=1"
        echo "firmware:   unknown"
        echo "csi:        unavailable"
    fi
    powersave=$(iw dev "$IFACE" get power_save 2>/dev/null | sed -n 's/.*Power save: //p')
    echo "power save: ${powersave:-unknown}"
}

# --status is a diagnosis of its own and has to run even when nothing works
[ "$ACTION" = "status" ] || require_firmware_access

case "$ACTION" in
status)
    show_status
    exit 0
    ;;
stop)
    # csi_collect = 0 also makes the firmware re-enable scanning
    PARAMS=$(makecsiparams -e 0) || die "makecsiparams failed"
    LEN=$(makecsiparams -e 0 -r | wc -c | awk '{print $1}')
    nexutil -I"$IFACE" -s500 -b -l"$LEN" -v"$PARAMS" >/dev/null || true
    STATE=$(csi_collect_state)
    [ "$STATE" = "0" ] || \
        die "the extractor did not take the stop request (csi_collect reads back as '${STATE:-nothing}')"
    echo "CSI collection stopped, scanning re-enabled on $IFACE"
    exit 0
    ;;
esac

is_connected || die "$IFACE is not associated - connect to your access point first"

set -- $(read_chanspec)
CHANNEL=$1
BANDWIDTH=$2
[ -n "$CHANNEL" ] || die "could not determine the channel of $IFACE"
echo "associated on channel $CHANNEL @ ${BANDWIDTH} MHz"

# Power save lets the chip doze between beacons, which shows up as long gaps in
# the CSI stream. Both knobs are runtime only and reset on the next driver load.
iw dev "$IFACE" set power_save off 2>/dev/null || warn "could not disable power save via iw"
nexutil -I"$IFACE" -s86 -i -v0 >/dev/null 2>&1 || warn "could not disable power save via nexutil"

# -k keeps the chip on the channel it is already tuned to, which is what keeps
# the association alive. The chanspec is still recorded in the parameter block
# for reference; drop it if this build of makecsiparams rejects the notation.
set -- -k -C "$COREMASK" -N "$NSSMASK"
[ "$ALLOW_SCAN" = "1" ] && set -- "$@" -S
[ -n "$MACS" ] && set -- "$@" -m "$MACS"
[ -n "$BYTE" ] && set -- "$@" -b "$BYTE"
[ -n "$DELAY" ] && set -- "$@" -d "$DELAY"

if PARAMS=$(makecsiparams "$@" -c "$CHANNEL/$BANDWIDTH" 2>/dev/null); then
    set -- "$@" -c "$CHANNEL/$BANDWIDTH"
else
    warn "chanspec $CHANNEL/$BANDWIDTH not accepted by makecsiparams, capturing on the current channel anyway"
    PARAMS=$(makecsiparams "$@") || die "makecsiparams failed"
fi
LEN=$(makecsiparams "$@" -r | wc -c | awk '{print $1}')
[ "$LEN" -ge 34 ] 2>/dev/null || die "unexpected parameter block length '$LEN'"

nexutil -I"$IFACE" -s500 -b -l"$LEN" -v"$PARAMS" >/dev/null || true

# The exit status above means nothing, so confirm the extractor really is armed
# by reading csi_collect out of the firmware's shared memory (ioctl 501).
STATE=$(csi_collect_state)
[ "$STATE" = "1" ] || \
    die "the extractor did not take the configuration (csi_collect reads back as '${STATE:-nothing}')"

# give the association a moment to fall over if the chip did move channel
sleep 2

if is_connected; then
    echo "CSI collection enabled, $IFACE still associated"
else
    warn "$IFACE lost its association while configuring the extractor"
fi

if [ "$ALLOW_SCAN" = "0" ]; then
    echo "note: scanning is suppressed until you run '$0 --stop'"
fi

echo
echo "capture with:"
echo "  tcpdump -i $IFACE dst port 5500 -w csi.pcap"
