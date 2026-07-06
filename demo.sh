#!/bin/bash
# =============================================================================
#  DCG Training Lab: Intel ISA-L zlib Shim — Performance Demo
#
#  This script demonstrates how the ISA-L shim transparently accelerates any
#  application that uses the standard zlib API, with ZERO code changes.
#
#  Workloads used:
#    1. python zlib    — in-process, purely CPU-bound (calls libz.so deflate directly)
#    2. qatzip-test   — Intel QATzip test utility, single-thread SW fallback path
#    3. java          — JDK java.util.zip.Deflater (calls native zlib via JNI)
#    4. pigz          — parallel gzip (N cores), server backup/archival pipeline
#    5. python workers — N concurrent worker processes, microservice/container pattern
#
#  qatzip-test source: https://github.com/intel/qatzip
#
#  How the shim works:
#    LD_PRELOAD=isal-shim.so ./app
#    The OS dynamic linker loads isal-shim.so BEFORE libz.so, so every call
#    to deflate/inflate is silently redirected to Intel ISA-L's igzip —
#    an AVX-512 / AVX2 optimised implementation — at run-time, with no
#    recompilation and no source changes to the application.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths — set by setup.sh via lab.env
# ---------------------------------------------------------------------------

# Override defaults with paths written by setup.sh (if present)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/lab.env" ]] && source "$SCRIPT_DIR/lab.env"
WORK_DIR="/tmp/isal_lab_$$"
RUNS=5          # timed iterations per workload (median is reported)
QATZIP_LOOPS=10 # internal loop count passed to qatzip-test -l
NWORKERS=$(nproc); (( NWORKERS > 8 )) && NWORKERS=8   # parallel threads/workers (Demo 4 & 5)

# ---------------------------------------------------------------------------
# Colours for readability
# ---------------------------------------------------------------------------
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

banner()  { echo -e "\n${CYAN}${BOLD}=== $* ===${RESET}"; }
info()    { echo -e "    ${YELLOW}$*${RESET}"; }
ok()      { echo -e "    ${GREEN}[OK]${RESET} $*"; }
err()     { echo -e "    ${RED}[ERROR]${RESET} $*" >&2; }
ruler()     { printf '%.0s-' {1..70}; echo; }
press_enter() { echo -e "\n    ${BOLD}Press Enter to continue...${RESET}"; read -r; }

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
banner "Step 0 — Prerequisites"

[[ -f "$ISAL_SHIM" ]]    && ok "isal-shim.so found: $ISAL_SHIM" \
    || { err "isal-shim.so not found at $ISAL_SHIM"; exit 1; }

[[ -f "$DICKENS" ]]      && ok "Test corpus found: $DICKENS ($(du -sh "$DICKENS" | cut -f1))" \
    || { err "Test corpus not found: $DICKENS"; exit 1; }

[[ -x "$QATZIP_TEST" ]]  && ok "qatzip-test found: $QATZIP_TEST" \
    || { err "qatzip-test not found: $QATZIP_TEST"; exit 1; }

command -v python3 &>/dev/null && ok "python3 found: $(command -v python3)" \
    || { err "python3 not found (needed for Demo 1)"; exit 1; }
command -v awk  &>/dev/null && ok "awk found" \
    || { err "awk not found"; exit 1; }
command -v java  &>/dev/null && ok "java found: $(command -v java)" \
    || { err "java not found (needed for Demo 3)"; exit 1; }
command -v javac &>/dev/null && ok "javac found: $(command -v javac)" \
    || { err "javac not found (needed for Demo 3)"; exit 1; }
command -v pigz &>/dev/null && ok "pigz found: $(command -v pigz)" \
    || { err "pigz not found (needed for Demo 4 — install: dnf install pigz / apt install pigz)"; exit 1; }

mkdir -p "$WORK_DIR"
info "Working directory: $WORK_DIR"
press_enter

# ---------------------------------------------------------------------------
# Build a larger test file so the timing difference is clearly visible.
# We replicate the dickens corpus to reach ~50 MB of compressible text.
# ---------------------------------------------------------------------------
banner "Step 1 — Prepare test data"

INPUT="$WORK_DIR/testdata.txt"
python3 - <<PYEOF
import os, shutil
src  = "$DICKENS"
dst  = "$INPUT"
sz   = os.path.getsize(src)
reps = max(1, int(20 * 1024 * 1024 / sz))   # target ~20 MB
with open(dst, 'wb') as out:
    for _ in range(reps):
        with open(src, 'rb') as f:
            shutil.copyfileobj(f, out)
final = os.path.getsize(dst)
print(f"    Created {dst} ({final/1024/1024:.1f} MB, {reps}x dickens corpus)")
PYEOF

INPUT_SIZE=$(stat -c%s "$INPUT")
info "Input size: $(numfmt --to=iec-i --suffix=B "$INPUT_SIZE")"
press_enter

# ---------------------------------------------------------------------------
# Helper: run qatzip-test, return only the [INFO] result lines.
# Usage: run_qatzip [env_prefix] <qatzip-test args...>
#   env_prefix — optional "KEY=VAL ..." string to prepend (empty string = none)
# [Warning]/[Error] hardware-not-found noise is suppressed; only [INFO] is kept.
# The || true prevents set -o pipefail from triggering on grep exit-1.
# ---------------------------------------------------------------------------
run_qatzip() {
    local env_prefix="$1"; shift
    { eval "$env_prefix" "$QATZIP_TEST" "$@" 2>&1; } | grep '\[INFO\]' || true
}

# Parse Gbps and msec from a single [INFO] line (stdin).
# INFO field layout (space-separated):
#   [INFO] srv=BOTH, tid=N, verify=N, count=N, msec=NNNNN, bytes=NNN, X.XXX Gbps, ...
#   Field 6 = "msec=NNNNN,"   Field 8 = "X.XXX"
parse_qatzip_single() {
    awk 'NR==1 {
        msec_f = $6; gsub(/[^0-9]/, "", msec_f)
        printf "%.3f %d\n", $8+0, msec_f+0
    }'
}

# Convert Gbps to MB/s  (1 Gbps = 1000/8 = 125 MB/s in SI units)
gbps_to_mbps() {
    awk "BEGIN { printf \"%d\", ($1) * 125 }"
}

# Time one external command invocation (stdout+stderr suppressed), return ms.
timed_ms() {
    local -n _tm_ret=$1; shift
    local t0 t1
    t0=$(date +%s%N)
    "$@" > /dev/null 2>&1
    t1=$(date +%s%N)
    _tm_ret=$(( (t1 - t0) / 1000000 ))
}

# Run RUNS iterations of an external command, return median wall-clock ms.
timed_median_ms() {
    local -n _tmm_ret=$1; shift
    local times=() t
    for (( i=0; i<RUNS; i++ )); do
        timed_ms t "$@"
        times+=("$t")
    done
    IFS=$'\n' _sorted=($(sort -n <<<"${times[*]}")); unset IFS
    _tmm_ret="${_sorted[$((RUNS/2))]}"
}

# ---------------------------------------------------------------------------
# DEMO 1 — Python zlib (in-process, purely CPU-bound)
# ---------------------------------------------------------------------------
banner "Demo 1 — Python zlib (in-process, purely CPU-bound)"
ruler
echo ""
info "Python's zlib.compress() calls libz.so deflate() directly from within the process."
info "Running entirely in-memory eliminates disk I/O — the delta is pure CPU/SIMD."
info "The shim intercepts deflate() at the OS loader level — no recompilation needed."
echo ""

# Write an in-process benchmark so multiple iterations run without fork overhead
PYBENCH="$WORK_DIR/zlibench.py"
cat > "$PYBENCH" << 'PYEOF'
import sys, zlib, time
data = open(sys.argv[1], 'rb').read()
reps = int(sys.argv[2])
# warm-up to avoid cold-start effects
zlib.compress(data, 1)
times = []
for _ in range(reps):
    t0 = time.perf_counter_ns()
    zlib.compress(data, 1)
    t1 = time.perf_counter_ns()
    times.append(t1 - t0)
times.sort()
median_ms = max(times[reps // 2] // 1_000_000, 1)
mbps = len(data) / 1_048_576 / median_ms * 1_000
print(f"{mbps:.1f} {median_ms}")
PYEOF

info "Command (baseline): python3 zlibench.py $INPUT $RUNS"
info "Command (shimmed):  LD_PRELOAD=isal-shim.so python3 zlibench.py $INPUT $RUNS"
echo ""

info "Running baseline (stock zlib)  ×${RUNS} ..."
read -r py_base_mbps py_base_ms < <(python3 "$PYBENCH" "$INPUT" "$RUNS")

info "Running with ISA-L shim        ×${RUNS} ..."
read -r py_shim_mbps py_shim_ms < <(
    env LD_LIBRARY_PATH="$ISAL_LIB:${LD_LIBRARY_PATH:-}" LD_PRELOAD="$ISAL_SHIM" \
        python3 "$PYBENCH" "$INPUT" "$RUNS"
)

py_speedup=$(awk "BEGIN { printf \"%.2f\", $py_shim_mbps / $py_base_mbps }")

echo ""
printf "    %-38s  %12s\n" "Scenario" "Throughput"
ruler
printf "    %-38s  %7s MB/s\n" "Python zlib (baseline)"     "$py_base_mbps"
printf "    %-38s  %7s MB/s\n" "Python zlib (+ ISA-L shim)" "$py_shim_mbps"
ruler
echo -e "\n    ${GREEN}${BOLD}Speedup: ${py_speedup}x faster with ISA-L shim${RESET}"
press_enter

# ---------------------------------------------------------------------------
# DEMO 2 — qatzip-test single-thread (SW zlib fallback)
# ---------------------------------------------------------------------------
banner "Demo 2 — qatzip-test single-thread (SW zlib fallback path)"
ruler
echo ""
info "QATzip offloads deflate to QAT hardware when available."
info "With no QAT device (-B 1 enables SW fallback), it falls back to zlib."
info "The shim intercepts that zlib path and replaces it with ISA-L igzip —"
info "no recompilation, no source changes to qatzip-test."
echo ""
info "Command (baseline): $QATZIP_TEST -m 4 -i $DICKENS -D both -l $QATZIP_LOOPS -B 1"
info "Command (shimmed):  LD_PRELOAD=isal-shim.so [same command]"
echo ""

info "Running baseline (SW zlib)  ..."
qt1_base_info=$(run_qatzip "" \
    -m 4 -i "$DICKENS" -D both -l "$QATZIP_LOOPS" -B 1)
read -r qt1_base_gbps qt1_base_msec < <(echo "$qt1_base_info" | parse_qatzip_single)

info "Running with ISA-L shim    ..."
qt1_shim_info=$(run_qatzip \
    "LD_LIBRARY_PATH=\"$ISAL_LIB:\${LD_LIBRARY_PATH:-}\" LD_PRELOAD=\"$ISAL_SHIM\"" \
    -m 4 -i "$DICKENS" -D both -l "$QATZIP_LOOPS" -B 1)
read -r qt1_shim_gbps qt1_shim_msec < <(echo "$qt1_shim_info" | parse_qatzip_single)

qt1_speedup=$(awk "BEGIN { printf \"%.2f\", $qt1_shim_gbps / $qt1_base_gbps }")

qt1_base_mbps=$(gbps_to_mbps "$qt1_base_gbps")
qt1_shim_mbps=$(gbps_to_mbps "$qt1_shim_gbps")
echo ""
printf "    %-40s  %12s\n" "Scenario" "Throughput"
ruler
printf "    %-40s  %7s MB/s\n" "qatzip-test (baseline SW zlib)" "$qt1_base_mbps"
printf "    %-40s  %7s MB/s\n" "qatzip-test (+ ISA-L shim)"    "$qt1_shim_mbps"
ruler
echo -e "\n    ${GREEN}${BOLD}Speedup: ${qt1_speedup}x faster with ISA-L shim${RESET}"
press_enter

# ---------------------------------------------------------------------------
# DEMO 3 — Java JDK (java.util.zip.Deflater → native zlib via JNI)
# ---------------------------------------------------------------------------
banner "Demo 3 — Java JDK (java.util.zip.Deflater, native zlib via JNI)"
ruler
echo ""
info "Java's java.util.zip.Deflater calls zlib deflate() via JNI (libzip.so → libz.so)."
info "LD_PRELOAD intercepts those native calls at the OS loader level —"
info "no JVM flags, no recompilation, no changes to the Java application."
echo ""

# Write and compile the micro-benchmark inline
cat > "$WORK_DIR/JavaZlibBench.java" << 'JAVAEOF'
import java.io.*;
import java.nio.file.*;
import java.util.zip.*;
import java.util.*;
public class JavaZlibBench {
    public static void main(String[] args) throws Exception {
        byte[] input = Files.readAllBytes(Paths.get(args[0]));
        int reps = Integer.parseInt(args[1]);
        byte[] output = new byte[input.length + 1024];
        // warm-up pass to trigger JIT compilation
        Deflater w = new Deflater(3); w.setInput(input); w.finish(); w.deflate(output); w.end();
        long[] times = new long[reps];
        for (int i = 0; i < reps; i++) {
            long t0 = System.nanoTime();
            Deflater d = new Deflater(3);
            d.setInput(input);
            d.finish();
            d.deflate(output);
            d.end();
            times[i] = (System.nanoTime() - t0) / 1_000_000L;
        }
        Arrays.sort(times);
        long median_ms = times[reps / 2];
        double mbps = (double) input.length / 1048576.0 / median_ms * 1000.0;
        System.out.printf("%.1f %d%n", mbps, median_ms);
    }
}
JAVAEOF
javac -d "$WORK_DIR" "$WORK_DIR/JavaZlibBench.java" 2>/dev/null
ok "JavaZlibBench compiled"
echo ""
info "Command (baseline): java JavaZlibBench $INPUT $RUNS"
info "Command (shimmed):  LD_PRELOAD=isal-shim.so java JavaZlibBench $INPUT $RUNS"
echo ""

info "Running baseline (stock zlib via JNI)  ..."
read -r java_base_mbps java_base_ms < <(java -cp "$WORK_DIR" JavaZlibBench "$INPUT" "$RUNS")

info "Running with ISA-L shim               ..."
read -r java_shim_mbps java_shim_ms < <(
    env LD_LIBRARY_PATH="$ISAL_LIB:${LD_LIBRARY_PATH:-}" LD_PRELOAD="$ISAL_SHIM" \
        java -cp "$WORK_DIR" JavaZlibBench "$INPUT" "$RUNS"
)

java_speedup=$(awk "BEGIN { printf \"%.2f\", $java_shim_mbps / $java_base_mbps }")

echo ""
printf "    %-40s  %12s\n" "Scenario" "Throughput"
ruler
printf "    %-40s  %7s MB/s\n" "Java Deflater (baseline zlib)"  "$java_base_mbps"
printf "    %-40s  %7s MB/s\n" "Java Deflater (+ ISA-L shim)"   "$java_shim_mbps"
ruler
echo -e "\n    ${GREEN}${BOLD}Speedup: ${java_speedup}x faster with ISA-L shim${RESET}"
press_enter

# ---------------------------------------------------------------------------
# DEMO 4 — pigz (parallel gzip, multi-core backup/archival pipeline)
# ---------------------------------------------------------------------------
banner "Demo 4 — pigz (${NWORKERS}-thread parallel gzip — backup/archival pipeline)"
ruler
echo ""
info "pigz is the standard parallelised gzip used in data-centre backup and"
info "log-archival pipelines. It splits the input into blocks and compresses"
info "each block on a separate thread — all $NWORKERS threads call deflate()."
info "The shim intercepts every thread simultaneously; no changes to the script."
info "Use cases: nightly backup jobs, log rotation, container image creation."
echo ""
info "Command (baseline): pigz -p $NWORKERS -1 -c INPUT > /dev/null"
info "Command (shimmed):  LD_PRELOAD=isal-shim.so [same command]"
echo ""

info "Running baseline (stock zlib, ${NWORKERS} threads) ×${RUNS} ..."
pigz_base_ms=0
timed_median_ms pigz_base_ms  pigz -p "$NWORKERS" -1 -c "$INPUT"

info "Running with ISA-L shim         (${NWORKERS} threads) ×${RUNS} ..."
pigz_shim_ms=0
timed_median_ms pigz_shim_ms  \
    env LD_LIBRARY_PATH="$ISAL_LIB:${LD_LIBRARY_PATH:-}" LD_PRELOAD="$ISAL_SHIM" \
    pigz -p "$NWORKERS" -1 -c "$INPUT"

pigz_base_mbps=$(awk "BEGIN { printf \"%.1f\", $INPUT_SIZE * 1000 / 1048576 / $pigz_base_ms }")
pigz_shim_mbps=$(awk "BEGIN { printf \"%.1f\", $INPUT_SIZE * 1000 / 1048576 / $pigz_shim_ms }")
pigz_speedup=$(awk "BEGIN { printf \"%.2f\", $pigz_base_ms / $pigz_shim_ms }")

echo ""
printf "    %-42s  %12s\n" "Scenario" "Throughput"
ruler
printf "    %-42s  %7s MB/s\n" "pigz (baseline, ${NWORKERS} threads)"     "$pigz_base_mbps"
printf "    %-42s  %7s MB/s\n" "pigz (+ ISA-L shim, ${NWORKERS} threads)" "$pigz_shim_mbps"
ruler
echo -e "\n    ${GREEN}${BOLD}Speedup: ${pigz_speedup}x faster with ISA-L shim${RESET}"
press_enter

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "Summary"
ruler
echo ""
printf "  ${BOLD}%-36s  %12s  %12s  %7s${RESET}\n" "Workload" "Baseline" "+ ISA-L Shim" "Speedup"
ruler

printf "  %-36s  %8s MB/s   %8s MB/s    %5sx\n" \
    "Python zlib (in-process, lvl 1)" "$py_base_mbps" "$py_shim_mbps" "$py_speedup"

printf "  %-36s  %8s MB/s   %8s MB/s    %5sx\n" \
    "qatzip-test (1 thread, SW)"      "$qt1_base_mbps" "$qt1_shim_mbps" "$qt1_speedup"

printf "  %-36s  %8s MB/s   %8s MB/s    %5sx\n" \
    "Java Deflater (JNI, level 3)"    "$java_base_mbps" "$java_shim_mbps" "$java_speedup"

printf "  %-36s  %8s MB/s   %8s MB/s    %5sx\n" \
    "pigz (${NWORKERS} threads, lvl 1)"  "$pigz_base_mbps" "$pigz_shim_mbps" "$pigz_speedup"

ruler
echo ""
echo -e "  ${CYAN}${BOLD}Key takeaway:${RESET}"
echo "  The same binary, zero recompilation, zero code changes."
echo "  One environment variable (LD_PRELOAD) drops in ISA-L igzip"
echo "  and delivers faster deflate/inflate across any zlib-based workload."
echo ""

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
rm -rf "$WORK_DIR"
