# device_advan_6781

Device tree for the **Advan X1** (`6781`) — MediaTek MT6789 family (Helio G100).

Independently authored, Apache-2.0. This is not a fork.

> Status: **Phase 1 (glue) written; Phase 2 (extraction) and Phase 3
> (sepolicy + overlays) outstanding.** Nothing here has built yet. Items
> marked [C] are carried forward and await tester-run verification -- this
> project has no live device; verification comes from the tester community
> running the gate in `notes/` (see the project JOURNAL). Nothing below is
> presented as measured unless it was.

## Device

| | |
|---|---|
| SoC | MediaTek MT6789 family, Helio G100 (MT6789H) — 2x Cortex-A76 + 6x Cortex-A55 [V: stock dtb + scatter] |
| GPU | Mali-G57 MC2 [V: stock driver binds `13000000.mali`-class Valhall; stock UMD r32p1-01eac0 both ABIs] |
| Memory | unknown (stock task config ships memfusion; RAM size unmeasured) |
| Display | FHD+ DSI panel (`Qnt36672e_fhdp_dsi_vdo_60hz_jdi_dphy_drv` in the stock dtb [V]), 60 Hz [V: panel string]; density [C: placeholder 440, tester-measured] |
| Touch / fingerprint | Goodix touch + Goodix fingerprint (`goodix,touch`, `mediatek,goodix-fp` in dtb [V]) |
| Cameras | GalaxyCore gc08a3 (front-class) + GalaxyCore gc32e1 + Sony imx782 + GalaxyCore bf2257 tuning sets in stock vendor [V: blob names]; sensor roles unmapped [C] |
| NFC | STMicro (`nfc_nci.st21nfc.st.so`, `android.hardware.nfc@1.2-service-st` [V]) -- NOT NXP |
| Shipped OS | Android 14 system on an Android 12 vendor — vendor SDK 31 / VNDK 31, launch API level 31 [V: stock build.props] |

## Layout

```
configs/     stock-derived configuration (staged Phase 2)
rootdir/     init rc files (staged Phase 2)
overlay/     static framework overlay (staged Phase 3)
sepolicy/    SELinux policy — vendor / private / public (staged Phase 3)
tools/       build-time gates (KMI, vendor-deps)
mali/        r54p1 integration (staged with the driver work, not before)
prebuilts/   v31 snapshot + misc (staged Phase 2)
```

The dtb, dtbo and the vendor_dlkm/first-stage modules live in a separate
repo, `device/advan/6781-kernel`. The kernel image itself is NOT in any of
these repos: it is itel-rs4-kernel's vanilla variant (the S666LN's kernel),
imported into `device/advan/6781-kernel/prebuilt/` by `import-kernel.sh`.
Proprietary blobs live in `vendor/advan/6781` and are produced by
`extract-files.sh` (plus the placed r54p1 set, `proprietary-files-r54p1.txt`).

## Building

```
repo init -u <crDroid 13.0 manifest> -b 13.0
cp device/advan/6781/6781.xml .repo/local_manifests/    # or fetch it first
repo sync
# the kernel: build itel-rs4-kernel's vanilla variant, then import it
#   (cd ~/itel-rs4-kernel && ./build.sh vanilla)
device/advan/6781/import-kernel.sh vanilla      # KMI-gated; required
. build/envsetup.sh
lunch lineage_6781-userdebug
mka bacon
```

Hosts without ncurses 5 (Debian 13, recent Ubuntu): RenderScript's 2016
clang and the build-produced `bcc_strip_attr` need `libncurses.so.5` /
`libtinfo.so.5`, and soong scrubs `LD_LIBRARY_PATH`. Either install the
distro's ncurses5 packages or symlink the `.so.6` libraries as `.so.5` into
`prebuilts/clang/host/linux-x86/clang-3289846/lib64` and
`$OUT_DIR/host/linux-x86/lib64` (the second only exists once the build has
produced it -- re-run after the first failure there).

Target: crDroid 13.0. Status (2026-09-29): the product parses and compiles;
no build has completed yet and it has never booted. Two gates run inside the build. The
**KMI gate** confirms all 358 prebuilt vendor modules (180 vendor_dlkm +
178 first-stage) against the shipped kernel. The **vendor dependency gate**
resolves every DT_NEEDED in the built vendor image, per ABI, and checks the
module load lists against the kernel package in content and order. Both hang
off staged files or `bacon`/`target-files-package` rather than an image
target, because `bacon` never builds one -- a gate attached to an unreachable
target reports success while testing nothing.

## Notes for anyone reusing this

**Blobs are pinned to ADVAN_6781_S34NF2_V4.0_20250304** (build `1741067669`,
vendor SPL `2025-02-05`). Extracting from a newer dump will ship blobs that
no longer match the fingerprint a build presents.

**The KMI is load-bearing.** Every prebuilt module requires
`module_layout = 0x7c24b32d` (measured 180/180 on the zip-chained stock set).
That hash is reproduced by the *config*, not the source. A kernel built from
`gki_defconfig` will not match and no vendor module will load.

**Recovery shares the boot kernel.** There is no dedicated recovery partition
-- recovery rides in `vendor_boot`. Recovery loads *more* modules than normal
boot (167 vs 161 in stock's own lists), not fewer.

**Block devices must be labelled through `/dev/block/by-name/`, and this is
an A/B device, so the by-name nodes are slotted.** Labelling by partition
number is how wrong labels happen; sweep by-name entries as regexes against
the live node list.

**Every blob must come from the stock firmware.** This project caught its own
unpack dir carrying a staged r54p1 UMD (naming our `libr54shim.so`, file
absent) -- the zip CRC is the provenance check, and anything not re-read
from zip-chained images is a lead, not evidence.

**Three different API numbers, easily conflated.** Stock declares
`ro.product.first_api_level=31`, `ro.vendor.build.version.sdk=31` and
`ro.vndk.version=31` -- an Android 14 *system* on an Android 12 *vendor*.
The 34 that appears everywhere is `ro.build.version.sdk`, the system side.
`PRODUCT_SHIPPING_API_LEVEL` takes 31.

**A12 AIDL sonames carry a `_platform` suffix that Android 13 dropped.**
`blob_fixup` in `extract-files.sh` renames them only where measured on Advan
stock (audio foundation prune, power-V2, light-V1, gnss-V1, wifi/vibrator/c2
rc repoints). Entries needing boot-time evidence (effectsconfig, codec2
generation, face/keymaster routing) are marked owed in the script, not
guessed. Derive the list by sweeping the built vendor image, and confirm
each replacement is actually installed to `/vendor` before adding a rename.

**Identity, signing keys and GApps are deliberately not set here.** They are
ROM decisions and belong in a build recipe, so this tree stays reusable.

## Credits

Bring-up method and gate designs come from the maintainer's itel RS4
clean-room tree (`device_itel_S666LN`) -- the KMI discipline, the watchdog
load-order lesson, the VNDK-31 mechanism and the tester-gate pattern. No
code, blobs or configuration from any other device tree are used here.
Blobs and configuration are Advan's and MediaTek's, extracted from the
retail firmware above.

## License

Apache-2.0. See [LICENSE](LICENSE).
