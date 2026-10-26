import 'package:audiobook_player/proofreading/review.dart';
import 'package:flutter_test/flutter_test.dart';

const _book =
    'On a bright winter morning, the traveller opened the gate. '
    'The lantern glowed.';

String _source() =>
    [
          'on a brigt winter morning',
          'the traveller opened the gate',
          'Unrelated production announcement about distant spacecraft.',
          'The lantern glowed.',
        ].indexed
        .map(
          (entry) =>
              '${entry.$1 + 1}\r\n00:00:01,250 --> 00:00:05,500\r\n${entry.$2}',
        )
        .join('\r\n\r\n');

void main() {
  test('bulk correction applies every reliable difference without retiming or changing unmatched/exact cues', () {
    final source = _source();
    final document = SrtDocument.parse(source);
    final reviews = compareWithBook(document, _book);
    expect(reviews.map((review) => review.status), [
      ReviewStatus.suggestion,
      ReviewStatus.suggestion,
      ReviewStatus.unmatched,
      ReviewStatus.exact,
    ]);
    final changes = bulkEbookCorrections(reviews, {});
    expect(changes, {
      0: 'On a bright winter morning,',
      1: 'the traveller opened the gate.',
    });
    final rendered = document.render(changes);
    expect(
      rendered,
      source
          .replaceFirst(
            'on a brigt winter morning',
            'On a bright winter morning,',
          )
          .replaceFirst(
            'the traveller opened the gate',
            'the traveller opened the gate.',
          ),
    );
    expect(
      SrtDocument.parse(rendered).cues.map((cue) => cue.timing),
      document.cues.map((cue) => cue.timing),
    );
    expect(document.render({}), source);
  });

  test('manual edits are protected by default and replaceable only for reliable suggestions', () {
    final document = SrtDocument.parse(_source());
    final reviews = [
      ...compareWithBook(document, _book),
      const CueReview(
        cueIndex: 4,
        reference: 'Ambiguous wording must not be applied.',
        confidence: 0.99,
        status: ReviewStatus.ambiguous,
      ),
    ];
    final edits = {
      0: 'Deliberate manual wording.',
      2: 'Manual unmatched cue.',
      3: 'Manual formatting of an exact cue.',
    };
    final preserved = Map<int, String>.of(edits);
    expect(bulkEbookCorrections(reviews, edits), {
      1: 'the traveller opened the gate.',
    });
    expect(bulkEbookCorrections(reviews, edits, overwriteEdited: true), {
      0: 'On a bright winter morning,',
      1: 'the traveller opened the gate.',
    });
    expect(edits, preserved);
  });

  test('bulk correction does not reapply wording already accepted', () {
    final document = SrtDocument.parse(_source());
    final reviews = compareWithBook(document, _book);
    final accepted = bulkEbookCorrections(reviews, {});
    expect(bulkEbookCorrections(reviews, accepted), isEmpty);
    expect(
      bulkEbookCorrections(reviews, accepted, overwriteEdited: true),
      isEmpty,
    );
    expect(
      document.render({
        ...accepted,
        ...bulkEbookCorrections(reviews, accepted, overwriteEdited: true),
      }),
      document.render(accepted),
    );
  });
}
