# DCG Training Lab: Intel ISA-L zlib Shim — Performance Demo

A self-contained lab script that shows how Intel ISA-L's **igzip** engine can transparently accelerate any application that uses the standard **zlib API** — with **zero code changes** and **zero recompilation**, by preloading a small shim library at run-time.

---

## How it works

```
Application → zlib (deflate/inflate) → libz.so
                                          ↑
              LD_PRELOAD=isal-shim.so ────┘  (intercepts calls)
                                          ↓
                               ISA-L igzip (AVX-512 / AVX2)
```

The OS dynamic linker loads `isal-shim.so` **before** `libz.so`. Every call to `deflate()` / `inflate()` is silently redirected to Intel ISA-L's  optimized implementation. The application sees the same zlib API — nothing changes from its perspective.

---

## Prerequisites

| Tool | Notes |
|------|-------|
| `git` | To clone ISA-L and QATzip |
| `make`, `cmake` | Build tools |
| `nasm` ≥ 2.14 | ISA-L uses NASM for AVX-512 routines |
| `autoconf`, `automake`, `libtool` | QATzip build system |
| `pkg-config` | Required by build system |
| `openssl-devel` / `libssl-dev` | Required to build qatlib (Step 3) |
| `curl` | Corpus download |
| `python3` | Demo 1 & 5 workload + test data generation |
| `awk` | Result parsing |
| `pigz` | Demo 4 workload — `dnf install pigz` / `apt install pigz` |

**Install openssl headers (if not present):**
```bash
# RHEL / Rocky Linux
sudo dnf install openssl-devel
# Ubuntu / Debian
sudo apt install libssl-dev
```

---

## Quickstart

```bash
# 1. Clone this repo
git clone https://github.com/vkarpenk/dcg-demo-isal-shim
cd dcg-demo-isal-shim

# 2. One-time setup: builds ISA-L, ISA-L shim, qatzip-test; downloads corpus
bash setup.sh

# 3. Run the interactive lab demo
bash demo.sh
```

Re-running `setup.sh` skips steps that are already complete.

To start fresh:
```bash
bash setup.sh --clean
bash setup.sh
```

---

## What `setup.sh` does

| Step | Action |
|------|--------|
| 1 | Checks all build dependencies and exits early with install hints if anything is missing |
| 2 | Clones [`intel/isa-l`](https://github.com/intel/isa-l), builds `libisal.so`, then builds `isal-shim.so` (the zlib shim) with CMake |
| 3 | Clones [`intel/qatlib`](https://github.com/intel/qatlib), builds and installs it locally — no root, no system package needed. Skipped if the system already provides qatlib via pkg-config |
| 4 | Clones [`intel/qatzip`](https://github.com/intel/qatzip), downloads the required `ax_pthread.m4` macro, builds `qatzip-test` |
| 5 | Downloads three Dickens novels from Project Gutenberg as the benchmark corpus (~2.7 MB of compressible text) |
| 6 | Installs OpenJDK 21 locally (if no system JDK found) for Demo 3 |
| 7 | Writes `lab.env` with all paths; `demo.sh` sources this automatically |

All build artifacts are placed under `lab/` next to the scripts. Nothing is installed system-wide.

---

## What `demo.sh` shows

The demo runs five back-to-back scenarios, pausing for **Enter** between each one:

### Demo 1 — Python `zlib` (in-process, purely CPU-bound)
Python's `zlib.compress()` calls `libz.so deflate()` directly. Running entirely in-memory eliminates disk I/O, so the measured delta is pure CPU/SIMD throughput. With `LD_PRELOAD`, every `deflate()` call is redirected to ISA-L igzip — no recompilation needed.

### Demo 2 — `qatzip-test` single-thread
Intel's `qatzip-test` utility runs compress + decompress in a tight loop with no I/O. When QAT hardware is unavailable it falls back to software zlib (`-B 1`). The shim intercepts that path.

### Demo 3 — Java JDK (`java.util.zip.Deflater` via JNI)
Java's `Deflater` class calls `deflate()` in native `libz.so` via JNI. `LD_PRELOAD` intercepts those calls at the OS loader level — no JVM flags, no recompilation, no changes to the Java application.

### Demo 4 — `pigz` (parallel gzip — backup/archival pipeline) ⭐ DCG server
`pigz` is the standard parallelised gzip used in data-centre backup and log-archival pipelines. It splits the input into blocks and compresses each on a separate OS thread. With `LD_PRELOAD`, every thread's `deflate()` call is intercepted simultaneously — no changes to the backup script, no restart. Use cases: nightly backup jobs, log rotation, container image creation.

### Summary table
At the end, a single table compares all three workloads side-by-side:

```
Workload                              Baseline    + ISA-L Shim   Speedup
------------------------------------------------------------------------
Python zlib (in-process, lvl 1)      350 MB/s      900 MB/s       2.5x
qatzip-test (1 thread, SW)            90 MB/s      750 MB/s       8.3x
Java Deflater (JNI, level 3)         200 MB/s      700 MB/s       3.5x
pigz (8 threads, lvl 1)             2800 MB/s     7200 MB/s       2.6x
```

> Figures are illustrative; actual results depend on CPU generation and data compressibility.

---

## Repository layout

```
.
├── setup.sh        # One-time environment setup
├── demo.sh         # Interactive lab demo
├── lab.env         # Auto-generated by setup.sh (gitignored)
└── lab/            # Auto-generated by setup.sh (gitignored)
    ├── isa-l/              # Cloned ISA-L source
    ├── isa-l-install/      # Installed ISA-L library
    ├── qatzip/             # Cloned QATzip source
    └── dickens             # Benchmark corpus
```

---

## Key takeaway

> The same binary. Zero recompilation. Zero source changes.  
> One environment variable (`LD_PRELOAD`) drops in ISA-L igzip and delivers faster deflate/inflate across zlib-dependent workload — from command-line tools to multi-threaded applications.

---

## References

- [Intel ISA-L on GitHub](https://github.com/intel/isa-l)
- [Intel QATzip on GitHub](https://github.com/intel/qatzip)
- [ISA-L zlib Shim README](https://github.com/intel/isa-l/tree/master/igzip/shim)
