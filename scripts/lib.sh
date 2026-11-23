# shellcheck shell=bash
# Shared helpers for check.sh, install.sh and verify.sh. Not meant to be run.

# Codec SSIDs that kernel 7.3's ALC287 quirk table maps to the
# "alc287-lenovo-legion-aw88399" fixup. Only 17aa3907 has been tested.
COVERED_SSIDS=(17aa3906 17aa3907 17aa3927 17aa3928 17aa3936 17aa3937 17aa3938 17aa3939)
TESTED_SSID=17aa3907

FW=/lib/firmware/aw88399_acf.bin
FW_SIZE_EXPECTED=152416
FW_SHA256=1e927c9bca76d868181c0f81df2bccef3cf19c7d0910219f229360c87babd42c

OEM_META=linux-oem-26.04b

N_FAIL=0
pass() { printf '  \033[32m[ PASS ]\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m[ FAIL ]\033[0m %s\n' "$1"; N_FAIL=$((N_FAIL + 1)); }
warn() { printf '  \033[33m[ WARN ]\033[0m %s\n' "$1"; }
info() { printf '  \033[34m[ INFO ]\033[0m %s\n' "$1"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# /proc/asound/cardN/codec#M file of the Realtek ALC287, or empty.
alc287_codec_file() {
    local f
    for f in /proc/asound/card*/codec#*; do
        [[ -r "$f" ]] && grep -q 'Codec: Realtek ALC287' "$f" && { echo "$f"; return; }
    done
}

# Codec subsystem ID without 0x, lowercase (e.g. 17aa3907), or empty.
alc287_ssid() {
    local f; f="$(alc287_codec_file)"
    [[ -n "$f" ]] || return 0
    awk -F': *' '/^Subsystem Id/ {sub(/^0x/, "", $2); print tolower($2); exit}' "$f"
}

# ALSA card number of the ALC287, or empty.
alc287_card() {
    local f; f="$(alc287_codec_file)"
    [[ "$f" =~ /card([0-9]+)/ ]] && echo "${BASH_REMATCH[1]}"
}

ssid_is_covered() {
    local s
    for s in "${COVERED_SSIDS[@]}"; do [[ "$1" == "$s" ]] && return 0; done
    return 1
}

has_awdz8399() {
    compgen -G '/sys/bus/acpi/devices/AWDZ8399:*' >/dev/null
}

# 0 if firmware is present and matches the known-good checksum.
firmware_ok() {
    [[ -f "$FW" ]] && [[ "$(sha256sum "$FW" | cut -d' ' -f1)" == "$FW_SHA256" ]]
}

firmware_size() { stat -Lc %s "$FW" 2>/dev/null || echo 0; }

# Return 0 if version string $1 is 7.3 or newer.
is_73_or_newer() {
    local v="${1%%-*}"
    local maj="${v%%.*}"
    local rest="${v#*.}"
    local min="${rest%%.*}"
    [[ "$maj" =~ ^[0-9]+$ && "$min" =~ ^[0-9]+$ ]] || return 1
    (( maj > 7 )) && return 0
    (( maj == 7 && min >= 3 )) && return 0
    return 1
}

apt_candidate() {
    apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

# Installed NVIDIA driver flavour, e.g. "595-open" or "580", or empty.
nvidia_branch() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-driver-*' 2>/dev/null \
        | awk '$1 ~ /^[hi]i/ {print $2}' \
        | sed -nE 's/^nvidia-driver-([0-9]+(-open)?)$/\1/p' | head -1
}

nvidia_uses_dkms() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-dkms-*' 2>/dev/null \
        | awk '$1 ~ /^[hi]i/ {found=1} END {exit !found}'
}

# Active (non-comment) audio overrides that would interfere with the fix.
audio_overrides() {
    grep -rhE '^[[:space:]]*options[^#]*(model=|dsp_driver)' /etc/modprobe.d/ 2>/dev/null
    tr ' ' '\n' < /proc/cmdline | grep -E 'dsp_driver=|snd[-_]hda[-_]intel\.model=' || true
}

# Held packages that are kernel or NVIDIA related.
kernel_nvidia_holds() {
    apt-mark showhold 2>/dev/null | grep -E '^(linux-|nvidia-|libnvidia-)' || true
}

# Kernel log for this boot (needs adm/systemd-journal group or root).
kernel_log() {
    journalctl -k -b --no-pager 2>/dev/null || dmesg 2>/dev/null || true
}
