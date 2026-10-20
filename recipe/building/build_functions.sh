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
      Linux:riscv64:linux-riscv64|Linux:s390x:linux-s390x) ;;
      Darwin:x86_64:osx-64|Darwin:arm64:osx-arm64) ;;
      *NT*:*:win-64|MSYS*:*:win-64|MINGW*:*:win-64|CYGWIN*:*:win-64) ;;
      *NT*:*:win-arm64|MSYS*:*:win-arm64|MINGW*:*:win-arm64|CYGWIN*:*:win-arm64) ;;
      *) return 0 ;;
    esac
  fi
  return 1
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

warn() { echo "WARNING: $*" >&2; }

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
