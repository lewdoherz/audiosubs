import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../subtitle_files.dart';
import 'jobs.dart';

Future<void> openTranscription(BuildContext context, List<String> files) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TranscriptionScreen(files: files),
      ),
    );

class TranscriptionScreen extends StatefulWidget {
  final List<String> files;
  const TranscriptionScreen({super.key, required this.files});
  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  final _source = TextEditingController(text: 'auto');
  final _target = TextEditingController();
  late final Set<String> _selected = widget.files.toSet();
  String _model = 'tiny';
  String _device = 'cpu';
  String _compute = 'int8';
  bool _bilingual = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    transcriptionJobs.addListener(_changed);
    unawaited(_models());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _models() async {
    try {
      await transcriptionJobs.refreshModels();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    transcriptionJobs.removeListener(_changed);
    _source.dispose();
    _target.dispose();
    super.dispose();
  }

  void _start(String operation) {
    final source = _source.text.trim().toLowerCase();
    final target = Platform.isAndroid
        ? (_target.text.isEmpty ? null : 'en')
        : (_target.text.trim().isEmpty
              ? null
              : _target.text.trim().toLowerCase());
    if (source != 'auto' && !RegExp(r'^[a-z]{2,3}$').hasMatch(source)) {
      setState(
        () => _error =
            'Source must be auto or an ISO language code, e.g. en, es, de.',
      );
      return;
    }
    if (target != null && !RegExp(r'^[a-z]{2,3}$').hasMatch(target)) {
      setState(() => _error = 'Target must be an ISO language code, e.g. es.');
      return;
    }
    if (operation == 'download' &&
        !Platform.isAndroid &&
        target != null &&
        source == 'auto') {
      setState(
        () => _error = 'Choose the source language explicitly to download its offline translation pair. Auto detection is available for transcription.',
      );
      return;
    }
    setState(() => _error = null);
    unawaited(
      transcriptionJobs.start({
        'operation': operation,
        'model': _model,
        'sourceLanguage': source,
        'targetLanguage': target,
        'bilingual': _bilingual && target != null,
        'device': _device,
        'computeType': _compute,
      }, operation == 'download' ? [] : _selected.toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final jobs = transcriptionJobs;
    final descriptors = jobs.modelList;
    final descriptor = descriptors.where((m) => m['id'] == _model).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Generate subtitles')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Playback does not require transcription. Jobs stay in this app when you return to the library.',
          ),
          const SizedBox(height: 12),
          Text(
            Platform.isAndroid
                ? 'Android: local whisper.cpp, CPU only, Android 7+ on arm64/x86_64. Translation is into English only. Tiny/base recommended; large models can exhaust RAM. Keep the app open during long jobs; Android may stop background apps.'
                : 'Windows: local faster-whisper and Argos. CPU/int8 is the safe default. CUDA requires compatible NVIDIA drivers, CUDA/cuBLAS and cuDNN. Translation packages are downloaded for an explicit source → target pair.',
          ),
          const SizedBox(height: 12),
          Text(
            'Model downloads need internet; transcription and translation do not upload audio and work offline after downloads. Completed files are never overwritten. ${Platform.isAndroid ? 'Generated subtitles use app-owned storage for safe atomic writes; existing sibling subtitles remain readable.' : 'Outputs go beside audio when writable, otherwise to app-owned subtitle storage.'}',
          ),
          const SizedBox(height: 16),
          if (descriptors.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: _model,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Speech model'),
              items: descriptors
                  .map(
                    (m) => DropdownMenuItem(
                      value: m['id'] as String,
                      child: Text(
                        '${m['id']} — ${m['installed'] == true ? 'downloaded' : 'not downloaded'}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: jobs.busy
                  ? null
                  : (value) => setState(() => _model = value!),
            ),
          if (descriptor != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SelectableText(
                'Estimated download/storage: ${((descriptor['bytes'] as num) / (1024 * 1024)).toStringAsFixed(0)} MiB; estimated model RAM: ${descriptor['memoryMb']} MB, plus decoder/runtime overhead.\n${descriptor['path'] ?? ''}',
              ),
            ),
          TextField(
            controller: _source,
            enabled: !jobs.busy,
            decoration: const InputDecoration(
              labelText: 'Source language: auto or ISO code',
            ),
          ),
          if (Platform.isAndroid)
            SwitchListTile(
              title: const Text('Translate into English'),
              value: _target.text == 'en',
              onChanged: jobs.busy
                  ? null
                  : (value) => setState(() => _target.text = value ? 'en' : ''),
            )
          else
            TextField(
              controller: _target,
              enabled: !jobs.busy,
              decoration: const InputDecoration(
                labelText:
                    'Translation target ISO code (blank = original only)',
                helperText: 'Requires an available Argos source → target package. Download it first.',
              ),
            ),
          SwitchListTile(
            title: const Text('Also write bilingual SRT'),
            value: _bilingual,
            onChanged: jobs.busy
                ? null
                : (value) => setState(() => _bilingual = value),
          ),
          if (!Platform.isAndroid) ...[
            DropdownButtonFormField<String>(
              initialValue: _device,
              decoration: const InputDecoration(labelText: 'Device'),
              items: [
                'cpu',
                'cuda',
                'auto',
              ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: jobs.busy ? null : (v) => setState(() => _device = v!),
            ),
            DropdownButtonFormField<String>(
              initialValue: _compute,
              decoration: const InputDecoration(labelText: 'Compute type'),
              items: [
                'int8',
                'float16',
                'float32',
              ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: jobs.busy
                  ? null
                  : (v) => setState(() => _compute = v!),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: jobs.busy ? null : () => _start('download'),
            child: const Text('Download speech / selected translation models'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Divider(),
          Text(
            'Files (${_selected.length}/${widget.files.toSet().length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          for (final path in widget.files.toSet())
            CheckboxListTile(
              title: Text(pathFileName(path)),
              subtitle: Text(path),
              value: _selected.contains(path),
              onChanged: jobs.busy
                  ? null
                  : (value) => setState(() {
                      if (value == true) {
                        _selected.add(path);
                      } else {
                        _selected.remove(path);
                      }
                    }),
            ),
          FilledButton(
            onPressed: jobs.busy || _selected.isEmpty
                ? null
                : () => _start('transcribe'),
            child: const Text('Generate missing subtitles'),
          ),
          const Divider(),
          Text(jobs.message, style: Theme.of(context).textTheme.titleMedium),
          if (jobs.currentFile != null)
            SelectableText('Current file: ${jobs.currentFile}'),
          if (jobs.busy) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: jobs.progress),
            TextButton(
              onPressed: jobs.cancelling ? null : jobs.cancel,
              child: Text(jobs.cancelling ? 'Cancelling…' : 'Cancel job'),
            ),
          ],
          for (final event in jobs.events.reversed)
            ListTile(
              leading: Icon(
                event['type'] == 'fileError'
                    ? Icons.error_outline
                    : event['type'] == 'output'
                    ? Icons.subtitles
                    : Icons.info_outline,
              ),
              title: SelectableText(
                event['path'] as String? ??
                    event['message'] as String? ??
                    '${event['type']}',
              ),
              subtitle: event['type'] == 'output'
                  ? Text('${event['kind']} • ${event['language'] ?? ''}')
                  : null,
            ),
        ],
      ),
    );
  }
}
