import 'dart:io'; import 'dart:math' as math; import 'dart:typed_data';
import 'codec.dart'; import 'gametext.dart';

const talkHeaderSize = 16;
const talkRecordSizes = [0x50, 0x40];
const talkMarker = 0x7FFF;
const talkPoolLimit = 0x7FFF;
const talkListName = 'script_talkevent_list.bin';
const commandLine = 1;
const commandChoice = 2;

class TalkLayout {
  final int text;
  final int options;
  final int optionCount;
  final int speaker;
  final int voice;
  final bool known;
  const TalkLayout(this.text, this.options, this.optionCount, this.speaker, this.voice, this.known);
}

const talkLayouts = {
  0x50: TalkLayout(0x20, 0x28, 0x2e, 0x04, 0x22, true),
  0x40: TalkLayout(0x20, 0x24, 0x2a, 0x04, 0x22, false),
};

const portraitExpressions = [
  'Normal', 'Joyful', 'Anger', 'Pensive', 'Tere', 'Tanoshii', 'Kurushimi', 'Hazukashii', 'Tokusyu_01', 'Tokusyu_02',
  'Tokusyu_03', 'Tokusyu_04', 'Tokusyu_05', 'Tokusyu_06', 'Tokusyu_07', 'Tokusyu_08', 'Tokusyu_09', 'eAnger', 'eHeart',
  'eMusicNote', 'eLight', 'Text1', 'Text2', 'Text3', 'chara_01', 'chara_02', 'chara_03',
];
const portraitSizes = ['Small', 'Middle', 'Large'];
const mouthModes = ['lip sync', 'MouthClose', 'MouthOpen', 'default'];

int signed16(int value) => value >= 0x8000 ? value - 0x10000 : value;

class TalkExtras {
  final int expression;
  final int size;
  final int next;
  final int mouth;
  final int lipSync;
  final int jump;
  final int feelingSpeaker;
  final int feelingChange;
  const TalkExtras(this.expression, this.size, this.next, this.mouth, this.lipSync,
      [this.jump = 0x7FFF, this.feelingSpeaker = -1, this.feelingChange = 0]);
}

int readU16(Uint8List data, int offset) => data[offset] | (data[offset + 1] << 8);

void writeU16(Uint8List data, int offset, int value) {
  data[offset] = value & 0xFF;
  data[offset + 1] = (value >> 8) & 0xFF;
}

class TalkLine {
  final int record;
  final int field;
  final String role;
  final int speaker;
  final int voice;
  final int rawOffset;
  final int slot;
  final TalkExtras? extras;
  TalkLine(this.record, this.field, this.role, this.speaker, this.voice, this.rawOffset, this.slot, [this.extras]);

  String get key => '$record.$role';
}

class TalkFile {
  final String name;
  final Uint8List source;
  final int recordSize;
  final int count;
  final int poolStart;
  final List<int> slotOffsets;
  final List<String> slotTexts;
  final List<TalkLine> lines;
  final int poolEnd;

  TalkFile(this.name, this.source, this.recordSize, this.count, this.poolStart, this.slotOffsets, this.slotTexts,
      this.lines, this.poolEnd);

  TalkLayout get layout => talkLayouts[recordSize]!;
  int recordOffset(int record) => talkHeaderSize + record * recordSize;
  String originalText(TalkLine line) => line.slot < 0 ? '' : slotTexts[line.slot];

  static int? detectRecordSize(Uint8List data, int count) {
    for (final size in talkRecordSizes) {
      final pool = talkHeaderSize + count * size;
      if (pool > data.length) continue;
      var tagsSame = true;
      var markersOk = true;
      final firstTag = count == 0 ? 0 : readU16(data, talkHeaderSize);
      for (var r = 0; r < count; r++) {
        final at = talkHeaderSize + r * size;
        if (readU16(data, at) != firstTag) tagsSame = false;
        if (readU16(data, at + 0x0a) != talkMarker) markersOk = false;
      }
      if (!tagsSame && !markersOk) continue;
      var o = pool;
      var terminated = true;
      while (o < data.length) {
        final end = wideEnd(data, o);
        if (end < 0) {
          terminated = false;
          break;
        }
        o = end + 2;
      }
      if (terminated) return size;
    }
    return null;
  }

  static TalkFile parse(Uint8List data, String name) {
    if (data.length < talkHeaderSize) throw FormatError('$name is too small to be a talk event file.');
    for (var i = 0; i < 12; i++) {
      if (data[i] != 0) throw FormatError('$name doesnt have a talk event header.');
    }
    final count = readU32(data, 12);
    final size = detectRecordSize(data, count);
    if (size == null || !talkLayouts.containsKey(size)) throw FormatError('$name has an unknown record layout.');
    final poolStart = talkHeaderSize + count * size;
    final offsets = <int>[];
    final texts = <String>[];
    var o = poolStart;
    while (o < data.length) {
      final end = wideEnd(data, o);
      offsets.add(o - poolStart);
      texts.add(decodeWide(data, o, end));
      o = end + 2;
    }
    final slotOf = {for (var i = 0; i < offsets.length; i++) offsets[i]: i};
    final layout = talkLayouts[size]!;
    final lines = <TalkLine>[];
    for (var r = 0; r < count; r++) {
      final at = talkHeaderSize + r * size;
      final command = readU16(data, at + 2);
      final speaker = readU16(data, at + layout.speaker);
      final voice = readU16(data, at + layout.voice);
      TalkExtras? extrasFor(int answer) {
        if (!layout.known) return null;
        final base = TalkExtras(signed16(readU16(data, at + 0x06)), signed16(readU16(data, at + 0x08)),
            readU16(data, at + 0x0a), readU16(data, at + 0x24), readU16(data, at + 0x26));
        if (answer < 0) return base;
        return TalkExtras(base.expression, base.size, base.next, base.mouth, base.lipSync,
            readU16(data, at + 0x30 + answer * 2), signed16(readU16(data, at + 0x36 + answer * 2)),
            signed16(readU16(data, at + 0x3c + answer * 2)));
      }

      void addLine(int field, String role, int answer) {
        final raw = readU16(data, at + field);
        lines.add(TalkLine(r, field, role, speaker, voice, raw, slotOf[raw] ?? -1, extrasFor(answer)));
      }

      if (command == commandLine) {
        addLine(layout.text, 'line', -1);
      } else if (command == commandChoice) {
        addLine(layout.text, 'ask', -1);
        final options = math.min(3, readU16(data, at + layout.optionCount));
        for (var k = 0; k < options; k++) {
          addLine(layout.options + k * 2, 'opt${k + 1}', k);
        }
      }
    }
    return TalkFile(name, data, size, count, poolStart, offsets, texts, lines, o);
  }

  Uint8List build(List<String> texts) {
    final head = Uint8List.fromList(Uint8List.sublistView(source, 0, poolStart));
    final pool = BytesBuilder(copy: false);
    var cursor = 0;
    int emit(String text) {
      final at = cursor;
      final bytes = encodeWide(text);
      pool.add(bytes);
      cursor += bytes.length;
      return at;
    }

    final bySlot = <int, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      bySlot.putIfAbsent(lines[i].slot, () => []).add(i);
    }
    void place(int index, int offset) => writeU16(head, recordOffset(lines[index].record) + lines[index].field, offset);

    for (var slot = 0; slot < slotOffsets.length; slot++) {
      final users = bySlot[slot] ?? const <int>[];
      final kept = [for (final i in users) if (texts[i] == slotTexts[slot]) i];
      final changed = [for (final i in users) if (texts[i] != slotTexts[slot]) i];
      if (users.isEmpty || kept.isNotEmpty) {
        final at = emit(slotTexts[slot]);
        for (final i in kept) {
          place(i, at);
        }
      }
      for (final i in changed) {
        place(i, emit(texts[i]));
      }
    }
    final loose = bySlot[-1] ?? const <int>[];
    var anyChanged = false;
    for (var i = 0; i < lines.length; i++) {
      if (texts[i] != originalText(lines[i])) anyChanged = true;
    }
    int? blank;
    for (final i in loose) {
      if (texts[i].isNotEmpty) {
        place(i, emit(texts[i]));
      } else if (anyChanged) {
        blank ??= emit('');
        place(i, blank);
      }
    }
    if (cursor > talkPoolLimit) {
      throw FormatError('$name: the text pool would be $cursor bytes. The game reads talk event text offsets as signed '
          '16 bit, so a file can only hold $talkPoolLimit bytes of text.');
    }
    final out = BytesBuilder(copy: false)
      ..add(head)
      ..add(pool.takeBytes());
    if (poolEnd < source.length) out.add(Uint8List.sublistView(source, poolEnd));
    return out.takeBytes();
  }
}

class TalkList {
  final List<int> speakerNameIds;
  final List<int> speakerCharacters;
  final List<String> files;
  TalkList(this.speakerNameIds, this.speakerCharacters, this.files);

  static TalkList? load(String folder) {
    final file = File('$folder${Platform.pathSeparator}$talkListName');
    if (!file.existsSync()) return null;
    final data = file.readAsBytesSync();
    if (data.length < 16) return null;
    final speakerSize = readU32(data, 0);
    final nameSize = readU32(data, 4);
    final nameCount = readU32(data, 8);
    final speakerCount = readU32(data, 12);
    if (speakerSize < 8 || nameSize == 0) return null;
    final ids = <int>[];
    final characters = <int>[];
    for (var i = 0; i < speakerCount && 16 + (i + 1) * speakerSize <= data.length; i++) {
      ids.add(readU16(data, 16 + i * speakerSize + 6));
      characters.add(signed16(readU16(data, 16 + i * speakerSize + 2)));
    }
    final namesAt = 16 + speakerCount * speakerSize;
    final names = <String>[];
    for (var i = 0; i < nameCount && namesAt + (i + 1) * nameSize <= data.length; i++) {
      final start = namesAt + i * nameSize;
      var end = start;
      while (end < start + nameSize && data[end] != 0) {
        end++;
      }
      names.add(String.fromCharCodes(data.sublist(start, end)));
    }
    return TalkList(ids, characters, names);
  }

  static String listPathFor(String gametextFolder) {
    final lang = Directory(gametextFolder).parent.path;
    return '$lang${Platform.pathSeparator}script${Platform.pathSeparator}talkevent';
  }
}

Map<int, String> characterNamesFor(String gametextPath) {
  final folder = File(gametextPath).parent.path;
  final list = TalkList.load(TalkList.listPathFor(folder));
  final gametext = File('$folder${Platform.pathSeparator}gametext.bin');
  if (list == null || !gametext.existsSync()) return const {};
  try {
    final text = GameTextDocument.parse(gametext.readAsBytesSync()).texts;
    final out = <int, String>{};
    for (var i = 0; i < list.speakerCharacters.length; i++) {
      final character = list.speakerCharacters[i];
      final id = list.speakerNameIds[i];
      if (character < 0 || id >= text.length || out.containsKey(character)) continue;
      out[character] = text[id];
    }
    return out;
  } catch (error) {
    return const {};
  }
}

List<String> loadSpeakerNames(String folder, TalkList? list) {
  if (list == null) return const [];
  final gametext = File('${Directory(folder).parent.parent.path}${Platform.pathSeparator}gametext'
      '${Platform.pathSeparator}gametext.bin');
  if (!gametext.existsSync()) return const [];
  try {
    final text = GameTextDocument.parse(gametext.readAsBytesSync()).texts;
    return [for (final id in list.speakerNameIds) id < text.length ? text[id] : '#$id'];
  } catch (error) {
    return const [];
  }
}

class TalkFolderDocument extends TextDocument {
  final String folder;
  final List<TalkFile> files;
  final List<int> starts;
  final List<String> skipped;
  final Map<String, int> fileIndex;
  List<String> noText = [];
  List<String> speakerNames = const [];
  Map<String, int> eventIds = const {};
  Map<String, String>? keyed;

  String speakerName(int index) => index < speakerNames.length ? speakerNames[index] : '#$index';
  int? eventIdOf(String name) => eventIds[name.toLowerCase()];
  bool get hasList => eventIds.isNotEmpty;

  TalkFolderDocument(this.folder, this.files, this.starts, this.skipped, List<String> original)
      : fileIndex = {for (var i = 0; i < files.length; i++) files[i].name.toLowerCase(): i},
        super(original, folder);

  @override
  String get kind => 'talkevent';

  int lineCount(int file) => files[file].lines.length;
  TalkLine lineAt(int id) {
    final (file, line) = locate(id);
    return files[file].lines[line];
  }

  (int, int) locate(int id) {
    var low = 0, high = files.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (starts[mid] <= id) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return (low, id - starts[low]);
  }

  String keyOf(int id) {
    final (file, line) = locate(id);
    return '${files[file].name.toLowerCase()}|${files[file].lines[line].key}';
  }

  String? textForKey(String key) {
    keyed ??= {for (var id = 0; id < texts.length; id++) keyOf(id): texts[id]};
    return keyed![key];
  }

  bool fileChanged(int file) {
    for (var i = starts[file]; i < starts[file] + lineCount(file); i++) {
      if (changed(i)) return true;
    }
    return false;
  }

  Uint8List fileBytes(int file) => files[file].build(texts.sublist(starts[file], starts[file] + lineCount(file)));

  @override
  Uint8List toBytes() => throw UnsupportedError('A talk event folder saves file by file.');

  static TalkFolderDocument load(String folder) {
    final dir = Directory(folder);
    if (!dir.existsSync()) throw FormatError('Folder not found: $folder');
    final entries = dir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.bin')).toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    final files = <TalkFile>[];
    final starts = <int>[];
    final skipped = <String>[];
    final voiceOnly = <String>[];
    final texts = <String>[];
    for (final entry in entries) {
      final name = entry.uri.pathSegments.last;
      try {
        final file = TalkFile.parse(entry.readAsBytesSync(), name);
        if (file.lines.isEmpty) {
          voiceOnly.add(name);
          continue;
        }
        starts.add(texts.length);
        files.add(file);
        for (final line in file.lines) {
          texts.add(file.originalText(line));
        }
      } on FormatError {
        skipped.add(name);
      }
    }
    if (files.isEmpty) throw FormatError('No talk event files were found in $folder.');
    final list = TalkList.load(folder);
    return TalkFolderDocument(folder, files, starts, skipped, texts)
      ..noText = voiceOnly
      ..speakerNames = loadSpeakerNames(folder, list)
      ..eventIds = list == null ? const {} : {for (var i = 0; i < list.files.length; i++) list.files[i].toLowerCase(): i};
  }
}

List<String> siblingTalkLanguages(String folder) {
  final current = languageOf('$folder\\');
  if (current == null) return [];
  return [
    for (final code in languageCodes)
      if (code != current && Directory(siblingPath('$folder\\', code)!).existsSync()) code
  ];
}
