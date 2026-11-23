#!/usr/bin/env bash
#
# Post-reboot health check for the AW88399 speaker fix. Changes nothing.
# Run after the fix, and again after any kernel or NVIDIA update.
#
# Usage:  ./scripts/verify.sh      (exit code 0 = all checks passed)
#
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

echo "======================================================================"
echo " AW88399 speaker fix — verification   $(date '+%Y-%m-%d %H:%M')"
echo " Kernel: $(uname -r)"
echo "======================================================================"

# Capture the log once. Don't pipe journalctl into `grep -q` under pipefail:
# grep exits early, journalctl gets SIGPIPE, and the check misreports.
KLOG="$(kernel_log)"
[[ -n "$KLOG" ]] || warn "kernel log not readable — re-run with sudo for checks 4 and 6"

echo
echo "1. Audio overrides"
OVR="$(audio_overrides)"
if [[ -n "$OVR" ]]; then
    fail "overrides present (remove them, README step 3):"
    sed 's/^/         /' <<<"$OVR"
else
    pass "no model= or dsp_driver overrides"
fi

echo
echo "2. Amplifier firmware"
if firmware_ok; then
    pass "${FW} matches the known-good checksum"
else
    fail "${FW} missing or wrong ($(firmware_size) bytes) — README step 2"
fi

echo
echo "3. Kernel driver"
if modinfo -n snd_hda_scodec_aw88399 >/dev/null 2>&1; then
    pass "running kernel has snd-hda-scodec-aw88399"
else
    fail "running kernel ($(uname -r)) has no AW88399 HDA driver — boot the OEM 7.3 kernel"
fi

echo
echo "4. Codec quirk"
# The fixup name prints empty on Ubuntu kernels; the match source is what
# matters: "codec SSID 17aa:XXXX" = quirk matched, "PCI SSID 17aa:0000" = none.
FIXUP="$(grep -i 'ALC287: picked fixup' <<<"$KLOG" | tail -1)"
if [[ -z "$FIXUP" ]]; then
    info "no 'picked fixup' line in the log"
else
    echo "         ${FIXUP##*kernel: }"
    if grep -q 'codec SSID 17aa:' <<<"$FIXUP"; then
        pass "codec-SSID quirk matched (Legion AW88399 fixup)"
    else
        fail "no codec-SSID quirk matched — amps will not be attached"
    fi
fi

echo
echo "5. Amplifier binding"
if [[ -e /sys/bus/i2c/devices/i2c-AWDZ8399:00 ]]; then
    fail "AWDZ8399 is a single direct I2C client — the 7.0 path, amps unused"
fi
BOUND=0; TOTAL=0
for a in /sys/bus/i2c/devices/*aw88399-hda*; do
    [[ -e "$a" ]] || continue
    TOTAL=$((TOTAL + 1))
    if [[ -e "$a/driver" ]]; then
        BOUND=$((BOUND + 1))
        info "$(basename "$a") -> $(basename "$(readlink -f "$a/driver")")"
    fi
done
if (( TOTAL == 0 )); then
    fail "no aw88399-hda I2C clients"
elif (( BOUND == TOTAL )); then
    pass "${BOUND}/${TOTAL} amplifiers bound to the HDA side-codec driver"
else
    fail "only ${BOUND}/${TOTAL} amplifiers bound"
fi

echo
echo "6. Amplifier initialisation (kernel log)"
AMPLOG="$(grep -i 'aw88399' <<<"$KLOG")"
if grep -q 'Bound - SSID' <<<"$AMPLOG"; then
    pass "amplifiers bound to the codec:"
    grep -E 'registered successfully|Bound - SSID' <<<"$AMPLOG" \
        | sed -E 's/^.*kernel: //; s/^/         /'
elif [[ -n "$AMPLOG" ]]; then
    fail "aw88399 messages, but no 'Bound - SSID' line:"
    tail -5 <<<"$AMPLOG" | sed -E 's/^.*kernel: //; s/^/         /'
elif [[ -n "$KLOG" ]]; then
    fail "no aw88399 messages — amplifiers never initialised"
fi

echo
echo "7. Mixer"
CARD="$(alc287_card)"
if [[ -z "$CARD" ]]; then
    fail "no ALC287 sound card found"
else
    for ctl in Master Speaker "Bass Speaker"; do
        STATE="$(amixer -c "$CARD" sget "$ctl" 2>/dev/null | grep -o '\[o[nf]*\]' | head -1)"
        if [[ -z "$STATE" ]]; then
            info "card ${CARD} '${ctl}': control not present"
        elif [[ "$STATE" == "[off]" ]]; then
            fail "card ${CARD} '${ctl}' is muted — amixer -c ${CARD} sset '${ctl}' unmute"
        else
            pass "card ${CARD} '${ctl}' unmuted"
        fi
    done
fi

echo
echo "8. NVIDIA (unchanged by the fix, but the kernel switch can break it)"
if [[ -n "$(nvidia_branch)" ]] || nvidia_uses_dkms; then
    if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
        pass "$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
    else
        fail "nvidia-smi fails — no NVIDIA module for $(uname -r), or module/userspace mismatch"
    fi
else
    info "no NVIDIA driver installed"
fi

echo
echo "======================================================================"
if (( N_FAIL == 0 )); then
    echo " All checks passed. Listening test:  speaker-test -c2 -twav -l1"
else
    echo " ${N_FAIL} check(s) failed — see README 'Troubleshooting'."
fi
echo "======================================================================"
exit $(( N_FAIL > 0 ))
