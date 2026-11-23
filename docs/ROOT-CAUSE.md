# Root Cause: Why the 16IAX10H Speakers Are Faint on Kernel 7.0

**Short version:** the speakers are driven by two Awinic AW88399 I2C smart
amplifiers. Kernel 7.0 can talk to the chip but has no way to attach it to
the HDA sound card, so the amplifiers are never switched on. Kernel 7.3 adds
that attachment. The cause is missing hardware enablement, not a
misconfiguration.

---

## 1. Signal path

```
                     ┌──────────────────────────────────────┐
                     │  Intel 800-series ACE (8086:7f50)    │
                     │  HDA controller                      │
                     └────────────────┬─────────────────────┘
                                      │ HD Audio link
                     ┌────────────────▼─────────────────────┐
                     │  Realtek ALC287  (codec SSID 17aa:3907)
                     └──┬──────────────┬───────────────┬────┘
                        │              │               │
       ┌────────────────▼──┐  ┌────────▼────────┐  ┌───▼──────────┐
       │ Headphone jack    │  │ Internal mics   │  │ Speaker pins │
       │ pin 0x21          │  │ pins 0x12/0x19  │  │ 0x14 / 0x17  │
       │ works             │  │ work            │  └───┬──────────┘
       └───────────────────┘  └─────────────────┘      │
                                                        │
                              ┌─────────────────────────▼─────────────┐
                              │  2× Awinic AW88399 smart amplifiers   │
                              │  I2C, ACPI device AWDZ8399            │
                              │                                       │
                              │  kernel 7.0: never switched on        │
                              │  kernel 7.3: attached to sound card   │
                              └─────────────────────────┬─────────────┘
                                                        │
                                             ┌──────────▼──────────┐
                                             │ Internal speakers   │
                                             │ (woofers + tweeters)│
                                             └─────────────────────┘

  Bluetooth → PipeWire → BT stack → external speaker   (never touches the above)
```

Every path that avoids the AW88399 stage works. The only path through it is
the one that fails. That isolates the fault to the amplifier stage.

## 2. What kernel 7.0 is missing

On Ubuntu 26.04's default kernel (`7.0.0-*-generic`):

| What is needed | Where it would be | On 7.0 |
|---|---|---|
| HDA side-codec driver `snd-hda-scodec-aw88399` | `kernel/sound/hda/codecs/side-codecs/` | **Absent** (only cs35l41, cs35l56, tas2781) |
| `AWDZ8399` handled by `serial-multi-instantiate` | ACPI core + `serial-multi-instantiate.ko` | **Absent** |
| ALC287 quirk for codec SSID `17aa:3907` | `snd-hda-codec-alc269.ko` | **Absent** (only older Legion models) |

What does exist is the generic ASoC driver `snd_soc_aw88399`. It binds to
the ACPI device as one plain I2C client, `i2c-AWDZ8399:00`. On this laptop the
sound card is a plain HDA card, not an ASoC card, so that driver isn't part of
any card. Its module use count stays at 0 and the amplifiers are never
configured or powered up.

### Evidence on 7.0

```console
$ lsmod | grep aw88399
snd_soc_aw88399        49152  0                     # loaded, used by nothing

$ ls /sys/bus/i2c/devices/ | grep AWDZ
i2c-AWDZ8399:00                                     # one plain client

$ journalctl -k -b | grep 'picked fixup'
ALC287: picked fixup  for PCI SSID 17aa:0000        # no quirk matched

$ journalctl -k -b | grep -ci aw88399
0                                                   # amps never initialised
```

The codec side is configured correctly. Autoconfig finds the speaker pins
(`line_outs=2 (0x14/0x17) type:speaker`). `speaker_outs=0` is normal when the
main outputs *are* the speakers, so it isn't a fault.

## 3. What kernel 7.3 adds

The same mechanism other laptop side-codec amplifiers use (Cirrus CS35L41
`CSC3551`, TI TAS2781 `TXNW2781`) now covers the AW88399:

1. **ACPI ignore list.** `AWDZ8399` is on the built-in list of serial-bus IDs
   the ACPI core doesn't enumerate as a single I2C device. A platform device is
   created instead.
2. **serial-multi-instantiate** claims `AWDZ8399` and creates one I2C client
   per amplifier: `i2c-AWDZ8399:00-aw88399-hda.0` and `.1`.
3. **snd-hda-scodec-aw88399-i2c / snd-hda-scodec-aw88399** bind those clients,
   load `aw88399_acf.bin` and register as HDA side codecs.
4. **ALC287 quirk.** `snd-hda-codec-alc269` has codec-SSID entries
   (`17aa:3906`, `3907`, `3927`, `3928`, `3936`–`3939`) mapping to the
   `alc287-lenovo-legion-aw88399` fixup. The fixup binds the two side codecs to
   the sound card, so the amplifiers are powered and configured whenever the
   speakers play.

The plain ASoC driver `snd_soc_aw88399` may still load by alias with use
count 0. On 7.3 that's normal, because it has nothing to bind to.

### Evidence on 7.3 (`7.3.0-1004-oem`)

```console
$ ls /sys/bus/i2c/devices/ | grep AWDZ
i2c-AWDZ8399:00-aw88399-hda.0
i2c-AWDZ8399:00-aw88399-hda.1

$ journalctl -k -b | grep -iE 'aw88399|picked fixup'
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.0: Applying properties for SSID 17AA3907
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.0: AW88399 HDA side codec registered successfully
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.1: Applying properties for SSID 17AA3907
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.1: AW88399 HDA side codec registered successfully
snd_hda_codec_alc269 hdaudioC1D0: ALC287: picked fixup  for codec SSID 17aa:3907
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.0: AW88399 Bound - SSID: 17AA3907, channel: 0
snd_hda_codec_alc269 hdaudioC1D0: bound i2c-AWDZ8399:00-aw88399-hda.0 (ops aw88399_hda_comp_ops [snd_hda_scodec_aw88399])
aw88399-hda i2c-AWDZ8399:00-aw88399-hda.1: AW88399 Bound - SSID: 17AA3907, channel: 1
snd_hda_codec_alc269 hdaudioC1D0: bound i2c-AWDZ8399:00-aw88399-hda.1 (ops aw88399_hda_comp_ops [snd_hda_scodec_aw88399])
```

The fixup name prints empty because Ubuntu kernels don't keep quirk names
(`CONFIG_SND_DEBUG_VERBOSE` is off). The switch from `PCI SSID 17aa:0000` to
**`codec SSID 17aa:3907`** shows the quirk matched.

## 4. Why the firmware matters

`snd-hda-scodec-aw88399` requests `aw88399_acf.bin` (the amplifier's
configuration/tuning file). `linux-firmware` doesn't ship it as of 20260319.
If the file is missing, or isn't the real 152,416-byte file (sha256
`1e927c9b…babd42c`), the amps don't come up correctly even on 7.3. A
14-byte `404: Not Found` page saved by `curl` without `-f` is an easy way to
end up there.

## 5. Why the usual fixes don't work

| Attempt | Why it can't help |
|---|---|
| Volume, mixer, output device, reboots | They work above the driver layer. Everything is already at 0 dB and unmuted; the amps are off. |
| Reinstalling PipeWire / PulseAudio / ALSA | The sound server is healthy: headphones, HDMI and Bluetooth work. It can't power an amp the kernel never attached. |
| `options snd-hda-intel model=...` | Kernel 7.0 has no quirk for this machine. Removing every override changed the boot log not at all. Some strings in circulating guides don't exist. |
| Forcing SOF (`snd-intel-dspcfg.dsp_driver=3`) | The SOF path on 7.0 has no `AWDZ8399` machine match or topology either. The 7.3 fix was tested on the default HDA path. |
| Reinstalling Ubuntu | Not a corrupted install. A fresh install behaves the same. |
| Mainline PPA kernel 7.3.x | Has the driver, but is unsigned (Secure Boot rejects it), and there's no prebuilt NVIDIA module for it. |
| Self-built patched kernel / DKMS | Works in principle, but means signing for Secure Boot and rebuilding NVIDIA. Unnecessary now that a signed 7.3 kernel is in the archive. |

## 6. Diagnose your own machine

```bash
uname -r
modinfo -n snd_hda_scodec_aw88399              # exists on 7.3+, error on 7.0
ls /sys/bus/i2c/devices/ | grep AWDZ           # one client (7.0) vs .0/.1 (7.3)
journalctl -k -b | grep -iE 'aw88399|picked fixup'
sha256sum /lib/firmware/aw88399_acf.bin
```

Or run `./scripts/verify.sh`, which checks all of this and explains each
result.
