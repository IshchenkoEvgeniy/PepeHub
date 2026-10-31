import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:pepehub/updates/update_delta.dart';
import 'package:pepehub/updates/update_manifest.dart';

/// Release-artifact validation: use the same streaming applier as the app.
Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('base-package patch target-package');
  }
  final base = File(args[0]), patch = File(args[1]), target = File(args[2]);
  final output = File('${patch.path}.verified');
  final delta = UpdateDelta(
    Uri.https('example.invalid', '/delta'),
    (await sha256.bind(patch.openRead()).first).toString(),
    await patch.length(),
    (await sha256.bind(base.openRead()).first).toString(),
    await base.length(),
    1,
  );
  final artifact = UpdateArtifact(
    Uri.https('example.invalid', '/package'),
    (await sha256.bind(target.openRead()).first).toString(),
    'apk',
    await target.length(),
    1,
  );
  try {
    await applyUpdateDelta(
      base: base,
      patch: patch,
      output: output,
      delta: delta,
      target: artifact,
    );
    stdout.writeln(
      jsonEncode({
        'verified': true,
        'patchBytes': delta.bytes,
        'packageBytes': artifact.bytes,
        'sha256': artifact.hash,
      }),
    );
  } finally {
    if (await output.exists()) await output.delete();
  }
}
