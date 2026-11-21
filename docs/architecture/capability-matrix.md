# Capability matrix

Single source of truth for *what PulseMac can measure, how, and how sure we are*.
"Verified" means the code path has run on real hardware with expected results. As of this
revision **nothing has been verified on a Mac** — the repository was authored in a Linux
container. Status column is therefore *Implemented (unverified)* unless stated.

Target: Apple silicon (M1+), macOS 14 Sonoma or later, direct distribution, not sandboxed.

| Feature | API / source | Hardware | Min OS | Permission / entitlement | Limitations | Status |
|---|---|---|---|---|---|---|
| Total / per-core CPU, user/system | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | All | 10.x | None | 32-bit tick counters (wrap handled); core index → P/E cluster mapping undocumented, not shown | Implemented (unverified) |
| P/E core counts | `sysctl hw.nperflevels`, `hw.perflevel{0,1}.logicalcpu` | Apple silicon | 12 | None | Counts only | Implemented (unverified) |
| Load average | `getloadavg` | All | — | None | Not a percentage; explained in UI | Implemented (unverified) |
| Memory breakdown | `host_statistics64(HOST_VM_INFO64)`, `host_page_size` | All | — | None | "Used" = app + wired + compressed (Activity Monitor definition) | Implemented (unverified) |
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level` (1/2/4) | All | 10.9 | None | Undocumented sysctl, long-stable; falls back to *Experimental* if missing | Implemented (unverified) |
| Swap | `sysctl vm.swapusage` (`xsw_usage`) | All | — | None | — | Implemented (unverified) |
| Page-ins/outs rate | `vm_statistics64.pageins/pageouts` deltas | All | — | None | Pages/s | Implemented (unverified) |
| Process list (all users) | `sysctl KERN_PROC_ALL` (`kinfo_proc`) | All | — | None | Short name ≤16 chars (path used when readable) | Implemented (unverified) |
| Process CPU/memory/disk I/O | `proc_pid_rusage(RUSAGE_INFO_V4)`; Mach-time → ns via `mach_timebase_info` | All | 10.12 | None for **own** processes | Other users' / system processes: EPERM without root → shown as "limited", never as 0 | Implemented (unverified) |
| Threads | `proc_pidinfo(PROC_PIDTASKINFO)` | All | — | Own processes | — | Implemented (unverified) |
| Command line | `sysctl KERN_PROCARGS2` | All | — | Own processes | Redacted, hidden until disclosed | Implemented (unverified) |
| Executable path | `proc_pidpath` | All | — | None (most) | Some protected processes refuse | Implemented (unverified) |
| Interface throughput | `sysctl NET_RT_IFLIST2` → `if_msghdr2.ifm_data` (64-bit) | All | — | None | Traffic, not internet speed; utun/awdl excluded from totals | Implemented (unverified) |
| Per-app network | NetworkStatistics.framework (private) / `nettop` | — | — | — | No public API; `nettop` only own processes, CPU-costly | **Deferred** |
| Disk I/O (system) | IOKit `IOBlockStorageDriver` → `Statistics` | All | — | None | Sums all block devices; disk images may double count | Implemented (unverified) |
| Volume capacity | `URLResourceValues` (`volumeAvailableCapacityForImportantUsage`) | All | 10.13 | None | Matches Finder "Available" (includes purgeable) | Implemented (unverified) |
| Folder sizes | `FileManager` + `totalFileAllocatedSize` | All | — | Full Disk Access optional | Protected folders counted as unreadable; no symlink follow; no volume crossing | Implemented; tested on Linux |
| Move to Trash | `FileManager.trashItem` | All | 10.8 | None | Re-validated by `CleanupGuard` per item | Implemented (unverified) |
| Battery charge / state / time | `IOPSCopyPowerSourcesInfo` | Laptops | — | None | Time remaining only when macOS gives a non-negative estimate on battery | Implemented (unverified) |
| Cycle count, health | `AppleSmartBattery` registry (`CycleCount`, `DesignCapacity`, `AppleRawMaxCapacity`) | Laptops | — | None | Keys undocumented; health shown only if both present | Implemented (unverified) |
| Thermal state | `ProcessInfo.thermalState` | All | 10.10.3 | None | 4 levels, no temperatures | Implemented (unverified) |
| Temperatures / fans | SMC / IOHIDEventSystem (private) | Per-chip keys | — | — | Keys change per SoC (Stats #1703) | **Deferred** |
| GPU utilization | IOKit `IOAccelerator` → `PerformanceStatistics["Device Utilization %"]` | Apple silicon (also AMD key fallback) | — | None | Undocumented keys → **Experimental** label | Implemented (unverified) |
| GPU power, ANE | IOReport (private) / `powermetrics` (root) | — | — | Root | Not public | **Unsupported** |
| Per-process GPU | — | — | — | — | Not attributable publicly | **Unsupported** |
| Process termination | `NSRunningApplication.terminate/forceTerminate`, `kill(SIGTERM/SIGKILL)` | All | — | Own processes only | Protected list, PID-reuse check, confirmation | Implemented (unverified) |
| Listening ports | `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` | All | — | Own processes | — | Deferred (P2) |
| System log | OSLogStore | — | 12 | Local store needs entitlement/root for system scope | — | Deferred |
| MetricKit | MetricKit | — | — | — | Reports *your own app's* metrics daily; not live system telemetry → **not used** | Rejected |

## Distribution implications

| Channel | Viable? | Why |
|---|---|---|
| Direct (Developer ID, notarized, hardened runtime) | **Yes — chosen** | All rows above work unsandboxed with no entitlements. |
| Mac App Store (sandboxed) | Partial | Process enumeration of other apps, `proc_pid_rusage`, IOKit registry reads and arbitrary folder scanning are restricted or need temporary exceptions Apple rarely grants. Would require a reduced "lite" product. |

See ADR [0003](adr/0003-distribution.md).
