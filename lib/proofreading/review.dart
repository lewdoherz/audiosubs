import 'dart:math' as math;
import 'dart:typed_data';

class SrtCue {
  final String number;
  final String timing;
  final String text;

  const SrtCue({
    required this.number,
    required this.timing,
    required this.text,
  });
}

class _TextSpan {
  final int start;
  final int end;
  const _TextSpan(this.start, this.end);
}

final _timestamp = RegExp(
  r'^\s*(\d{2,}):([0-5]\d):([0-5]\d)[,.](\d{3})\s+-->\s+'
  r'(\d{2,}):([0-5]\d):([0-5]\d)[,.](\d{3})'
  r'(?:\s+X1:\d+\s+X2:\d+\s+Y1:\d+\s+Y2:\d+)?\s*$',
);

/// A lossless source document: rendering changes only selected text spans.
class SrtDocument {
  final List<SrtCue> cues;
  final String _source;
  final List<_TextSpan> _spans;
  final List<String> _lineEndings;

  SrtDocument._(this.cues, this._source, this._spans, this._lineEndings);

  factory SrtDocument.parse(String content) {
    final cues = <SrtCue>[];
    final spans = <_TextSpan>[];
    final endings = <String>[];
    final lines = <_TextSpan>[];
    var position = content.startsWith('\uFEFF') ? 1 : 0;
    final lineBreak = RegExp(r'\r\n|\n|\r');
    for (final match in lineBreak.allMatches(content, position)) {
      lines.add(_TextSpan(position, match.start));
      position = match.end;
    }
    lines.add(_TextSpan(position, content.length));
    String line(int index) =>
        content.substring(lines[index].start, lines[index].end);
    var index = 0;
    while (index < lines.length) {
      if (line(index).trim().isEmpty) {
        index++;
        continue;
      }
      final first = index;
      while (index < lines.length && line(index).trim().isNotEmpty) {
        index++;
      }
      final number = line(first);
      if (index - first < 3 || !RegExp(r'^\d+$').hasMatch(number)) {
        throw FormatException('Invalid SRT cue at line ${first + 1}.');
      }
      final timing = line(first + 1);
      final timestamp = _timestamp.firstMatch(timing);
      if (timestamp == null) {
        throw FormatException('Invalid SRT timestamp at line ${first + 2}.');
      }
      int milliseconds(int offset) =>
          int.parse(timestamp.group(offset)!) * 3600000 +
          int.parse(timestamp.group(offset + 1)!) * 60000 +
          int.parse(timestamp.group(offset + 2)!) * 1000 +
          int.parse(timestamp.group(offset + 3)!);
      if (milliseconds(5) < milliseconds(1)) {
        throw FormatException(
          'SRT cue ends before it starts at line ${first + 2}.',
        );
      }
      for (var textLine = first + 2; textLine < index; textLine++) {
        if (line(textLine).contains('-->')) {
          throw FormatException(
            'Unexpected timestamp inside SRT cue at line ${textLine + 1}.',
          );
        }
      }
      final span = _TextSpan(lines[first + 2].start, lines[index - 1].end);
      final newlineStart = lines[first].end;
      final newlineEnd = lines[first + 1].start;
      endings.add(content.substring(newlineStart, newlineEnd));
      spans.add(span);
      cues.add(
        SrtCue(
          number: number,
          timing: timing,
          text: content.substring(span.start, span.end),
        ),
      );
    }
    if (cues.isEmpty) throw const FormatException('No SRT cues found.');
    return SrtDocument._(
      List.unmodifiable(cues),
      content,
      List.unmodifiable(spans),
      endings,
    );
  }

  /// Refuses blank cues, block injection and timestamp injection. The caller
  /// explicitly chooses replacements; comparison never applies them itself.
  String render(Map<int, String> replacements) {
    for (final entry in replacements.entries) {
      if (entry.key < 0 || entry.key >= cues.length) {
        throw RangeError.index(entry.key, cues, 'cueIndex');
      }
      final normalized = entry.value
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n');
      if (normalized.trim().isEmpty ||
          normalized.split('\n').any((line) => line.trim().isEmpty) ||
          normalized.contains('-->') ||
          normalized.contains('\u0000')) {
        throw const FormatException(
          'Replacement must contain only nonempty subtitle text lines.',
        );
      }
    }
    final output = StringBuffer();
    var offset = 0;
    for (var index = 0; index < cues.length; index++) {
      final replacement = replacements[index];
      if (replacement == null || replacement == cues[index].text) continue;
      final span = _spans[index];
      output.write(_source.substring(offset, span.start));
      output.write(
        replacement
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '\n')
            .replaceAll('\n', _lineEndings[index]),
      );
      offset = span.end;
    }
    output.write(_source.substring(offset));
    return output.toString();
  }
}

enum ReviewStatus { exact, suggestion, unmatched, ambiguous }

class CueReview {
  final int cueIndex;
  final String? reference;
  final double confidence;
  final ReviewStatus status;

  const CueReview({
    required this.cueIndex,
    required this.reference,
    required this.confidence,
    required this.status,
  });
}

/// Plans only reliable differences; ambiguous/unmatched cues never supply text.
/// Existing per-cue edits are protected unless the user explicitly opts in.
Map<int, String> bulkEbookCorrections(
  List<CueReview> reviews,
  Map<int, String> currentEdits, {
  bool overwriteEdited = false,
}) => {
  for (final review in reviews)
    if (review.status == ReviewStatus.suggestion &&
        review.reference != null &&
        (overwriteEdited || !currentEdits.containsKey(review.cueIndex)) &&
        currentEdits[review.cueIndex] != review.reference)
      review.cueIndex: review.reference!,
};

class _Word {
  final String value;
  final int start;
  final int end;
  const _Word(this.value, this.start, this.end);
}

final _words = RegExp(
  r"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}\p{N}]+)*",
  unicode: true,
);

List<_Word> _tokenize(String text) => [
  for (final match in _words.allMatches(text))
    _Word(
      match.group(0)!.toLowerCase().replaceAll('’', "'"),
      match.start,
      match.end,
    ),
];

class _Posting {
  int count = 0;
  final List<int> positions = [];
}

class _Candidate {
  final int start;
  final int end;
  final double confidence;
  const _Candidate(this.start, this.end, this.confidence);
}

class _Matches {
  final List<_Candidate> candidates;
  final bool incomplete;
  const _Matches(this.candidates, this.incomplete);
}

final _subtitleMarkup = RegExp(
  r'</?(?:i|b|u|s|font)(?:\s[^>]*)?>',
  caseSensitive: false,
);

String _plainSubtitle(String text) => text.replaceAll(_subtitleMarkup, '');

/// Linear book indexing, capped posting lists (32), 64 candidate windows per
/// cue and at most 100 cue words. Long/poorly anchored cues abstain rather than
/// performing an unbounded fuzzy search. A successful anchor permits only 96
/// skipped book words; larger omissions require manual review or comparison
/// of separate subtitle sections, not an automatic jump to another chapter.
/// Unicode letters/marks/numbers are supported; languages without word spaces
/// and canonically different Unicode spellings may conservatively abstain.
List<CueReview> compareWithBook(SrtDocument subtitles, String bookText) {
  final book = _tokenize(bookText);
  final postings = <String, _Posting>{};
  for (var index = 0; index < book.length; index++) {
    final posting = postings.putIfAbsent(book[index].value, _Posting.new);
    posting.count++;
    if (posting.positions.length < 32) posting.positions.add(index);
  }
  final cueWords = [
    for (final cue in subtitles.cues) _tokenize(_plainSubtitle(cue.text)),
  ];
  final global = <int, _Matches>{};
  _Matches lookup(int index, int cursor) =>
      _findCandidates(cueWords[index], book, postings, cursor);
  _Matches globalLookup(int index) =>
      global.putIfAbsent(index, () => lookup(index, -1));
  final reviews = <CueReview>[];
  var cursor = -1;
  for (var index = 0; index < subtitles.cues.length; index++) {
    final matches = cursor < 0 ? globalLookup(index) : lookup(index, cursor);
    final candidates = matches.candidates;
    if (candidates.isEmpty) {
      reviews.add(
        CueReview(
          cueIndex: index,
          reference: null,
          confidence: 0,
          status: ReviewStatus.unmatched,
        ),
      );
      global.remove(index);
      continue;
    }
    // A following cue can disambiguate repeated wording, but an unmatched cue
    // never moves the cursor. Lookahead does not authorize a large book skip.
    final nextMatches = index + 1 < cueWords.length
        ? globalLookup(index + 1)
        : null;
    final following = nextMatches != null && !nextMatches.incomplete
        ? nextMatches.candidates
        : const <_Candidate>[];
    double score(_Candidate candidate) {
      var score = candidate.confidence;
      if (cursor >= 0) score += 0.12 / (1 + (candidate.start - cursor) / 4);
      var continuity = 0.0;
      for (final next in following) {
        final gap = next.start - candidate.end;
        if (gap >= 0 && gap <= 96) {
          continuity = math.max(continuity, 0.12 / (1 + gap / 4));
        }
      }
      return score + continuity;
    }

    final scores = {
      for (final candidate in candidates) candidate: score(candidate),
    };
    candidates.sort((a, b) => scores[b]!.compareTo(scores[a]!));
    final best = candidates.first;
    final ambiguous =
        matches.incomplete ||
        (candidates.length > 1 &&
            scores[best]! - scores[candidates[1]]! < 0.055);
    if (ambiguous) {
      reviews.add(
        CueReview(
          cueIndex: index,
          reference: null,
          confidence: best.confidence,
          status: ReviewStatus.ambiguous,
        ),
      );
    } else {
      final reference = _reference(bookText, book, best.start, best.end);
      final original = _plainSubtitle(subtitles.cues[index].text)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      reviews.add(
        CueReview(
          cueIndex: index,
          reference: reference,
          confidence: best.confidence,
          status: original == reference
              ? ReviewStatus.exact
              : ReviewStatus.suggestion,
        ),
      );
      cursor = best.end;
    }
    global.remove(index);
  }
  return reviews;
}

_Matches _findCandidates(
  List<_Word> cue,
  List<_Word> book,
  Map<String, _Posting> postings,
  int cursor,
) {
  if (cue.isEmpty || cue.length > 100 || book.isEmpty) {
    return const _Matches([], false);
  }
  final anchors = <int>[
    for (var i = 0; i < cue.length; i++)
      if (cue[i].value.runes.length >= 2 && postings.containsKey(cue[i].value))
        i,
  ];
  anchors.sort(
    (a, b) =>
        postings[cue[a].value]!.count.compareTo(postings[cue[b].value]!.count),
  );
  final votes = <int, double>{};
  final hasRareAnchor =
      anchors.isNotEmpty && postings[cue[anchors.first].value]!.count <= 32;
  var incomplete = cursor < 0 && anchors.isNotEmpty && !hasRareAnchor;
  final selected = anchors.where(
    (anchor) => !hasRareAnchor || postings[cue[anchor].value]!.count <= 32,
  );
  for (final anchor in selected.take(4)) {
    final posting = postings[cue[anchor].value]!;
    void add(int position) {
      final start = position - anchor;
      if (start < -2 || start >= book.length) return;
      if (cursor >= 0 && (start < cursor - 2 || start > cursor + 98)) return;
      votes.update(
        start,
        (value) => value + 1 / posting.count,
        ifAbsent: () => 1 / posting.count,
      );
    }

    if (cursor < 0) {
      for (final position in posting.positions) {
        add(position);
      }
    } else {
      // Local scanning also finds occurrences beyond the capped global index.
      final end = math.min(book.length, cursor + 100 + cue.length);
      for (var position = cursor; position < end; position++) {
        if (book[position].value == cue[anchor].value) add(position);
      }
    }
  }
  final starts = votes.keys.toList()
    ..sort((a, b) {
      final vote = votes[b]!.compareTo(votes[a]!);
      return vote != 0 ? vote : a.compareTo(b);
    });
  if (starts.length > 64) incomplete = true;
  final results = <String, _Candidate>{};
  final costs = <String, double>{};
  for (final start in starts.take(64)) {
    final candidate = _align(cue, book, start, costs);
    if (candidate == null ||
        (cursor >= 0 &&
            (candidate.start < cursor || candidate.start - cursor > 96))) {
      continue;
    }
    final key = '${candidate.start}:${candidate.end}';
    final previous = results[key];
    if (previous == null || previous.confidence < candidate.confidence) {
      results[key] = candidate;
    }
  }
  final sorted = results.values.toList()
    ..sort((a, b) => b.confidence.compareTo(a.confidence));
  return _Matches(sorted, incomplete);
}

_Candidate? _align(
  List<_Word> cue,
  List<_Word> book,
  int guess,
  Map<String, double> costs,
) {
  final from = math.max(0, guess - 2);
  final to = math.min(book.length, guess + cue.length + 4);
  final width = to - from + 1;
  if (width <= 1) return null;
  var previous = Float64List(width);
  var current = Float64List(width);
  final direction = List.generate(cue.length + 1, (_) => Uint8List(width));
  for (var i = 1; i <= cue.length; i++) {
    current[0] = i.toDouble();
    direction[i][0] = 2;
    for (var j = 1; j < width; j++) {
      final substitution = _wordCost(
        cue[i - 1].value,
        book[from + j - 1].value,
        costs,
      );
      var best = previous[j - 1] + substitution;
      var step = 1;
      final deletion = previous[j] + 1;
      final insertion = current[j - 1] + 1;
      if (deletion < best) {
        best = deletion;
        step = 2;
      }
      if (insertion < best) {
        best = insertion;
        step = 3;
      }
      current[j] = best;
      direction[i][j] = step;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  var last = 1;
  for (var j = 2; j < width; j++) {
    if (previous[j] < previous[last] ||
        (previous[j] == previous[last] &&
            (from + j - guess - cue.length).abs() <
                (from + last - guess - cue.length).abs())) {
      last = j;
    }
  }
  final cost = previous[last];
  final confidence = 1 - cost / cue.length;
  if (confidence < 0.82) return null;
  var i = cue.length;
  var j = last;
  var exact = 0;
  var related = 0;
  var firstCue = -1;
  var lastCue = -1;
  while (i > 0) {
    final step = direction[i][j];
    if (step == 1) {
      final wordCost = _wordCost(
        cue[i - 1].value,
        book[from + j - 1].value,
        costs,
      );
      if (wordCost == 0) exact++;
      if (wordCost < 1) {
        related++;
        firstCue = i - 1;
        if (lastCue < 0) lastCue = i - 1;
      }
      i--;
      j--;
    } else if (step == 2) {
      i--;
    } else {
      j--;
    }
  }
  if (firstCue != 0 ||
      lastCue != cue.length - 1 ||
      exact < math.max(1, (cue.length * 0.45).ceil()) ||
      related < (cue.length * 0.8).ceil()) {
    return null;
  }
  return _Candidate(from + j, from + last, confidence);
}

double _wordCost(String a, String b, Map<String, double> cache) {
  if (a == b) return 0;
  final key = '$a\u0000$b';
  final cached = cache[key];
  if (cached != null) return cached;
  final left = a.runes.toList();
  final right = b.runes.toList();
  var result = 1.15;
  if (left.length >= 3 &&
      right.length >= 3 &&
      left.length <= 48 &&
      right.length <= 48 &&
      (left.length - right.length).abs() <= 2) {
    var previous = List<int>.generate(right.length + 1, (i) => i);
    var current = List<int>.filled(right.length + 1, 0);
    var beforePrevious = List<int>.filled(right.length + 1, 0);
    for (var i = 1; i <= left.length; i++) {
      current[0] = i;
      for (var j = 1; j <= right.length; j++) {
        current[j] = math.min(
          previous[j] + 1,
          math.min(
            current[j - 1] + 1,
            previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1),
          ),
        );
        if (i > 1 &&
            j > 1 &&
            left[i - 1] == right[j - 2] &&
            left[i - 2] == right[j - 1]) {
          current[j] = math.min(current[j], beforePrevious[j - 2] + 1);
        }
      }
      final swap = beforePrevious;
      beforePrevious = previous;
      previous = current;
      current = swap;
    }
    final edits = previous.last;
    if (edits <= 3 && edits / math.max(left.length, right.length) <= 0.34) {
      result = 0.24 + edits * 0.10;
    }
  }
  if (cache.length < 4096) cache[key] = result;
  return result;
}

String _reference(String text, List<_Word> words, int start, int end) {
  var first = words[start].start;
  var last = words[end - 1].end;
  if (first > 0 &&
      RegExp(r'[“«"‘]').hasMatch(text[first - 1]) &&
      (first < 2 || RegExp(r'\s').hasMatch(text[first - 2]))) {
    first--;
  }
  final punctuation = RegExp(r'''[,.;:!?…»”’"\)\]]''');
  while (last < text.length && punctuation.hasMatch(text[last])) {
    last++;
  }
  return text.substring(first, last).replaceAll(RegExp(r'\s+'), ' ').trim();
}

class DiffToken {
  final String text;
  final bool changed;
  const DiffToken({required this.text, required this.changed});
}

final _displayTokens = RegExp(
  r"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}\p{N}]+)*|\s+|[^\p{L}\p{N}\s]",
  unicode: true,
);

/// Exact display-token LCS; case and punctuation changes remain visible. For
/// very long rows, bounded prefix/suffix alignment avoids a quadratic matrix.
List<DiffToken> wordDifferences(String text, String other) {
  final tokens = _displayTokens
      .allMatches(text)
      .map((m) => m.group(0)!)
      .toList();
  final reference = _displayTokens
      .allMatches(other)
      .map((m) => m.group(0)!)
      .toList();
  final unchanged = List<bool>.filled(tokens.length, false);
  if (tokens.length * reference.length > 250000) {
    var prefix = 0;
    while (prefix < tokens.length &&
        prefix < reference.length &&
        tokens[prefix] == reference[prefix]) {
      unchanged[prefix++] = true;
    }
    var a = tokens.length - 1;
    var b = reference.length - 1;
    while (a >= prefix && b >= prefix && tokens[a] == reference[b]) {
      unchanged[a--] = true;
      b--;
    }
  } else {
    final rows = List.generate(
      tokens.length + 1,
      (_) => Uint32List(reference.length + 1),
    );
    for (var i = tokens.length - 1; i >= 0; i--) {
      for (var j = reference.length - 1; j >= 0; j--) {
        rows[i][j] = tokens[i] == reference[j]
            ? rows[i + 1][j + 1] + 1
            : math.max(rows[i + 1][j], rows[i][j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    while (i < tokens.length && j < reference.length) {
      if (tokens[i] == reference[j]) {
        unchanged[i] = true;
        i++;
        j++;
      } else if (rows[i + 1][j] >= rows[i][j + 1]) {
        i++;
      } else {
        j++;
      }
    }
  }
  return [
    for (var i = 0; i < tokens.length; i++)
      DiffToken(text: tokens[i], changed: !unchanged[i]),
  ];
}
