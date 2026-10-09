"""Construct and enforce AudioSubs' replaceable LGPL FFmpeg/PyAV runtime.

Only build_lgpl_pyav.ps1 activates MSVC. All downloads are checksum pinned;
changing upstream inputs requires an explicit pin update, never a stock wheel.
"""
from __future__ import annotations

import argparse
import base64
import csv
import ctypes
import hashlib
import importlib.metadata
import io
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "worker/build/lgpl"
MANIFEST = BUILD / "provenance.json"
VERSION = "19.0.1+audiosubs.lgpl"
FFMPEG_COMMIT = "946fcce07b6dcd0331c8cc609192aeff5e1924f8"
INPUTS = {
    "ffmpeg": ("https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz", "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"),
    "msys2": ("https://repo.msys2.org/distrib/x86_64/msys2-base-x86_64-20260927.tar.xz", "ea2f31a0b6ade63914ce441ffb022f0f6aa96982bfefa2326460a26d5fb01322"),
    "make": ("https://repo.msys2.org/msys/x86_64/make-4.4.1-3-x86_64.pkg.tar.zst", "af0bdba17f06fe037f0194069adaa31a8fe45f1a11381501896aea1fae37bd5d"),
    "diffutils": ("https://repo.msys2.org/msys/x86_64/diffutils-3.12-1-x86_64.pkg.tar.zst", "7902c8ce3d4dd69a0f5e98dc9d5c83c17b23314ba486169db57ef6e2835ce3b6"),
    "pyav": ("https://files.pythonhosted.org/packages/90/bc/a2a40e503250fe5d4174471911828f31658864eb69a8a7cb960c715e17b7/av-19.0.1.tar.gz", "08674930eaf1af78a3ed8f93d3ba49383323b3a867e84349d9c399e36f7497da"),
    "setuptools": ("https://files.pythonhosted.org/packages/5d/40/e1e72872c6354b306daef1703549e8e83b4d43cfea356311bf722a043752/setuptools-83.0.0-py3-none-any.whl", "29b23c360f22f414dc7336bb39178cc7bcbf6021ed2733cde173f09dba19abb3"),
    "cython": ("https://files.pythonhosted.org/packages/f4/9b/cd724d91c500116769bdb853450a2197ba3d640dbbe3b02fc54ebdfdbd1b/cython-3.3.0-cp312-cp312-win_amd64.whl", "333449cc0350baedee5a6af27929eac8a71eac4ec59333c45ff476b33c6c660d"),
}
FFMPEG_FLAGS = [
    "--toolchain=msvc", "--arch=x86_64", "--target-os=win64",
    "--disable-autodetect", "--disable-network", "--disable-gpl",
    "--disable-nonfree", "--disable-x86asm", "--enable-shared",
    "--disable-static", "--disable-programs", "--disable-doc", "--disable-debug",
]
LIBRARIES = {"avutil": 61, "avcodec": 63, "avformat": 63, "avdevice": 63, "avfilter": 12, "swscale": 10, "swresample": 7}
DLL_LOADER = '''# AudioSubs LGPL build: retain this handle for nested extension imports.
import os as _lgpl_os
_lgpl_dll_directory = _lgpl_os.add_dll_directory(_lgpl_os.path.dirname(__file__))
'''


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def record(path: Path, url: str | None = None) -> dict:
    result = {"path": str(path.resolve()), "sha256": digest(path)}
    if url:
        result["url"] = url
    return result


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def fetch(name: str) -> Path:
    url, expected = INPUTS[name]
    path = BUILD / "downloads" / url.rsplit("/", 1)[1]
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        temporary = path.with_suffix(path.suffix + ".partial")
        request = urllib.request.Request(url, headers={"User-Agent": "AudioSubs-LGPL-runtime-builder"})
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as target:
            shutil.copyfileobj(response, target)
        if digest(temporary) != expected:
            temporary.unlink()
            raise RuntimeError(f"Checksum mismatch for {url}; pinned upstream input changed. Do not silently accept new inputs.")
        temporary.replace(path)
    if digest(path) != expected:
        raise RuntimeError(f"Pinned input checksum mismatch: {path}")
    return path


def run(*arguments: str | Path, cwd: Path | None = None) -> None:
    subprocess.run([str(value) for value in arguments], cwd=cwd, check=True)


def inspect_libraries(directory: Path) -> list[dict]:
    results = []
    handles = []
    with os.add_dll_directory(str(directory.resolve())):
        for name, major in LIBRARIES.items():
            path = directory / f"{name}-{major}.dll"
            library = ctypes.CDLL(str(path.resolve()))
            handles.append(library)
            values = {}
            for field in ("license", "configuration", "version"):
                function = getattr(library, f"{name}_{field}")
                function.argtypes = []
                function.restype = ctypes.c_uint if field == "version" else ctypes.c_char_p
                value = function()
                values[field] = value if field == "version" else value.decode("utf-8")
            config = values["configuration"]
            if "LGPL" not in values["license"] or re.search(r"--enable-(?:gpl|nonfree)(?:\s|=|$)", config):
                raise RuntimeError(f"Refusing non-LGPL FFmpeg library: {path}: {values}")
            if any(flag not in config for flag in FFMPEG_FLAGS) or re.search(r"--enable-lib\S+", config):
                raise RuntimeError(f"Refusing a nonminimal/external-dependency FFmpeg configuration: {path}")
            if values["version"] >> 16 != major or "--enable-shared" not in config:
                raise RuntimeError(f"Wrong FFmpeg ABI or nonshared build: {path}")
            values.update(name=name, file=path.name, sha256=digest(path))
            results.append(values)
    return results


def install(wheel: Path) -> None:
    run(sys.executable, "-m", "pip", "install", "--no-deps", "--force-reinstall", wheel)
    # pip's RECORD owns stock av.libs. Reject leftovers instead of disguising them
    # as LGPL by selectively removing x264/x265 or renaming DLLs.
    run(sys.executable, Path(__file__).resolve(), "verify")


def verify(bundle: Path | None = None) -> dict:
    if not MANIFEST.exists():
        raise RuntimeError("Missing LGPL provenance; run scripts/build_lgpl_pyav.ps1.")
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if data["schema"] != 1 or data["pyav"]["version"] != VERSION:
        raise RuntimeError("Unsupported LGPL provenance manifest.")
    if data["ffmpeg"]["archive"]["sha256"] != INPUTS["ffmpeg"][1] or data["ffmpeg"].get("build_kind") != "minimal":
        raise RuntimeError("FFmpeg provenance does not match the approved minimal LGPL source build.")
    if any(flag not in data["ffmpeg"]["configuration"] for flag in FFMPEG_FLAGS):
        raise RuntimeError("FFmpeg lacks the required minimal, non-GPL, non-networked configuration.")
    if bundle is None:
        distribution = importlib.metadata.distribution("av")
        if distribution.version != VERSION:
            raise RuntimeError(f"Stock/unapproved PyAV {distribution.version} installed; LGPL build required.")
        package = Path(distribution.locate_file("av"))
        search_root = package.parent
    else:
        search_root = bundle.resolve()
        package = search_root / "_internal/av"
    stamp = package / "_lgpl_provenance.json"
    if not stamp.exists() or json.loads(stamp.read_text(encoding="utf-8")) != data["embedded"]:
        raise RuntimeError(f"PyAV LGPL build stamp missing or mismatched: {package}")
    for path in search_root.rglob("*"):
        if path.is_dir() and path.name.lower().startswith("av.libs"):
            raise RuntimeError(f"Stock PyAV av.libs is forbidden: {path}")
        if path.suffix.lower() == ".dll":
            lower = path.name.lower()
            if any(token in lower for token in ("x264", "x265", "xvid", "postproc")):
                raise RuntimeError(f"GPL codec DLL is forbidden: {path}")
            if re.match(r"(?:lib)?(?:avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample)", lower):
                expected = next((item for item in data["ffmpeg"]["libraries"] if item["file"].lower() == lower), None)
                if expected is None or digest(path) != expected["sha256"]:
                    raise RuntimeError(f"Unapproved FFmpeg DLL copy: {path}")
    for relative, expected in data["pyav"]["extensions"].items():
        path = package / relative
        if not path.exists() or digest(path) != expected:
            raise RuntimeError(f"PyAV extension does not match the locally built wheel: {path}")
    actual = inspect_libraries(package)
    if actual != data["ffmpeg"]["libraries"]:
        raise RuntimeError("Runtime FFmpeg license/configuration/version differs from build provenance.")
    if bundle is None:
        import av
        if av.__version__ != VERSION or av.library_versions["libavcodec"][0] != 63:
            raise RuntimeError("PyAV imported the wrong FFmpeg/PyAV ABI.")
        for name in ("mp3", "aac", "pcm_s16le", "flac", "vorbis", "opus"):
            av.Codec(name, "r")
        for name in ("mp3", "mov", "wav", "flac", "ogg", "aac"):
            if not av.format.ContainerFormat(name).is_input:
                raise RuntimeError(f"Required audio demuxer unavailable: {name}")
        # Ensure normal PyAV imports resolve the approved DLLs, not a DLL on PATH.
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.GetModuleHandleW.argtypes = [ctypes.c_wchar_p]
        kernel.GetModuleHandleW.restype = ctypes.c_void_p
        kernel.GetModuleFileNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint]
        kernel.GetModuleFileNameW.restype = ctypes.c_uint
        for item in actual:
            buffer = ctypes.create_unicode_buffer(32768)
            handle = kernel.GetModuleHandleW(item["file"])
            if not handle or not kernel.GetModuleFileNameW(handle, buffer, len(buffer)):
                raise RuntimeError(f"Cannot identify loaded DLL: {item['file']}")
            if Path(buffer.value).resolve() != (package / item["file"]).resolve():
                raise RuntimeError(f"PyAV loaded FFmpeg outside its replaceable package: {buffer.value}")
    return data


def reuse() -> int:
    if not MANIFEST.exists():
        return 2
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    wheel = Path(data["pyav"]["wheel"]["path"])
    if not wheel.exists() or digest(wheel) != data["pyav"]["wheel"]["sha256"]:
        raise RuntimeError("Cached custom wheel missing/corrupt; use -Rebuild.")
    try:
        installed = importlib.metadata.version("av")
    except importlib.metadata.PackageNotFoundError:
        installed = None
    if installed != VERSION:
        install(wheel)
    else:
        verify()
    return 0


def build_ffmpeg(inputs: dict[str, Path]) -> tuple[Path, Path]:
    portable = BUILD / "tools"
    msys = portable / "msys64"
    if not (msys / "usr/bin/bash.exe").exists():
        portable.mkdir(parents=True, exist_ok=True)
        with tarfile.open(inputs["msys2"]) as archive:
            archive.extractall(portable, filter="data")
    # Coreutils' unrelated link.exe shadows Microsoft's linker in MSYS shells.
    # Rename only our private build-tool copy, never anything on the system.
    unix_link = msys / "usr/bin/link.exe"
    if unix_link.exists():
        unix_link.rename(msys / "usr/bin/link-coreutils.exe")
    bash = msys / "usr/bin/bash.exe"
    environment = os.environ.copy()
    environment["PATH"] = str(msys / "usr/bin") + os.pathsep + environment["PATH"]
    environment["MSYSTEM"] = "MSYS"
    environment["CHERE_INVOKING"] = "1"
    environment["MSYS2_PATH_TYPE"] = "inherit"
    for tool, executable in (("make", "make.exe"), ("diffutils", "cmp.exe")):
        environment["AUDIOSUBS_TOOL_PACKAGE"] = str(inputs[tool].resolve())
        if not (msys / "usr/bin" / executable).exists():
            subprocess.run([str(bash), "--noprofile", "--norc", "-c",
                            'tar --zstd -xf "$(cygpath -u "$AUDIOSUBS_TOOL_PACKAGE")" -C /'],
                           env=environment, check=True)
    source_root = BUILD / "ffmpeg-source"
    if source_root.exists():
        shutil.rmtree(source_root)
    source_root.mkdir()
    with tarfile.open(inputs["ffmpeg"]) as archive:
        archive.extractall(source_root, filter="data")
    source = source_root / "ffmpeg-9.0.2"
    install_root = BUILD / "ffmpeg"
    if install_root.exists():
        shutil.rmtree(install_root)
    install_root.mkdir()
    environment["AUDIOSUBS_FFMPEG_PREFIX"] = str(install_root.resolve())
    recipe = source_root / "build-minimal.sh"
    # Keep paths out of shell interpolation. cygpath translates the prefix;
    # bash inherits the activated MSVC environment (no login/profile reset).
    recipe.write_text(
        'set -eu\n'
        'prefix=$(cygpath -u "$AUDIOSUBS_FFMPEG_PREFIX")\n'
        'bash ./configure --prefix="$prefix" ' + " ".join(FFMPEG_FLAGS) + '\n'
        'make -j' + str(min(os.cpu_count() or 1, 8)) + '\n'
        'make install\n',
        encoding="utf-8", newline="\n")
    subprocess.run([str(bash), "--noprofile", "--norc", str(recipe.resolve()).replace("\\", "/")],
                   cwd=source, env=environment, check=True)
    shutil.copy2(source / "COPYING.LGPLv2.1", install_root / "LICENSE.txt")
    return install_root, source


def build() -> None:
    if not shutil.which("cl") or not shutil.which("lib") or not shutil.which("dumpbin"):
        raise RuntimeError("Run build_lgpl_pyav.ps1 to activate Visual Studio x64 C++ tools.")
    inputs = {name: fetch(name) for name in INPUTS}
    ffmpeg, ffmpeg_source = build_ffmpeg(inputs)
    libraries = inspect_libraries(ffmpeg / "bin")
    for name, major in LIBRARIES.items():
        target = ffmpeg / "lib" / f"{name}.lib"
        if target.exists():
            continue
        # Recreate MSVC import libraries from the actual DLL exports if the
        # selected MSVC toolchain did not emit the unversioned .lib names.
        dll = ffmpeg / "bin" / f"{name}-{major}.dll"
        exports = subprocess.check_output(["dumpbin", "/nologo", "/exports", str(dll)], text=True)
        symbols = re.findall(r"^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\w+)(?:\s+=.*)?\s*$", exports, re.MULTILINE)
        if not symbols:
            raise RuntimeError(f"No DLL exports found: {dll}")
        definition = ffmpeg / "lib" / f"{name}-msvc.def"
        definition.write_text(f"LIBRARY {dll.name}\nEXPORTS\n" + "\n".join(symbols) + "\n", encoding="ascii")
        run("lib", "/nologo", "/machine:x64", f"/def:{definition}", f"/out:{target}")
    source_root = BUILD / "pyav-source"
    if source_root.exists():
        shutil.rmtree(source_root)
    source_root.mkdir()
    with tarfile.open(inputs["pyav"]) as archive:
        archive.extractall(source_root, filter="data")
    source = source_root / "av-19.0.1"
    about = source / "av/about.py"
    contents, count = re.subn(r'(?m)^__version__\s*=\s*[\'\"]19\.0\.1[\'\"]', f'__version__ = "{VERSION}"', about.read_text(encoding="utf-8"))
    if count != 1:
        raise RuntimeError("Pinned PyAV version declaration changed unexpectedly.")
    about.write_text(contents, encoding="utf-8")
    init = source / "av/__init__.py"
    init.write_text(DLL_LOADER + init.read_text(encoding="utf-8"), encoding="utf-8")
    version_header = (ffmpeg / "include/libavutil/ffversion.h").read_text(encoding="utf-8")
    version = re.search(r'#define FFMPEG_VERSION "([^"]+)"', version_header).group(1)
    if version != "9.0.2":
        raise RuntimeError(f"Unexpected minimal FFmpeg source version: {version}")
    ffmpeg_data = {
        "archive": record(inputs["ffmpeg"], INPUTS["ffmpeg"][0]),
        "source_release": record(inputs["ffmpeg"], INPUTS["ffmpeg"][0]),
        "root": str(ffmpeg.resolve()), "version": version, "build_kind": "minimal",
        "source_commit": FFMPEG_COMMIT, "source_url": INPUTS["ffmpeg"][0],
        "source_root": str(ffmpeg_source.resolve()),
        "configure_flags": FFMPEG_FLAGS,
        "build_source_url": "https://github.com/FFmpeg/FFmpeg",
        "build_recipe": str(BUILD / "ffmpeg-source/build-minimal.sh"),
        "build_tools": {name: record(inputs[name], INPUTS[name][0]) for name in ("msys2", "make", "diffutils")},
        "configuration": libraries[0]["configuration"], "libraries": libraries,
        "metadata_files": [str(ffmpeg / "LICENSE.txt"), str(ffmpeg / "include/libavutil/ffversion.h"),
                           str(ffmpeg_source / "ffbuild/config.mak"), str(ffmpeg_source / "ffbuild/config.log"),
                           str(ffmpeg_source / "config.h"), str(ffmpeg_source / "config_components.h")],
        "rebuild_files": [str(BUILD / "ffmpeg-source/build-minimal.sh"),
                          str(ROOT / "scripts/lgpl_pyav.py"), str(ROOT / "scripts/build_lgpl_pyav.ps1")],
    }
    embedded = {"schema": 1, "pyav_version": VERSION, "ffmpeg": {key: ffmpeg_data[key] for key in ("version", "source_commit", "configuration", "libraries")}}
    write_json(source / "av/_lgpl_provenance.json", embedded)
    run(sys.executable, "-m", "pip", "install", "--no-deps", inputs["setuptools"], inputs["cython"])
    wheels = BUILD / "wheels"
    wheels.mkdir(exist_ok=True)
    run(sys.executable, "setup.py", f"--ffmpeg-dir={ffmpeg}", "bdist_wheel", "--dist-dir", wheels, cwd=source)
    candidates = list(wheels.glob(f"av-{VERSION}-*.whl"))
    if len(candidates) != 1:
        raise RuntimeError(f"Expected exactly one custom wheel: {candidates}")
    wheel = candidates[0]
    # Bundle shared DLLs beside av, retaining their public filenames and dynamic
    # linkage. They can be replaced with ABI-compatible user builds after install.
    # Rebuild RECORD so pip owns all staged DLLs and removes them on reinstall.
    with zipfile.ZipFile(wheel) as archive:
        payload = {name: archive.read(name) for name in archive.namelist() if not name.endswith("/RECORD")}
    for item in libraries:
        payload[f"av/{item['file']}"] = (ffmpeg / "bin" / item["file"]).read_bytes()
    payload["av/_lgpl_provenance.json"] = (source / "av/_lgpl_provenance.json").read_bytes()
    payload["av/FFMPEG-LICENSE.txt"] = (ffmpeg / "LICENSE.txt").read_bytes()
    metadata = next(name.rsplit("/", 1)[0] for name in payload if name.endswith(".dist-info/METADATA"))
    rows = []
    for name, content in payload.items():
        checksum = base64.urlsafe_b64encode(hashlib.sha256(content).digest()).rstrip(b"=").decode("ascii")
        rows.append((name, f"sha256={checksum}", len(content)))
    record_name = f"{metadata}/RECORD"
    rows.append((record_name, "", ""))
    stream = io.StringIO(newline="")
    csv.writer(stream, lineterminator="\n").writerows(rows)
    payload[record_name] = stream.getvalue().encode("utf-8")
    temporary = wheel.with_suffix(".partial")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, content in payload.items():
            archive.writestr(name, content)
    temporary.replace(wheel)
    patches = BUILD / "pyav-local-changes.json"
    write_json(patches, {"upstream_version": "19.0.1", "local_version": VERSION, "dll_loader_prefix": DLL_LOADER, "wheel_additions": [name for name in payload if name.startswith("av/") and (name.endswith(".dll") or name.endswith("_lgpl_provenance.json") or name.endswith("FFMPEG-LICENSE.txt"))]})
    compiler = subprocess.run(["cl"], capture_output=True, text=True)
    data = {
        "schema": 1, "ffmpeg": ffmpeg_data, "embedded": embedded,
        "pyav": {"version": VERSION, "source": record(inputs["pyav"], INPUTS["pyav"][0]), "wheel": record(wheel),
                  "source_root": str(source.resolve()), "local_changes": str(patches),
                  "extensions": {name[3:]: hashlib.sha256(content).hexdigest() for name, content in payload.items() if name.startswith("av/") and name.endswith(".pyd")},
                  "build_requirements": {name: record(inputs[name], INPUTS[name][0]) for name in ("setuptools", "cython")}},
        "toolchain": {"python": sys.version, "compiler": compiler.stdout + compiler.stderr},
        "release_policy": "LGPL shared DLLs only; provide matching source and build scripts, licenses, and allow reverse engineering for debugging modifications. DLLs remain individually replaceable; no app license change.",
        "intended_audio_formats": ["mp3", "m4a", "m4b", "wav", "flac", "ogg", "aac"],
    }
    write_json(MANIFEST, data)
    write_json(BUILD / "checksums.json", {name: record(path, INPUTS[name][0]) for name, path in inputs.items()})
    install(wheel)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("build", "reuse", "verify"))
    parser.add_argument("--bundle", type=Path)
    arguments = parser.parse_args()
    if sys.platform != "win32" or sys.version_info[:2] != (3, 12) or struct.calcsize("P") != 8:
        raise RuntimeError("Requires managed Windows x64 Python 3.12.")
    if arguments.command == "reuse":
        return reuse()
    if arguments.command == "build":
        build()
    else:
        verify(arguments.bundle)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"LGPL runtime error: {error}", file=sys.stderr)
        raise SystemExit(1)
