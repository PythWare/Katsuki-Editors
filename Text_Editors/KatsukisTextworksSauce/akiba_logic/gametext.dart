import 'dart:io'; import 'dart:math' as math; import 'dart:typed_data';
import 'codec.dart';

const gameTextHeaderSize = 8;
const taskHeaderSize = 16;
const taskRecordSize = 12;
const nameHeaderSize = 16;
const nameSlotBytes = 32;
const nameSlotChars = nameSlotBytes ~/ 2 - 1;
const hashHeaderSize = 16;
const hashRecordSize = 8;

abstract class TextDocument {
  String? filePath;
  final List<String> original;
  final List<String> texts;
  TextDocument(this.original, this.filePath) : texts = List<String>.of(original);

  String get kind;
  int get length => texts.length;
  int? get maxChars => null;
  bool changed(int id) => texts[id] != original[id];
  int get changedCount {
    var n = 0;
    for (var i = 0; i < texts.length; i++) {
      if (texts[i] != original[i]) n++;
    }
    return n;
  }

  void setText(int id, String value) {
    final limit = maxChars;
    if (limit != null && value.length > limit) {
      throw FormatError('This slot holds at most $limit characters, the new value has ${value.length}.');
    }
    texts[id] = value;
  }

  Uint8List toBytes();
}

class GameTextDocument extends TextDocument {
  final Uint8List source;
  final int tableOffset;
  final List<int> offsets;
  final List<int> slotOrder;
  final Map<int, List<int>> slotUsers;
  final int poolEnd;

  GameTextDocument(this.source, this.tableOffset, this.offsets, this.slotOrder, this.slotUsers, this.poolEnd,
      List<String> original, String? filePath)
      : super(original, filePath);

  @override
  String get kind => 'gametext.bin';

  bool isShared(int id) {
    final users = slotUsers[offsets[id]];
    return users != null && users.length > 1;
  }

  bool isPlaceholder(int id) => id != 0 && offsets[id] == offsets[0] && original[id].isEmpty;

  static GameTextDocument parse(Uint8List data, [String? filePath]) {
    if (data.length < gameTextHeaderSize) throw FormatError('The file is too small to be a gametext.bin.');
    final count = readU32(data, 0);
    final tableOffset = readU32(data, 4);
    final tableEnd = tableOffset + count * 4;
    if (count == 0 || tableOffset < gameTextHeaderSize || tableOffset % 4 != 0 || tableEnd > data.length) {
      throw FormatError('The offset table doesnt fit inside the file. This doesnt look like a gametext.bin.');
    }
    final offsets = <int>[];
    final texts = <String>[];
    final cache = <int, String>{};
    final users = <int, List<int>>{};
    var poolEnd = tableEnd;
    for (var id = 0; id < count; id++) {
      final offset = readU32(data, tableOffset + id * 4);
      offsets.add(offset);
      if (offset == 0) {
        texts.add('');
        continue;
      }
      final start = tableOffset + offset;
      if (start < tableEnd || start >= data.length) {
        throw FormatError('Text ${padId(id)} points outside the string pool. This doesnt look like a gametext.bin.');
      }
      final text = cache[offset];
      if (text != null) {
        texts.add(text);
      } else {
        final end = wideEnd(data, start);
        if (end < 0) throw FormatError('Text ${padId(id)} isnt terminated.');
        final decoded = decodeWide(data, start, end);
        cache[offset] = decoded;
        texts.add(decoded);
        poolEnd = math.max(poolEnd, end + 2);
      }
      users.putIfAbsent(offset, () => []).add(id);
    }
    final order = users.keys.toList()..sort();
    return GameTextDocument(data, tableOffset, offsets, order, users, poolEnd, texts, filePath);
  }

  @override
  Uint8List toBytes() {
    final count = texts.length;
    final tableEnd = tableOffset + count * 4;
    final head = Uint8List(tableEnd);
    head.setRange(0, tableOffset, source);
    writeU32(head, 0, count);
    writeU32(head, 4, tableOffset);
    final pool = BytesBuilder(copy: false);
    var cursor = tableEnd;
    int emit(String text) {
      final relative = cursor - tableOffset;
      final bytes = encodeWide(text);
      pool.add(bytes);
      cursor += bytes.length;
      return relative;
    }

    for (final slot in slotOrder) {
      final ids = slotUsers[slot]!;
      final kept = [for (final id in ids) if (!changed(id)) id];
      if (kept.isNotEmpty) {
        final relative = emit(original[kept.first]);
        for (final id in kept) {
          writeU32(head, tableOffset + id * 4, relative);
        }
      }
      for (final id in ids) {
        if (changed(id)) writeU32(head, tableOffset + id * 4, emit(texts[id]));
      }
    }
    for (var id = 0; id < count; id++) {
      if (offsets[id] == 0 && changed(id)) writeU32(head, tableOffset + id * 4, emit(texts[id]));
    }
    final out = BytesBuilder(copy: false)
      ..add(head)
      ..add(pool.takeBytes());
    if (poolEnd < source.length) out.add(Uint8List.sublistView(source, poolEnd));
    return out.takeBytes();
  }
}

class TaskTextDocument extends TextDocument {
  final Uint8List header;
  final List<int> extras;
  final List<int> pads;
  final Uint8List tail;

  TaskTextDocument(this.header, this.extras, this.pads, this.tail, List<String> original, String? filePath)
      : super(original, filePath);

  @override
  String get kind => 'TaskChangeText.bin';

  static TaskTextDocument parse(Uint8List data, [String? filePath]) {
    if (data.length < taskHeaderSize) throw FormatError('The file is too small to be a TaskChangeText.bin.');
    final count = readU32(data, 0);
    final tableEnd = taskHeaderSize + count * taskRecordSize;
    if (count == 0 || tableEnd > data.length) {
      throw FormatError('The record table doesnt fit inside the file. This doesnt look like a TaskChangeText.bin.');
    }
    final texts = <String>[];
    final extras = <int>[];
    final pads = <int>[];
    var dataEnd = tableEnd;
    for (var id = 0; id < count; id++) {
      final record = taskHeaderSize + id * taskRecordSize;
      final offset = readU32(data, record);
      final size = readU32(data, record + 4);
      extras.add(readU32(data, record + 8));
      if (offset < tableEnd || size < 2 || size.isOdd || offset + size > data.length) {
        throw FormatError('Line ${padId(id)} points outside the file. This doesnt look like a TaskChangeText.bin.');
      }
      final end = wideEnd(data, offset, offset + size);
      if (end < 0) throw FormatError('Line ${padId(id)} isnt terminated.');
      texts.add(decodeWide(data, offset, end));
      pads.add(offset + size - end);
      dataEnd = math.max(dataEnd, offset + size);
    }
    final header = Uint8List.fromList(Uint8List.sublistView(data, 0, taskHeaderSize));
    final tail = Uint8List.fromList(Uint8List.sublistView(data, dataEnd));
    return TaskTextDocument(header, extras, pads, tail, texts, filePath);
  }

  @override
  Uint8List toBytes() {
    final count = texts.length;
    final tableEnd = taskHeaderSize + count * taskRecordSize;
    final head = Uint8List(tableEnd);
    head.setRange(0, taskHeaderSize, header);
    writeU32(head, 0, count);
    final pool = BytesBuilder(copy: false);
    var cursor = tableEnd;
    for (var id = 0; id < count; id++) {
      final bytes = encodeWide(texts[id], pads[id]);
      final record = taskHeaderSize + id * taskRecordSize;
      writeU32(head, record, cursor);
      writeU32(head, record + 4, bytes.length);
      writeU32(head, record + 8, extras[id]);
      pool.add(bytes);
      cursor += bytes.length;
    }
    return (BytesBuilder(copy: false)
          ..add(head)
          ..add(pool.takeBytes())
          ..add(tail))
        .takeBytes();
  }
}

class NameTemplateDocument extends TextDocument {
  final Uint8List source;
  final int rows;
  final int slotsPerRow;

  NameTemplateDocument(this.source, this.rows, this.slotsPerRow, List<String> original, String? filePath)
      : super(original, filePath);

  @override
  String get kind => 'gametext_name.bin';
  @override
  int? get maxChars => nameSlotChars;

  int slotOffset(int id) => nameHeaderSize + id * nameSlotBytes;

  static NameTemplateDocument parse(Uint8List data, [String? filePath]) {
    if (data.length < nameHeaderSize) throw FormatError('The file is too small to be a gametext_name.bin.');
    final rows = readU32(data, 0);
    final body = data.length - nameHeaderSize;
    if (rows == 0 || body % rows != 0 || (body ~/ rows) % nameSlotBytes != 0 || body ~/ rows == 0) {
      throw FormatError('The row size doesnt divide evenly. This doesnt look like a gametext_name.bin.');
    }
    final slotsPerRow = body ~/ rows ~/ nameSlotBytes;
    final texts = <String>[];
    for (var id = 0; id < rows * slotsPerRow; id++) {
      final start = nameHeaderSize + id * nameSlotBytes;
      final end = wideEnd(data, start, start + nameSlotBytes);
      texts.add(decodeWide(data, start, end < 0 ? start + nameSlotBytes : end));
    }
    return NameTemplateDocument(Uint8List.fromList(data), rows, slotsPerRow, texts, filePath);
  }

  @override
  Uint8List toBytes() {
    final out = Uint8List.fromList(source);
    for (var id = 0; id < texts.length; id++) {
      if (!changed(id)) continue;
      final start = slotOffset(id);
      out.fillRange(start, start + nameSlotBytes, 0);
      final bytes = encodeWide(texts[id], 0);
      out.setRange(start, start + bytes.length, bytes);
    }
    return out;
  }
}

Map<int, int> parseHashTable(Uint8List data) {
  final out = <int, int>{};
  if (data.length < hashHeaderSize) return out;
  final count = readU32(data, 0);
  if (hashHeaderSize + count * hashRecordSize > data.length) return out;
  for (var i = 0; i < count; i++) {
    final record = hashHeaderSize + i * hashRecordSize;
    out[readU32(data, record + 4)] = readU32(data, record);
  }
  return out;
}

Map<int, int> loadHashTable(String gameTextPath) {
  final file = File('${File(gameTextPath).parent.path}${Platform.pathSeparator}gametext_hash.bin.l');
  try {
    return file.existsSync() ? parseHashTable(file.readAsBytesSync()) : {};
  } catch (error) {
    return {};
  }
}

TextDocument parseKind(String kind, Uint8List data, [String? filePath]) => switch (kind) {
      'gametext' => GameTextDocument.parse(data, filePath),
      'task' => TaskTextDocument.parse(data, filePath),
      'names' => NameTemplateDocument.parse(data, filePath),
      _ => throw FormatError('Unknown document kind $kind'),
    };

const languageCodes = ['us', 'jp', 'ch', 'sc', 'kr'];
final languagePattern = RegExp(r'([\\/])lang_([a-z]{2})([\\/])', caseSensitive: false);

String? languageOf(String path) {
  final matches = languagePattern.allMatches(path).toList();
  return matches.isEmpty ? null : matches.last.group(2)!.toLowerCase();
}

String? siblingPath(String path, String language) {
  final matches = languagePattern.allMatches(path).toList();
  if (matches.isEmpty) return null;
  final m = matches.last;
  return '${path.substring(0, m.start)}${m.group(1)}lang_$language${m.group(3)}${path.substring(m.end)}';
}

List<String> siblingLanguages(String path) {
  final current = languageOf(path);
  if (current == null) return [];
  return [
    for (final code in languageCodes)
      if (code != current && File(siblingPath(path, code)!).existsSync()) code
  ];
}
