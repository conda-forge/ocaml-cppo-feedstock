# ==============================================================================
# Build Helper Functions (Standalone Recipe Version)
# ==============================================================================
# Simplified helper functions for standalone conda-forge recipes.
# ==============================================================================

# ==============================================================================
# PLATFORM DETECTION
# ==============================================================================

is_macos() { [[ "${target_platform}" == "osx-"* ]]; }
is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_non_unix() { [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; }
is_cross_compile() {
  # 1. conda-build's own flag, when it survives activation ordering.
  [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]] && return 0
  # 2. explicit platform pair, when both reach the shell.
  [[ -n "${build_platform:-}" && -n "${target_platform:-}" \
     && "${build_platform}" != "${target_platform}" ]] && return 0
  # 3. target subdir vs the machine we are actually running on.
  #    target_platform is reliably exported (build.sh writes it to
  #    etc/conda/test-files/target-platform).
  if [[ -n "${target_platform:-}" ]]; then
    case "$(uname -s):$(uname -m):${target_platform}" in
      Linux:x86_64:linux-64|Linux:aarch64:linux-aarch64|Linux:ppc64le:linux-ppc64le) ;;
      Darwin:x86_64:osx-64|Darwin:arm64:osx-arm64) ;;
      *NT*:*:win-64|MSYS*:*:win-64|MINGW*:*:win-64|CYGWIN*:*:win-64) ;;
      *) return 0 ;;
    esac
  fi
  return 1
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

warn() { echo "WARNING: $*" >&2; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# Get compiler path based on type and toolchain
get_compiler() {
  local compiler_type="${1}"  # "c" or "cxx"
  local toolchain_prefix="${2:-}"

  local c_compiler cxx_compiler
  if [[ -n "${toolchain_prefix}" ]]; then
    if [[ "${toolchain_prefix}" == *"apple-darwin"* ]]; then
      c_compiler="${toolchain_prefix}-clang"
      cxx_compiler="${toolchain_prefix}-clang++"
    else
      c_compiler="${toolchain_prefix}-gcc"
      cxx_compiler="${toolchain_prefix}-g++"
    fi
  else
    if is_macos; then
      c_compiler="clang"
      cxx_compiler="clang++"
    else
      c_compiler="gcc"
      cxx_compiler="g++"
    fi
  fi

  if [[ "${compiler_type}" == "c" ]]; then
    echo "${c_compiler}"
  else
    echo "${cxx_compiler}"
  fi
}

# Resolves the TARGET triplet. gcc_linux-64 activation overwrites
# CONDA_TOOLCHAIN_HOST with the BUILD triplet after ocaml_activate.sh runs, so
# prefer OCAML_CROSS_TARGET (set by ocaml_cross_activate.sh) when present.
target_triplet() {
  echo "${OCAML_CROSS_TARGET:-${CONDA_TOOLCHAIN_HOST:-${HOST:-}}}"
}

get_target_c_compiler() { get_compiler "c" "$(target_triplet)"; }
get_target_cxx_compiler() { get_compiler "cxx" "$(target_triplet)"; }

# ==============================================================================
# CROSS-COMPILATION SETUP FUNCTIONS
# ==============================================================================

swap_ocaml_compilers() {
  echo "  Swapping OCaml compilers to cross-compilers..."
  local triplet="$(target_triplet)"
  pushd "${BUILD_PREFIX}/bin" > /dev/null
    for tool in ocamlc ocamldep ocamlopt ocamlobjinfo; do
      if [[ -f "${tool}" ]] || [[ -L "${tool}" ]]; then
        mv "${tool}" "${tool}.build"
        ln -sf "${triplet}-${tool}" "${tool}"
      fi
      if [[ -f "${tool}.opt" ]] || [[ -L "${tool}.opt" ]]; then
        mv "${tool}.opt" "${tool}.opt.build"
        ln -sf "${triplet}-${tool}.opt" "${tool}.opt"
      fi
    done
  popd > /dev/null
}

setup_cross_c_compilers() {
  echo "  Setting up C/C++ cross-compiler symlinks..."
  local target_cc="$(get_target_c_compiler)"
  local target_cxx="$(get_target_cxx_compiler)"

  pushd "${BUILD_PREFIX}/bin" > /dev/null
    for tool in gcc cc; do
      if [[ -f "${tool}" ]] || [[ -L "${tool}" ]]; then
        mv "${tool}" "${tool}.build" 2>/dev/null || true
      fi
      ln -sf "${target_cc}" "${tool}"
    done
    for tool in g++ c++; do
      if [[ -f "${tool}" ]] || [[ -L "${tool}" ]]; then
        mv "${tool}" "${tool}.build" 2>/dev/null || true
      fi
      ln -sf "${target_cxx}" "${tool}"
    done
  popd > /dev/null
}

configure_cross_environment() {
  echo "  Configuring cross-compilation environment variables..."
  export CONDA_OCAML_CC="$(get_target_c_compiler)"
  if is_macos; then
    export CONDA_OCAML_MKEXE="${CONDA_OCAML_CC}"
    export CONDA_OCAML_MKDLL="${CONDA_OCAML_CC} -dynamiclib"
  else
    export CONDA_OCAML_MKEXE="${CONDA_OCAML_CC} -Wl,-E -ldl"
    export CONDA_OCAML_MKDLL="${CONDA_OCAML_CC} -shared"
  fi

  # Resolve the target triplet via target_triplet(); macOS's conda-forge
  # compiler activation sets neither OCAML_CROSS_TARGET, CONDA_TOOLCHAIN_HOST,
  # nor HOST, so we fall back to discovering the triplet from the installed
  # "<triplet>-ocamlc" wrapper in BUILD_PREFIX/bin.
  local triplet
  triplet="$(target_triplet)"
  if [[ -z "${triplet}" ]]; then
    local ocamlc_matches=("${BUILD_PREFIX}/bin/"*-ocamlc)
    if [[ -f "${ocamlc_matches[0]:-}" ]] && [[ ${#ocamlc_matches[@]} -eq 1 ]]; then
      local ocamlc_basename
      ocamlc_basename="$(basename "${ocamlc_matches[0]}")"
      triplet="${ocamlc_basename%-ocamlc}"
    elif [[ ${#ocamlc_matches[@]} -gt 1 ]]; then
      fail "Ambiguous target triplet: multiple *-ocamlc files found in ${BUILD_PREFIX}/bin: ${ocamlc_matches[*]}"
    fi
  fi
  if [[ -z "${triplet}" ]]; then
    fail "Could not resolve target triplet: OCAML_CROSS_TARGET, CONDA_TOOLCHAIN_HOST, and HOST are all unset, and no unique *-ocamlc file was found in ${BUILD_PREFIX}/bin"
  fi
  echo "  Resolved target triplet: ${triplet} (OCAML_CROSS_TARGET=${OCAML_CROSS_TARGET:-unset}, CONDA_TOOLCHAIN_HOST=${CONDA_TOOLCHAIN_HOST:-unset})"

  export CONDA_OCAML_AR="${triplet}-ar"
  export CONDA_OCAML_AS="${triplet}-as"
  export CONDA_OCAML_LD="${triplet}-ld"
  export QEMU_LD_PREFIX="${BUILD_PREFIX}/${triplet}/sysroot"

  local cross_ocaml_lib="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${triplet}/lib/ocaml"
  echo "  Cross OCaml lib path: ${cross_ocaml_lib}"
  if [[ ! -d "${cross_ocaml_lib}" ]]; then
    fail "Cross OCaml lib directory not found for target triplet '${triplet}': expected ${cross_ocaml_lib}"
  fi
  export OCAMLLIB="${cross_ocaml_lib}"
  export LIBRARY_PATH="${cross_ocaml_lib}:${PREFIX}/lib:${LIBRARY_PATH:-}"
  export LDFLAGS="-L${cross_ocaml_lib} -L${PREFIX}/lib ${LDFLAGS:-}"
}

create_macos_ocamlmklib_wrapper() {
  echo "  Creating macOS ocamlmklib wrapper..."
  local real_ocamlmklib="${BUILD_PREFIX}/bin/ocamlmklib"

  if [[ -f "${real_ocamlmklib}" ]] && [[ ! -f "${real_ocamlmklib}.real" ]]; then
    mv "${real_ocamlmklib}" "${real_ocamlmklib}.real"
    cat > "${real_ocamlmklib}" << 'WRAPPER_EOF'
#!/bin/bash
exec "${0}.real" -ldopt "-Wl,-undefined,dynamic_lookup" "$@"
WRAPPER_EOF
    chmod +x "${real_ocamlmklib}"
  fi
}

patch_ocaml_makefile_config() {
  echo "  Patching OCaml Makefile.config for target architecture..."
  local ocaml_lib=$(ocamlc -where)
  local ocaml_config="${ocaml_lib}/Makefile.config"

  if [[ -f "${ocaml_config}" ]]; then
    cp "${ocaml_config}" "${ocaml_config}.bak"
    local target_cc="$(get_target_c_compiler)"
    local triplet="$(target_triplet)"
    sed -i "s|^CC=.*|CC=${target_cc}|" "${ocaml_config}"
    sed -i "s|^NATIVE_C_COMPILER=.*|NATIVE_C_COMPILER=${target_cc}|" "${ocaml_config}"
    sed -i "s|^BYTECODE_C_COMPILER=.*|BYTECODE_C_COMPILER=${target_cc}|" "${ocaml_config}"
    sed -i "s|^PACKLD=.*|PACKLD=${triplet}-ld -r -o \$(EMPTY)|" "${ocaml_config}"
    sed -i "s|^ASM=.*|ASM=${triplet}-as|" "${ocaml_config}"
    sed -i "s|^TOOLPREF=.*|TOOLPREF=${triplet}-|" "${ocaml_config}"
  fi
}
