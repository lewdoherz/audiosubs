import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audiobook_player/proofreading/ebook.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('audiosubs_ebook_');
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<EbookDocument> readFixture(String name, List<int> bytes) async {
    final file = File('${temporary.path}/$name');
    await file.writeAsBytes(bytes);
    return readEbook(file.path);
  }

  test('EPUB follows OPF spine and resolves encoded relative URLs', () async {
    final book = await readFixture('ordered.epub', _epub());
    expect(book.title, 'Fixture & Book');
    expect(book.text, 'Second on disk\nFirst on disk');
    expect(book.text, isNot(contains('Navigation')));
  });

  test(
    'EPUB rejects encrypted reading text but permits font obfuscation',
    () async {
      final encrypted = _epub(
        encryption: '''
      <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <EncryptedData><CipherData><CipherReference URI="OPS/Text/second%20chapter.xhtml"/></CipherData></EncryptedData>
      </encryption>''',
      );
      await expectLater(
        readFixture('encrypted.epub', encrypted),
        throwsFormatException,
      );
      final fontOnly = await readFixture(
        'font.epub',
        _epub(
          encryption: '''
      <encryption><EncryptedData><CipherData><CipherReference URI="OPS/font.otf"/></CipherData></EncryptedData></encryption>''',
        ),
      );
      expect(fontOnly.text, contains('Second on disk'));
    },
  );

  test(
    'EPUB missing spine content is an error rather than partial text',
    () async {
      await expectLater(
        readFixture('missing.epub', _epub(missingChapter: true)),
        throwsFormatException,
      );
    },
  );

  test('HTML decodes entities and preserves blocks without executable/navigation text', () async {
    final book = await readFixture(
      'book.HTML',
      utf8.encode('''
      <!doctype html><html><head><title>A &amp; B</title>
      <style>not book text</style><script>not book text either</script></head>
      <body><nav>Navigation</nav><p>Tom &amp; Jo&nbsp;said &ldquo;Hi&rdquo;.</p>
      <div>Next <em>paragraph</em>.<br>New line.</div><p hidden>Hidden</p>
      <div role="navigation">Also navigation</div></body></html>'''),
    );
    expect(book.title, 'A & B');
    expect(book.text, 'Tom & Jo said “Hi”.\nNext paragraph.\nNew line.');
  });

  test('DOCX joins runs and separates paragraphs and table cells', () async {
    final book = await readFixture(
      'book.docx',
      _zip({
        'word/document.xml': '''<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:r><w:t>Hello </w:t></w:r><w:r><w:t>world &amp; friends.</w:t></w:r></w:p>
        <w:p><w:del><w:r><w:delText>deleted</w:delText></w:r></w:del><w:r><w:t>Next</w:t><w:br/><w:t>line</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell one</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Cell two</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
      </w:body></w:document>''',
      }),
    );
    expect(book.text, 'Hello world & friends.\nNext\nline\nCell one\nCell two');
  });

  test('FB2 extracts main bodies in order, entities and inline text', () async {
    final book = await readFixture(
      'book.fb2',
      utf8.encode('''
      <?xml version="1.0" encoding="UTF-8"?>
      <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
      <description><title-info><book-title>My book</book-title><annotation><p>Not body text</p></annotation></title-info></description>
      <body><section><title><p>Chapter One</p></title><p>A <emphasis>little</emphasis> &amp; more.</p><p>Next.</p></section></body>
      <body name="notes"><section><p>Footnote not main text</p></section></body><binary>not text</binary>
      </FictionBook>'''),
    );
    expect(book.title, 'My book');
    expect(book.text, 'Chapter One\nA little & more.\nNext.');
  });

  test('TXT supports UTF-8, UTF-16 BOM and Windows-1252 punctuation', () async {
    final utf = await readFixture(
      'utf.txt',
      utf8.encode('\ufeffFirst\r\nSecond café'),
    );
    expect(utf.text, 'First\nSecond café');
    final windows = await readFixture('windows.txt', [
      0x93,
      ...ascii.encode('Hello'),
      0x94,
      0x20,
      0x80,
    ]);
    expect(windows.text, '“Hello” €');
    final utf16 = await readFixture('utf16.txt', [
      0xff,
      0xfe,
      0x41,
      0,
      0x0a,
      0,
      0x42,
      0,
    ]);
    expect(utf16.text, 'A\nB');
  });

  test(
    'MOBI uncompressed UTF-8 extracts readable HTML and its title',
    () async {
      final source = utf8.encode(
        '<html><body><p>Café &amp; tea.</p><p>Next.</p></body></html>',
      );
      final book = await readFixture(
        'book.mobi',
        _mobi(source, textLength: source.length, encoding: 65001),
      );
      expect(book.title, 'Fixture title');
      expect(book.text, 'Café & tea.\nNext.');
    },
  );

  test(
    'PalmDOC handles literals, overlapping back-references and byte pairs',
    () async {
      // abc, then six bytes from three bytes back, then the " d" byte pair,
      // followed by a two-byte literal sequence containing CP1252 quotes.
      final compressed = [0x61, 0x62, 0x63, 0x80, 0x1b, 0xe4, 2, 0x93, 0x94];
      final book = await readFixture(
        'compressed.azw',
        _mobi(compressed, compression: 2, textLength: 13),
      );
      expect(book.text, 'abcabcabc d“”');
    },
  );

  test('legacy PalmDOC databases preserve plain text', () async {
    final source = ascii.encode('First paragraph\nSecond paragraph');
    final book = await readFixture(
      'palm.mobi',
      _mobi(source, palm: true, textLength: source.length),
    );
    expect(book.text, 'First paragraph\nSecond paragraph');
  });

  test(
    'MOBI reads independent records and strips declared trailing bytes',
    () async {
      final first = ascii.encode('<p>First</p>');
      final second = ascii.encode('<p>Second</p>');
      final book = await readFixture(
        'trailing.mobi',
        _mobi(
          [...first, 0x41, 0x82],
          additional: [
            [...second, 0x42, 0x82],
          ],
          textLength: first.length + second.length,
          extraFlags: 2,
        ),
      );
      expect(book.text, 'First\nSecond');
    },
  );

  test('MOBI strips multibyte overlap before decoding joined UTF-8', () async {
    final first = [...ascii.encode('<p>caf'), 0xc3];
    final second = [0xa9, ...ascii.encode('</p>')];
    final book = await readFixture(
      'overlap.mobi',
      _mobi(
        [...first, 0xa9, 1],
        additional: [
          [...second, 0],
        ],
        textLength: first.length + second.length,
        encoding: 65001,
        extraFlags: 1,
      ),
    );
    expect(book.text, 'café');
  });

  test('MOBI DRM, HUFF/CDIC and KF8 are explicitly rejected', () async {
    for (final bytes in [
      _mobi(ascii.encode('secret'), encryption: 2, textLength: 6),
      _mobi(ascii.encode('secret'), compression: 17480, textLength: 6),
      _mobi(ascii.encode('secret'), version: 8, textLength: 6),
    ]) {
      await expectLater(
        readFixture('unsupported.azw3', bytes),
        throwsFormatException,
      );
    }
  });

  test(
    'MOBI invalid compression sequences and corrupt lengths fail explicitly',
    () async {
      for (final bytes in [
        _mobi([0x80, 8], compression: 2, textLength: 3),
        _mobi([4, 0x61], compression: 2, textLength: 4),
        _mobi(ascii.encode('short'), textLength: 40),
        _mobi([0xc3], encoding: 65001, textLength: 1),
      ]) {
        await expectLater(
          readFixture('damaged.mobi', bytes),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'empty, malformed, textless and unsupported inputs fail explicitly',
    () async {
      for (final fixture in <(String, List<int>)>[
        ('empty.txt', []),
        ('blank.txt', utf8.encode(' \n\t ')),
        ('bad.epub', [1, 2, 3]),
        ('bad.docx', _zip({'word/document.xml': '<broken>'})),
        ('bad.fb2', utf8.encode('<FictionBook><body>')),
        ('bad.mobi', List.filled(100, 0)),
        (
          'image.htm',
          utf8.encode('<img src="image.jpg"><script>hidden text</script>'),
        ),
        ('unsupported.kfx', utf8.encode('not a supported format')),
        (
          'unsupported.fb2',
          utf8.encode(
            '<?xml version="1.0" encoding="windows-1251"?><FictionBook/>',
          ),
        ),
      ]) {
        await expectLater(
          readFixture(fixture.$1, fixture.$2),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'ZIP traversal members and declared oversized entries are rejected',
    () async {
      await expectLater(
        readFixture(
          'unsafe.docx',
          _zip({
            '../outside.txt': 'unsafe',
            'word/document.xml':
                '<document><body><p>Text</p></body></document>',
          }),
        ),
        throwsFormatException,
      );
      final bytes = _zip({
        'word/document.xml': '<document><body><p>Text</p></body></document>',
      });
      final data = ByteData.sublistView(bytes);
      for (var offset = 0; offset < bytes.length - 46; offset++) {
        if (data.getUint32(offset, Endian.little) == 0x02014b50) {
          data.setUint32(offset + 24, 17 * 1024 * 1024, Endian.little);
          break;
        }
      }
      await expectLater(
        readFixture('oversized.docx', bytes),
        throwsFormatException,
      );
    },
  );
}

Uint8List _zip(Map<String, String> members) {
  final archive = Archive();
  for (final member in members.entries) {
    archive.add(ArchiveFile.bytes(member.key, utf8.encode(member.value)));
  }
  return ZipEncoder().encodeBytes(archive);
}

Uint8List _epub({String? encryption, bool missingChapter = false}) => _zip({
  'mimetype': 'application/epub+zip',
  'META-INF/container.xml': '''<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  'OPS/package.opf': '''<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Fixture &amp; Book</dc:title></metadata>
    <manifest><item id="first" href="Text/first.xhtml" media-type="application/xhtml+xml"/>
    <item id="second" href="Text/sub/../second%20chapter.xhtml#start" media-type="application/xhtml+xml"/>
    <item id="nav" href="navigation.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="appendix" href="appendix.xhtml" media-type="application/xhtml+xml"/></manifest>
    <spine><itemref idref="nav"/><itemref idref="second"/><itemref idref="first"/><itemref idref="appendix" linear="no"/></spine></package>''',
  'OPS/Text/first.xhtml': '<html><body><p>First on disk</p></body></html>',
  if (!missingChapter)
    'OPS/Text/second chapter.xhtml':
        '<html><body><p>Second on disk</p></body></html>',
  'OPS/navigation.xhtml': '<html><body><p>Navigation</p></body></html>',
  'META-INF/encryption.xml': ?encryption,
});

Uint8List _mobi(
  List<int> payload, {
  required int textLength,
  int compression = 1,
  int encoding = 1252,
  int encryption = 0,
  int version = 6,
  int extraFlags = 0,
  bool palm = false,
  List<List<int>> additional = const [],
}) {
  final title = ascii.encode('Fixture title');
  final headerLength = palm ? 16 : 16 + 232 + title.length;
  final records = [payload, ...additional];
  final count = 1 + records.length;
  final recordStart = 78 + count * 8 + 2;
  final total =
      recordStart +
      headerLength +
      records.fold<int>(0, (size, record) => size + record.length);
  final bytes = Uint8List(total);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, title.length, title);
  bytes.setRange(60, 68, ascii.encode(palm ? 'TEXtREAd' : 'BOOKMOBI'));
  data.setUint16(76, count);
  data.setUint32(78, recordStart);
  var offset = recordStart + headerLength;
  for (var index = 0; index < records.length; index++) {
    data.setUint32(78 + (index + 1) * 8, offset);
    bytes.setRange(offset, offset + records[index].length, records[index]);
    offset += records[index].length;
  }
  data.setUint16(recordStart, compression);
  data.setUint32(recordStart + 4, textLength);
  data.setUint16(recordStart + 8, records.length);
  data.setUint16(recordStart + 10, 4096);
  data.setUint16(recordStart + 12, encryption);
  if (!palm) {
    bytes.setRange(recordStart + 16, recordStart + 20, ascii.encode('MOBI'));
    data.setUint32(recordStart + 20, 232);
    data.setUint32(recordStart + 24, 2);
    data.setUint32(recordStart + 28, encoding);
    data.setUint32(recordStart + 36, version);
    data.setUint32(recordStart + 84, 248);
    data.setUint32(recordStart + 88, title.length);
    data.setUint32(recordStart + 168, 0xffffffff);
    data.setUint32(recordStart + 172, 0xffffffff);
    data.setUint32(recordStart + 240, extraFlags);
    bytes.setRange(recordStart + 248, recordStart + 248 + title.length, title);
  }
  return bytes;
}
