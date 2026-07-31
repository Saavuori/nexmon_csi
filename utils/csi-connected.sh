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
    collect=$(nexutil -I"$IFACE" -g501 -i 2>/dev/null) || true
    echo "csi:        ${collect:-unavailable}"
    powersave=$(iw dev "$IFACE" get power_save 2>/dev/null | sed -n 's/.*Power save: //p')
    echo "power save: ${powersave:-unknown}"
}

case "$ACTION" in
status)
    show_status
    exit 0
    ;;
stop)
    # csi_collect = 0 also makes the firmware re-enable scanning
    PARAMS=$(makecsiparams -e 0) || die "makecsiparams failed"
    LEN=$(makecsiparams -e 0 -r | wc -c | awk '{print $1}')
    nexutil -I"$IFACE" -s500 -b -l"$LEN" -v"$PARAMS" >/dev/null || \
        die "nexutil could not reach the extractor on $IFACE"
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

nexutil -I"$IFACE" -s500 -b -l"$LEN" -v"$PARAMS" >/dev/null || \
    die "nexutil could not configure the extractor - is the nexmon CSI firmware loaded?"

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
