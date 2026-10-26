import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

const ebookExtensions = <String>{
  'epub',
  'fb2',
  'docx',
  'txt',
  'html',
  'htm',
  'mobi',
  'azw',
  'azw3',
  'pdf',
};

class EbookDocument {
  final String title;
  final String text;

  const EbookDocument({required this.title, required this.text});
}

const _maxFileBytes = 64 * 1024 * 1024;
const _maxExpandedBytes = 128 * 1024 * 1024;
const _maxEntryBytes = 16 * 1024 * 1024;
const _maxTextCharacters = 32 * 1024 * 1024;
const _maxNodes = 1000000;
const _maxDepth = 256;

/// Reads local files only. ZIP/XML/HTML and Kindle parsing run in a worker
/// isolate. PDFium performs its native work on pdfrx's background worker.
Future<EbookDocument> readEbook(String path) async {
  final filename = path.replaceAll('\\', '/').split('/').last;
  final dot = filename.lastIndexOf('.');
  final extension = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  if (!ebookExtensions.contains(extension)) {
    throw const FormatException(
      'Unsupported ebook format. Choose EPUB, FB2, DOCX, TXT, HTML, MOBI/AZW, or a text PDF.',
    );
  }
  try {
    if (extension == 'pdf') {
      await _checkFile(File(path));
      return await _readPdf(path, filename);
    }
    return await Isolate.run(() => _readLocal(path, extension, filename));
  } on FormatException {
    rethrow;
  } on FileSystemException catch (error) {
    throw FormatException(
      'Cannot read the ebook. Check that the file is accessible: ${error.message}',
    );
  } catch (error) {
    throw FormatException(
      'Cannot parse this $extension ebook. It may be damaged, encrypted, or unsupported. Details: $error',
    );
  }
}

Future<void> _checkFile(File file) async {
  final size = await file.length();
  if (size == 0) throw const FormatException('The ebook file is empty.');
  if (size > _maxFileBytes) {
    throw const FormatException(
      'The ebook exceeds the 64 MiB import limit. Choose a smaller text edition.',
    );
  }
}

Future<EbookDocument> _readLocal(
  String path,
  String extension,
  String filename,
) async {
  final file = File(path);
  await _checkFile(file);
  final bytes = await file.readAsBytes();
  if (bytes.length > _maxFileBytes) {
    throw const FormatException('The ebook exceeds the 64 MiB import limit.');
  }
  switch (extension) {
    case 'epub':
      return _readEpub(bytes, filename);
    case 'docx':
      return _readDocx(bytes, filename);
    case 'fb2':
      return _readFb2(bytes, filename);
    case 'html':
    case 'htm':
      final source = _decodeText(bytes, markup: true);
      final document = html_parser.parse(source);
      return _result(
        document.querySelector('title')?.text ?? filename,
        _htmlText(document.body ?? document.documentElement!),
        filename,
      );
    case 'mobi':
    case 'azw':
    case 'azw3':
      return _readMobi(bytes, filename);
    default:
      return _result(filename, _decodeText(bytes), filename);
  }
}

EbookDocument _result(String title, String text, String fallback) {
  if (text.length > _maxTextCharacters) {
    throw const FormatException(
      'The ebook text exceeds the 32 million character import limit.',
    );
  }
  final clean = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\u0000', '')
      .replaceAll('\ufeff', '')
      .trim();
  if (clean.isEmpty) {
    throw const FormatException(
      'No readable text was found in this ebook. Choose a text edition.',
    );
  }
  return EbookDocument(
    title: title.trim().isEmpty ? fallback : title.trim(),
    text: clean,
  );
}

Future<EbookDocument> _readPdf(String path, String filename) async {
  // Required before direct document APIs; idempotent and initializes bundled
  // native PDFium on Android/Windows, not the network-backed web engine.
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openFile(path);
  try {
    final text = StringBuffer();
    if (document.pages.length > 10000) {
      throw const FormatException(
        'The PDF exceeds the 10,000 page import limit.',
      );
    }
    for (final page in document.pages) {
      final pageText = await page.loadText();
      if (pageText != null) text.writeln(pageText.fullText);
      if (text.length > _maxTextCharacters) {
        throw const FormatException('The PDF text exceeds the import limit.');
      }
    }
    if (text.toString().trim().isEmpty) {
      throw const FormatException(
        'This PDF has no extractable text. Scanned/image PDFs need OCR first; AudioSubs does not perform OCR.',
      );
    }
    return _result(filename, text.toString(), filename);
  } finally {
    await document.dispose();
  }
}

const _cp1252 = <int>[
  0x20ac,
  0x81,
  0x201a,
  0x192,
  0x201e,
  0x2026,
  0x2020,
  0x2021,
  0x2c6,
  0x2030,
  0x160,
  0x2039,
  0x152,
  0x8d,
  0x17d,
  0x8f,
  0x90,
  0x2018,
  0x2019,
  0x201c,
  0x201d,
  0x2022,
  0x2013,
  0x2014,
  0x2dc,
  0x2122,
  0x161,
  0x203a,
  0x153,
  0x9d,
  0x17e,
  0x178,
];

String _windowsText(List<int> bytes) => String.fromCharCodes(
  bytes.map(
    (byte) => byte >= 0x80 && byte < 0xa0 ? _cp1252[byte - 0x80] : byte,
  ),
);

String _decodeText(Uint8List bytes, {bool markup = false, int? encoding}) {
  if (encoding == 1252) return _windowsText(bytes);
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
          (bytes[0] == 0xfe && bytes[1] == 0xff))) {
    if (bytes.length.isOdd) {
      throw const FormatException('Truncated UTF-16 ebook text.');
    }
    final little = bytes[0] == 0xff;
    final data = ByteData.sublistView(bytes);
    return String.fromCharCodes([
      for (var offset = 2; offset < bytes.length; offset += 2)
        data.getUint16(offset, little ? Endian.little : Endian.big),
    ]);
  }
  var forceUtf8 = encoding == 65001;
  if (markup && bytes.isNotEmpty) {
    final head = latin1.decode(
      Uint8List.sublistView(
        bytes,
        0,
        bytes.length < 1024 ? bytes.length : 1024,
      ),
    );
    final declared = RegExp(
      r'''(?:encoding\s*=\s*["']|charset\s*=\s*["']?)([a-zA-Z0-9_-]+)''',
      caseSensitive: false,
    ).firstMatch(head)?.group(1)?.toLowerCase();
    if (declared != null) {
      if (const {
        'windows-1252',
        'cp1252',
        'iso-8859-1',
        'latin1',
      }.contains(declared)) {
        return _windowsText(bytes);
      }
      if (!const {'utf-8', 'utf8', 'us-ascii', 'ascii'}.contains(declared)) {
        throw FormatException(
          'Unsupported text encoding "$declared". Save this ebook as UTF-8 first.',
        );
      }
      forceUtf8 = true;
    }
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    if (forceUtf8) {
      throw const FormatException(
        'The ebook contains invalid UTF-8 text. Re-export it as UTF-8.',
      );
    }
    return _windowsText(bytes);
  }
}

XmlDocument _xml(Uint8List bytes) {
  final source = _decodeText(bytes, markup: true);
  if (RegExp(r'<!DOCTYPE|<!ENTITY', caseSensitive: false).hasMatch(source)) {
    throw const FormatException(
      'XML document types and entity declarations are unsupported. Re-export the ebook without a DTD.',
    );
  }
  final document = XmlDocument.parse(source);
  var nodes = 0;
  final pending = <(XmlNode, int)>[(document, 0)];
  while (pending.isNotEmpty) {
    final (node, depth) = pending.removeLast();
    if (++nodes > _maxNodes || depth > _maxDepth) {
      throw const FormatException(
        'The ebook XML is too complex to import safely.',
      );
    }
    for (final child in node.children) {
      pending.add((child, depth + 1));
    }
  }
  return document;
}

Iterable<XmlElement> _elements(XmlNode node, String name) => node.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == name);

String? _attribute(XmlElement element, String name) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == name) return attribute.value;
  }
  return null;
}

const _htmlBlocks = <String>{
  'address',
  'article',
  'aside',
  'blockquote',
  'div',
  'dl',
  'dt',
  'dd',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'header',
  'hr',
  'li',
  'main',
  'ol',
  'p',
  'pre',
  'section',
  'table',
  'tr',
  'ul',
  'mbp:pagebreak',
};

String _htmlText(html.Node root) {
  final output = StringBuffer();
  var count = 0;
  void visit(html.Node node, int depth) {
    if (++count > _maxNodes ||
        depth > _maxDepth ||
        output.length > _maxTextCharacters) {
      throw const FormatException(
        'The ebook HTML is too complex or too large to import safely.',
      );
    }
    if (node is html.Text) {
      output.write(node.data.replaceAll(RegExp(r'\s+'), ' '));
    } else if (node is html.Element) {
      final tag = node.localName;
      if (const {
            'script',
            'style',
            'nav',
            'head',
            'noscript',
            'template',
          }.contains(tag) ||
          node.attributes.containsKey('hidden') ||
          node.attributes['aria-hidden'] == 'true' ||
          node.attributes['role'] == 'navigation' ||
          node.attributes['epub:type']?.split(RegExp(r'\s+')).contains('toc') ==
              true) {
        return;
      }
      final block = _htmlBlocks.contains(tag);
      if (block || tag == 'br') output.writeln();
      if (tag == 'td' || tag == 'th') output.write(' ');
      for (final child in node.nodes) {
        visit(child, depth + 1);
      }
      if (block) output.writeln();
    } else {
      for (final child in node.nodes) {
        visit(child, depth + 1);
      }
    }
  }

  visit(root, 0);
  return output
      .toString()
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

/// ZIP members remain in memory. No archive-controlled path is ever written.
class _BookZip {
  final Map<String, ZipFileHeader> _entries = {};

  _BookZip(Uint8List bytes) {
    if (bytes.length < 22) {
      throw const FormatException('Invalid or truncated ZIP ebook.');
    }
    final data = ByteData.sublistView(bytes);
    var end = -1;
    final earliest = bytes.length - 65557 > 0 ? bytes.length - 65557 : 0;
    for (var offset = bytes.length - 22; offset >= earliest; offset--) {
      if (data.getUint32(offset, Endian.little) == 0x06054b50 &&
          offset + 22 + data.getUint16(offset + 20, Endian.little) ==
              bytes.length) {
        end = offset;
        break;
      }
    }
    if (end < 0) throw const FormatException('Invalid ZIP ebook directory.');
    final count = data.getUint16(end + 10, Endian.little);
    if (count > 10000 ||
        data.getUint32(end + 12, Endian.little) > 8 * 1024 * 1024) {
      throw const FormatException(
        'The ZIP ebook directory exceeds safe import limits (10,000 entries / 8 MiB).',
      );
    }
    if (data.getUint16(end + 4, Endian.little) != 0 ||
        data.getUint16(end + 6, Endian.little) != 0 ||
        data.getUint16(end + 8, Endian.little) != count) {
      throw const FormatException(
        'Split/multi-volume ZIP ebooks are unsupported.',
      );
    }
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.length != count) {
      throw const FormatException('The ZIP ebook directory is incomplete.');
    }
    var expanded = 0;
    for (final entry in directory.fileHeaders) {
      if (entry.generalPurposeBitFlag & 1 != 0 ||
          (entry.file!.flags & 1) != 0) {
        throw const FormatException(
          'This ZIP ebook is encrypted. Choose a DRM-free, unencrypted edition.',
        );
      }
      if (entry.compressionMethod != 0 && entry.compressionMethod != 8) {
        throw const FormatException(
          'Unsupported ZIP compression. Re-export using standard ZIP/deflate.',
        );
      }
      expanded += entry.uncompressedSize;
      if (entry.uncompressedSize > _maxEntryBytes ||
          expanded > _maxExpandedBytes) {
        throw const FormatException(
          'The ebook exceeds safe expanded ZIP limits (16 MiB/member, 128 MiB total).',
        );
      }
      final name = entry.filename;
      if (name.startsWith('/') ||
          name.contains('\\') ||
          name.split('/').any((part) => part == '..') ||
          name.contains(':')) {
        throw const FormatException(
          'The ZIP ebook contains an unsafe member path.',
        );
      }
      if (_entries.containsKey(name)) {
        throw const FormatException(
          'The ZIP ebook has duplicate member paths.',
        );
      }
      _entries[name] = entry;
    }
  }

  bool contains(String name) => _entries.containsKey(name);

  Uint8List read(String name) {
    final entry = _entries[name];
    if (entry == null) {
      throw FormatException(
        'The ebook is missing "$name". Re-export a complete ebook.',
      );
    }
    final bytes = entry.file!.getStream().toUint8List();
    if (bytes.length != entry.uncompressedSize ||
        getCrc32(bytes) != entry.crc32) {
      throw FormatException(
        'The ebook member "$name" is damaged (size/checksum mismatch).',
      );
    }
    return bytes;
  }
}

String _resolveMember(String base, String reference) {
  final uri = Uri.parse(reference);
  if (uri.hasScheme || uri.hasAuthority || reference.contains('\\')) {
    throw const FormatException(
      'The ebook refers to a remote or invalid content URL. Only bundled offline content is supported.',
    );
  }
  final resolved = Uri(path: '/$base').resolveUri(uri);
  final path = Uri.decodeComponent(resolved.path);
  if (!path.startsWith('/') ||
      path.contains('\\') ||
      path.contains('\u0000') ||
      path.split('/').contains('..')) {
    throw const FormatException(
      'The ebook contains an invalid relative content URL.',
    );
  }
  return path.substring(1);
}

EbookDocument _readEpub(Uint8List bytes, String filename) {
  final zip = _BookZip(bytes);
  final container = _xml(zip.read('META-INF/container.xml'));
  final roots = _elements(container, 'rootfile').toList();
  if (roots.isEmpty) {
    throw const FormatException('The EPUB has no package document.');
  }
  final packagePath = _attribute(roots.first, 'full-path');
  if (packagePath == null || packagePath.isEmpty) {
    throw const FormatException('The EPUB package path is missing.');
  }
  final opfPath = _resolveMember('', packagePath);
  final package = _xml(zip.read(opfPath));
  final manifest = <String, XmlElement>{};
  for (final item in _elements(package, 'item')) {
    final id = _attribute(item, 'id');
    if (id != null) manifest[id] = item;
  }
  final encrypted = <String>{};
  if (zip.contains('META-INF/encryption.xml')) {
    final encryption = _xml(zip.read('META-INF/encryption.xml'));
    for (final item in _elements(encryption, 'CipherReference')) {
      final uri = _attribute(item, 'URI');
      if (uri != null) encrypted.add(_resolveMember('', uri));
    }
  }
  final output = StringBuffer();
  for (final itemref in _elements(package, 'itemref')) {
    if (_attribute(itemref, 'linear') == 'no') continue;
    final item = manifest[_attribute(itemref, 'idref')];
    if (item == null) {
      throw const FormatException(
        'The EPUB spine references a missing manifest item.',
      );
    }
    if ((_attribute(item, 'properties') ?? '')
        .split(RegExp(r'\s+'))
        .contains('nav')) {
      continue;
    }
    final href = _attribute(item, 'href');
    if (href == null) {
      throw const FormatException('The EPUB spine item has no content URL.');
    }
    final member = _resolveMember(opfPath, href);
    if (encrypted.contains(member)) {
      throw const FormatException(
        'The EPUB reading text is DRM-encrypted. Choose a DRM-free edition.',
      );
    }
    final mediaType = _attribute(item, 'media-type');
    if (mediaType != 'application/xhtml+xml' && mediaType != 'text/html') {
      throw FormatException(
        'Unsupported EPUB spine content "$mediaType". Choose a reflowable text EPUB.',
      );
    }
    final document = html_parser.parse(
      _decodeText(zip.read(member), markup: true),
    );
    output.writeln(_htmlText(document.body ?? document.documentElement!));
    if (output.length > _maxTextCharacters) {
      throw const FormatException('The EPUB text exceeds the import limit.');
    }
  }
  final titles = _elements(package, 'title');
  return _result(
    titles.isEmpty ? filename : titles.first.innerText,
    output.toString(),
    filename,
  );
}

EbookDocument _readDocx(Uint8List bytes, String filename) {
  final zip = _BookZip(bytes);
  final document = _xml(zip.read('word/document.xml'));
  final bodies = _elements(document, 'body');
  if (bodies.isEmpty) {
    throw const FormatException('The DOCX has no document body.');
  }
  final output = StringBuffer();
  void visit(XmlNode node) {
    if (node is! XmlElement) return;
    final name = node.name.local;
    // Exclude deleted revisions/instructions, retaining visible field results.
    if (name == 'del' || name == 'instrText') return;
    if (name == 't') {
      output.write(node.innerText);
    } else if (name == 'tab') {
      output.write(' ');
    } else if (name == 'br' || name == 'cr') {
      output.writeln();
    } else {
      for (final child in node.children) {
        visit(child);
      }
      if (name == 'p') output.writeln();
    }
    if (output.length > _maxTextCharacters) {
      throw const FormatException('The DOCX text exceeds the import limit.');
    }
  }

  visit(bodies.first);
  return _result(filename, output.toString(), filename);
}

EbookDocument _readFb2(Uint8List bytes, String filename) {
  final document = _xml(bytes);
  if (document.rootElement.name.local != 'FictionBook') {
    throw const FormatException('This file is not a FictionBook (FB2) ebook.');
  }
  final output = StringBuffer();
  void visit(XmlNode node) {
    if (node is XmlText || node is XmlCDATA) {
      output.write(node.value?.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    if (node is XmlElement &&
        const {'binary', 'image'}.contains(node.name.local)) {
      return;
    }
    final block =
        node is XmlElement &&
        const {
          'p',
          'v',
          'subtitle',
          'text-author',
          'empty-line',
          'section',
          'title',
          'poem',
          'stanza',
        }.contains(node.name.local);
    if (block) output.writeln();
    for (final child in node.children) {
      visit(child);
    }
    if (block) output.writeln();
  }

  for (final body in _elements(document, 'body')) {
    // FB2 named bodies hold notes, not the main reading sequence.
    if (_attribute(body, 'name') != null) continue;
    visit(body);
  }
  final title = _elements(document, 'book-title');
  final text = output
      .toString()
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
  return _result(
    title.isEmpty ? filename : title.first.innerText,
    text,
    filename,
  );
}

// Clean-room implementation from the public format descriptions only:
// https://wiki.mobileread.com/wiki/MOBI
// https://wiki.mobileread.com/wiki/PalmDOC
// No third-party Kindle parser source or DRM circumvention is used.
EbookDocument _readMobi(Uint8List bytes, String filename) {
  if (bytes.length < 86) {
    throw const FormatException('Invalid or truncated Palm/MOBI database.');
  }
  final data = ByteData.sublistView(bytes);
  final signature = ascii.decode(
    Uint8List.sublistView(bytes, 60, 68),
    allowInvalid: true,
  );
  final palm = signature == 'TEXtREAd';
  if (!palm && signature != 'BOOKMOBI') {
    throw const FormatException(
      'This is not a supported PalmDOC/MOBI ebook. KFX and other Kindle containers are unsupported; export EPUB instead.',
    );
  }
  final count = data.getUint16(76);
  if (count < 2 || count > 10000 || 78 + count * 8 > bytes.length) {
    throw const FormatException('Invalid MOBI record directory.');
  }
  final offsets = <int>[];
  for (var index = 0; index < count; index++) {
    final offset = data.getUint32(78 + index * 8);
    if (offset < 78 + count * 8 ||
        offset >= bytes.length ||
        (offsets.isNotEmpty && offset <= offsets.last)) {
      throw const FormatException('Invalid MOBI record offsets.');
    }
    offsets.add(offset);
  }
  offsets.add(bytes.length);
  final header = Uint8List.sublistView(bytes, offsets[0], offsets[1]);
  if (header.length < 16) {
    throw const FormatException('Truncated PalmDOC header.');
  }
  final h = ByteData.sublistView(header);
  final compression = h.getUint16(0);
  if (!palm && h.getUint16(12) != 0) {
    throw const FormatException(
      'This Kindle ebook is DRM-encrypted. Choose a DRM-free EPUB or MOBI edition.',
    );
  }
  if (compression == 17480) {
    throw const FormatException(
      'HUFF/CDIC Kindle compression is unsupported. Convert a DRM-free copy to EPUB first.',
    );
  }
  if (compression != 1 && compression != 2) {
    throw const FormatException(
      'Unsupported PalmDOC/MOBI compression. Export EPUB instead.',
    );
  }
  final textLength = h.getUint32(4);
  final textRecords = h.getUint16(8);
  final recordSize = h.getUint16(10);
  if (textLength == 0 ||
      textLength > _maxTextCharacters ||
      textRecords == 0 ||
      textRecords >= count ||
      recordSize == 0 ||
      recordSize > 65536) {
    throw const FormatException(
      'Invalid or oversized MOBI text record information.',
    );
  }
  var encoding = 1252;
  var extraFlags = 0;
  var title = _windowsText(Uint8List.sublistView(bytes, 0, 32))
      .split('\u0000')
      .first;
  if (!palm) {
    if (header.length < 40 ||
        ascii.decode(
              Uint8List.sublistView(header, 16, 20),
              allowInvalid: true,
            ) !=
            'MOBI') {
      throw const FormatException(
        'Missing MOBI header. Export a standard DRM-free MOBI or EPUB.',
      );
    }
    final headerLength = h.getUint32(20);
    if (headerLength < 24 || headerLength + 16 > header.length) {
      throw const FormatException('Truncated MOBI header.');
    }
    if (h.getUint32(36) >= 8 || h.getUint32(24) == 248) {
      throw const FormatException(
        'KF8/AZW3 layout is unsupported. Convert a DRM-free copy to EPUB; legacy MOBI7 renditions are supported.',
      );
    }
    encoding = h.getUint32(28);
    if (encoding != 1252 && encoding != 65001) {
      throw FormatException(
        'Unsupported MOBI text encoding $encoding. Export UTF-8 EPUB instead.',
      );
    }
    if (headerLength >= 164) {
      final drmOffset = h.getUint32(168);
      final drmCount = h.getUint32(172);
      if (drmOffset != 0xffffffff && drmCount != 0 && drmCount != 0xffffffff) {
        throw const FormatException(
          'This Kindle ebook contains DRM data. Choose a DRM-free edition.',
        );
      }
    }
    if (headerLength >= 228) extraFlags = h.getUint32(240);
    if (headerLength >= 76) {
      final start = h.getUint32(84);
      final length = h.getUint32(88);
      if (length > 0) {
        if (start < 16 + headerLength || start + length > header.length) {
          throw const FormatException('Invalid MOBI title offset.');
        }
        title = _decodeText(
          Uint8List.sublistView(header, start, start + length),
          encoding: encoding,
        );
      }
    }
  }
  final text = BytesBuilder(copy: false);
  for (var index = 1; index <= textRecords; index++) {
    final record = Uint8List.sublistView(
      bytes,
      offsets[index],
      offsets[index + 1],
    );
    final end = _mobiTextEnd(record, extraFlags);
    final payload = Uint8List.sublistView(record, 0, end);
    final decoded = compression == 1
        ? payload
        : _palmDecompress(payload, recordSize);
    if (decoded.length > recordSize ||
        text.length + decoded.length > _maxTextCharacters) {
      throw const FormatException(
        'MOBI text exceeds its declared record size or the import limit.',
      );
    }
    text.add(decoded);
  }
  final decoded = text.takeBytes();
  if (decoded.length != textLength) {
    throw const FormatException(
      'MOBI text length does not match its header. The ebook is damaged or unsupported.',
    );
  }
  final source = _decodeText(decoded, encoding: encoding);
  if (palm) return _result(title, source, filename);
  final document = html_parser.parse(source);
  return _result(
    title,
    _htmlText(document.body ?? document.documentElement!),
    filename,
  );
}

int _mobiTextEnd(Uint8List record, int flags) {
  var end = record.length;
  for (var bit = 31; bit >= 1; bit--) {
    if (flags & (1 << bit) == 0) continue;
    var size = 0;
    var shift = 0;
    var cursor = end;
    var terminated = false;
    while (cursor > 0 && shift < 28) {
      final byte = record[--cursor];
      size |= (byte & 0x7f) << shift;
      shift += 7;
      if (byte & 0x80 != 0) {
        terminated = true;
        break;
      }
    }
    if (!terminated || size < end - cursor || size > end) {
      throw const FormatException('Invalid MOBI trailing record data.');
    }
    end -= size;
  }
  if (flags & 1 != 0) {
    if (end == 0) {
      throw const FormatException('Invalid MOBI character overlap data.');
    }
    end -= (record[end - 1] & 3) + 1;
    if (end < 0) {
      throw const FormatException('Truncated MOBI character overlap data.');
    }
  }
  return end;
}

Uint8List _palmDecompress(Uint8List input, int limit) {
  final output = Uint8List(limit);
  var length = 0;
  var cursor = 0;
  void append(int byte) {
    if (length >= limit) {
      throw const FormatException(
        'PalmDOC decompression exceeds its record size.',
      );
    }
    output[length++] = byte;
  }

  while (cursor < input.length) {
    final byte = input[cursor++];
    if (byte >= 1 && byte <= 8) {
      if (cursor + byte > input.length) {
        throw const FormatException('Truncated PalmDOC literal sequence.');
      }
      for (var index = 0; index < byte; index++) {
        append(input[cursor++]);
      }
    } else if (byte >= 0x80 && byte <= 0xbf) {
      if (cursor == input.length) {
        throw const FormatException('Truncated PalmDOC back-reference.');
      }
      final pair = ((byte & 0x3f) << 8) | input[cursor++];
      final distance = pair >> 3;
      final count = (pair & 7) + 3;
      if (distance == 0 || distance > length) {
        throw const FormatException('Invalid PalmDOC back-reference distance.');
      }
      for (var index = 0; index < count; index++) {
        append(output[length - distance]);
      }
    } else if (byte >= 0xc0) {
      append(0x20);
      append(byte ^ 0x80);
    } else {
      append(byte);
    }
  }
  return Uint8List.sublistView(output, 0, length);
}
