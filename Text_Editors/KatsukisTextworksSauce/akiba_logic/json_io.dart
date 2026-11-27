import 'dart:convert'; import 'dart:io'; import 'dart:typed_data';
import 'codec.dart'; import 'gametext.dart'; import 'talkevent.dart';

const jsonFormatVersion = 1;
const jsonMetaKey = 'akiba';
const jsonLinesKey = 'lines';
const gametextFolderFiles = {'gametext': 'gametext.bin', 'task': 'TaskChangeText.bin', 'names': 'gametext_name.bin'};
const jsonKinds = {'gametext', 'task', 'names', 'talkevent'};

String stemOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

String jsonNameFor(String binaryName) => '${stemOf(binaryName)}.json';

String nameKey(int id, int perRow) => 'R${padId(id ~/ perRow, 2)}.${id % perRow}';

String talkKey(TalkLine line) => '${padId(line.record, 3)}.${line.role}';

List<String> documentKeys(TextDocument doc) {
  if (doc is NameTemplateDocument) return [for (var i = 0; i < doc.length; i++) nameKey(i, doc.slotsPerRow)];
  return [for (var i = 0; i < doc.length; i++) padId(i)];
}

List<String> talkKeys(TalkFile file) => [for (final line in file.lines) talkKey(line)];

Map<String, String> collectLines(List<String> keys, List<String> texts) {
  final out = <String, String>{};
  for (var i = 0; i < keys.length; i++) {
    if (texts[i].isNotEmpty) out[keys[i]] = texts[i];
  }
  return out;
}

String encodeJsonText(String kind, String file, String? language, Map<String, String> lines) {
  final body = {
    jsonMetaKey: {'format': jsonFormatVersion, 'kind': kind, 'file': file, 'language': language ?? ''},
    jsonLinesKey: lines,
  };
  return '${const JsonEncoder.withIndent('  ').convert(body)}\n';
}

String kindFromFileName(String file) {
  final lower = file.toLowerCase();
  for (final MapEntry(key: kind, value: name) in gametextFolderFiles.entries) {
    if (lower == name.toLowerCase()) return kind;
  }
  return 'talkevent';
}

class JsonText {
  final String source;
  final String kind;
  final String file;
  final Map<String, String> lines;
  JsonText(this.source, this.kind, this.file, this.lines);

  static JsonText read(String path) {
    var raw = File(path).readAsStringSync();
    if (raw.startsWith('﻿')) raw = raw.substring(1);
    final Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException catch (error) {
      throw FormatError('${baseName(path)} isnt valid JSON: ${error.message}');
    }
    if (data is! Map) throw FormatError('${baseName(path)} doesnt hold a JSON object.');
    final body = data[jsonLinesKey];
    if (body is! Map) throw FormatError('${baseName(path)} has no "$jsonLinesKey" object.');
    final lines = <String, String>{};
    for (final MapEntry(:key, :value) in body.entries) {
      if (value is String) lines['$key'] = value;
    }
    final meta = data[jsonMetaKey];
    var file = meta is Map && meta['file'] is String ? meta['file'] as String : '';
    if (!file.toLowerCase().endsWith('.bin') || file.contains(RegExp(r'[\\/:]'))) file = '${stemOf(baseName(path))}.bin';
    var kind = meta is Map && meta['kind'] is String ? meta['kind'] as String : '';
    if (!jsonKinds.contains(kind)) kind = kindFromFileName(file);
    return JsonText(path, kind, file, lines);
  }
}

String baseName(String path) => path.split(RegExp(r'[\\/]')).last;

class ApplyResult {
  final int applied;
  final List<String> unknown;
  ApplyResult(this.applied, this.unknown);
}

ApplyResult applyLines(List<String> keys, Map<String, String> lines, void Function(int index, String text) set) {
  final index = {for (var i = 0; i < keys.length; i++) keys[i]: i};
  var applied = 0;
  final unknown = <String>[];
  for (final MapEntry(:key, :value) in lines.entries) {
    final at = index[key];
    if (at == null) {
      unknown.add(key);
      continue;
    }
    set(at, value);
    applied++;
  }
  return ApplyResult(applied, unknown);
}

class BuiltFile {
  final String file;
  final Uint8List bytes;
  final int applied;
  final List<String> unknown;
  BuiltFile(this.file, this.bytes, this.applied, this.unknown);
}

void checkReadBack(String kind, String file, Uint8List bytes, List<String> expected) {
  final List<String> actual;
  if (kind == 'talkevent') {
    final parsed = TalkFile.parse(bytes, file);
    actual = [for (final line in parsed.lines) parsed.originalText(line)];
  } else {
    actual = parseKind(kind, bytes).texts;
  }
  var same = actual.length == expected.length;
  for (var i = 0; same && i < actual.length; i++) {
    same = actual[i] == expected[i];
  }
  if (!same) throw FormatError('$file didnt read back the same text after import, so it wasnt written.');
}

BuiltFile buildFromDocument(JsonText item, TextDocument doc) {
  final result = applyLines(documentKeys(doc), item.lines, doc.setText);
  final bytes = doc.toBytes();
  checkReadBack(item.kind, item.file, bytes, doc.texts);
  return BuiltFile(item.file, bytes, result.applied, result.unknown);
}

BuiltFile buildFromTalkFile(JsonText item, TalkFile file, List<String> texts) {
  final result = applyLines(talkKeys(file), item.lines, (i, text) => texts[i] = text);
  final bytes = file.build(texts);
  checkReadBack('talkevent', item.file, bytes, texts);
  return BuiltFile(item.file, bytes, result.applied, result.unknown);
}

List<String> jsonFilesIn(String folder) {
  final dir = Directory(folder);
  if (!dir.existsSync()) return const [];
  final files = dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.json')).toList()
    ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
  return [for (final f in files) f.path];
}

int writeWithBackup(String path, Uint8List bytes) {
  final target = File(path);
  final backup = File('$path.bak');
  var backups = 0;
  if (target.existsSync() && !backup.existsSync()) {
    target.copySync(backup.path);
    backups = 1;
  }
  target.writeAsBytesSync(bytes, flush: true);
  return backups;
}
