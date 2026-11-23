#!/usr/bin/env bash
#
# Read-only pre-check: does this guide apply to this machine, and is it
# ready for the fix? Changes nothing. No root needed.
#
# Usage:  ./scripts/check.sh
#
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

echo "======================================================================"
echo " AW88399 speaker fix — pre-check   $(date '+%Y-%m-%d %H:%M')"
echo "======================================================================"

echo
echo "1. Hardware"
info "model: $(cat /sys/class/dmi/id/product_version 2>/dev/null) ($(cat /sys/class/dmi/id/product_name 2>/dev/null))"
SSID="$(alc287_ssid)"
if [[ -z "$SSID" ]]; then
    fail "no Realtek ALC287 codec found — this guide does not apply"
elif [[ "$SSID" == "$TESTED_SSID" ]]; then
    pass "ALC287 codec SSID ${SSID} — the tested configuration"
elif ssid_is_covered "$SSID"; then
    pass "ALC287 codec SSID ${SSID} — covered by the kernel 7.3 quirk (untested)"
else
    fail "ALC287 codec SSID ${SSID} — NOT in the kernel 7.3 AW88399 quirk list"
fi
if has_awdz8399; then
    pass "Awinic AW88399 amplifiers present (ACPI AWDZ8399)"
else
    fail "no AWDZ8399 ACPI device — this machine does not use AW88399 amps"
fi

echo
echo "2. Running kernel: $(uname -r)"
ACTIVE=0
if modinfo -n snd_hda_scodec_aw88399 >/dev/null 2>&1; then
    ACTIVE=1
    pass "has the AW88399 HDA side-codec driver"
else
    info "no AW88399 HDA side-codec driver (expected on 7.0 kernels) — needs the fix"
fi

echo
echo "3. Fix availability (Ubuntu archive)"
. /etc/os-release 2>/dev/null
if [[ "${VERSION_ID:-}" != "26.04" ]]; then
    warn "this is ${PRETTY_NAME:-unknown}; the steps target Ubuntu 26.04 LTS"
fi
CAND="$(apt_candidate "$OEM_META")"
if [[ -z "$CAND" || "$CAND" == "(none)" ]]; then
    fail "${OEM_META} not available — run 'sudo apt update' and check again"
elif is_73_or_newer "$CAND"; then
    pass "${OEM_META} ${CAND} available (signed, kernel 7.3+)"
else
    fail "${OEM_META} candidate ${CAND} is older than 7.3"
fi
HWE="$(apt_candidate linux-generic-hwe-26.04)"
[[ -n "$HWE" ]] && info "standard HWE kernel candidate: ${HWE}"

echo
echo "4. Amplifier firmware (${FW})"
if firmware_ok; then
    pass "present, checksum matches"
elif [[ -e "$FW" ]]; then
    fail "present but WRONG ($(firmware_size) bytes, expected ${FW_SIZE_EXPECTED}) — see README step 2"
else
    fail "missing — see README step 2 (no Ubuntu package ships this file)"
fi

echo
echo "5. Things that would block or break the fix"
OVR="$(audio_overrides)"
if [[ -n "$OVR" ]]; then
    fail "audio overrides found — remove them (README step 3):"
    sed 's/^/         /' <<<"$OVR"
else
    pass "no model= or dsp_driver overrides"
fi

HOLDS="$(kernel_nvidia_holds)"
if [[ -n "$HOLDS" ]]; then
    warn "held kernel/NVIDIA packages — the install will likely fail until unheld:"
    sed 's/^/         /' <<<"$HOLDS"
else
    pass "no held kernel/NVIDIA packages"
fi

if command -v mokutil >/dev/null 2>&1; then
    info "Secure Boot: $(mokutil --sb-state 2>/dev/null | head -1) (fine: the OEM kernel is signed)"
fi

BR="$(nvidia_branch)"
if nvidia_uses_dkms; then
    info "NVIDIA via DKMS — it will build for the new kernel on install"
elif [[ -n "$BR" ]]; then
    NVPKG="linux-modules-nvidia-${BR}-${OEM_META#linux-}"
    NVC="$(apt_candidate "$NVPKG")"
    if [[ -n "$NVC" && "$NVC" != "(none)" ]]; then
        pass "NVIDIA ${BR}: prebuilt module ${NVPKG} available (${NVC})"
    else
        fail "NVIDIA ${BR}: no ${NVPKG} in the archive — switch to a supported branch first"
    fi
else
    info "no NVIDIA driver package detected"
fi

echo
echo "======================================================================"
if (( N_FAIL == 0 && ACTIVE )); then
    echo " The fixed kernel is already running. Next: ./scripts/verify.sh"
elif (( N_FAIL == 0 )); then
    echo " Ready. Next: ./scripts/install.sh --dry-run, then sudo ./scripts/install.sh"
else
    echo " ${N_FAIL} problem(s) above. Fix them before installing."
fi
echo "======================================================================"
exit $(( N_FAIL > 0 ))
