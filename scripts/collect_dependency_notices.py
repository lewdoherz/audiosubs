#!/usr/bin/env python3
"""Collect release notices from frozen inventories, not all development packages.

Invoke with managed Python after PyInstaller and LGPL provenance validation.
Python dependencies: standard library only. Exact source archives and generated
build inputs are taken from the LGPL builder provenance. No model weights are
fetched. Download caches and temporary notice trees are under worker/build.
A failed run never replaces the existing notice directory. This is not a compliance opinion
and does not grant or change the AudioSubs application license.
"""
from __future__ import annotations

import argparse
import ast
import ctypes
import hashlib
import importlib.metadata
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CT2_TAG = 'https://raw.githubusercontent.com/OpenNMT/CTranslate2/v4.8.2/'
NOTICE_NAME = re.compile(r'^(licen[cs]e|copying|copyright|notice|third[-_ ]?party|acknowledg)', re.I)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + '\n').encode('utf-8')


def key(name):
    return re.sub(r'[-_.]+', '-', name).lower()


def safe_url(url):
    parsed = urllib.parse.urlsplit(url)
    require(parsed.scheme in ('https', 'http'), 'Notice sources must use public HTTPS/HTTP URLs')
    query = {name.lower() for name, _ in urllib.parse.parse_qsl(parsed.query)}
    require(not parsed.username and not parsed.password and not query.intersection(
        {'token', 'access_token', 'api_key', 'apikey', 'password', 'credential', 'signature', 'auth', 'sig'}),
        'Credentials are prohibited in notice source URLs')
    return url


def notice_path(name):
    path = PurePosixPath(name.replace('\\', '/'))
    if '__pycache__' in path.parts or path.suffix.lower() in ('.pyc', '.pyo'):
        return False
    # A third_party source directory is not itself a notice: retain its
    # licence/notice files, not every nested implementation and test fixture.
    return bool(NOTICE_NAME.match(path.name)) or any(
        part.lower() in ('licenses', 'licences') for part in path.parts[:-1])


def archive_files(data):
    """Read files without extracting archive-controlled paths to disk."""
    buffer = io.BytesIO(data)
    if zipfile.is_zipfile(buffer):
        with zipfile.ZipFile(buffer) as archive:
            for name in sorted(archive.namelist()):
                if not name.endswith('/'):
                    yield name, archive.read(name)
    else:
        buffer.seek(0)
        # Sequential compressed-tar reads avoid re-decompressing the entire
        # source archive for every filename after sorting its members.
        with tarfile.open(fileobj=buffer, mode='r|*') as archive:
            for member in archive:
                if member.isfile():
                    yield member.name, archive.extractfile(member).read()


class Collector:
    def __init__(self, args, output):
        self.args = args
        self.output = output
        self.components = []
        self.downloads = {}
        self.unresolved = []
        self.cache = args.cache.resolve()
        self.cache.mkdir(parents=True, exist_ok=True)

    def fetch(self, url, sha256=None):
        safe_url(url)
        target = self.cache / 'downloads' / hashlib.sha256(url.encode()).hexdigest()
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.is_file():
            request = urllib.request.Request(url, headers={'User-Agent': 'AudioSubs-notice-collector/2.0.0'})
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    data = response.read()
            except OSError as error:
                raise RuntimeError(f'Required notice download failed: {url}: {error}') from error
            require(data, f'Empty upstream response: {url}')
            if sha256:
                require(digest(data) == sha256, f'Upstream SHA256 mismatch: {url}')
            temporary = target.with_suffix('.tmp')
            temporary.write_bytes(data)
            temporary.replace(target)
        data = target.read_bytes()
        require(not sha256 or digest(data) == sha256, f'Cached SHA256 mismatch: {url}')
        self.downloads[url] = {'url': url, 'sha256': digest(data)}
        return data

    def save(self, component, relative, data, origin):
        require(data.strip(), f'Empty required notice: {component["name"]}/{relative}')
        path = PurePosixPath(relative.replace('\\', '/'))
        require(not path.is_absolute() and '..' not in path.parts, f'Unsafe notice path: {relative}')
        destination = self.output / component['id'] / Path(*path.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        item = {'path': destination.relative_to(self.output).as_posix(), 'sha256': digest(data), 'origin': origin}
        component['notices'].append(item)
        return item

    def component(self, name, version, urls, **fields):
        require(version, f'Missing exact version: {name}')
        result = {'id': re.sub(r'[^a-zA-Z0-9_.-]', '_', name + '-' + version),
                  'name': name, 'version': version, 'source_urls': sorted(set(filter(None, urls))),
                  'notices': [], **fields}
        for url in result['source_urls']:
            safe_url(url)
        require(not any(c['id'] == result['id'] for c in self.components), f'Duplicate component: {name}')
        self.components.append(result)
        return result

    def local_notices(self, component, root):
        root = Path(root)
        if root.exists():
            for path in sorted(root.rglob('*')):
                if path.is_file() and notice_path(path.relative_to(root).as_posix()):
                    relative = path.relative_to(root).as_posix()
                    self.save(component, relative, path.read_bytes(), 'local redistribution input: ' + relative)

    def upstream_archive_notices(self, component, url, sha256=None):
        for name, data in archive_files(self.fetch(url, sha256)):
            if notice_path(name):
                self.save(component, 'upstream/' + name, data, url)

    def pypi_artifact(self, name, version, suffix):
        url = f'https://pypi.org/pypi/{urllib.parse.quote(name)}/{urllib.parse.quote(version)}/json'
        metadata = json.loads(self.fetch(url))
        require(metadata['info']['version'] == version, f'PyPI version mismatch: {name}')
        assets = [a for a in metadata['urls'] if suffix(a)]
        require(len(assets) == 1, f'Expected one pinned PyPI artifact for {name} {version}, found {len(assets)}')
        asset = assets[0]
        return asset, self.fetch(asset['url'], asset['digests']['sha256'])


def toc_entries(value):
    if isinstance(value, (list, tuple)):
        if len(value) == 3 and all(isinstance(v, str) for v in value):
            yield value
        else:
            for child in value:
                yield from toc_entries(child)


def collect_python_packages(c):
    site = c.args.venv.resolve() / 'Lib/site-packages'
    require(site.is_dir(), f'Managed venv metadata missing: {site}')
    distributions = list(importlib.metadata.distributions(path=[str(site)]))
    owners = {}
    for distribution in distributions:
        for file in distribution.files or []:
            owners.setdefault(str(distribution.locate_file(file).resolve()).lower(), []).append(distribution)
    selected = {}
    shipped = {p.relative_to(c.args.runtime / '_internal').as_posix().lower()
               for p in (c.args.runtime / '_internal').rglob('*') if p.is_file()}
    for distribution in distributions:
        if any(str(f).replace('\\', '/').lower() in shipped for f in distribution.files or []):
            selected[key(distribution.metadata['Name'])] = distribution
    for toc_name in ('PYZ-00.toc', 'COLLECT-00.toc'):
        toc = c.args.pyinstaller_work / toc_name
        require(toc.is_file(), f'Frozen package inventory required: {toc}')
        inventory = ast.literal_eval(toc.read_text(encoding='utf-8'))
        for _, source, _ in toc_entries(inventory):
            path = Path(source)
            if path.is_relative_to(site):
                matches = owners.get(str(path.resolve()).lower(), [])
                require(matches, f'No managed distribution owns shipped source: {source}')
                for distribution in matches:
                    selected[key(distribution.metadata['Name'])] = distribution
    require({'av', 'ctranslate2', 'argostranslate', 'faster-whisper'} <= selected.keys(),
            'Frozen inventory omits a required worker package')
    # The executable contains PyInstaller's bootloader even though build-time imports are excluded.
    for distribution in distributions:
        if key(distribution.metadata['Name']) == 'pyinstaller':
            selected['pyinstaller'] = distribution
    for name, distribution in sorted(selected.items()):
        metadata = distribution.metadata
        version = distribution.version
        urls = ([f'https://github.com/PyAV-Org/PyAV/tree/v19.0.1'] if name == 'av' and version.startswith('19.0.1+')
                else [f'https://pypi.org/project/{metadata["Name"]}/{version}/'])
        if metadata.get('Home-page', '').startswith('https://'):
            urls.append(metadata['Home-page'])
        for value in metadata.get_all('Project-URL', []):
            url = value.partition(',')[2].strip()
            if url.startswith('https://'):
                urls.append(url)
        component = c.component(metadata['Name'], version, urls, kind='python-distribution',
                                license_expression=metadata.get('License-Expression'),
                                license_metadata=metadata.get('License'))
        metadata_paths = [Path(distribution.locate_file(f)) for f in distribution.files or []
                          if str(f).replace('\\', '/').endswith('.dist-info/METADATA')
                          and len(PurePosixPath(str(f).replace('\\', '/')).parts) == 2]
        require(len(metadata_paths) == 1, f'Missing distribution metadata: {name}')
        info = metadata_paths[0].parent
        required_license_paths = set()
        for filename in metadata.get_all('License-File', []):
            relative = PurePosixPath(filename.replace('\\', '/'))
            require(not relative.is_absolute() and '..' not in relative.parts,
                    f'Unsafe required license path in {name} metadata')
            candidates = [info / Path(*relative.parts), info / 'licenses' / Path(*relative.parts)]
            require(any(path.is_file() and path.stat().st_size for path in candidates),
                    f'Required License-File absent from managed {name}: {filename}')
            required_license_paths.update(str(path.relative_to(site)).replace('\\', '/')
                                          for path in candidates if path.is_file())
        for filename in ('METADATA', 'WHEEL'):
            path = info / filename
            if path.is_file():
                c.save(component, filename, path.read_bytes(), 'managed venv distribution metadata')
        licenses = []
        for file in distribution.files or []:
            relative = str(file).replace('\\', '/')
            if (notice_path(relative) or relative in required_license_paths) and '..' not in PurePosixPath(relative).parts:
                path = Path(distribution.locate_file(file))
                if path.is_file():
                    licenses.append(relative)
                    c.save(component, relative, path.read_bytes(), 'managed venv package file')
        if not licenses:
            if name == 'ctranslate2':
                require(version == '4.8.2', 'Update pinned CTranslate2 notice sources for changed version')
                url = CT2_TAG + 'LICENSE'
                c.save(component, 'LICENSE', c.fetch(url), url)
            elif name == 'av' and version.startswith('19.0.1+'):
                url = 'https://raw.githubusercontent.com/PyAV-Org/PyAV/v19.0.1/LICENSE.txt'
                c.save(component, 'LICENSE.txt', c.fetch(url), url)
            else:
                asset, data = c.pypi_artifact(metadata['Name'], version, lambda a: a['packagetype'] == 'sdist')
                before = len(component['notices'])
                for filename, contents in archive_files(data):
                    if notice_path(filename):
                        c.save(component, 'upstream/' + filename, contents, asset['url'])
                require(len(component['notices']) > before, f'Required license missing from {name} {version} source')
    return selected


def collect_cpython(c):
    cfg = dict(line.split(' = ', 1) for line in (c.args.venv / 'pyvenv.cfg').read_text().splitlines() if ' = ' in line)
    require(cfg.get('version') == '3.12.10', 'Update CPython pinned acknowledgements for changed runtime')
    home = Path(cfg['home'])
    require(file_digest(home / 'python312.dll') == file_digest(c.args.runtime / '_internal/python312.dll'),
            'Frozen Python DLL does not match managed CPython installation')
    component = c.component('CPython', '3.12.10', ['https://www.python.org/downloads/release/python-31210/',
                                                'https://github.com/python/cpython/tree/v3.12.10'], kind='native-runtime')
    license_file = home / 'LICENSE.txt'
    require(license_file.is_file(), 'Managed CPython LICENSE.txt with Windows third-party terms is required')
    c.save(component, 'LICENSE.txt', license_file.read_bytes(), 'managed CPython 3.12.10 binary distribution')
    for filename in ('Doc/license.rst', 'PCbuild/python.props', 'PCbuild/get_externals.bat'):
        url = 'https://raw.githubusercontent.com/python/cpython/v3.12.10/' + filename
        c.save(component, filename, c.fetch(url), url)
    internal = c.args.runtime / '_internal'
    externals = [
        ('bzip2', '1.0.8', 'bzip2-1.0.8', '_bz2.pyd'),
        ('libffi', '3.4.4', 'libffi-3.4.4', 'libffi-8.dll'),
        ('OpenSSL', '3.0.16', 'openssl-3.0.16', 'libssl-3.dll'),
        ('SQLite', '3.49.1', 'sqlite-3.49.1.0', 'sqlite3.dll'),
        ('XZ', '5.2.5', 'xz-5.2.5', '_lzma.pyd'),
        ('zlib', '1.3.1', 'zlib-1.3.1', 'python312.dll'),
    ]
    for name, version, tag, binary in externals:
        path = internal / binary
        if not path.is_file():
            continue
        if (home / binary).is_file():
            original = home / binary
        else:
            original = home / 'DLLs' / binary
        require(original.is_file() and file_digest(original) == file_digest(path),
                f'CPython incorporated library differs from managed runtime: {binary}')
        url = 'https://github.com/python/cpython-source-deps/tree/' + tag
        dependency = c.component('CPython-' + name, version, [url], kind='CPython-incorporated-library',
                                 redistributed_file=binary, sha256=file_digest(path))
        archive_url = 'https://codeload.github.com/python/cpython-source-deps/tar.gz/refs/tags/' + tag
        c.upstream_archive_notices(dependency, archive_url)
        if name == 'SQLite' and not dependency['notices']:
            url = 'https://www.sqlite.org/copyright.html'
            c.save(dependency, 'Public-Domain-Dedication.html', c.fetch(url), url)
        require(dependency['notices'], f'CPython incorporated library license missing: {name}')
    # Preserve both upstream incorporated-software acknowledgements and the
    # Windows binary license, which includes libffi, bzip2 and MS/Apache terms.
    c.unresolved.append('Microsoft Distributable Code restrictions in CPython LICENSE.txt require publisher/distributor end-user terms review; this script does not accept or grant those terms.')


def windows_version(path):
    require(os.name == 'nt', 'Windows file-version extraction requires Windows for exact native versions')
    api = ctypes.WinDLL('version', use_last_error=True)
    api.GetFileVersionInfoSizeW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_ulong)]
    api.GetFileVersionInfoSizeW.restype = ctypes.c_ulong
    api.GetFileVersionInfoW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
    api.VerQueryValueW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint)]
    size = api.GetFileVersionInfoSizeW(str(path), None)
    require(size, f'Exact native file version unavailable: {path.name}')
    buffer = ctypes.create_string_buffer(size)
    require(api.GetFileVersionInfoW(str(path), 0, size, buffer), f'Cannot read native version: {path.name}')
    pointer, length = ctypes.c_void_p(), ctypes.c_uint()
    require(api.VerQueryValueW(buffer, '\\', ctypes.byref(pointer), ctypes.byref(length)), f'Cannot query native version: {path.name}')
    words = ctypes.cast(pointer, ctypes.POINTER(ctypes.c_uint32))
    require(words[0] == 0xFEEF04BD, f'Invalid native version resource: {path.name}')
    return '.'.join(str(n) for n in (words[2] >> 16, words[2] & 65535, words[3] >> 16, words[3] & 65535))


def collect_native(c):
    internal = c.args.runtime / '_internal'
    binaries = sorted(p for p in internal.rglob('*') if p.is_file() and p.suffix.lower() == '.dll')
    intel = [p for p in binaries if p.name.lower() == 'libiomp5md.dll']
    require(intel, 'Shipped CT2 Intel OpenMP runtime is missing')
    component = c.component('Intel-OpenMP', windows_version(intel[0]), ['https://pypi.org/project/intel-openmp/2025.3.0/'],
                            kind='native-runtime', package_version='2025.3.0')
    asset, data = c.pypi_artifact('intel-openmp', '2025.3.0', lambda a: a['filename'].endswith('win_amd64.whl'))
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        dlls = [name for name in archive.namelist() if name.lower().endswith('/libiomp5md.dll')]
        require(len(dlls) == 1 and all(file_digest(path) == digest(archive.read(dlls[0])) for path in intel),
                'CT2 OpenMP DLL does not match Intel 2025.3.0 redistribution package; provide matching vendor input rather than substitute terms')
        for filename in sorted(archive.namelist()):
            if not filename.endswith('/') and notice_path(filename):
                c.save(component, filename, archive.read(filename), asset['url'])
    require(component['notices'], 'Intel OpenMP redistribution license missing')
    component['redistributed_files'] = [{'path': p.relative_to(internal).as_posix(), 'sha256': file_digest(p)} for p in intel]
    # CT2 includes static oneDNN and MKL, whose notices are not in the wheel.
    dnnl = c.component('oneDNN', '3.1.1', ['https://github.com/oneapi-src/oneDNN/tree/v3.1.1'], kind='CT2-static-dependency')
    c.upstream_archive_notices(dnnl, 'https://codeload.github.com/oneapi-src/oneDNN/tar.gz/refs/tags/v3.1.1')
    require(dnnl['notices'], 'oneDNN license/third-party notices missing')
    mkl = c.component('Intel-MKL', '2025.3.0', ['https://pypi.org/project/mkl/2025.3.0/'], kind='CT2-static-dependency')
    asset, data = c.pypi_artifact('mkl', '2025.3.0', lambda a: a['filename'].endswith('win_amd64.whl'))
    for filename, contents in archive_files(data):
        if notice_path(filename):
            c.save(mkl, filename, contents, asset['url'])
    require(mkl['notices'], 'Intel MKL redistribution license missing')
    recipe = CT2_TAG + 'python/tools/prepare_build_environment_windows.sh'
    dnnl['version_evidence'] = recipe
    mkl['version_evidence'] = recipe
    c.save(mkl, 'CT2-native-build-inputs.sh', c.fetch(recipe), recipe)
    c.unresolved.append('CT2 static MKL/oneDNN versions are from the official v4.8.2 Windows wheel recipe; verify vendor wheel provenance if its build inputs differ. Intel EULA 2.1.D(2) requires an end-user agreement prohibiting reverse engineering, decompilation and disassembly of Intel Redistributables; section 7.3 requires Intel liability limitations to be made binding on customers. Review the applicable redistributable list and distribution entitlement. These restrictions are not an AudioSubs application license.')
    nvidia = [p.name for p in binaries if p.name.lower().startswith(
        ('cudnn', 'cublas', 'cudart', 'nvrtc', 'curand', 'cusparse', 'cufft'))]
    require(not nvidia, f'User-selected runtime excludes NVIDIA redistribution files: {nvidia}')
    crt = [p for p in binaries if re.match(r'(vcruntime|msvcp|ucrtbase|api-ms-win-crt)', p.name, re.I)]
    require(crt, 'Expected Microsoft CRT runtime files missing')
    url = 'https://visualstudio.microsoft.com/wp-content/uploads/2021/09/Visual-C-Runtime-2015-2022-License-1.docx'
    component = c.component('Microsoft-CRT', '2015-2022', [url,
        'https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170'], kind='native-runtime')
    data = c.fetch(url)
    c.save(component, 'Runtime-License.docx', data, url)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        document = ET.fromstring(archive.read('word/document.xml'))
    namespace = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
    text = '\n'.join(''.join(p.itertext()) for p in document.iter(namespace + 'p'))
    require('MICROSOFT' in text.upper() and 'LICENSE' in text.upper(), 'Microsoft CRT license document incomplete')
    c.save(component, 'Runtime-License.txt', text.encode('utf-8'), url)
    component['redistributed_files'] = [{'path': p.relative_to(internal).as_posix(), 'version': windows_version(p), 'sha256': file_digest(p)} for p in crt]
    c.unresolved.append('Microsoft CRT app-local redistribution entitlement and end-user restrictions must be reviewed by publisher. Collected runtime terms do not assign an AudioSubs license.')


def yaml_section(text, section):
    """Read dependency names only, not YAML values or arbitrary YAML objects."""
    result, active = [], False
    for line in text.splitlines():
        if re.match(r'^' + re.escape(section) + r':\s*(?:#.*)?$', line):
            active = True
            continue
        if active and line and not line[0].isspace() and not line.startswith('#'):
            break
        if active:
            match = re.match(r'^  ([A-Za-z0-9_]+):', line)
            if match:
                result.append(match[1])
    return result


def uri_path(uri, base):
    parsed = urllib.parse.urlparse(urllib.parse.urljoin(base.as_uri(), uri))
    require(parsed.scheme == 'file', 'Dart package root must be local file metadata')
    return Path(urllib.request.url2pathname(parsed.path))


def collect_flutter(c):
    config_path = ROOT / '.dart_tool/package_config.json'
    require(config_path.is_file(), 'Flutter resolved package metadata missing')
    config = json.loads(config_path.read_text(encoding='utf-8'))
    packages = {p['name']: uri_path(p['rootUri'], config_path) for p in config['packages']}
    app = (ROOT / 'pubspec.yaml').read_text(encoding='utf-8')
    queue = yaml_section(app, 'dependencies')
    selected = set()
    while queue:
        name = queue.pop()
        if name in selected:
            continue
        require(name in packages, f'Dart runtime dependency metadata missing: {name}')
        selected.add(name)
        pubspec = packages[name] / 'pubspec.yaml'
        require(pubspec.is_file(), f'Dart package pubspec missing: {name}')
        queue.extend(yaml_section(pubspec.read_text(encoding='utf-8'), 'dependencies'))
    flutter_root = uri_path(config['flutterRoot'], config_path)
    version_file = flutter_root / 'bin/cache/flutter.version.json'
    require(version_file.is_file(), 'Exact Flutter engine/framework version metadata missing')
    versions = json.loads(version_file.read_text(encoding='utf-8'))
    component = c.component('Flutter', versions['frameworkVersion'], ['https://github.com/flutter/flutter/tree/' + versions['frameworkRevision']],
                            kind='application-framework', engine_revision=versions['engineRevision'], dart_version=versions['dartSdkVersion'])
    c.save(component, 'VERSION.json', json_bytes(versions), 'Flutter SDK version metadata')
    c.save(component, 'LICENSE', (flutter_root / 'LICENSE').read_bytes(), 'Flutter SDK BSD license')
    engine = flutter_root / 'bin/cache/artifacts/engine'
    notices = sorted(p for p in engine.rglob('*') if p.is_file() and NOTICE_NAME.match(p.name)
                     and ('windows' in p.relative_to(engine).as_posix() or 'android' in p.relative_to(engine).as_posix()))
    require(notices, 'Flutter engine third-party acknowledgements missing')
    for path in notices:
        c.save(component, 'engine/' + path.relative_to(engine).as_posix(), path.read_bytes(), 'Flutter SDK engine redistribution notice')
    for name in sorted(selected):
        root = packages[name]
        if root.is_relative_to(flutter_root):
            continue  # Covered by the same exact Flutter framework version and BSD license.
        pubspec = (root / 'pubspec.yaml').read_text(encoding='utf-8')
        version = re.search(r'^version:\s*[\'"]?([^\s\'"#]+)', pubspec, re.M)
        require(version, f'Dart package exact version missing: {name}')
        urls = [f'https://pub.dev/packages/{name}/versions/{version[1]}']
        for field in ('repository', 'homepage'):
            match = re.search(r'^' + field + r':\s*[\'"]?(https://[^\s\'"#]+)', pubspec, re.M)
            if match:
                urls.append(match[1])
        component = c.component(name, version[1], urls, kind='dart-runtime-package')
        c.save(component, 'pubspec.yaml', pubspec.encode(), 'resolved Dart package metadata')
        c.local_notices(component, root)
        require(any(not n['path'].endswith('pubspec.yaml') for n in component['notices']), f'Dart package license text missing: {name}')




def add_zip(archive, name, data):
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, data)




def collect_ffmpeg(c):
    provenance = json.loads(c.args.provenance.read_text(encoding='utf-8'))
    ffmpeg = provenance['ffmpeg']
    libraries = ffmpeg['libraries']
    require(libraries, 'No LGPL FFmpeg library provenance')
    configuration = ffmpeg['configuration']
    for library in libraries:
        require('LGPL' in library['license'] and '--enable-gpl' not in library['configuration']
                and '--enable-nonfree' not in library['configuration'], f'Non-LGPL FFmpeg library: {library["name"]}')
        require(library['configuration'] == configuration, 'FFmpeg library configurations disagree')
        matches = list((c.args.runtime / '_internal').rglob(Path(library['file']).name))
        require(matches and all(file_digest(p) == library['sha256'] for p in matches), f'Frozen FFmpeg library differs from provenance: {library["name"]}')
    require('--enable-gpl' not in configuration and '--enable-nonfree' not in configuration, 'GPL/nonfree FFmpeg build rejected')
    component = c.component('FFmpeg', ffmpeg['version'], [ffmpeg['source_url'], ffmpeg['build_source_url']],
                            kind='LGPL-shared-runtime', configuration=configuration, libraries=libraries)
    c.save(component, 'provenance.json', json_bytes(provenance), 'LGPL runtime builder provenance')
    for filename in ffmpeg['metadata_files']:
        path = Path(filename)
        require(path.is_file(), f'FFmpeg licensing/provenance input missing: {filename}')
        c.save(component, 'build-metadata/' + path.name, path.read_bytes(), 'LGPL build input')
    require(ffmpeg.get('build_kind') == 'minimal', 'Only the selected minimal LGPL FFmpeg build may be packaged')
    require('--disable-autodetect' in configuration, 'Minimal FFmpeg must disable external autodetection')
    require(not any(flag.startswith('--enable-lib') or flag in
                    ('--enable-iconv', '--enable-openssl', '--enable-zlib', '--enable-bzlib', '--enable-lzma')
                    for flag in configuration.split()),
            'Minimal FFmpeg provenance contains uncovered external dependencies')
    source_release = ffmpeg['source_release']
    source_tar = Path(source_release['path'])
    require(source_tar.is_file() and file_digest(source_tar) == source_release['sha256'],
            'Exact original FFmpeg source archive is missing or has changed')
    commit = ffmpeg['source_commit']
    require(re.fullmatch('[0-9a-f]{40}', commit), 'Exact FFmpeg source commit unavailable')
    source_record = {'component': 'FFmpeg', 'version': ffmpeg['version'], 'commit': commit,
                     'url': source_release['url'], 'sha256': source_release['sha256'],
                     'archive': 'sources/' + source_tar.name, 'configuration': configuration}
    require(ffmpeg.get('rebuild_files'), 'Complete FFmpeg rebuild inputs are required')
    records = []
    c.args.source_zip.parent.mkdir(parents=True, exist_ok=True)
    temporary = c.cache / 'corresponding-source.zip.tmp'
    with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        add_zip(archive, 'sources/' + source_tar.name, source_tar.read_bytes())
        for name, data in archive_files(source_tar.read_bytes()):
            if notice_path(name):
                c.save(component, 'source-notices/' + name, data, source_release['url'])
        require(any('COPYING.LGPL' in n['path'] for n in component['notices']),
                'FFmpeg source archive lacks LGPL license texts')
        records.append(source_record)
        pyav = provenance['pyav']
        sdist = Path(pyav['source']['path'])
        require(file_digest(sdist) == pyav['source']['sha256'], 'PyAV original source digest mismatch')
        add_zip(archive, 'pyav/' + sdist.name, sdist.read_bytes())
        changes = Path(pyav['local_changes'])
        require(changes.is_file(), 'Exact PyAV local-change record is missing')
        add_zip(archive, 'pyav/local-changes.json', changes.read_bytes())
        records.append({'component': 'PyAV', 'version': pyav['version'],
                        'url': pyav['source']['url'], 'sha256': pyav['source']['sha256'],
                        'archive': 'pyav/' + sdist.name,
                        'local_changes': 'pyav/local-changes.json'})
        add_zip(archive, 'provenance.json', json_bytes(provenance))
        for filename in ffmpeg['metadata_files']:
            path = Path(filename)
            add_zip(archive, 'ffmpeg-build-metadata/' + path.name, path.read_bytes())
        add_zip(archive, 'SOURCES.json', json_bytes(records))
        for filename in ('scripts/lgpl_pyav.py', 'scripts/build_lgpl_pyav.ps1', 'scripts/collect_dependency_notices.py'):
            path = ROOT / filename
            require(path.is_file(), f'PyAV rebuild/relink script missing: {filename}')
            add_zip(archive, filename, path.read_bytes())
        for filename in ffmpeg['rebuild_files']:
            path = Path(filename)
            require(path.is_file(), f'FFmpeg rebuild input missing: {filename}')
            add_zip(archive, 'ffmpeg-rebuild/' + path.name, path.read_bytes())
        instructions = ('Corresponding sources for the LGPL FFmpeg shared libraries shipped by AudioSubs 2.0.0.\n'
            'No license for AudioSubs itself is granted by this source archive.\n'
            'provenance.json records exact DLL hashes/configuration; pyav/local-changes.json records the PyAV modifications.\n'
            'SOURCES.json records the original source URL, revision and SHA256.\n'
            'sources/ contains the complete hash-verified official FFmpeg source archive. No external libraries are linked.\n'
            'ffmpeg-rebuild/build-minimal.sh contains the exact publisher configure/build commands.\n'
            'Build with the recorded MSVC and MSYS2 tools using the included original FFmpeg source,\n'
            'and use generated config.mak/config.log/config.h in ffmpeg-build-metadata to compare settings.\n'
            '\nReproduce the publisher libraries (Windows x64, Python3.12 and Visual Studio C++ tools):\n'
            'Extract this ZIP into a new directory, open PowerShell there, then run:\n'
            '  py -3.12 -m venv worker/.venv\n'
            '  New-Item -ItemType Directory worker/build/lgpl/downloads -Force\n'
            '  Copy-Item sources/*.tar.xz,pyav/*.tar.gz worker/build/lgpl/downloads/\n'
            '  powershell -ExecutionPolicy Bypass -File scripts/build_lgpl_pyav.ps1\n'
            'The script downloads checksum-pinned MSYS2/build utilities and setuptools/Cython, not speech models.\n'
            'Shared DLL output: worker/build/lgpl/ffmpeg/bin/; custom PyAV wheel: worker/build/lgpl/wheels/.\n'
            '\nFor modified FFmpeg, unpack the complete source tarball and edit it. Activate the recorded MSVC environment,\n'
            'set AUDIOSUBS_FFMPEG_PREFIX to your output directory, and run ffmpeg-rebuild/build-minimal.sh from\n'
            'the source directory using the provisioned MSYS2 bash/make (retain its MSVC linker setup).\n'
            'For PyAV modifications/relinking, use the original sdist and local-changes.json; adapt the supplied\n'
            'builder to your modified sources instead of the publisher checksum guard. Keep the shared ABI compatible.\n'
            'Close AudioSubs and replace the separate DLLs in transcription_runtime/_internal/av/ with your build.\n'
            'This archive does not certify compliance with every third-party or application distribution term.\n')
        add_zip(archive, 'REBUILD.txt', instructions.encode('utf-8'))
    shutil.copyfile(temporary, c.args.source_zip)
    temporary.unlink()
    component['source_release'] = {'filename': c.args.source_zip.name, 'url': c.args.release_source_url,
                                   'sha256': file_digest(c.args.source_zip), 'source_commit': commit,
                                   'components': records}
    c.save(component, 'SOURCE-RELEASE.json', json_bytes(component['source_release']), 'publisher corresponding-source release')
    c.unresolved.append('LGPL source delivery, shared-library replacement/relink rights and compatible application end-user terms require publisher review. Source archive must be published at its recorded release URL alongside the binaries.')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--runtime', type=Path, default=ROOT / 'worker/runtime/audiosubs_worker')
    parser.add_argument('--venv', type=Path, default=ROOT / 'worker/.venv')
    parser.add_argument('--provenance', type=Path, default=ROOT / 'worker/build/lgpl/provenance.json')
    parser.add_argument('--pyinstaller-work', type=Path, default=ROOT / 'worker/build/audiosubs_worker')
    parser.add_argument('--cache', type=Path, default=ROOT / 'worker/build/dependency-notices')
    parser.add_argument('--output', type=Path, help='Defaults to runtime/_internal/THIRD-PARTY-LICENSES')
    parser.add_argument('--source-zip', type=Path, default=ROOT / 'dist/2.0.0/AudioSubs-2.0.0-ffmpeg-lgpl-source.zip')
    parser.add_argument('--release-source-url', required=True, help='Public URL at which the corresponding-source ZIP will be published')
    args = parser.parse_args()
    args.runtime = args.runtime.resolve()
    args.venv = args.venv.resolve()
    output = args.output or args.runtime / '_internal/THIRD-PARTY-LICENSES'
    safe_url(args.release_source_url)
    require(args.provenance.is_file(), 'LGPL runtime provenance manifest is required before collecting notices')
    require((args.runtime / 'audiosubs_worker.exe').is_file(), 'Packaged worker executable is required')
    args.cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='notices-', dir=args.cache) as temporary:
        c = Collector(args, Path(temporary))
        collect_python_packages(c)
        collect_cpython(c)
        collect_native(c)
        collect_flutter(c)
        collect_ffmpeg(c)
        manifest = {'schema': 1, 'application': {'name': 'AudioSubs', 'version': '2.0.0',
            'license': 'No application LICENSE was supplied; these notices do not grant an application license.'},
            'scope': 'Frozen Python module/data inventory, native runtime dependencies, Flutter engine and Dart runtime dependency graph. Development-only distributions are excluded.',
            'components': sorted(c.components, key=lambda v: (v['name'].lower(), v['version'])),
            'downloads': sorted(c.downloads.values(), key=lambda v: v['url']),
            'unresolved_terms': sorted(set(c.unresolved)),
            'legal_compliance': 'Not determined by this collection tool.'}
        (c.output / 'manifest.json').write_bytes(json_bytes(manifest))
        lines = ['AudioSubs 2.0.0 - third-party notices', '', manifest['application']['license'], '', manifest['scope'], '']
        for component in manifest['components']:
            lines.append(component['name'] + ' ' + component['version'])
            lines.extend('  Source: ' + url for url in component['source_urls'])
            lines.extend('  Text: ' + item['path'] for item in sorted(component['notices'], key=lambda v: v['path']))
            lines.append('')
        lines.extend(['Unresolved distribution terms (not a legal-compliance certification):', *manifest['unresolved_terms'], ''])
        terms = [
            'AudioSubs — Windows third-party component terms',
            '',
            'These terms apply only to the identified Intel and Microsoft redistributables.',
            'You agree not to reverse engineer, decompile or disassemble Intel redistributables, '
            'except where applicable law gives non-waivable rights.',
            'The applicable vendor warranty exclusions and liability limitations below are '
            'incorporated into your agreement for those components.',
            '',
            'No restriction here applies to LGPL components. You may modify or replace '
            'the LGPL FFmpeg shared libraries, relink them, and reverse engineer AudioSubs '
            'to debug those modifications. No AudioSubs application licence is assigned here.',
            'Corresponding FFmpeg/PyAV sources: ' + args.release_source_url,
            '',
        ]
        for name in ('Intel-OpenMP', 'Intel-MKL', 'Microsoft-CRT', 'CPython'):
            component = next((item for item in c.components if item['name'] == name), None)
            require(component is not None, f'Required Windows terms component missing: {name}')
            texts = [
                item for item in component['notices']
                if item['path'].lower().endswith('.txt')
                and ('license' in item['path'].lower() or 'licence' in item['path'].lower())
            ]
            require(texts, f'Required full Windows component terms missing: {name}')
            for item in sorted(texts, key=lambda value: value['path']):
                raw = (c.output / item['path']).read_bytes()
                if raw.startswith((b'\xff\xfe', b'\xfe\xff')):
                    text = raw.decode('utf-16')
                else:
                    try:
                        text = raw.decode('utf-8-sig')
                    except UnicodeDecodeError:
                        # Intel/Microsoft Windows licence files can use ANSI.
                        # Preserve the original bytes above; render CP1252 here.
                        text = raw.decode('cp1252')
                terms.extend([
                    '=== ' + name + ' ' + component['version'] + ' ===',
                    'Source: ' + item['origin'],
                    text,
                    '',
                ])
        (c.output / 'WINDOWS-TERMS.txt').write_text('\n'.join(terms), encoding='utf-8-sig', newline='\n')
        (c.output / 'INDEX.txt').write_text('\n'.join(lines), encoding='utf-8', newline='\n')
        output.parent.mkdir(parents=True, exist_ok=True)
        if output.exists():
            require(output.name == 'THIRD-PARTY-LICENSES', 'Refusing to replace a non-notice directory')
            shutil.rmtree(output)
        shutil.copytree(c.output, output)
    print(f'Collected {len(manifest["components"])} component notices: {output}')
    print(f'Corresponding sources: {args.source_zip}')
    print('Review manifest.json unresolved_terms; collection is not legal approval.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, zipfile.BadZipFile, tarfile.TarError) as error:
        print(f'Dependency notice collection failed: {error}', file=sys.stderr)
        sys.exit(1)
