# Mali r54p1 kbase — the build recipe and its patches

🔴 **These lived only in `.build/malibuild/`, which is gitignored.** RESUME §10's
lesson, in its original costume: *"Every lost file lived in `~` on a build box;
every surviving one lived in a repo."* `v31_delta.py` was lost exactly this way.
The files here PRODUCE the shipped `mali_kbase_mt6789.ko`; without them the
module is a binary nobody can regenerate.

| file | what it is |
|---|---|
| `build-mali-kbase.sh` | the build command (copy of `.build/malibuild/build.sh`). Kernel at `~/itel-rs4-kernel`, GPU source under `.build/malibuild/gpu`, MTK device-module headers extracted from Samsung's `Kernel.tar.gz` into `.build/malibuild/dm`. |
| `0001-weak-ged-a16-stubs.patch` | weak stubs for the 13 A16 `ged_dvfs_*` symbols this device's A12-era `ged.ko` does not export (dual-GPU / stack-domain / sysram bookkeeping; Mali-G57 MC2 has one power domain). 🔴 The name `ged_fr_swd_*` stood here until 2026-09-03 and matches nothing in the source. |
| `0002-build-sh-enable-ged-dvfs.patch` | turns on the ged/DVFS integration (the 5 `ged_*` imports) |
| `0003-a12-ged-bool-not-a16-enum.patch` | 🔴 **the one that makes GPU DVFS actually run** |

## Why 0003 exists

The kbase is compiled against **A16** MTK headers where
`enum ged_gpu_power_state { GED_POWER_OFF=0, GED_SLEEP=1, GED_POWER_ON=2 }`.
The `ged.ko` on this device is **A12**, and its
`ged_dvfs_gpu_clock_switch_notify()` gates on `tbz w0, #0` — it takes a **bool**,
which is exactly what stock's r32p1 kbase passes (0 from `pm_callback_power_off`,
1 from `pm_callback_power_on`; both disassembled and compared).

Passing `GED_POWER_ON == 2` leaves bit 0 clear, so ged takes its "off" branch,
never reaches `hrtimer_start_range_ns` at `ged.ko+0xdd28`, never arms the DVFS
timer whose callback is `ged_sw_vsync_check_cb`, and so never reaches
`ged_dvfs_run` — which has exactly ONE caller in the whole module. The GPU then
sits at whatever OPP it powered on at, i.e. maximum, forever.

Measured before the fix (v3build6): 54 notify calls captured with a `%x0` kprobe,
values **0 and 2 only**; `current_freqency` read `0 1003000` permanently.
Measured after (v3build7): the OPP index walks **0,1,2,3,5,7,18,37** with load.

## 🪤 Two traps when re-applying

1. **Keep the defines at file scope.** They were first inserted after the file's
   last `#include`, which sits inside
   `#if IS_ENABLED(CONFIG_MALI_MTK_GPU_DVFS_HINT_26M_LOADING)` — not enabled — so
   both compiled out and the build failed with "undeclared identifier". Verify by
   computing preprocessor depth, not by reading the diff.
2. 🔴 **`build.sh` exits 0 even when `make` fails.** It runs `make` then
   `log "make rc=$?"`, printing the code without propagating it. Read the printed
   `make rc=`, never the shell's exit status.

## 🔴 The build does not end at `make` — the shipped module is STRIPPED

`build-mali-kbase.sh` produces a **34,722,136-byte** module with debug info. The
one that ships is **1,836,832 bytes**. The step between was missing from this
file until 2026-09-03, which meant the recipe did not in fact produce the
artefact it claims to:

```sh
llvm-strip --strip-debug mali_kbase.ko      # from toolchain/clang-r416183b/bin
```

Confirmed by RECONSTRUCTION rather than assumed: run against the unstripped
5.10.260 build it reproduces the then-shipped module byte-for-byte
(sha256 `aae4c44a…`). Establish the command that way before trusting it on a new
build — a strip that merely produces *a* plausible module proves nothing.

## Verifying the result

`tools/verify-release-v3build6.sh` §4 reads `pm_callback_power_on`'s argument out
of the built module's disassembly and requires bit 0 set, with
`pm_callback_power_off` as the control. It was tested BOTH ways: the fixed module
passes, the broken one fails on `w0=[2] bit0=[0]`.
