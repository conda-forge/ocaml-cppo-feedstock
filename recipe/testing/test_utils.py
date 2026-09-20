#!/usr/bin/env python3
"""Shared test utilities for cppo package tests."""

import os
import platform
from functools import lru_cache
from pathlib import Path


def get_prefix() -> Path:
    """Get the conda prefix path."""
    prefix = os.environ.get("PREFIX", os.environ.get("CONDA_PREFIX", ""))
    if not prefix:
        # Fallback for local testing
        return Path("/usr")
    return Path(prefix)


@lru_cache(maxsize=1)
def get_ocaml_build_version() -> tuple[int, int, int]:
    """Get OCaml version that was used during build.

    Reads from etc/conda/test-files/ocaml-build-version file written during build.

    Returns:
        Tuple of (major, minor, patch) version numbers.
        Returns (0, 0, 0) if version file not found or cannot be parsed.
    """
    prefix = get_prefix()
    version_file = prefix / "etc" / "conda" / "test-files" / "ocaml-build-version"

    try:
        version_str = version_file.read_text().strip()
        parts = version_str.split(".")
        return (int(parts[0]), int(parts[1]), int(parts[2].split("+")[0]))
    except (FileNotFoundError, IndexError, ValueError):
        return (0, 0, 0)


def get_ocaml_build_version_str() -> str:
    """Get OCaml build version as a string."""
    version = get_ocaml_build_version()
    if version == (0, 0, 0):
        return "unknown"
    return f"{version[0]}.{version[1]}.{version[2]}"


def get_target_arch() -> str:
    """Get the target architecture, handling cross-compilation.

    On CI runners, cross-compiled packages run under QEMU but platform.machine()
    returns the HOST arch (x86_64), not the TARGET arch (aarch64/ppc64le).

    Check conda's target_platform env var first, then fall back to platform.machine().

    NOTE: This is used only for non-verification purposes (e.g. selecting a runtime
    workaround). The architecture test must verify against get_target_platform()
    and the actual binary contents, not this function.
    """
    target_platform = os.environ.get("target_platform", "")
    if "aarch64" in target_platform:
        return "aarch64"
    if "ppc64le" in target_platform:
        return "ppc64le"
    if "arm64" in target_platform:
        return "arm64"
    return platform.machine().lower()


def get_target_platform() -> str:
    """Read the conda target platform recorded during build.

    Reads from etc/conda/test-files/target-platform, a file written by
    build.sh containing exactly one line with the conda target platform
    string (e.g. "linux-64", "osx-arm64", "linux-ppc64le").

    Returns:
        The stripped target platform string.

    Raises:
        FileNotFoundError: If the target-platform file does not exist. A
            missing file indicates a packaging problem and must never be
            treated as a silent pass by callers.
    """
    prefix = get_prefix()
    platform_file = prefix / "etc" / "conda" / "test-files" / "target-platform"
    if not platform_file.exists():
        raise FileNotFoundError(
            f"target-platform file not found at {platform_file}; "
            "cannot verify binary architecture"
        )
    return platform_file.read_text().strip()


def handle_test_result(test_name: str, success: bool) -> int:
    """Report a test result honestly, with no version- or arch-based suppression.

    Args:
        test_name: Name of the test for reporting
        success: Whether the test passed

    Returns:
        Exit code: 0 if success, 1 if failure
    """
    if success:
        print(f"\n=== {test_name} passed ===")
        return 0

    print(f"\n=== {test_name} FAILED ===")
    return 1
