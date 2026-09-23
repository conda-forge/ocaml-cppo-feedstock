#!/usr/bin/env python3
"""Test: cppo binary architecture validation

Verifies cppo binary is built for a recognized architecture.
Works cross-platform using Python's struct module for PE parsing on Windows.
"""

import platform
import shutil
import struct
import subprocess
import sys

from test_utils import get_target_platform, handle_test_result

# Token that `file` emits for a native binary of each conda target platform.
# Unrecognized target platforms must fail loudly - no permissive fallback.
UNIX_ARCH_TOKENS = {
    "linux-64": "x86-64",
    "osx-64": "x86_64",
    "linux-aarch64": "aarch64",
    "osx-arm64": "arm64",
    "linux-ppc64le": "PowerPC",
}


def check_unix_arch(binary_path):
    """Check architecture using file command on Unix, against the target platform."""
    result = subprocess.run(
        ["file", binary_path],
        capture_output=True,
        text=True,
        check=False,
    )
    file_output = result.stdout.strip()
    print(f"File info: {file_output}")

    try:
        target_platform = get_target_platform()
    except FileNotFoundError as e:
        print(f"[FAIL] {e}")
        return False

    expected_token = UNIX_ARCH_TOKENS.get(target_platform)
    if expected_token is None:
        print(f"[FAIL] Unrecognized target platform: {target_platform}")
        return False

    if expected_token.lower() in file_output.lower():
        print(f"  Target platform: {target_platform} (expected token: {expected_token})")
        print("[OK] Architecture check passed")
        return True

    print(f"[FAIL] Architecture mismatch for target platform {target_platform}")
    print(f"  Expected token: {expected_token}")
    print(f"  file output: {file_output}")
    return False


# PE machine type expected for each conda target platform.
WINDOWS_ARCH_MACHINE_TYPES = {
    "win-64": 0x8664,
    "win-arm64": 0xAA64,
}


def check_windows_arch(binary_path):
    """Check PE architecture on Windows using native Python, against the target platform."""
    try:
        with open(binary_path, "rb") as f:
            dos_header = f.read(64)
            if dos_header[:2] != b"MZ":
                print("[FAIL] Not a valid DOS/PE file")
                return False

            pe_offset = struct.unpack("<I", dos_header[0x3C:0x40])[0]
            f.seek(pe_offset)
            pe_sig = f.read(4)
            if pe_sig != b"PE\x00\x00":
                print("[FAIL] Invalid PE signature")
                return False

            machine_type = struct.unpack("<H", f.read(2))[0]

            machine_names = {
                0x8664: "AMD64 (x86-64)",
                0x014C: "i386 (x86)",
                0xAA64: "ARM64",
            }
            name = machine_names.get(machine_type, f"unknown (0x{machine_type:04X})")
            print(f"  Machine type: {name}")

            if machine_type == 0x014C:
                print("[FAIL] Expected 64-bit, got 32-bit x86")
                return False

            try:
                target_platform = get_target_platform()
            except FileNotFoundError as e:
                print(f"[FAIL] {e}")
                return False

            expected_machine = WINDOWS_ARCH_MACHINE_TYPES.get(target_platform)
            if expected_machine is None:
                print(f"[FAIL] Unrecognized target platform: {target_platform}")
                return False

            if machine_type != expected_machine:
                print(f"[FAIL] Architecture mismatch for target platform {target_platform}")
                print(f"  Expected machine type: 0x{expected_machine:04X}")
                print(f"  Actual machine type: 0x{machine_type:04X}")
                return False

            print("[OK] Architecture check passed")
            return True

    except Exception as e:
        print(f"[FAIL] Failed to read PE header: {e}")
        return False


def main():
    print("=== cppo Binary Architecture Tests ===")

    cppo_path = shutil.which("cppo")
    if not cppo_path:
        print("[FAIL] cppo not found in PATH")
        return 1

    if platform.system() == "Windows" and not cppo_path.endswith(".exe"):
        cppo_path += ".exe"

    print(f"Binary: {cppo_path}")

    if platform.system() == "Windows":
        success = check_windows_arch(cppo_path)
    else:
        success = check_unix_arch(cppo_path)

    return handle_test_result("cppo architecture tests", success)


if __name__ == "__main__":
    sys.exit(main())
