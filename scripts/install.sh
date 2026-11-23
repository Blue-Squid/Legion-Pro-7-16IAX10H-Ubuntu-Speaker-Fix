#!/usr/bin/env bash
#
# Install Ubuntu's signed OEM kernel (linux-oem-26.04b, 7.3+) plus the
# matching prebuilt NVIDIA modules if an NVIDIA driver is installed.
#
# Always simulates first; apt then shows its plan and asks before changing
# anything. The current kernel stays installed as a fallback.
#
# Usage:  ./scripts/install.sh --dry-run    show what would happen (no root)
#         sudo ./scripts/install.sh         install
#
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$(readlink -f "$0")")/lib.sh"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
(( DRY )) || [[ $EUID -eq 0 ]] || die "run with sudo (or use --dry-run)"

# ---------------------------------------------------------------------------
echo "==> Preflight"
. /etc/os-release
[[ "${VERSION_ID:-}" == "26.04" ]] || die "this targets Ubuntu 26.04 LTS (found ${PRETTY_NAME:-unknown})"

SSID="$(alc287_ssid)"
[[ -n "$SSID" ]] || die "no Realtek ALC287 codec found — this fix does not apply"
ssid_is_covered "$SSID" || die "codec SSID ${SSID} is not covered by the kernel quirk — this fix will not help"
has_awdz8399 || die "no AWDZ8399 (AW88399 amplifier) ACPI device — this fix does not apply"
echo "    hardware: ALC287 ${SSID}, AW88399 amps present"

firmware_ok || die "amplifier firmware missing or wrong at ${FW} — do README step 2 first"
echo "    firmware: ok"

OVR="$(audio_overrides)"
[[ -z "$OVR" ]] || die "remove these audio overrides first (README step 3):
${OVR}"
echo "    no audio overrides"

CAND="$(apt_candidate "$OEM_META")"
is_73_or_newer "${CAND:-0}" || die "${OEM_META} candidate '${CAND:-none}' is not 7.3+ — run 'sudo apt update'"
echo "    ${OEM_META}: ${CAND}"

PKGS=("$OEM_META")
BR="$(nvidia_branch)"
if nvidia_uses_dkms; then
    echo "    NVIDIA: DKMS — will build for the new kernel"
elif [[ -n "$BR" ]]; then
    NVPKG="linux-modules-nvidia-${BR}-${OEM_META#linux-}"
    NVC="$(apt_candidate "$NVPKG")"
    [[ -n "$NVC" && "$NVC" != "(none)" ]] || die "no prebuilt ${NVPKG} in the archive for your NVIDIA ${BR} driver"
    PKGS+=("$NVPKG")
    echo "    NVIDIA ${BR}: adding ${NVPKG}"
else
    echo "    NVIDIA: none detected"
fi

# ---------------------------------------------------------------------------
echo
echo "==> Simulating: apt-get install ${PKGS[*]}"
SIM="$(apt-get install -s "${PKGS[@]}" 2>&1)" || {
    echo "$SIM" | grep -vE '^(Inst|Conf) ' | tail -25
    echo
    HOLDS="$(kernel_nvidia_holds)"
    if [[ -n "$HOLDS" ]]; then
        echo "Held packages that are probably blocking this:"
        sed 's/^/    /' <<<"$HOLDS"
        echo "Unhold them (sudo apt-mark unhold ...), run 'sudo apt full-upgrade',"
        echo "then re-run this script. Re-hold afterwards if you want."
    fi
    die "apt cannot resolve the install (see above)"
}
grep -E '^Remv ' <<<"$SIM" | sed 's/^/    /' || true
grep -E 'upgraded,' <<<"$SIM" | sed 's/^/    /' || true
if grep -q '^Remv ' <<<"$SIM"; then
    echo "    NOTE: apt wants to REMOVE the packages listed above — read them carefully."
fi

if (( DRY )); then
    echo
    echo "Dry run only — nothing changed. Install with: sudo $0"
    exit 0
fi

# ---------------------------------------------------------------------------
echo
echo "==> Installing (apt will ask to confirm)"
apt-get install "${PKGS[@]}"

KVER="$(find /boot -maxdepth 1 -name 'vmlinuz-*-oem' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -1)"
echo
echo "==> Post-install checks (${KVER:-no OEM kernel found})"
ok=1
[[ -n "$KVER" ]] || { echo "    MISSING OEM kernel image in /boot"; ok=0; }
if [[ -n "$KVER" ]]; then
    if [[ -n "$(find "/lib/modules/${KVER}" -name 'snd-hda-scodec-aw88399*' 2>/dev/null)" ]]; then
        echo "    AW88399 HDA driver present for ${KVER}"
    else
        echo "    MISSING AW88399 HDA driver for ${KVER}"; ok=0
    fi
    if [[ -n "$BR" ]] || nvidia_uses_dkms; then
        if [[ -n "$(find "/lib/modules/${KVER}" -name 'nvidia.ko*' 2>/dev/null)" ]]; then
            echo "    NVIDIA module present for ${KVER}"
        else
            echo "    MISSING NVIDIA module for ${KVER} — do not reboot until resolved"; ok=0
        fi
    fi
fi

echo
echo "============================================================"
if (( ok )); then
    echo " Done. Reboot, then run: ./scripts/verify.sh"
    echo " The previous kernel stays in GRUB as a fallback (Advanced options)."
else
    echo " Finished WITH PROBLEMS (see above). Fix them before rebooting."
fi
echo "============================================================"
