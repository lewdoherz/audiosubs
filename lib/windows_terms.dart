import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// The Windows runtime is not loaded until its component terms are accepted.
Future<bool> requestWindowsTermsAcceptance() async {
  final result = Completer<bool>();
  String? document;
  String? failure;
  File? acceptance;
  String? fingerprint;
  try {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final terms = File(
      '$executableDirectory/transcription_runtime/_internal/'
      'THIRD-PARTY-LICENSES/WINDOWS-TERMS.txt',
    );
    document = await terms.readAsString();
    fingerprint = sha256.convert(utf8.encode(document)).toString();
    final support = await getApplicationSupportDirectory();
    acceptance = File('${support.path}/windows-terms-acceptance.txt');
    if (await acceptance.exists() &&
        (await acceptance.readAsString()).trim() == fingerprint) {
      return true;
    }
  } catch (error) {
    failure =
        'The bundled third-party terms could not be read. '
        'Restore the complete AudioSubs Windows package.\n$error';
  }
  runApp(
    MaterialApp(
      title: 'AudioSubs — Windows component terms',
      theme: ThemeData.dark(),
      home: WindowsTermsScreen(
        document: document,
        failure: failure,
        onAccept: () async {
          final target = acceptance!;
          await target.parent.create(recursive: true);
          await target.writeAsString('$fingerprint\n', flush: true);
          result.complete(true);
        },
        onDecline: () {
          result.complete(false);
          exit(0);
        },
      ),
    ),
  );
  return result.future;
}

class WindowsTermsScreen extends StatefulWidget {
  const WindowsTermsScreen({
    super.key,
    required this.document,
    required this.onAccept,
    required this.onDecline,
    this.failure,
  });

  final String? document;
  final String? failure;
  final Future<void> Function() onAccept;
  final VoidCallback onDecline;

  @override
  State<WindowsTermsScreen> createState() => _WindowsTermsScreenState();
}

class _WindowsTermsScreenState extends State<WindowsTermsScreen> {
  bool _agreed = false;
  bool _saving = false;
  String? _saveError;

  Future<void> _accept() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.onAccept();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = 'Acceptance could not be saved: $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.document != null && widget.failure == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Windows third-party component terms')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'The Windows transcription runtime includes Intel and Microsoft '
              'redistributables. Their component-specific terms apply below. '
              'These are not a GPL licence for AudioSubs and do not restrict '
              'your LGPL library replacement/relinking rights.',
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(widget.failure ?? widget.document ?? ''),
              ),
            ),
            if (_saveError != null)
              Text(
                _saveError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (available)
              CheckboxListTile(
                title: const Text(
                  'I agree to these third-party component terms',
                ),
                value: _agreed,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _agreed = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : widget.onDecline,
                  child: const Text('Decline and exit'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: available && _agreed && !_saving ? _accept : null,
                  child: Text(
                    _saving ? 'Saving…' : 'Accept and start AudioSubs',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
