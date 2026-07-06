#!/bin/bash
# =============================================================================
#  setup.sh — ISA-L Shim Lab: Environment Setup
#
#  Run this once before demo.sh. It will:
#    1. Clone and build Intel ISA-L (library + zlib shim)
#    2. Clone and build Intel qatlib (headers + .so, no root needed)
#    3. Clone and build Intel QATzip (qatzip-test utility)
#    4. Download a Dickens text corpus for benchmarking
#    5. Install OpenJDK 21 locally if no system JDK is found
#    6. Write lab.env with all paths — picked up automatically by demo.sh
#
#  Usage:
#    bash setup.sh          # first-time setup
#    bash setup.sh --clean  # wipe lab/ and start fresh
#
#  After setup completes, run the demo:
#    bash demo.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$SCRIPT_DIR/lab"
ISAL_SRC="$LAB_DIR/isa-l"
ISAL_INSTALL="$LAB_DIR/isa-l-install"
SHIM_BUILD="$ISAL_SRC/igzip/shim/build"
QATZIP_SRC="$LAB_DIR/qatzip"
QATLIB_SRC="$LAB_DIR/qatlib"
QATLIB_INSTALL="$LAB_DIR/qatlib-install"
DICKENS_FILE="$LAB_DIR/dickens"
ENV_FILE="$SCRIPT_DIR/lab.env"

# ---------------------------------------------------------------------------
# Colours (same palette as demo.sh)
# ---------------------------------------------------------------------------
BOLD='\033[1m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

banner() { echo -e "\n${CYAN}${BOLD}=== $* ===${RESET}"; }
ok()     { echo -e "    ${GREEN}[OK]${RESET} $*"; }
info()   { echo -e "    ${YELLOW}$*${RESET}"; }
err()    { echo -e "    ${RED}[ERROR]${RESET} $*" >&2; }
step()   { echo -e "\n  ${BOLD}> $*${RESET}"; }

# ---------------------------------------------------------------------------
# --clean flag
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--clean" ]]; then
    echo -e "${YELLOW}Removing $LAB_DIR and $ENV_FILE ...${RESET}"
    rm -rf "$LAB_DIR" "$ENV_FILE"
    echo "Done. Run 'bash setup.sh' to set up again."
    exit 0
fi

banner "ISA-L Shim Lab — Environment Setup"
echo ""
info "Script directory : $SCRIPT_DIR"
info "Lab directory    : $LAB_DIR"
info "This will take a few minutes to clone and build."

mkdir -p "$LAB_DIR"

# ---------------------------------------------------------------------------
# Step 1 — Check build dependencies
# ---------------------------------------------------------------------------
banner "Step 1 — Checking build dependencies"

missing=()
check_cmd() {
    local cmd=$1 pkg=${2:-$1}
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd"
    else
        err "$cmd not found  (install: $pkg)"
        missing+=("$pkg")
    fi
}

check_cmd git      git
check_cmd make     make
check_cmd cmake    cmake
check_cmd nasm     nasm
check_cmd autoconf autoconf
check_cmd automake   automake
check_cmd libtoolize libtool
check_cmd pkg-config pkg-config
check_cmd curl     curl
check_cmd python3  python3
check_cmd pigz     pigz   # Demo 4: parallel gzip backup/archival pipeline

# Java is needed for Demo 3 — not fatal here; Step 5 will install if missing
if command -v javac &>/dev/null; then
    ok "javac (system JDK)"
else
    info "javac not found — OpenJDK 21 will be installed locally in Step 5"
fi

# liblz4-dev is required by QATzip's configure (lz4.h).
if [[ -f /usr/include/lz4.h || -f /usr/local/include/lz4.h ]]; then
    ok "lz4.h (liblz4-dev)"
else
    err "lz4.h not found  (install: liblz4-dev)"
    missing+=("liblz4-dev")
fi

# libnuma-dev is required by qatlib's configure.
if [[ -f /usr/include/numa.h || -f /usr/local/include/numa.h ]]; then
    ok "numa.h (libnuma-dev)"
else
    err "numa.h not found  (install: libnuma-dev)"
    missing+=("libnuma-dev")
fi

# libssl-dev is required by qatlib's configure (openssl/md5.h).\nif [[ -f /usr/include/openssl/md5.h || -f /usr/local/include/openssl/md5.h ]]; then\n    ok \"openssl/md5.h (libssl-dev)\"\nelse\n    err \"openssl/md5.h not found  (install: libssl-dev)\"\n    missing+=(\"libssl-dev\")\nfi

# qatlib headers are needed to compile qatzip-test.
# Prefer system package; fall back to local source build in Step 3.
# QATzip requires qat/cpa.h AND qat/qae_mem.h — Ubuntu's libqat-dev only
# ships the former; the latter requires a full qatlib source build.
if pkg-config --exists qatlib 2>/dev/null && [[ -f /usr/include/qat/qae_mem.h ]]; then
    ok "qatlib (system pkg-config + full headers)"
elif [[ -f /usr/include/qat/cpa.h && -f /usr/include/qat/qae_mem.h ]]; then
    ok "qatlib headers found (including qae_mem.h)"
elif [[ -f /usr/include/qat/cpa.h ]]; then
    info "qatlib partial headers found (qae_mem.h missing) — will build qatlib from source in Step 3"
    info "  TIP: Ubuntu's libqat-dev omits qae_mem.h; the source build fills the gap"
else
    info "qatlib not found system-wide — will clone and build locally in Step 3"
    info "  TIP (Ubuntu): sudo apt install libqat-dev libnl-3-dev libnl-genl-3-dev libudev-dev libtool libnuma-dev libssl-dev"
    info "  TIP (RHEL):   sudo dnf install qatlib-devel numactl-devel openssl-devel"
fi

if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    err "Missing dependencies: ${missing[*]}"
    err "Install them and re-run setup.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 2 — Clone and build Intel ISA-L
# ---------------------------------------------------------------------------
banner "Step 2 — Intel ISA-L  (https://github.com/intel/isa-l)"

if [[ -d "$ISAL_SRC/.git" ]]; then
    info "Already cloned — skipping clone"
else
    step "git clone --depth 1 https://github.com/intel/isa-l"
    git clone --depth 1 https://github.com/intel/isa-l "$ISAL_SRC"
fi

if [[ -f "$ISAL_INSTALL/lib/libisal.so" ]]; then
    info "ISA-L library already built — skipping"
else
    step "Building ISA-L library (make -j$(nproc)) ..."
    pushd "$ISAL_SRC" > /dev/null
    ./autogen.sh
    ./configure --prefix="$ISAL_INSTALL"
    make -j"$(nproc)"
    make install
    popd > /dev/null
    ok "ISA-L installed → $ISAL_INSTALL"
fi

if [[ -f "$SHIM_BUILD/isal-shim.so" ]]; then
    info "isal-shim.so already built — skipping"
else
    step "Building ISA-L zlib shim (igzip/shim/) ..."
    mkdir -p "$SHIM_BUILD"
    pushd "$SHIM_BUILD" > /dev/null
    # Pre-set ISAL_LIBRARY to bypass find_library (which uses NO_DEFAULT_PATH
    # and won't search lib/ subdirectories automatically).
    cmake -DCMAKE_BUILD_TYPE=Release \
          -DISAL_INSTALL_DIR="$ISAL_INSTALL" \
          -DISAL_LIBRARY="$ISAL_INSTALL/lib/libisal.so" \
          ..
    make -j"$(nproc)"
    popd > /dev/null
fi

ISAL_SHIM_PATH="$SHIM_BUILD/isal-shim.so"
[[ -f "$ISAL_SHIM_PATH" ]] \
    && ok "isal-shim.so → $ISAL_SHIM_PATH" \
    || { err "isal-shim.so not found after build"; exit 1; }

# ---------------------------------------------------------------------------
# Step 3 — Clone and build Intel qatlib (headers + shared library)
# ---------------------------------------------------------------------------
banner "Step 3 — Intel qatlib  (https://github.com/intel/qatlib)"

# If the system already provides qatlib via pkg-config with full headers, skip
# the local build.  QATzip requires qae_mem.h in addition to cpa.h — Ubuntu's
# libqat-dev omits qae_mem.h, so a source build is needed in that case.
if pkg-config --exists qatlib 2>/dev/null && [[ -f /usr/include/qat/qae_mem.h ]]; then
    QATLIB_INSTALL="$(pkg-config --variable=prefix qatlib)"
    info "System qatlib found (pkg-config + full headers) — skipping local build"
    ok "qatlib prefix: $QATLIB_INSTALL"
elif [[ -f /usr/include/qat/cpa.h && -f /usr/include/qat/qae_mem.h ]]; then
    QATLIB_INSTALL="/usr"
    info "System qatlib headers found (including qae_mem.h) — skipping local build"
    ok "qatlib prefix: $QATLIB_INSTALL"
else
    if [[ -d "$QATLIB_SRC/.git" ]]; then
        info "Already cloned — skipping clone"
    else
        step "git clone --depth 1 https://github.com/intel/qatlib"
        git clone --depth 1 https://github.com/intel/qatlib "$QATLIB_SRC"
    fi

    if [[ -f "$QATLIB_INSTALL/lib/libqat.so" || -f "$QATLIB_INSTALL/lib64/libqat.so" ]]; then
        info "qatlib already built — skipping"
    else
        # qatlib source build requires libnl-3-dev and libudev-dev.
        if ! [[ -f /usr/include/libnl3/netlink/netlink.h || -f /usr/local/include/libnl3/netlink/netlink.h ]]; then
            err "libnl3 headers not found — qatlib source build will likely fail."
            err "Install: sudo apt install libnl-3-dev libnl-genl-3-dev libudev-dev libnuma-dev libssl-dev  (Ubuntu)"
            err "         sudo dnf install libnl3-devel numactl-devel openssl-devel  (RHEL)"
            err "Or install the pre-built headers package:  sudo apt install libqat-dev"
            exit 1
        fi
        step "Building qatlib (make -j$(nproc)) ..."
        pushd "$QATLIB_SRC" > /dev/null
        # ax_pthread.m4 may not be installed system-wide — download if absent.
        if [[ ! -f m4/ax_pthread.m4 ]]; then
            mkdir -p m4
            curl -fsSL --retry 3 \
                "https://raw.githubusercontent.com/autoconf-archive/autoconf-archive/master/m4/ax_pthread.m4" \
                -o m4/ax_pthread.m4
        fi
        ACLOCAL_PATH="$PWD/m4${ACLOCAL_PATH:+:$ACLOCAL_PATH}" ./autogen.sh
        ./configure --prefix="$QATLIB_INSTALL" \
                    --enable-shared --disable-static \
                    --disable-systemd
        make -j"$(nproc)"
        make install
        popd > /dev/null
        ok "qatlib installed → $QATLIB_INSTALL"
    fi
fi

# Resolve lib dir (some distros use lib64)
if   [[ -d "$QATLIB_INSTALL/lib64" ]]; then QATLIB_LIB="$QATLIB_INSTALL/lib64"
elif [[ -d "$QATLIB_INSTALL/lib" ]];   then QATLIB_LIB="$QATLIB_INSTALL/lib"
else QATLIB_LIB="$QATLIB_INSTALL/lib"
fi

# ---------------------------------------------------------------------------
# Step 4 — Clone and build Intel QATzip
# ---------------------------------------------------------------------------
banner "Step 4 — Intel QATzip  (https://github.com/intel/qatzip)"

if [[ -d "$QATZIP_SRC/.git" ]]; then
    info "Already cloned — skipping clone"
else
    step "git clone --depth 1 https://github.com/intel/qatzip"
    git clone --depth 1 https://github.com/intel/qatzip "$QATZIP_SRC"
fi

QATZIP_TEST_PATH="$QATZIP_SRC/test/qatzip-test"

if [[ -x "$QATZIP_TEST_PATH" ]]; then
    info "qatzip-test already built — skipping"
else
    step "Building QATzip (make -j$(nproc)) ..."
    pushd "$QATZIP_SRC" > /dev/null
    # ax_pthread.m4 is required by configure.ac but not bundled in the repo.
    # Download it and point aclocal at it via ACLOCAL_PATH (no root needed).
    if [[ ! -f m4/ax_pthread.m4 ]]; then
        mkdir -p m4
        curl -fsSL --retry 3 \
            "https://raw.githubusercontent.com/autoconf-archive/autoconf-archive/master/m4/ax_pthread.m4" \
            -o m4/ax_pthread.m4
    fi
    ACLOCAL_PATH="$PWD/m4${ACLOCAL_PATH:+:$ACLOCAL_PATH}" ./autogen.sh
    # Pass CPPFLAGS/LDFLAGS so the compiler finds qat/cpa.h and libqat even when
    # qatlib was built locally and its pkg-config Cflags entry is empty.
    PKG_CONFIG_PATH="$QATLIB_LIB/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        CPPFLAGS="-I$QATLIB_INSTALL/include" \
        LDFLAGS="-L$QATLIB_LIB" \
        ./configure
    make -j"$(nproc)"
    popd > /dev/null
fi

[[ -x "$QATZIP_TEST_PATH" ]] \
    && ok "qatzip-test → $QATZIP_TEST_PATH" \
    || { err "qatzip-test not found after build"; exit 1; }

# ---------------------------------------------------------------------------
# Step 5 — Download Dickens corpus
# ---------------------------------------------------------------------------
banner "Step 5 — Dickens text corpus (benchmark input)"

if [[ -f "$DICKENS_FILE" && $(stat -c%s "$DICKENS_FILE") -gt 500000 ]]; then
    ok "Corpus already present — $(du -sh "$DICKENS_FILE" | cut -f1)"
else
    step "Downloading three Dickens novels from Project Gutenberg..."
    info "(A Tale of Two Cities + Great Expectations + Oliver Twist ≈ 2.7 MB)"
    TMP_FILE="$LAB_DIR/.dickens_tmp"
    rm -f "$TMP_FILE"
    # A Tale of Two Cities (pg98)
    curl -fsSL --retry 3 "https://www.gutenberg.org/cache/epub/98/pg98.txt"     >> "$TMP_FILE"
    # Great Expectations (pg1400)
    curl -fsSL --retry 3 "https://www.gutenberg.org/cache/epub/1400/pg1400.txt" >> "$TMP_FILE"
    # Oliver Twist (pg730)
    curl -fsSL --retry 3 "https://www.gutenberg.org/cache/epub/730/pg730.txt"   >> "$TMP_FILE"
    mv "$TMP_FILE" "$DICKENS_FILE"
    ok "Corpus saved → $DICKENS_FILE ($(du -sh "$DICKENS_FILE" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# Step 6 — Java JDK (Demo 3: java.util.zip.Deflater benchmark)
# ---------------------------------------------------------------------------
banner "Step 6 — Java JDK (Demo 3: java.util.zip.Deflater benchmark)"

JDK_DIR="$LAB_DIR/jdk"
JAVA_HOME_LAB=""

if command -v javac &>/dev/null; then
    javac_real="$(readlink -f "$(command -v javac)")"
    JAVA_HOME_LAB="$(dirname "$(dirname "$javac_real")")"
    ok "System JDK found: $JAVA_HOME_LAB"
elif [[ -x "$JDK_DIR/bin/javac" ]]; then
    JAVA_HOME_LAB="$JDK_DIR"
    ok "Local JDK already present: $JDK_DIR"
else
    step "Downloading OpenJDK 21 (Adoptium Temurin) into $JDK_DIR ..."
    info "This is a one-time ~190 MB download."
    JDK_TGZ="$LAB_DIR/.jdk21.tar.gz"
    curl -fsSL --retry 3 \
        "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse" \
        -o "$JDK_TGZ"
    tar -xzf "$JDK_TGZ" -C "$LAB_DIR"
    extracted="$(find "$LAB_DIR" -maxdepth 1 -name 'jdk-*' -type d | head -1)"
    if [[ -n "$extracted" && "$extracted" != "$JDK_DIR" ]]; then
        mv "$extracted" "$JDK_DIR"
    fi
    rm -f "$JDK_TGZ"
    [[ -x "$JDK_DIR/bin/javac" ]] \
        && ok "OpenJDK 21 installed → $JDK_DIR" \
        || { err "JDK install failed — javac not found in $JDK_DIR/bin"; exit 1; }
    JAVA_HOME_LAB="$JDK_DIR"
fi

# ---------------------------------------------------------------------------
# Step 7 — Write lab.env
# ---------------------------------------------------------------------------
banner "Step 7 — Writing lab.env"

cat > "$ENV_FILE" <<EOF
# Auto-generated by setup.sh — re-run setup.sh to regenerate
# Sourced automatically by demo.sh at startup.
ISAL_SHIM="$ISAL_SHIM_PATH"
ISAL_LIB="$ISAL_INSTALL/lib"
DICKENS="$DICKENS_FILE"
QATZIP_TEST="$QATZIP_TEST_PATH"
# qatlib shared library — needed at runtime by qatzip-test
export LD_LIBRARY_PATH="$QATLIB_LIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF

# Append JAVA_HOME so demo.sh finds java/javac even if installed locally
if [[ -n "$JAVA_HOME_LAB" ]]; then
    cat >> "$ENV_FILE" <<JAVAENV
JAVA_HOME="$JAVA_HOME_LAB"
export PATH="\$JAVA_HOME/bin:\$PATH"
JAVAENV
fi

ok "lab.env written → $ENV_FILE"
echo ""
cat "$ENV_FILE"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
banner "Setup complete"
echo ""
echo -e "  ${GREEN}${BOLD}Everything is ready. Run the lab demo with:${RESET}"
echo ""
echo "    bash demo.sh"
echo ""
