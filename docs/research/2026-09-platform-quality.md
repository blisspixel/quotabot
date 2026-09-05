# Platform quality research

Reviewed 2026-09-04 against `main` at `2e283956` and stable 0.10.3.
This is a development plan based on source inspection and primary documentation.
No native display, suspend, assistive-technology, or real-account smoke was run
for this report. No paid service was used.

The strongest next platform work makes local capacity more truthful and the
desktop dependable in ordinary laptop and Linux sessions. Signing can remain
an independent acquisition track while these improvements ship in 0.x.

## Existing foundation

- [Local hardware discovery](../../collector/lib/local_hardware.dart) already
  bounds process time and output, reads system RAM on all three OSes, selects
  one NVIDIA device without summing VRAM, and has a Windows GPU fallback.
  [Hardware fit](../../collector/lib/registry.dart) remains advisory and prefers
  loaded models. The 0.10.3 display already separates loaded model, running
  context, model GPU residency, and host pressure.
- [Window geometry](../../app/lib/window_geometry.dart) already restores windows
  onto attached work areas and handles removed displays and scaling in pure
  tests. [Dashboard lifecycle](../../app/lib/main.dart) reconciles screen
  changes, coalesces refreshes, retains stale evidence after failures, and
  falls back to normal close behavior when tray initialization throws.
- [First run](../../app/lib/first_run.dart), explicit
  [update checks](../../app/lib/update_check.dart), transactional source setup,
  portable bundles, rollback, checksum and provenance checks already exist.
  Rebuilding these features would miss the remaining gaps.
- [CI](../../.github/workflows/ci.yml) exercises Windows, macOS, and Linux.
  [Desktop readiness smoke](../../tools/desktop_readiness_smoke.py) verifies
  Windows Shell tray registration. Its Linux execution uses D-Bus plus Xvfb;
  this does not establish native Wayland behavior or a visible tray host.
  [Building guidance](../BUILDING.md) correctly distinguishes widget tests from
  native accessibility evidence.

## Ranked implementation slices

### 1. Correct and identify hardware evidence before expanding charts

The Windows fallback in `local_hardware.dart` treats
`Win32_VideoController.AdapterRAM` as GPU capacity. Microsoft defines that
property as `uint32` bytes, so it cannot faithfully represent capacities above
4 GiB. NVIDIA's separate metadata path avoids this fallback. Preserve the GPU
name when no trustworthy capacity exists, and replace or explicitly qualify
the fallback capacity rather than presenting it as an exact modern GPU total.
[Microsoft property contract](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-videocontroller).

Also separate the selected adapter's evidence from the Windows fallback's
busiest counter across all GPU engines. Add bounded source and scope fields
before claiming a per-device graph. A DXGI helper can supply wider dedicated
capacity, but `QueryVideoMemoryInfo` reports the calling process's budget and
usage. Subtracting those fields cannot establish another runtime's free VRAM.
[Microsoft DXGI contract](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/nf-dxgi1_4-idxgiadapter3-queryvideomemoryinfo).

Acceptance: fixtures cover 0, wrapped or capped 32-bit values, multiple adapters,
unsupported counters, localized counter failure, and driver absence. Unknown
memory never becomes zero capacity or a false fit constraint. A native Windows
AMD or Intel record compares wider capacity evidence with the driver view;
the NVIDIA path has a separate record. Source-only fixtures are not that record.

### 2. Make tray availability and foreground recovery explicit

Successful `setIcon` and `setContextMenu` calls currently cause Linux to enter
close-to-tray behavior. There is no session tray-host capability check in
`_initTray`. A missing visual host can therefore escape the existing exception
fallback. This is a source-based risk to reproduce, not a claimed native failure.
The Status Notifier protocol exposes whether a host is registered; the plugin
also documents GNOME's possible AppIndicator extension requirement.
[StatusNotifierWatcher](https://specifications.freedesktop.org/status-notifier-item/latest/status-notifier-watcher.html),
[tray_manager documentation](https://github.com/leanflutter/tray_manager).

Introduce a small desktop capability seam. Enable close-to-tray only when there
is evidence of a recoverable tray; keep an ordinary window and a clear close
action otherwise. Watch host disappearance and reappearance without terminating
quota collection. Keep explicit Quit available from the window as well as the
tray. The upstream plugin migration announcement is a reason to isolate this
seam, not to migrate the whole app without a failing requirement.

`_showWindow`, restore, and focus currently repaint without requesting a due
refresh. Add a coalesced foreground freshness check and a clock-gap recovery
policy so returning to the app can repair old evidence without waiting for an
hourly cadence. Respect throttling and avoid a refresh on every focus event.
Flutter's `resumed` means visible and focused, not a reliable system wake event;
some lifecycle notifications can be skipped.
[Flutter lifecycle contract](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html).

Acceptance: deterministic tests cover host loss, no host, plugin failure,
duplicate focus events, a pending refresh, clock reversal, a long clock gap,
and failed refresh after a reset. Native smoke covers GNOME Wayland without an
indicator extension, a Wayland session with a tray host, and X11. Close never
strands an unreachable process. Laptop sleep and resume retain original capture
times until a fresh read succeeds.

### 3. Extend passive evidence to Linux AMD and Apple Silicon

Linux currently checks only `/usr/bin/nvidia-smi` for GPU discovery. Add the
documented WSL path with the same fixed-command, timeout and output bounds;
unsupported utilization must not discard usable memory fields. NVIDIA documents
both `/usr/lib/wsl/lib/nvidia-smi` and limited WSL query support.
[NVIDIA WSL guide](https://docs.nvidia.com/cuda/wsl-user-guide/index.html).

For AMD Linux, use a bounded allowlist of read-only DRM device memory files.
The kernel exposes total and used VRAM in bytes. Keep each adapter separate,
distinguish dedicated and shared pools, and never sum GTT with system RAM or
change power, clock, or UMA settings.
[Linux AMDGPU memory interface](https://docs.kernel.org/gpu/amdgpu/driver-misc.html).

On macOS, keep host RAM pressure distinct from Metal's unified-memory property
and recommended working-set budget. Add a small packaged native metadata helper
or equivalent bounded native binding shared by CLI and desktop. Apple explicitly
describes the working-set value as approximate; it is not current free VRAM.
Never count unified RAM twice or subtract unrelated observations to manufacture
free capacity.
[Apple Metal memory contract](https://developer.apple.com/documentation/metal/mtldevice/hasunifiedmemory).

Acceptance: fixtures cover Apple Silicon shared pools, Intel Mac unknown GPU
capacity, Linux AMD permission denial and device removal, multiple adapters,
malformed counters, and WSL missing fields. Native records identify runtime,
driver and architecture and contain only bounded metadata. Unknown remains a
supported result. No test loads a model to prove the probe works.

### 4. Explain collector environment and local runtime reachability

The runtime adapters correctly reject non-loopback host overrides. Keep that
boundary. WSL NAT and mirrored networking have different localhost behavior;
mirrored mode can reach Windows servers at `127.0.0.1`, while IPv6 localhost is
not supported for that case. Do not recommend opening all interfaces or disabling
firewalls as the normal repair.
[Microsoft WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking).

Add bounded environment facts to diagnostics: native host or WSL, effective
loopback endpoint, endpoint reachable or refused, metadata valid or malformed,
and where hardware was observed. A Windows runtime reached from WSL does not
make WSL's VM RAM the runtime's physical host RAM. Likewise, a sandbox or
container can have a different loopback namespace. Keep the routing result
separate from this explanation and avoid broad host or process scans.

LM Studio now explicitly documents LM Link serving a localhost REST request on
a preferred remote device. Loopback reachability therefore cannot establish
that the collector's memory pool belongs to the execution device. Audit this
existing adapter before using host fit to strengthen its on-device claim; the
[local-model report](2026-09-local-models.md) covers that compatibility work.
[LM Studio LM Link](https://lmstudio.ai/docs/developer/core/lmlink).

Acceptance: test native and WSL fixtures, IPv4 and IPv6 endpoints, rejected LAN
overrides, missing server, and malformed inventory. Validate real WSL NAT and
mirrored sessions separately when available. `doctor` and first run give the
same actionable explanation, and neither reads or changes host configuration.

### 5. Turn native usability claims into a small repeatable matrix

Extend the existing geometry and accessibility tests rather than replace them.
Run compact view, local details, analytics, first run, profiles, update dialog,
and tray with keyboard-only navigation, 200 percent text/display scaling, high
contrast or grayscale, reduced motion, and a screen reader. Flutter's own
release checklist calls out intelligible controls and large scale factors.
[Flutter accessibility guidance](https://docs.flutter.dev/ui/accessibility).

Acceptance records should cover Windows Narrator, macOS VoiceOver and Linux
Orca; mixed-DPI monitors, negative display coordinates, unplugging the active
display, moving between workspaces, and reconnecting a dock. No lost focus,
clipped repair text, invisible off-screen window, or color-only state may pass.
Exercise first run with no runtime, server present without models, stopped
runtime, and a runtime installed while the dialog remains open. Report OS,
desktop session, architecture, artifact digest, observed result, and explicit
not-tested cells. A hosted build or widget semantics test does not fill an
interactive cell.

## Delivery order and release discipline

Ship slice 1 first, then foreground recovery and the no-tray fallback, then the
additional hardware sources. Environment diagnostics and native usability
records can proceed alongside those bounded changes. Each slice carries its
own parser or lifecycle regression, affected CLI/MCP/desktop contract checks,
documentation update, and the existing three-OS analysis and 80 percent coverage
gates. Keep main green, publish an immutable 0.x release only after its complete
release and install matrix succeeds, and retain exact unsigned disclosures until
signing actually activates. No store listing is required for these outcomes.

Treat late-2026 native plugin and runtime changes as compatibility signals to
review against this matrix. Avoid speculative platform rewrites, inference
benchmarks, automatic driver tuning, or package-channel expansion ahead of
demonstrated local-capacity and usability improvements.
