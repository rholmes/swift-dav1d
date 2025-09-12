#!/usr/bin/env bash
set -euo pipefail

# ======================================
# Config — tune as desired
# ======================================
DAV1D_TAG="${DAV1D_TAG:-1.5.1}"            # Pin for reproducibility (Jan 19, 2025)
PRODUCT_NAME="dav1d"                       # Swift module name & XCFramework name
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
PACKAGE_ROOT="$( cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd )"
BUILD_DIR="${SCRIPT_DIR}/build-dav1d"
OUT_DIR="${BUILD_DIR}/out"
SRC_DIR="${BUILD_DIR}/src"
XC_OUT="${OUT_DIR}/${PRODUCT_NAME}.xcframework"
SPM_XC_DEST="${SPM_XC_DEST:-$PACKAGE_ROOT/Sources}"  # xcframework install dir
SPM_HEADERS_DEST="${SPM_HEADERS_DEST:-$PACKAGE_ROOT/Sources/Cdav1d/include/dav1d}"  # shim header install dir

# Optional toggles
ENABLE_WATCHOS="${ENABLE_WATCHOS:-0}"  # 1 to build watchOS slices
STRIP=${STRIP:-1}                      # 1 to strip symbols in .a slices
COPY_TO_SPM="${COPY_TO_SPM:-1}"        # 1 to copy the framework and headers to the Swift package

# Minimum OS versions
IOS_MIN=13.0
IOS_SIM_MIN=13.0
MACOS_MIN=11.0
CATALYST_IOS_MIN=14.0      # macABI minimum iOS version
TVOS_MIN=13.0
WATCHOS_MIN=6.0

# Common Meson options for small & fast static libs
MESON_OPTS=(
  --buildtype=release
  -Ddefault_library=static
  -Db_lto=false
  -Db_ndebug=true
  -Denable_asm=true
  -Denable_tools=false
  -Denable_tests=false
  -Denable_examples=false
)

# ======================================
# Helpers
# ======================================
log() { printf "\n\033[1;34m▶ %s\033[0m\n" "$*"; }
die() { echo "✖ $*" >&2; exit 1; }

xcrun_sdk() { xcrun --sdk "$1" --show-sdk-path; }
clang_path() { xcrun --sdk "$1" -f clang; }
ar_path() { xcrun --sdk "$1" -f ar; }
strip_path() { xcrun --sdk "$1" -f strip; }

ensure_tools() {
  command -v meson >/dev/null || die "meson not found"
  command -v ninja >/dev/null || die "ninja not found"
  command -v nasm >/dev/null || die "nasm not found (required for x86* ASM)"
  xcrun -find clang >/dev/null || die "Xcode command line tools not configured"
}

ensure_checkout() {
  log "Fetching dav1d ${DAV1D_TAG}"
  rm -rf "${BUILD_DIR}" "${OUT_DIR}"
  mkdir -p "${BUILD_DIR}" "${OUT_DIR}"
  git clone --filter=blob:none https://code.videolan.org/videolan/dav1d.git "${SRC_DIR}"
  git -C "${SRC_DIR}" fetch --tags --force
  git -C "${SRC_DIR}" checkout -q "${DAV1D_TAG}^{commit}"
}

# Create a Meson cross file for a given Apple target triple and SDK
make_cross() {
  local name="$1" triple="$2" sdk="$3" min_flag="$4" min_ver="$5"
  local cc="$(clang_path "${sdk}")"
  local arbin="$(ar_path "${sdk}")"
  local stripbin="$(strip_path "${sdk}")"
  local sysroot="$(xcrun_sdk "${sdk}")"
  local dir="${BUILD_DIR}/cross"
  mkdir -p "${dir}"
  local file="${dir}/${name}.ini"

  # Derive arch/cpu_family for Meson
  local arch="${triple%%-*}"   # first component of the triple, e.g. armv7k, arm64, etc.
  local cpu_family="${arch}"

  case "${arch}" in
    arm64)    cpu_family="aarch64" ;;
    arm64_32) cpu_family="aarch64" ;;  # if you ever revive it
    armv7k)   cpu_family="arm" ;;      # treat as generic 32-bit ARM
  esac

  cat > "${file}" <<EOF
[binaries]
c = '${cc}'
ar = '${arbin}'
strip = '${stripbin}'

[host_machine]
system = 'darwin'
cpu_family = '${cpu_family}'
cpu = '${arch}'
endian = 'little'

[built-in options]
c_args = ['-target','${triple}','-isysroot','${sysroot}','-${min_flag}=${min_ver}','-O3','-fvisibility=hidden','-ffunction-sections','-fdata-sections']
c_link_args = ['-target','${triple}','-isysroot','${sysroot}','-${min_flag}=${min_ver}','-Wl,-dead_strip']
EOF
  echo "${file}"
}

strip_lib() {
  local lib="$1"
  if [[ "${STRIP}" == "1" ]]; then
    log "Stripping symbols from $(basename "${lib}")"
    strip -S -x "${lib}" || die "strip failed for ${lib}"
  fi
}

build_one() {
  local name="$1" triple="$2" sdk="$3" min_flag="$4" min_ver="$5" accumulate="${6:-1}"

  log "Configuring ${name} (${triple}, ${sdk}, min ${min_ver})"
  local cross_file
  cross_file="$(make_cross "${name}" "${triple}" "${sdk}" "${min_flag}" "${min_ver}")"

  local bdir="${BUILD_DIR}/build-${name}"
  rm -rf "${bdir}"
  meson setup "${bdir}" "${SRC_DIR}" --cross-file "${cross_file}" "${MESON_OPTS[@]}"
  meson compile -C "${bdir}"

  # Locate the static library (Meson puts it under build-*/src/)
  local libpath="${BUILD_DIR}/build-${name}/src/libdav1d.a"
  [[ -f "${libpath}" ]] || die "libdav1d.a not found for ${name} at ${libpath}"

  # Strip the thin archive if enabled (applies to ALL slices)
  strip_lib "${libpath}"

  # Use shared headers for every slice
  local headers_dir="${SHARED_HEADERS_DIR}"

  # Optionally accumulate per-arch libs (default on)
  if [[ "${accumulate}" == "1" ]]; then
    XC_LIB_ARGS+=("-library" "${libpath}" "-headers" "${headers_dir}")
  fi
}

make_universal() {
  # $1: output path, $2+: input thin .a paths
  local out="$1"; shift
  rm -f "${out}"
  lipo -create "$@" -output "${out}"
  # quick sanity print
  lipo -info "${out}"
}

create_xcframework() {
  log "Creating XCFramework"
  rm -rf "${XC_OUT}"
  xcodebuild -create-xcframework "${XC_LIB_ARGS[@]}" -output "${XC_OUT}" >/dev/null
  log "XCFramework written to: ${XC_OUT}"
}

# Copy staged headers into the SwiftPM C shim (Sources/Clibaom/include/aom)
install_headers_into_spm() {
  local staged_headers="$1"  # e.g., $BUILD_DIR/headers
  local src="$staged_headers/dav1d/"
  local dest="$SPM_HEADERS_DEST"
  echo "==> Installing headers into SwiftPM shim: $dest"
  mkdir -p "$dest"
  rsync -a --delete "$src" "$dest/"
}

# Copy xcframework into the SwiftPM target (Sources)
install_framework_into_spm() {
  local src="$XC_OUT"
  local dest="$SPM_XC_DEST"
  echo "==> Installing xcframework into SwiftPM target: $dest"
  mkdir -p "$dest"
  rsync -a --delete "$src" "$dest/"
}

# ======================================
# Build Matrix
# ======================================
main() {
  ensure_tools
  ensure_checkout

  # Shared headers used by every slice (public API only)
  SHARED_HEADERS_DIR="${BUILD_DIR}/headers"
  mkdir -p "${SHARED_HEADERS_DIR}/dav1d"

  # Copy public headers (only .h files from include/dav1d)
  rsync -a \
    --include='*/' \
    --include='*.h' \
    --exclude='*' \
    "${SRC_DIR}/include/dav1d/" "${SHARED_HEADERS_DIR}/dav1d/"

  XC_LIB_ARGS=()

  # iOS device (arm64)
  build_one "ios-arm64" "arm64-apple-ios${IOS_MIN}" iphoneos "miphoneos-version-min" "${IOS_MIN}" 1

  # iOS Simulator (arm64 + x86_64)
  build_one "iossim-arm64"  "arm64-apple-ios${IOS_SIM_MIN}-simulator"  iphonesimulator "mios-simulator-version-min" "${IOS_SIM_MIN}" 0
  build_one "iossim-x86_64" "x86_64-apple-ios${IOS_SIM_MIN}-simulator" iphonesimulator "mios-simulator-version-min" "${IOS_SIM_MIN}" 0

  IOSSIM_UNI="${BUILD_DIR}/universal/iossim/libdav1d.a"
  mkdir -p "$(dirname "${IOSSIM_UNI}")"
  make_universal "${IOSSIM_UNI}" \
    "${BUILD_DIR}/build-iossim-arm64/src/libdav1d.a" \
    "${BUILD_DIR}/build-iossim-x86_64/src/libdav1d.a"
  strip_lib "${IOSSIM_UNI}"
  XC_LIB_ARGS+=("-library" "${IOSSIM_UNI}" "-headers" "${SHARED_HEADERS_DIR}")

  # macOS (arm64 + x86_64)
  build_one "macos-arm64"  "arm64-apple-macosx${MACOS_MIN}"  macosx "mmacosx-version-min" "${MACOS_MIN}" 0
  build_one "macos-x86_64" "x86_64-apple-macosx${MACOS_MIN}" macosx "mmacosx-version-min" "${MACOS_MIN}" 0

  MACOS_UNI="${BUILD_DIR}/universal/macos/libdav1d.a"
  mkdir -p "$(dirname "${MACOS_UNI}")"
  make_universal "${MACOS_UNI}" \
    "${BUILD_DIR}/build-macos-arm64/src/libdav1d.a" \
    "${BUILD_DIR}/build-macos-x86_64/src/libdav1d.a"
  strip_lib "${MACOS_UNI}"
  XC_LIB_ARGS+=("-library" "${MACOS_UNI}" "-headers" "${SHARED_HEADERS_DIR}")

  # Mac Catalyst (arm64 + x86_64) — macABI
  build_one "catalyst-arm64"  "arm64-apple-ios${CATALYST_IOS_MIN}-macabi"  macosx "miphoneos-version-min" "${CATALYST_IOS_MIN}" 0
  build_one "catalyst-x86_64" "x86_64-apple-ios${CATALYST_IOS_MIN}-macabi" macosx "miphoneos-version-min" "${CATALYST_IOS_MIN}" 0

  CATALYST_UNI="${BUILD_DIR}/universal/catalyst/libdav1d.a"
  mkdir -p "$(dirname "${CATALYST_UNI}")"
  make_universal "${CATALYST_UNI}" \
    "${BUILD_DIR}/build-catalyst-arm64/src/libdav1d.a" \
    "${BUILD_DIR}/build-catalyst-x86_64/src/libdav1d.a"
  strip_lib "${CATALYST_UNI}"
  XC_LIB_ARGS+=("-library" "${CATALYST_UNI}" "-headers" "${SHARED_HEADERS_DIR}")

  # tvOS device (arm64)
  build_one "tvos-arm64" "arm64-apple-tvos${TVOS_MIN}" appletvos "mappletvos-version-min" "${TVOS_MIN}" 1

  # tvOS Simulator (arm64 + x86_64)
  build_one "tvossim-arm64"  "arm64-apple-tvos${TVOS_MIN}-simulator"  appletvsimulator "mtvos-simulator-version-min" "${TVOS_MIN}" 0
  build_one "tvossim-x86_64" "x86_64-apple-tvos${TVOS_MIN}-simulator" appletvsimulator "mtvos-simulator-version-min" "${TVOS_MIN}" 0

  TVOSSIM_UNI="${BUILD_DIR}/universal/tvossim/libdav1d.a"
  mkdir -p "$(dirname "${TVOSSIM_UNI}")"
  make_universal "${TVOSSIM_UNI}" \
    "${BUILD_DIR}/build-tvossim-arm64/src/libdav1d.a" \
    "${BUILD_DIR}/build-tvossim-x86_64/src/libdav1d.a"
  strip_lib "${TVOSSIM_UNI}"
  XC_LIB_ARGS+=("-library" "${TVOSSIM_UNI}" "-headers" "${SHARED_HEADERS_DIR}")

  # Optional: watchOS (sim only needed for most apps)
  if [[ "${ENABLE_WATCHOS:-0}" == "1" ]]; then
    # watchOS device (armv7k only)
    build_one "watchos-armv7k" "armv7k-apple-watchos${WATCHOS_MIN}" watchos "mwatchos-version-min" "${WATCHOS_MIN}" 1

    # watchOS Simulator (x86_64 + arm64) — build thin, then lipo
    build_one "watchsim-x86_64" "x86_64-apple-watchos${WATCHOS_MIN}-simulator" watchsimulator "mwatchos-simulator-version-min" "${WATCHOS_MIN}" 0
    build_one "watchsim-arm64"  "arm64-apple-watchos${WATCHOS_MIN}-simulator"  watchsimulator "mwatchos-simulator-version-min" "${WATCHOS_MIN}" 0

    WATCHOS_SIM_UNI="${BUILD_DIR}/universal/watchsim/libdav1d.a"
    mkdir -p "$(dirname "${WATCHOS_SIM_UNI}")"
    make_universal "${WATCHOS_SIM_UNI}" \
      "${BUILD_DIR}/build-watchsim-x86_64/src/libdav1d.a" \
      "${BUILD_DIR}/build-watchsim-arm64/src/libdav1d.a"
    strip_lib "${WATCHOS_SIM_UNI}"
    XC_LIB_ARGS+=("-library" "${WATCHOS_SIM_UNI}" "-headers" "${SHARED_HEADERS_DIR}")
  fi

  create_xcframework

  # Optional: install framework and headers into SwiftPM shim
  if [[ "$COPY_TO_SPM" == "1" ]]; then
    install_framework_into_spm
    install_headers_into_spm "$SHARED_HEADERS_DIR"
  fi

  log "Done."
}

main "$@"
