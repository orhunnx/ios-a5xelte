#!/usr/bin/env python3
"""Cross-build the bounded SPIR-V/Midgard compiler as a native iOS executable.

Uses an unmodified full Mesa 26.2.4 release archive. All extraction, generated
Meson integration, static libraries and executable stay in the output directory.
Meson, Mako, PyYAML and packaging must be installed for the invoking Python.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


def run(command: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, check=True, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="", flush=True)
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mesa_archive", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args()
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    archive = args.mesa_archive.resolve()
    source = out / "src" / "mesa-26.2.4"
    build = out / "build"
    compiler = Path(__file__).resolve().parents[1] / "spirv_pair_midgard.c"
    family_dir = Path(__file__).resolve().parents[1] / "families"
    generic_profile = Path(__file__).resolve().parents[1] / "generic" / "ios_602_profile.h"
    archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    if archive_sha != "bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9":
        raise ValueError("requires the pinned official Mesa26.2.4 archive")
    if not source.exists():
        source.parent.mkdir(exist_ok=True)
        with tarfile.open(archive) as tar:
            tar.extractall(source.parent, filter="data")
    if (source / "VERSION").read_text().strip() != "26.2.4":
        raise ValueError("requires the full Mesa 26.2.4 release")
    sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).strip()
    clang = run(["xcrun", "--sdk", "iphoneos", "--find", "clang"]).strip()
    clangxx = run(["xcrun", "--sdk", "iphoneos", "--find", "clang++"]).strip()
    ar = run(["xcrun", "--sdk", "iphoneos", "--find", "ar"]).strip()
    cross = out / "ios-arm64.ini"
    target_args = ["-target", "arm64-apple-ios16.0", "-mcpu=cortex-a53",
                   "-march=armv8-a+crypto", "-isysroot", sdk]
    cross.write_text(
        "[binaries]\n" +
        f"c = {[clang, *target_args]!r}\n" +
        f"cpp = {[clangxx, *target_args]!r}\n" +
        f"objc = {[clang, *target_args]!r}\n" +
        f"ar = {ar!r}\nstrip = '/usr/bin/strip'\n" +
        "[host_machine]\nsystem = 'darwin'\ncpu_family = 'aarch64'\n" +
        "cpu = 'arm64'\nendian = 'little'\n" +
        "[properties]\nneeds_exe_wrapper = true\n" +
        f"sys_root = {sdk!r}\n" +
        "[built-in options]\nc_link_args = ['-Wl,-dead_strip']\n" +
        "cpp_link_args = ['-Wl,-dead_strip']\n")
    # Only build-system integration changes inside the private extracted copy.
    marker = ("\n# A5 iOS compiler executable (private build integration only)\n"
              "subdir('src/panfrost')\nsubdir('a5-ios')\n")
    root_meson = source / "meson.build"
    compiler_mode = ("# A5 iOS standalone compiler needs full NIR, not the driverless stub.\n"
                     "with_gfx_compute = true\n"
                     "add_project_arguments('-DHAVE_GFX_COMPUTE', language: ['c', 'cpp'])\n"
                     "subdir('src')")
    if compiler_mode not in root_meson.read_text():
        root_meson.write_text(root_meson.read_text().replace(
            "subdir('src')", compiler_mode))
    old_marker = "\n# A5 iOS compiler executable (private build integration only)\nsubdir('a5-ios')\n"
    if old_marker in root_meson.read_text():
        root_meson.write_text(root_meson.read_text().replace(old_marker, ""))
    if marker not in root_meson.read_text():
        with root_meson.open("a") as stream:
            stream.write(marker)
    integration = source / "a5-ios"
    integration.mkdir(exist_ok=True)
    generic_source = integration / "midgard_generic.c"
    generic_source_text = (family_dir / "misc_backend.c").read_text()
    if generic_source_text.count("NIR_PASS(_,nir,nir_lower_variable_initializers,") != 1:
        raise ValueError("shared backend must lower initializers exactly once")
    generic_source.write_text(generic_source_text)
    for name in ("misc_resource_lowering.h", "misc_native_rt.h", "misc_dynamic.h", "misc_anisotropy.h"):
        shutil.copyfile(family_dir / name, integration / name)
    shutil.copyfile(generic_profile, integration / "ios_602_profile.h")
    (integration / "meson.build").write_text(
        "executable('midgard', files(" + repr(str(compiler)) + "),\n"
        "  include_directories: [inc_include, inc_src, inc_panfrost],\n"
        "  dependencies: [idep_vtn, idep_nir, idep_mesautil],\n"
        "  link_with: [libpanfrost_compiler, libpanfrost_midgard_disasm],\n"
        "  c_args: ['-Werror', '-mcpu=cortex-a53', '-march=armv8-a+crypto'], install: false)\n"
        "executable('midgard-generic602', files('midgard_generic.c'),\n"
        "  include_directories: [inc_include, inc_src, inc_panfrost],\n"
        "  dependencies: [idep_vtn, idep_nir, idep_mesautil],\n"
        "  link_with: [libpanfrost_compiler, libpanfrost_midgard_disasm],\n"
        "  c_args: ['-Werror', '-mcpu=cortex-a53', '-march=armv8-a+crypto',\n"
        "           '-DA5_FAMILY_CONFIG=\"ios_602_profile.h\"'], install: false)\n")
    if not (build / "build.ninja").exists():
        run([sys.executable, "-m", "mesonbuild.mesonmain", "setup", str(build),
             str(source), "--cross-file", str(cross),
             "-Dbuildtype=debugoptimized", "-Db_ndebug=false", "-Ddefault_library=static",
             "-Dgallium-drivers=", "-Dvulkan-drivers=", "-Dtools=",
             "-Dplatforms=", "-Dllvm=disabled", "-Degl=disabled", "-Dgles1=disabled",
             "-Dgles2=disabled", "-Dglx=disabled", "-Dzstd=disabled",
             "-Dshader-cache=disabled", "-Dlibunwind=disabled", "-Dvalgrind=disabled",
             "-Dxmlconfig=disabled", "-Dexpat=disabled", "-Dspirv-tools=disabled",
             "-Dbuild-tests=false"])
    run(["ninja", "-j", str(args.jobs), "a5-ios/midgard", "a5-ios/midgard-generic602"], cwd=build)
    executable = out / "midgard"
    shutil.copy2(build / "a5-ios" / "midgard", executable)
    generic_executable = out / "midgard-generic602"
    shutil.copy2(build / "a5-ios" / "midgard-generic602", generic_executable)
    for tool in (executable, generic_executable):
        run(["strip", "-S", "-x", str(tool)])
        run(["codesign", "--force", "--sign", "-", str(tool)])
    load_commands = run(["otool", "-l", str(executable)])
    dependencies = run(["otool", "-L", str(executable)])
    file_info = run(["file", str(executable)])
    header = run(["otool", "-hv", str(executable)])
    if "platform 2" not in load_commands or "executable arm64" not in file_info or \
            "EXECUTE" not in header:
        raise ValueError("output must be an arm64 MH_EXECUTE with iOS platform2")
    dependency_paths = [line.strip().split()[0]
                        for line in dependencies.splitlines()[1:] if line.strip()]
    if any(not path.startswith(("/usr/lib/", "/System/Library/"))
           for path in dependency_paths):
        raise ValueError("host dependency leaked into the iOS executable")
    (out / "build-manifest.json").write_text(json.dumps({
        "mesa_version": "26.2.4", "mesa_archive_sha256": archive_sha,
        "compiler_source_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest(),
        "target": "arm64-apple-ios16.0", "sdk": sdk,
        "nir_validation": True, "executable_bytes": executable.stat().st_size,
        "executable_sha256": hashlib.sha256(
            executable.read_bytes()).hexdigest(), "dependencies": dependency_paths,
        "generic_602_source_sha256": hashlib.sha256(generic_source.read_bytes()).hexdigest(),
        "generic_profile_sha256": hashlib.sha256(generic_profile.read_bytes()).hexdigest(),
        "generic_dynamic_abi_sha256": hashlib.sha256((integration / "misc_dynamic.h").read_bytes()).hexdigest(),
        "generic_helper_sha256": {name: hashlib.sha256((integration / name).read_bytes()).hexdigest()
            for name in ("misc_dynamic.h", "misc_resource_lowering.h", "misc_native_rt.h")},
        "generic_602_executable_sha256": hashlib.sha256(generic_executable.read_bytes()).hexdigest(),
    }, indent=2) + "\n")
    print(executable)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(error.stdout or error, file=sys.stderr)
        raise SystemExit(error.returncode) from error
