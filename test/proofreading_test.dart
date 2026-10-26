import 'package:audiobook_player/proofreading/review.dart';
import 'package:flutter_test/flutter_test.dart';

SrtDocument subtitles(List<String> text) => SrtDocument.parse(
  [
    for (var i = 0; i < text.length; i++)
      '${i + 1}\n00:00:01,000 --> 00:00:04,500\n${text[i]}',
  ].join('\n\n'),
);

void main() {
  group('lossless SRT parsing and rendering', () {
    test(
      'preserves BOM, CRLF, numbering, timing, separators and unchanged text',
      () {
        const source =
            '\uFEFF001\r\n00:01:02,003  -->  00:01:04,567\r\n'
            'Original first line\r\nsecond line\r\n \r\n'
            '19\r\n00:01:05,000 --> 00:01:07,000\r\nUntouched!\r\n';
        final document = SrtDocument.parse(source);
        expect(document.cues.length, 2);
        expect(document.cues.first.number, '001');
        expect(document.cues.first.timing, '00:01:02,003  -->  00:01:04,567');
        expect(document.cues.first.text, 'Original first line\r\nsecond line');
        expect(document.render({}), source);
        expect(document.render({0: document.cues.first.text}), source);
        expect(
          document.render({0: 'Corrected\nsecond line'}),
          source.replaceFirst(
            'Original first line\r\nsecond line',
            'Corrected\r\nsecond line',
          ),
        );
      },
    );

    test(
      'retains nonsequential cue numbers, order and missing final newline',
      () {
        const source =
            '10\n00:00:03,000 --> 00:00:04,000\nOne\n\n'
            '2\n00:00:01,000 --> 00:00:02,000\nTwo';
        final document = SrtDocument.parse(source);
        expect(document.cues.map((cue) => cue.number), ['10', '2']);
        expect(
          document.render({1: 'Second'}),
          source.replaceFirst('Two', 'Second'),
        );
      },
    );

    test('retains mixed source line endings outside a replacement', () {
      const source =
          '1\r\n00:00:01,000 --> 00:00:02,000\r\nOld\r\n\r\n'
          '2\n00:00:02,000 --> 00:00:03,000\nOther\n';
      expect(
        SrtDocument.parse(source).render({0: 'New\nline'}),
        source.replaceFirst('Old', 'New\r\nline'),
      );
    });

    final malformed = <String>[
      '',
      '\uFEFF \n\n',
      'not an SRT file',
      'one\n00:00:00,000 --> 00:00:01,000\nText',
      '1\n00:00:00,000 --> 00:00:01,000',
      '1\n00:60:00,000 --> 00:61:01,000\nText',
      '1\n00:00:03,000 --> 00:00:01,000\nText',
      '1\n00:00:00,000 --> 00:00:01,000\nText\n\nBROKEN',
      '1\n00:00:00,000 --> 00:00:01,000\nText\n'
          '2\n00:00:02,000 --> 00:00:03,000\nMissing separator',
      '1\n00:00:00,000 --> 00:00:01,000 trailing garbage\nText',
    ];
    for (var i = 0; i < malformed.length; i++) {
      test('refuses malformed nonempty blocks ($i)', () {
        expect(() => SrtDocument.parse(malformed[i]), throwsFormatException);
      });
    }

    test(
      'refuses empty text, blank block and timestamp replacement injection',
      () {
        final document = subtitles(['Original']);
        for (final replacement in [
          '',
          '   ',
          '\nText',
          'Text\n',
          'Text\n \nInjected',
          'Text\r\n\r\n2\r\n00:00:01,000 --> 00:00:02,000\r\nInjected',
          '00:00:01,000 --> 00:00:02,000',
          'Text\u0000',
        ]) {
          expect(
            () => document.render({0: replacement}),
            throwsFormatException,
          );
        }
        expect(() => document.render({-1: 'Text'}), throwsRangeError);
        expect(() => document.render({1: 'Text'}), throwsRangeError);
        expect(document.cues.single.text, 'Original');
        expect(document.render({}), contains('Original'));
      },
    );
  });

  group('conservative ebook passage alignment', () {
    test(
      'corrects spelling, capitalization and punctuation across split cues',
      () {
        final document = subtitles([
          'on a brigt winter morning',
          'the traveller opened the gate',
        ]);
        final result = compareWithBook(
          document,
          'On a bright winter morning, the traveller opened the gate.',
        );
        expect(result.map((review) => review.status), [
          ReviewStatus.suggestion,
          ReviewStatus.suggestion,
        ]);
        expect(result.map((review) => review.reference), [
          'On a bright winter morning,',
          'the traveller opened the gate.',
        ]);
        expect(result.first.confidence, greaterThan(0.82));
        expect(document.cues.first.text, 'on a brigt winter morning');
        expect(document.render({}), contains('on a brigt winter morning'));
      },
    );

    test(
      'matches sentence-internal fragments without adding adjacent words',
      () {
        final result = compareWithBook(
          subtitles(['silver leaves drifted']),
          'Before sunrise, silver leaves drifted across the empty courtyard.',
        );
        expect(result.single.reference, 'silver leaves drifted');
        expect(result.single.status, ReviewStatus.exact);
      },
    );

    test('subtitle styling does not prevent alignment or require destructive edits', () {
      final document = subtitles(['<i>The silver bell rang.</i>']);
      final review = compareWithBook(document, 'The silver bell rang.').single;
      expect(review.status, ReviewStatus.exact);
      expect(document.render({}), contains('<i>The silver bell rang.</i>'));
      final misspelled = compareWithBook(
        subtitles(['<b>The silver bel rang.</b>']),
        'The silver bell rang.',
      ).single;
      expect(misspelled.status, ReviewStatus.suggestion);
      expect(misspelled.reference, 'The silver bell rang.');
    });

    test('handles several unrelated spelling correction fixtures', () {
      final fixtures = <(String, String)>[
        (
          'The captain examined the brokn telescope',
          'The captain examined the broken telescope.',
        ),
        (
          'Every distant mountan glowed at sunset',
          'Every distant mountain glowed at sunset.',
        ),
        (
          'We followed the winding pasage underground',
          'We followed the winding passage underground.',
        ),
      ];
      for (final (spoken, book) in fixtures) {
        final result = compareWithBook(subtitles([spoken]), book).single;
        expect(result.status, ReviewStatus.suggestion);
        expect(result.reference, book);
      }
    });

    test('supports short fragments and transposed-letter spelling errors', () {
      final result = compareWithBook(subtitles(['teh gate']), 'The gate.');
      expect(result.single.status, ReviewStatus.suggestion);
      expect(result.single.reference, 'The gate.');
    });

    test('overlapping repeated wording remains ambiguous', () {
      final result = compareWithBook(subtitles(['go go']), 'Go go go.');
      expect(result.single.status, ReviewStatus.ambiguous);
      expect(result.single.reference, isNull);
    });

    test('globally locates a chapter after a long full-book preface', () {
      final preface = List.filled(
        600,
        'Earlier chapters discuss forgotten kingdoms.',
      ).join(' ');
      final result = compareWithBook(
        subtitles([
          'the observatory roof slid open',
          'cold stars filled the sky',
        ]),
        '$preface The observatory roof slid open. Cold stars filled the sky.',
      );
      expect(result.map((review) => review.reference), [
        'The observatory roof slid open.',
        'Cold stars filled the sky.',
      ]);
      expect(
        result.every((review) => review.status == ReviewStatus.suggestion),
        isTrue,
      );
    });

    test('rare anchors remain usable alongside extremely common words', () {
      final preface = List.filled(200, 'The old road.').join(' ');
      final result = compareWithBook(
        subtitles(['the copper bell']),
        '$preface The copper bell.',
      );
      expect(result.single.reference, 'The copper bell.');
      expect(result.single.status, ReviewStatus.suggestion);
    });

    test('allows a bounded omitted book passage between anchored cues', () {
      final result = compareWithBook(
        subtitles([
          'Mara inspected the old compass',
          'she followed the narrow trail',
        ]),
        'Mara inspected the old compass. '
        'Inside its lid someone had engraved a tiny map showing the river and the distant mountains. '
        'She followed the narrow trail.',
      );
      expect(result.map((review) => review.reference), [
        'Mara inspected the old compass.',
        'She followed the narrow trail.',
      ]);
    });

    test(
      'does not jump a large unexplained gap or move its cursor on failure',
      () {
        final gap = List.filled(130, 'filler').join(' ');
        final result = compareWithBook(
          subtitles([
            'The bronze door opened',
            'The remote lighthouse collapsed',
            'A white bird entered',
          ]),
          'The bronze door opened. A white bird entered. '
          '$gap The remote lighthouse collapsed.',
        );
        expect(result[0].reference, 'The bronze door opened.');
        expect(result[1].status, ReviewStatus.unmatched);
        expect(result[2].reference, 'A white bird entered.');
      },
    );

    test('does not jump backward after a reliable chapter anchor', () {
      final result = compareWithBook(
        subtitles([
          'The green carriage arrived',
          'The ancient bridge vanished',
          'Its passengers stepped outside',
        ]),
        'The ancient bridge vanished. The green carriage arrived. '
        'Its passengers stepped outside.',
      );
      expect(result[0].reference, 'The green carriage arrived.');
      expect(result[1].status, ReviewStatus.unmatched);
      expect(result[2].reference, 'Its passengers stepped outside.');
    });

    test('abstains on repeated phrases without contextual disambiguation', () {
      final result = compareWithBook(
        subtitles(['the lantern burned steadily']),
        'The lantern burned steadily. Soldiers waited outside. '
        'The lantern burned steadily. Nobody moved.',
      );
      expect(result.single.status, ReviewStatus.ambiguous);
      expect(result.single.reference, isNull);
    });

    test('following cue disambiguates a repeated phrase', () {
      final result = compareWithBook(
        subtitles([
          'the lantern burned steadily',
          'beside it rested a silver key',
        ]),
        'The lantern burned steadily. Soldiers waited outside the eastern gate. '
        'The lantern burned steadily. Beside it rested a silver key.',
      );
      expect(result.map((review) => review.reference), [
        'The lantern burned steadily.',
        'Beside it rested a silver key.',
      ]);
      expect(
        result.every((review) => review.status == ReviewStatus.suggestion),
        isTrue,
      );
    });

    test('highly repeated global anchors cannot fabricate uniqueness', () {
      final result = compareWithBook(
        subtitles(['the bells rang softly']),
        List.filled(80, 'The bells rang softly.').join(' '),
      );
      expect(result.single.status, ReviewStatus.ambiguous);
      expect(result.single.reference, isNull);
    });

    test('unmatched commentary does not poison subsequent alignment', () {
      final result = compareWithBook(
        subtitles([
          'the river flowed beneath stone arches',
          'quantum bananas dance inexplicably',
          'a small boat approached the landing',
        ]),
        'The river flowed beneath stone arches. '
        'A small boat approached the landing.',
      );
      expect(result[0].reference, 'The river flowed beneath stone arches.');
      expect(result[1].status, ReviewStatus.unmatched);
      expect(result[1].reference, isNull);
      expect(result[2].reference, 'A small boat approached the landing.');
      expect(result.map((review) => review.cueIndex), [0, 1, 2]);
    });

    test('recovers globally after an unmatched opening cue', () {
      final result = compareWithBook(
        subtitles([
          'unrelated production announcement',
          'the violet curtains fell silently',
        ]),
        'Before this chapter came many stories. The violet curtains fell silently.',
      );
      expect(result.first.status, ReviewStatus.unmatched);
      expect(result.last.reference, 'The violet curtains fell silently.');
    });

    test('supports accented, Cyrillic and Greek word tokens', () {
      for (final (spoken, book) in <(String, String)>[
        ('élodie traversa la forêt', 'Élodie traversa la forêt.'),
        ('тихая река текла медленно', 'Тихая река текла медленно.'),
        ('ο άνεμος φυσούσε απαλά', 'Ο άνεμος φυσούσε απαλά.'),
      ]) {
        final result = compareWithBook(subtitles([spoken]), book).single;
        expect(result.reference, book);
        expect(result.status, ReviewStatus.suggestion);
      }
    });

    test(
      'preserves curly apostrophes and quotation punctuation from the book',
      () {
        final result = compareWithBook(
          subtitles(["don't open that window"]),
          '“Don’t open that window!”',
        );
        expect(result.single.reference, '“Don’t open that window!”');
      },
    );

    test(
      'does not invent lexical matches for unrelated or translated text',
      () {
        const book =
            'Mara opened the wooden door and entered the quiet garden.';
        for (final text in [
          'Mara compró una bicicleta roja',
          'galaxies rotate beyond invisible horizons',
        ]) {
          final result = compareWithBook(subtitles([text]), book).single;
          expect(result.status, ReviewStatus.unmatched);
          expect(result.reference, isNull);
        }
      },
    );

    test(
      'empty books and excessively long cues abstain without losing rows',
      () {
        final document = subtitles([
          'Normal subtitle',
          List.filled(101, 'word').join(' '),
        ]);
        final result = compareWithBook(document, 'Normal subtitle.');
        expect(result.length, 2);
        expect(result.last.status, ReviewStatus.unmatched);
        expect(
          compareWithBook(
            document,
            '',
          ).every((review) => review.status == ReviewStatus.unmatched),
          isTrue,
        );
      },
    );
  });

  group('word-level display differences', () {
    test('preserves whitespace and punctuation and marks lexical changes', () {
      const text = 'Hello,  brave\nworld!';
      final tokens = wordDifferences(text, 'Hello,  bright\nworld.');
      expect(tokens.map((token) => token.text).join(), text);
      expect(
        tokens.where((token) => token.changed).map((token) => token.text),
        ['brave', '!'],
      );
      expect(
        tokens
            .where((token) => !token.changed)
            .map((token) => token.text)
            .join(),
        'Hello,  \nworld',
      );
    });

    test('can show the inserted side and capitalization independently', () {
      final tokens = wordDifferences('The bright sun.', 'the sun.');
      expect(
        tokens.where((token) => token.changed).map((token) => token.text),
        containsAll(['The', 'bright']),
      );
      expect(
        tokens.singleWhere((token) => token.text == 'sun').changed,
        isFalse,
      );
      expect(wordDifferences('', 'new words'), isEmpty);
      expect(wordDifferences('old', '').single.changed, isTrue);
    });

    test('retains unicode, combining marks, emoji and long rows', () {
      for (final text in [
        'Élodie — привет! 👋',
        '\u0301 orphan combining mark',
      ]) {
        final tokens = wordDifferences(text, text);
        expect(tokens.map((token) => token.text).join(), text);
        expect(tokens.any((token) => token.changed), isFalse);
      }
      final text = '${List.filled(600, 'same ').join()}old end';
      final other = '${List.filled(600, 'same ').join()}new end';
      final tokens = wordDifferences(text, other);
      expect(tokens.map((token) => token.text).join(), text);
      expect(
        tokens.where((token) => token.changed).map((token) => token.text),
        ['old'],
      );
    });
  });
}
