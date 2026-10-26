import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'ebook.dart';
import 'review.dart';
import 'storage.dart';

// Keep worker closures outside State: sibling UI closures can otherwise cause
// Isolate.run to capture the widget tree's unsendable native resources.
Future<SrtDocument> _readSrtInBackground(String path) =>
    Isolate.run(() => SrtDocument.parse(File(path).readAsStringSync()));

Future<List<CueReview>> _compareInBackground(
  SrtDocument document,
  String text,
) => Isolate.run(() => compareWithBook(document, text));

/// The caller supplies the existing persistent Android URI/cache resolver.
class ProofreadingScreen extends StatefulWidget {
  final Future<String> Function(PlatformFile) resolvePath;
  final String? initialSubtitlePath;
  final String? audioPath;

  const ProofreadingScreen({
    super.key,
    required this.resolvePath,
    this.initialSubtitlePath,
    this.audioPath,
  });

  @override
  State<ProofreadingScreen> createState() => _ProofreadingScreenState();
}

class _ProofreadingScreenState extends State<ProofreadingScreen> {
  final _editor = TextEditingController();
  final _edits = <int, String>{};
  String? _subtitlePath;
  SrtDocument? _document;
  EbookDocument? _book;
  List<CueReview>? _reviews;
  int _index = 0;
  bool _busy = false;
  bool _words = true;
  bool _issuesOnly = false;
  bool _unsaved = false;
  String? _error;
  String? _savedPath;

  @override
  void initState() {
    super.initState();
    final path = widget.initialSubtitlePath;
    if (path != null) _loadSubtitles(path);
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  Future<bool> _discardChanges() async {
    if (!_unsaved) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved corrections?'),
            content: const Text('The original SRT has not been changed.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep reviewing'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick(bool ebook) async {
    if (!ebook && !await _discardChanges()) return;
    if (!mounted) return;
    await _run(() async {
      final file = await FilePicker.pickFile(
        type: Platform.isAndroid ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isAndroid
            ? null
            : (ebook ? ebookExtensions.toList() : ['srt']),
      );
      if (file == null || !mounted) return;
      final extension = file.name.split('.').last.toLowerCase();
      if (!(ebook ? ebookExtensions : {'srt'}).contains(extension)) {
        throw FormatException(
          ebook
              ? 'Choose a supported ebook: ${ebookExtensions.join(', ')}.'
              : 'Choose an SRT file.',
        );
      }
      final path = await widget.resolvePath(file);
      if (path.isEmpty) {
        throw const FileSystemException('The selected file is not readable.');
      }
      if (ebook) {
        final book = await readEbook(path);
        if (!mounted) return;
        setState(() {
          _book = book;
          _reviews = null;
        });
      } else {
        await _readSubtitles(path);
      }
      await _compare();
    });
  }

  Future<void> _loadSubtitles(String path) => _run(() async {
    await _readSubtitles(path);
    await _compare();
  });

  Future<void> _readSubtitles(String path) async {
    final document = await _readSrtInBackground(path);
    if (!mounted) return;
    setState(() {
      _document = document;
      _subtitlePath = path;
      _reviews = null;
      _edits.clear();
      _unsaved = false;
      _savedPath = null;
      _index = 0;
      _editor.text = document.cues.first.text;
    });
  }

  Future<void> _compare() async {
    final document = _document;
    final book = _book;
    if (document == null || book == null) return;
    final reviews = await _compareInBackground(document, book.text);
    if (!mounted) return;
    setState(() {
      _reviews = reviews;
    });
  }

  List<int> get _visibleIndices {
    final document = _document;
    if (document == null) return [];
    return [
      for (var i = 0; i < document.cues.length; i++)
        if (!_issuesOnly ||
            _reviews == null ||
            _reviews![i].status != ReviewStatus.exact)
          i,
    ];
  }

  void _go(int index) {
    setState(() {
      _index = index;
      _editor.text = _edits[index] ?? _document!.cues[index].text;
    });
  }

  void _edit(String value) {
    setState(() {
      if (value == _document!.cues[_index].text) {
        _edits.remove(_index);
      } else {
        _edits[_index] = value;
      }
      _unsaved = true;
      _savedPath = null;
    });
  }

  Future<void> _autoCorrect() async {
    final reviews = _reviews;
    if (_busy || reviews == null) return;
    final preserving = bulkEbookCorrections(reviews, _edits);
    final replacing = bulkEbookCorrections(
      reviews,
      _edits,
      overwriteEdited: true,
    );
    final manualOnly = reviews
        .where(
          (review) =>
              review.status == ReviewStatus.unmatched ||
              review.status == ReviewStatus.ambiguous,
        )
        .length;
    var overwriteEdited = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, updateDialog) {
          final count = overwriteEdited ? replacing.length : preserving.length;
          return AlertDialog(
            title: const Text('Auto-correct all matched cues?'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$count cues will use their matched ebook wording.'),
                  Text(
                    '$manualOnly ambiguous or unmatched cues still need manual review.',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This changes spelling, capitalization, punctuation and line breaks, and replaces inline styling in those cues. A text match is not a guarantee of correctness.',
                  ),
                  if (replacing.length > preserving.length)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Replace already edited cues too'),
                      subtitle: Text(
                        '${replacing.length - preserving.length} existing edits are protected by default.',
                      ),
                      value: overwriteEdited,
                      onChanged: (value) =>
                          updateDialog(() => overwriteEdited = value ?? false),
                    ),
                  const SizedBox(height: 12),
                  const Text(
                    'Timestamps and original files stay unchanged. Review the edits, then save a corrected copy.',
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: count == 0
                    ? null
                    : () => Navigator.pop(context, true),
                child: Text('Auto-correct $count cues'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;
    final changes = overwriteEdited ? replacing : preserving;
    setState(() {
      _edits.addAll(changes);
      _editor.text = _edits[_index] ?? _document!.cues[_index].text;
      _unsaved = true;
      _savedPath = null;
      _error = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Auto-corrected ${changes.length} cues. Review and save a corrected copy.',
        ),
      ),
    );
  }

  Future<void> _save() => _run(() async {
    final content = _document!.render(_edits);
    final path = await saveCorrectedSubtitles(
      sourcePath: _subtitlePath!,
      audioPath: widget.audioPath,
      content: content,
    );
    if (!mounted) return;
    setState(() {
      _savedPath = path;
      _unsaved = false;
    });
  });

  Widget _diff(String text, String other) {
    if (!_words) return SelectableText(text);
    final colors = Theme.of(context).colorScheme;
    return SelectableText.rich(
      TextSpan(
        style: Theme.of(context).textTheme.bodyLarge,
        children: [
          for (final token in wordDifferences(text, other))
            TextSpan(
              text: token.text,
              style: token.changed
                  ? TextStyle(
                      backgroundColor: colors.tertiaryContainer,
                      color: colors.onTertiaryContainer,
                      fontWeight: FontWeight.bold,
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  String _status(CueReview? review) => switch (review?.status) {
    ReviewStatus.exact => 'Matches ebook',
    ReviewStatus.suggestion =>
      'Suggested correction · ${(review!.confidence * 100).round()}% match (not a guarantee)',
    ReviewStatus.ambiguous => 'Ambiguous passage — review manually',
    ReviewStatus.unmatched => 'No reliable match — original retained',
    null => 'Choose an ebook to compare',
  };

  @override
  Widget build(BuildContext context) {
    final document = _document;
    final review = _reviews == null ? null : _reviews![_index];
    final cue = document?.cues[_index];
    final visible = _visibleIndices;
    final position = visible.indexOf(_index);
    return PopScope(
      canPop: !_unsaved && !_busy,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _busy) return;
        if (await _discardChanges() && context.mounted) {
          setState(() => _unsaved = false);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.pop(context, _savedPath);
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Check subtitles against ebook')),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Local proofreading · same-language, same-edition books work best. Review suggestions before applying; timestamps never change.',
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _busy ? null : () => _pick(false),
                              icon: const Icon(Icons.subtitles),
                              label: const Text('Open SRT'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy ? null : () => _pick(true),
                              icon: const Icon(Icons.menu_book),
                              label: const Text('Open ebook'),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  _busy ||
                                      _reviews == null ||
                                      !_reviews!.any(
                                        (review) =>
                                            review.status ==
                                            ReviewStatus.suggestion,
                                      )
                                  ? null
                                  : _autoCorrect,
                              icon: const Icon(Icons.auto_fix_high),
                              label: const Text(
                                'Auto-correct all matched cues',
                              ),
                            ),
                            FilledButton.icon(
                              onPressed: _busy || _edits.isEmpty ? null : _save,
                              icon: const Icon(Icons.save_as),
                              label: Text(
                                'Save corrected copy (${_edits.length})',
                              ),
                            ),
                          ],
                        ),
                        if (_subtitlePath != null)
                          SelectableText('SRT: $_subtitlePath'),
                        if (_book != null) Text('Ebook: ${_book!.title}'),
                        Text(
                          'Formats: ${ebookExtensions.join(', ').toUpperCase()}. DRM-protected books and scanned PDFs are not supported.',
                        ),
                        const Text(
                          'Kindle: legacy MOBI/AZW or the MOBI rendition of hybrid files. KF8-only/AZW3, KFX and HUFF/CDIC compression need conversion to EPUB first.',
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () => showLicensePage(context: context),
                            child: const Text('Open-source licences'),
                          ),
                        ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: SelectableText(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        if (_savedPath != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: SelectableText(
                              'Saved corrected copy:\n$_savedPath\nOriginal preserved. Select this copy in the player to use it.',
                            ),
                          ),
                        if (_reviews != null) ...[
                          const Divider(),
                          Text(
                            '${_reviews!.where((r) => r.status == ReviewStatus.exact).length} matching · ${_reviews!.where((r) => r.status == ReviewStatus.suggestion).length} suggestions · ${_reviews!.where((r) => r.status == ReviewStatus.unmatched || r.status == ReviewStatus.ambiguous).length} need manual review',
                          ),
                        ],
                        if (cue != null) ...[
                          Wrap(
                            spacing: 16,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilterChip(
                                label: const Text('Word differences'),
                                selected: _words,
                                onSelected: (value) =>
                                    setState(() => _words = value),
                              ),
                              FilterChip(
                                label: const Text('Differences only'),
                                selected: _issuesOnly,
                                onSelected: (value) {
                                  setState(() => _issuesOnly = value);
                                  final indices = _visibleIndices;
                                  if (indices.isNotEmpty &&
                                      !indices.contains(_index)) {
                                    _go(indices.first);
                                  }
                                },
                              ),
                              Text(
                                '${_edits.length} edited${_unsaved ? ' · unsaved' : ''}',
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Previous cue',
                                onPressed: _busy || position <= 0
                                    ? null
                                    : () => _go(visible[position - 1]),
                                icon: const Icon(Icons.chevron_left),
                              ),
                              Expanded(
                                child: Text(
                                  'Cue ${_index + 1} / ${document!.cues.length} · ${cue.timing}',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Next cue',
                                onPressed:
                                    _busy ||
                                        visible.isEmpty ||
                                        position >= visible.length - 1
                                    ? null
                                    : () => _go(
                                        visible[position < 0
                                            ? 0
                                            : position + 1],
                                      ),
                                icon: const Icon(Icons.chevron_right),
                              ),
                            ],
                          ),
                          if (document.cues.length > 1)
                            Slider(
                              label: 'Cue ${_index + 1}',
                              min: 0,
                              max: (document.cues.length - 1).toDouble(),
                              value: _index.toDouble(),
                              onChanged: _busy
                                  ? null
                                  : (value) => _go(value.round()),
                            ),
                          if (_issuesOnly && visible.isEmpty)
                            const Text('No differences found.'),
                          const SizedBox(height: 8),
                          Text(
                            _status(review),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Original subtitle',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          _diff(cue.text, review?.reference ?? cue.text),
                          const SizedBox(height: 16),
                          const Text(
                            'Ebook passage',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          if (review?.reference != null)
                            _diff(review!.reference!, cue.text)
                          else
                            const Text(
                              'No unique aligned passage. Edit manually or keep the original.',
                            ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            children: [
                              OutlinedButton(
                                onPressed:
                                    _busy ||
                                        review?.status !=
                                            ReviewStatus.suggestion
                                    ? null
                                    : () {
                                        _editor.text = review!.reference!;
                                        _edit(_editor.text);
                                      },
                                child: const Text('Use ebook wording'),
                              ),
                              TextButton(
                                onPressed: _busy || !_edits.containsKey(_index)
                                    ? null
                                    : () {
                                        _editor.text = cue.text;
                                        _edit(cue.text);
                                      },
                                child: const Text('Restore original cue'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _editor,
                            enabled: !_busy,
                            minLines: 3,
                            maxLines: 8,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              labelText: 'Corrected subtitle',
                              helperText: 'Edit spelling, punctuation and line breaks. Do not add blank cue separators.',
                            ),
                            onChanged: _edit,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
