#!/usr/bin/env bash
set -euxo pipefail

# ==============================================================================
# CPPO BUILD SCRIPT (Standalone Recipe)
# ==============================================================================
# Build the cppo preprocessor for OCaml using Dune.
# Standalone version - source extracts to ${SRC_DIR} directly.
#
# NOTE: cppo is published to the TARGET subdir, so the cppo binary built
# here MUST be TARGET-arch, not BUILD-arch.
# ==============================================================================

source "${RECIPE_DIR}/building/build_functions.sh"

# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================

cd "${SRC_DIR}"

# macOS: OCaml compiler has @rpath/libzstd.1.dylib embedded but rpath doesn't
# resolve in build environment. Set DYLD_FALLBACK_LIBRARY_PATH so executables
# can find libzstd at runtime.
if is_macos; then
  export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

# Windows: Set install prefix and ensure OCaml binaries are in PATH
if is_non_unix; then
  export CPPO_INSTALL_PREFIX="${_PREFIX_}/Library"
  # BUILD_PREFIX is a Win32 path (e.g. D:\bld\...). Appending it raw into a
  # colon-delimited PATH leaves a drive colon mid-list, which MSYS2's automatic
  # PATH conversion then splits on and shreds when it spawns a native process.
  # Use the MSYS2 (/d/bld/...) form instead.
  BUILD_PREFIX_POSIX="$(cygpath -u "${BUILD_PREFIX}")"
  export PATH="${BUILD_PREFIX_POSIX}/bin:${BUILD_PREFIX_POSIX}/Library/bin:${PATH}"

  echo "=== Windows build environment ==="
  echo "Install prefix: ${CPPO_INSTALL_PREFIX}"
  echo "PATH: ${PATH}"
else
  export CPPO_INSTALL_PREFIX="${PREFIX}"
fi

# Set OCAMLPATH so dune can find ocamlbuild package (META in lib/ocaml/ocamlbuild/).
# Native builds only: under cross-compilation configure_cross_environment points
# OCAMLLIB at the cross tree, and findlib searches OCAMLPATH before the stdlib dir,
# so a native lib/ocaml here would let dune resolve NATIVE unix.cmxa / str.cmxa into
# a target-arch link.
if ! is_cross_compile; then
  if is_non_unix; then
    export OCAMLPATH="${BUILD_PREFIX}/Library/lib/ocaml:${OCAMLPATH:-}"
  else
    export OCAMLPATH="${BUILD_PREFIX}/lib/ocaml:${OCAMLPATH:-}"
  fi
fi

# ==============================================================================
# PACKAGE SELECTION
# ==============================================================================
# cppo_ocamlbuild is built unconditionally alongside cppo.

DUNE_PACKAGES="cppo,cppo_ocamlbuild"

echo "=== Build configuration ==="
echo "  DUNE_PACKAGES: ${DUNE_PACKAGES}"

# ==============================================================================
# PLATFORM-SPECIFIC BUILD
# ==============================================================================

# Debug: Show cross-compilation environment
echo "=== Cross-compilation detection ==="
echo "  CONDA_BUILD_CROSS_COMPILATION: ${CONDA_BUILD_CROSS_COMPILATION:-not set}"
echo "  build_platform: ${build_platform:-not set}"
echo "  target_platform: ${target_platform:-not set}"
echo "  is_cross_compile: $(is_cross_compile && echo 'true' || echo 'false')"

if is_cross_compile; then
  # ===========================================================================
  # CROSS-COMPILATION PATH
  # ===========================================================================
  echo "=== Cross-compilation build ==="
  # cppo is published to the TARGET subdir, so the cppo binary built here
  # MUST be TARGET-arch (build_platform=${build_platform}, target_platform=${target_platform}).

  swap_ocaml_compilers
  setup_cross_c_compilers
  configure_cross_environment
  if is_macos; then
    create_macos_ocamlmklib_wrapper
  fi

  echo "  ocamlc: $(which ocamlc)"
  ocamlc -version
  DETECTED_ARCH=$(ocamlc -config | grep "^architecture:" | awk '{print $2}')
  echo "  Detected OCaml target architecture: ${DETECTED_ARCH:-(undetermined)}"
  echo "  OCAMLLIB: ${OCAMLLIB:-not set}"

  # Build cppo using dune (cppo uses dune build system)
  if command -v dune &>/dev/null; then
    echo "Building cppo with dune..."
    dune build --profile=release -p "${DUNE_PACKAGES}"
  else
    echo "ERROR: dune not found - cppo requires dune build system"
    exit 1
  fi

elif is_non_unix; then
  # ===========================================================================
  # WINDOWS BUILD PATH
  # ===========================================================================
  echo "=== Windows build ==="

  # OCaml reports its own C toolchain: msvc on the MSVC port, cc on mingw.
  # grep -a: ocamlc -config output can trip grep's binary detection.
  ocaml_ccomp_type="$(ocamlc -config 2>/dev/null | grep -a '^ccomp_type:' | awk '{print $2}')"
  if [[ "${ocaml_ccomp_type}" == "msvc" ]]; then
    # Measured on menhir: on this lane the inherited PATH is roughly twice as
    # long as on the mingw lane - the MSVC/SDK block appears twice and conda
    # prefixes appear about 8 times - and MSYS2 hands native children an EMPTY
    # PATH instead of converting it. Fix: build a short PATH from scratch
    # instead of prepending. /usr/bin is kept so bash's own tools resolve.
    ml64_dir="$(dirname "$(command -v ml64)")"
    export PATH="${BUILD_PREFIX_POSIX}/Library/bin:${BUILD_PREFIX_POSIX}/bin:${ml64_dir}:/usr/bin:/c/Windows/System32:/c/Windows"
  fi
  echo "  ocamlc ccomp_type: ${ocaml_ccomp_type:-(undetermined)}"
  echo "  ml64: $(command -v ml64 || echo 'NOT FOUND')"
  echo "  cygpath: $(command -v cygpath || echo 'NOT FOUND')"

  # dune's windows cache layout mis-handles mixed path separators and dies in
  # mkdir_p on $SRC_DIR/dune/db. The cache buys nothing in a one-shot CI build.
  export DUNE_CACHE=disabled

  # Build cppo using dune
  if command -v dune &>/dev/null; then
    echo "Building cppo with dune..."
    dune build --profile=release -p "${DUNE_PACKAGES}"
  else
    echo "ERROR: dune not found - cppo requires dune build system"
    exit 1
  fi

else
  # ===========================================================================
  # NATIVE UNIX BUILD (Linux/macOS native)
  # ===========================================================================
  echo "=== Native build ==="

  # Build cppo using dune
  if command -v dune &>/dev/null; then
    echo "Building cppo with dune..."
    dune build --profile=release -p "${DUNE_PACKAGES}"
  else
    echo "ERROR: dune not found - cppo requires dune build system"
    exit 1
  fi
fi

# ==============================================================================
# INSTALL
# ==============================================================================

dune install --prefix="${CPPO_INSTALL_PREFIX}" --libdir="${CPPO_INSTALL_PREFIX}"/lib/ocaml ${DUNE_PACKAGES//,/ }

# ==============================================================================
# WRITE OCAML BUILD VERSION FOR TESTS
# ==============================================================================
# Tests need to know the OCaml version used during build to distinguish
# between known bugs (OCaml <= 5.3.0) and real failures (OCaml >= 5.4.0)

TEST_FILES_DIR="${PREFIX}/etc/conda/test-files"
mkdir -p "${TEST_FILES_DIR}"
OCAML_BUILD_VERSION=$(ocamlc -version)
echo "${OCAML_BUILD_VERSION}" > "${TEST_FILES_DIR}/ocaml-build-version"
echo "Wrote OCaml build version ${OCAML_BUILD_VERSION} to ${TEST_FILES_DIR}/ocaml-build-version"

echo "${target_platform}" > "${TEST_FILES_DIR}/target-platform"
echo "Wrote target platform ${target_platform} to ${TEST_FILES_DIR}/target-platform"

# ==============================================================================
# VERIFY INSTALLATION
# ==============================================================================

# Check for cppo binary in the correct location
if is_non_unix; then
  CPPO_BIN="${CPPO_INSTALL_PREFIX}/bin/cppo.exe"
  ALT_CPPO_BIN="${CPPO_INSTALL_PREFIX}/bin/cppo"
else
  CPPO_BIN="${CPPO_INSTALL_PREFIX}/bin/cppo"
  ALT_CPPO_BIN="${CPPO_INSTALL_PREFIX}/bin/cppo.exe"
fi

if [[ -f "${CPPO_BIN}" ]] || [[ -f "${ALT_CPPO_BIN}" ]]; then
  # Use whichever exists
  [[ -f "${CPPO_BIN}" ]] && ACTUAL_BIN="${CPPO_BIN}" || ACTUAL_BIN="${ALT_CPPO_BIN}"

  echo "=== cppo installed successfully ==="
  echo "Binary: ${ACTUAL_BIN}"

  # For cross-compilation, verify the installed binary matches the TARGET
  # architecture: cppo is published to the TARGET subdir, so it must be
  # TARGET-arch.
  if is_cross_compile; then
    case "${target_platform}" in
      linux-64) EXPECTED_ARCH_TOKEN="x86-64" ;;
      osx-64) EXPECTED_ARCH_TOKEN="x86_64" ;;
      linux-aarch64) EXPECTED_ARCH_TOKEN="aarch64" ;;
      osx-arm64) EXPECTED_ARCH_TOKEN="arm64" ;;
      linux-ppc64le) EXPECTED_ARCH_TOKEN="PowerPC" ;;
      *)
        echo "ERROR: unrecognised target_platform '${target_platform}' - no known 'file' architecture token to assert against"
        exit 1
        ;;
    esac
    FILE_OUTPUT=$(file "${ACTUAL_BIN}")
    echo "${FILE_OUTPUT}"
    if echo "${FILE_OUTPUT}" | grep -q "${EXPECTED_ARCH_TOKEN}"; then
      echo "[OK] Binary is correctly built for TARGET architecture (${target_platform}, expected '${EXPECTED_ARCH_TOKEN}')"
    else
      echo "ERROR: cppo binary architecture mismatch"
      echo "  target_platform: ${target_platform}"
      echo "  expected 'file' token: ${EXPECTED_ARCH_TOKEN}"
      echo "  actual 'file' output: ${FILE_OUTPUT}"
      exit 1
    fi
  elif ! is_non_unix; then
    # Native Unix build - show file info (optional)
    file "${ACTUAL_BIN}" || true
  fi

  # Windows: file command unavailable, just verify binary exists and is non-empty
  if is_non_unix; then
    if [[ -s "${ACTUAL_BIN}" ]]; then
      echo "[OK] Binary exists and is non-empty"
    else
      echo "WARNING: Binary is empty or missing"
      exit 1
    fi
  fi
else
  echo "ERROR: cppo binary not found at ${CPPO_BIN} or ${ALT_CPPO_BIN}"
  exit 1
fi

echo "=== cppo build complete ==="
