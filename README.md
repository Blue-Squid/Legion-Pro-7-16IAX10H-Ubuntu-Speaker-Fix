# Legion Pro 7 16IAX10H: Fix Quiet Internal Speakers on Ubuntu 26.04

On Ubuntu 26.04 LTS, the internal speakers of the Lenovo Legion Pro 7
16IAX10H (Gen 10) are barely audible at full volume and have no bass.

**The fix is a stock Ubuntu package.** Install Ubuntu's signed OEM kernel,
`linux-oem-26.04b` (7.3), plus one firmware file. You don't need a patched
kernel or DKMS module. Secure Boot stays on, and the NVIDIA driver keeps
working.

- [Am I affected?](#am-i-affected)
- [Apply the fix](#apply-the-fix)
- [Test it](#test-it)
- [Troubleshooting and rollback](#troubleshooting-and-rollback)
- [Root cause](#root-cause) (full write-up: [docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md))

---

## Am I affected?

Symptoms:

- Internal speakers are faint and tinny even at 100%, with no bass.
- Headphones, the microphones, HDMI/DisplayPort audio and Bluetooth all work normally.
- Every mixer control is already unmuted at 0 dB, so turning up the volume doesn't help.
- The speakers sound fine under Windows.

Confirm the hardware:

```bash
cat /sys/class/dmi/id/product_version          # Legion Pro 7 16IAX10H
grep -h 'Subsystem Id' /proc/asound/card*/codec#* # 0x17aa3907
ls /sys/bus/acpi/devices/ | grep AWDZ8399        # AWDZ8399:00
```

Or run the read-only pre-check, which changes nothing:

```bash
./scripts/check.sh
```

### Covered codec IDs

Kernel 7.3 applies the fix automatically to these codec subsystem IDs. Only
`17aa:3907` has been tested.

| Codec SSID | Status |
|---|---|
| `17aa:3907` | ✅ Tested (Legion Pro 7 16IAX10H, product `83F5`) |
| `17aa:3906`, `17aa:3927`, `17aa:3928`, `17aa:3936`, `17aa:3937`, `17aa:3938`, `17aa:3939` | In the kernel quirk table, untested |

If your SSID isn't listed, this fix won't help on its own.

### Tested on

| | |
|---|---|
| Date | 2026-11-24 |
| Machine | Lenovo Legion Pro 7 16IAX10H (`83F5`), BIOS `Q7CN42WW` (2025-08-20) |
| OS | Ubuntu 26.04.1 LTS |
| Kernel | `7.3.0-1004-oem` (`linux-oem-26.04b` 7.3.0-1004.4) |
| Audio | Realtek ALC287 (SSID `17aa:3907`) + 2× Awinic AW88399 (ACPI `AWDZ8399`), legacy HDA driver (default) |
| Userspace | PipeWire 1.6.2, alsa-ucm-conf 1.2.15.3-1ubuntu1.7 |
| GPU | RTX 5080 Laptop, NVIDIA 595.99.02 open (Ubuntu prebuilt modules) |
| Secure Boot | Enabled |

Also present during testing, probably not needed:
`options snd-hda-intel power_save=0 power_save_controller=N` and
`blacklist snd_soc_avs` in `/etc/modprobe.d/`.

---

## Apply the fix

Takes about 10 minutes plus a reboot. Your current kernel stays installed as
a fallback.

### 1. Bring the system up to date

```bash
sudo apt update && sudo apt full-upgrade
```

Reboot if this installed a new kernel or NVIDIA driver. The OEM kernel's
NVIDIA module needs your NVIDIA userspace at the current archive version, and
being up to date keeps your fallback kernel's NVIDIA module matched too.

### 2. Install the amplifier firmware

No Ubuntu package ships this file, so you have to install it yourself. It
comes from the community project
[16iax10h-linux-sound-saga](https://github.com/nadimkobeissi/16iax10h-linux-sound-saga):

```bash
cd /tmp
curl -fLO https://raw.githubusercontent.com/nadimkobeissi/16iax10h-linux-sound-saga/main/fix/firmware/aw88399_acf.bin
echo "1e927c9bca76d868181c0f81df2bccef3cf19c7d0910219f229360c87babd42c  aw88399_acf.bin" | sha256sum -c
sudo install -m 0644 aw88399_acf.bin /lib/firmware/aw88399_acf.bin
```

`sha256sum -c` must print `aw88399_acf.bin: OK`, and the file is 152,416
bytes. Keep the `-f` flag on `curl`: without it, a bad URL saves a 14-byte
`404: Not Found` page under the firmware's name. The amps then silently fail
to come up.

### 3. Remove audio overrides from forum guides

The fix uses the default HDA driver. Remove any of these if they're present:

```bash
grep -rnE '^[^#]*(model=|dsp_driver)' /etc/modprobe.d/   # should print nothing
grep -o 'snd-intel-dspcfg.dsp_driver=[0-9]' /proc/cmdline # should print nothing
```

- **`options snd-hda-intel model=...`** lines in `/etc/modprobe.d/`: delete
  them. Kernel 7.0 has no quirk for this machine, so these strings do nothing
  useful.
- **`snd-intel-dspcfg.dsp_driver=...`** on the kernel command line: remove it
  from `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then run
  `sudo update-grub`. The same option in modprobe files also has to go.
  **Don't force SOF (`dsp_driver=3`).**

After changing modprobe files, run `sudo update-initramfs -u`.

### 4. Install the OEM kernel

The script checks your hardware, firmware, overrides and NVIDIA setup. It
simulates the install, and then apt shows its plan and asks before changing
anything.

```bash
./scripts/install.sh --dry-run    # see what would happen
sudo ./scripts/install.sh
```

<details>
<summary>Manual equivalent</summary>

```bash
# Without NVIDIA:
sudo apt install linux-oem-26.04b

# With an NVIDIA driver: add the matching prebuilt module. Replace 595-open
# with your branch (see: dpkg -l 'nvidia-driver-*'):
sudo apt install linux-oem-26.04b linux-modules-nvidia-595-open-oem-26.04b
```

If you use `nvidia-dkms-*` instead of prebuilt modules, install only
`linux-oem-26.04b`. DKMS builds the module itself.
</details>

If apt can't resolve the install, the usual cause is **held packages**
(`apt-mark showhold`). Unhold the kernel and NVIDIA packages, run
`sudo apt full-upgrade`, install, and then re-hold them if you want.

### 5. Reboot

GRUB boots the newest kernel by default, which is the OEM 7.3 one.

---

## Test it

```bash
uname -r                       # 7.3.0-xxxx-oem
./scripts/verify.sh            # every check must PASS (exit code 0)
speaker-test -c2 -twav -l1     # "Front Left" / "Front Right" at full level, with bass
```

`verify.sh` checks the overrides, firmware, kernel driver, codec quirk,
amplifier binding, kernel log, mixer and NVIDIA. If you'd rather check by
hand, a working system shows this in `journalctl -k -b | grep -i aw88399`:

```
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.0: AW88399 HDA side codec registered successfully
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.1: AW88399 HDA side codec registered successfully
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.0: AW88399 Bound - SSID: 17AA3907, channel: 0
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.1: AW88399 Bound - SSID: 17AA3907, channel: 1
```

and `journalctl -k -b | grep 'picked fixup'` shows:

```
ALC287: picked fixup  for codec SSID 17aa:3907
```

The fixup name prints empty on Ubuntu kernels, and that's normal. The part
that matters is **`codec SSID 17aa:3907`**. On the broken 7.0 kernel the line
reads `for PCI SSID 17aa:0000`, meaning no quirk matched.

Also check that the GPU survived the kernel switch: `nvidia-smi` should list
your GPU.

---

## Troubleshooting and rollback

| Symptom | Likely cause | Fix |
|---|---|---|
| `uname -r` isn't the OEM kernel | GRUB booted another entry | Pick it under *Advanced options*, or remove the older kernels |
| Log still says `PCI SSID 17aa:0000` | Not running 7.3, or a `model=` override | Check `uname -r`; redo step 3 |
| No `aw88399-hda` devices; `i2c-AWDZ8399:00` exists instead | Running a kernel older than 7.3 | Boot the OEM kernel |
| `aw88399` log lines but no `Bound - SSID` | Firmware missing or wrong | Redo step 2 and check the checksum |
| Still faint after all checks pass | Wrong output device or a low volume setting | Check Settings → Sound (output: *Speakers*) and `alsamixer -c <card>` |
| No GPU acceleration after reboot | No NVIDIA module for the new kernel | `dpkg -l 'linux-modules-nvidia-*' \| grep oem`; install the matching `linux-modules-nvidia-<branch>-oem-26.04b` |

**Boot the old kernel:** the GRUB menu is usually hidden. Hold **Shift**, or
tap **Esc** once, as the firmware logo goes away. Then choose *Advanced
options for Ubuntu* and pick your previous `-generic` kernel.

**Remove the fix:**

```bash
sudo apt remove linux-oem-26.04b 'linux-image-7.3.*-oem' 'linux-modules-nvidia-*-oem-26.04b'
sudo reboot
```

The firmware file is harmless to leave in place.

### Staying up to date

- The OEM kernel updates through apt like any other kernel, via the
  `linux-oem-26.04b` meta package.
- Ubuntu 26.10 already ships 7.3, so the standard 26.04 HWE kernel is
  expected to reach 7.3 with 26.04.2 (around February 2027). After that the
  OEM kernel is optional. This is a projection, not an announcement. Check
  with `apt-cache policy linux-generic-hwe-26.04` and run `verify.sh` before
  removing the OEM kernel.
- Run `./scripts/verify.sh` after any kernel or NVIDIA update.

### Other distributions

Any kernel 7.3 or newer built with `CONFIG_SND_HDA_SCODEC_AW88399_I2C`, plus
the firmware from step 2, should work the same way. That hasn't been tested
here.

---

## Root cause

The internal speakers aren't driven by the Realtek ALC287 codec directly. The
codec feeds **two Awinic AW88399 smart amplifiers** on an I2C bus, and those
drive the speakers.

Kernel 7.0 (Ubuntu 26.04's default) has a standalone driver for the AW88399
chip, but nothing ties it to the laptop's HDA sound card:

- no HDA side-codec driver for the AW88399;
- no ALC287 quirk for these Lenovo models.

So the driver binds to the chip, no sound card ever uses it, and the
amplifiers are never configured or switched on. Every other audio path
(headphones, mics, HDMI, Bluetooth) bypasses the amps, which is why only the
speakers are affected.

Kernel 7.3 adds the missing pieces:

1. The ACPI core hands the `AWDZ8399` device to `serial-multi-instantiate`
   instead of creating one plain I2C device.
2. `serial-multi-instantiate` creates one I2C client per amplifier
   (`…-aw88399-hda.0`, `.1`).
3. The new `snd-hda-scodec-aw88399` driver binds them and loads
   `aw88399_acf.bin`.
4. An ALC287 quirk keyed on the codec subsystem ID
   (`alc287-lenovo-legion-aw88399`) attaches both amps to the sound card.
   They now power up whenever the speakers play.

Ubuntu's OEM kernel track ships 7.3 for 26.04 LTS ahead of the standard
kernel.

**Why the common forum fixes fail:** volume and mixer settings, reinstalling
PipeWire or ALSA, `model=` overrides and forcing SOF (`dsp_driver=3`) all work
above the missing piece or on a path that lacks it. None of them can turn the
amplifiers on. Mainline PPA kernels have the driver, but they're unsigned
(blocked by Secure Boot) and come without prebuilt NVIDIA modules.

For the signal path, the 7.0 vs 7.3 evidence and diagnostic commands, see
[docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md).

---

## Credits and references

- [nadimkobeissi/16iax10h-linux-sound-saga](https://github.com/nadimkobeissi/16iax10h-linux-sound-saga):
  community investigation of this hardware and the source of the firmware file.
- [CachyOS #759](https://github.com/CachyOS/linux-cachyos/issues/759) and
  [#687](https://github.com/CachyOS/linux-cachyos/issues/687): AW88399
  enablement discussion for the 16IAX10H.
- [Launchpad question #823678](https://answers.launchpad.net/ubuntu-certification/+question/823678):
  Ubuntu audio support request for this laptop.
- [Lenovo Community thread](https://forums.lenovo.com/t5/Ubuntu/Legion-Pro-7-16IAX10H-Ubuntu-ALC3306-sound/m-p/5376602)
  and [Linux Mint forum thread](https://forums.linuxmint.com/viewtopic.php?t=457586).

## License

Scripts and documentation: [MIT](LICENSE). The AW88399 firmware isn't
included in this repository. It belongs to its respective owners and is
downloaded from the project linked in step 2.
