import 'dart:ffi'; import 'dart:io'; import 'dart:math' as math; import 'dart:typed_data';
import 'codec.dart'; import 'd2d.dart'; import 'gametext.dart'; import 'json_io.dart'; import 'search_index.dart';
import 'side_panels.dart'; import 'talkevent.dart'; import 'ui.dart';
import 'win.dart';

const editorPanelWidth = 1100.0;
const editorPanelHeight = 760.0;
const editorPanelX = 540.0;
const editorPanelY = 40.0;
const searchDelayMs = 120;
const snippetContext = 32;
const snippetLimit = 140;
const highlightLimit = 2000;
const searchHitColor = 0xFF7A5C00;
const searchTimerId = 2;
const lineBlockSize = 100;
const entryPreviewLimit = 60;
const fieldPreviewLimit = 200;

String shortenPathSmart(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  if (parts.length >= 3) return '\\${parts[parts.length - 3]}\\${parts[parts.length - 2]}\\${parts.last}';
  return path;
}

String fileNameOf(String path) => path.split(RegExp(r'[\\/]')).last;

String grouped(int n) {
  final digits = n.abs().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (match) => ',');
  return n < 0 ? '-$digits' : digits;
}

String signedGrouped(int n) => n >= 0 ? '+${grouped(n)}' : grouped(n);

String buildSnippet(String text, String query, bool caseSensitive) {
  final haystack = caseSensitive ? text : text.toLowerCase();
  final found = haystack.indexOf(caseSensitive ? query : query.toLowerCase());
  final position = math.max(found, 0);
  final start = math.max(0, position - snippetContext);
  final end = math.min(text.length, start + snippetLimit);
  var snippet = text.substring(start, end).trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' ');
  if (start > 0) snippet = '...$snippet';
  if (end < text.length) snippet = '$snippet...';
  return snippet;
}

class EditorHost {
  final void Function(Panel panel) showExclusive;
  final int Function() fallbackOwner;
  final (int, int) Function() origin;
  final void Function() closeApp;
  final void Function() toggleTopmost;
  EditorHost(this.showExclusive, this.fallbackOwner, this.origin, this.closeApp, this.toggleTopmost);
}

abstract class TextEditorPanel extends Panel {
  final EditorHost host;
  String get kind;
  String get titleNoun;
  String get defaultFileName;
  String get idleStatus;
  List<FileFilter> get openFilters;
  String get entriesHeading => 'Blocks';
  String get fieldsHeading => 'Lines';
  String get jumpHeading => 'Jump to ID';
  String get idNoun => 'ID';
  String get errorTitle => '$titleNoun Error';
  String get emptyInfo => 'No $titleNoun file loaded.';
  int get jumpDigits => 5;
  bool get supportsReference => true;
  (double, double) get columnWidths => (240, 400);
  int get blockSize => lineBlockSize;

  TextDocument? document;
  Uint8List? sourceBytes;
  String? path;
  String? lastSavedPath;
  int entryIndex = 0;
  int fieldIndex = 0;
  bool dirty = false;
  late String status;
  String loadedText = '';
  int loadedBytes = 0;
  final searchIndex = SearchIndex();
  List<int> searchMatches = [];
  bool searchTruncated = false;
  String searchQuery = '';
  bool searchPending = false;
  String? referenceLanguage;
  bool referenceTouched = false;
  final referenceCache = <String, TextDocument?>{};
  double referenceShare = 0.4;

  late final Label infoLabel = add(Label('', labelBoldStyle.copy(wrap: true, vAlign: vAlignNear), white));
  late final Label statusLabel = add(Label('', labelStyle.copy(wrap: true, vAlign: vAlignNear), mutedFg));
  late final Label searchLabel = add(Label('Search', labelBoldStyle, goldFg));
  late final Label jumpLabel = add(Label(jumpHeading, labelBoldStyle, goldFg));
  late final ToggleButton exactToggle = add(ToggleButton('Exact', () => runSearch()));
  late final ToggleButton caseToggle = add(ToggleButton('Aa', () => runSearch()));
  late final Label entriesHeadingLabel = add(Label(entriesHeading, labelBoldStyle, headingFg));
  late final Label fieldsHeadingLabel = add(Label(fieldsHeading, labelBoldStyle, headingFg));
  late final Label resultsHeadingLabel = add(Label('Results', labelBoldStyle, headingFg));
  late final VirtualList entriesList = add(VirtualList((index) => selectEntry(index)));
  late final VirtualList fieldsList = add(VirtualList(onFieldSelect)..marks = lineMarks);
  late final VirtualList resultsList = add(VirtualList(onResultSelect)
    ..marks = (index, label) => matchRanges(label, label.indexOf('|') + 1));
  late final Label valueLabel = add(Label('Value', labelBoldStyle, headingFg));
  late final Label lengthLabel = add(Label('', labelStyle, mutedFg));
  late final Label referenceLabel = add(Label('', labelBoldStyle, headingFg));
  late final Sash columnSashA = add(Sash(true, (delta) => dragColumn(0, delta)));
  late final Sash columnSashB = add(Sash(true, (delta) => dragColumn(1, delta)));
  late final Sash splitSash = add(Sash(false, dragSplit));
  late final Sash referenceSash = add(Sash(false, dragReference));
  late final List<Button> valueButtons;
  late final Button languageButton;
  late final Button referenceButton;
  late final TextBox searchBox;
  late final TextBox jumpBox;
  late final TextBox editor;
  late final TextBox referenceBox;
  late double columnA;
  late double columnB;
  double columnsHeight = 260;

  TextEditorPanel(String title, this.host)
      : super(title, editorPanelWidth, editorPanelHeight, editorPanelX, editorPanelY, host.origin, () {},
            minWidth: 640, minHeight: 460) {
    onClose = closeDocument;
    status = idleStatus;
    columnA = columnWidths.$1;
    columnB = columnWidths.$2;
    searchBox = TextBox(this, 101, face: uiFont);
    jumpBox = TextBox(this, 102, center: true);
    editor = TextBox(this, 103, multiline: true, face: uiFont, points: 11);
    referenceBox = TextBox(this, 104, multiline: true, readOnly: true, face: uiFont, points: 11, foreground: mutedFg);
    referenceBox.show(false);
    valueButtons = [
      Button('J', showJsonMenu, accent, accentActive, black),
      Button('RA', reloadAllValues, 0xFF6A4A4A, 0xFF8F6161),
      Button('C', saveAs, 0xFF4D6D4F, 0xFF66956A),
      Button('R', restoreSelectedValue, 0xFF4D5C71, 0xFF6E83A1),
    ];
    for (final button in valueButtons) {
      add(button);
    }
    referenceButton = Button('Ref Off', cycleReference, toggleOff, scrollActive)..w = 70;
    if (supportsReference) addHeader(referenceButton);
    languageButton = addHeader(Button('Lang --', switchLanguage, toggleOff, scrollActive)..w = 70);
    fitToScreen();
    refresh();
  }

  TextDocument parseBytes(Uint8List data, String? filePath) => parseKind(kind, data, filePath);
  void documentLoaded() {}
  Uint8List? pendingBytes;

  TextDocument readDocument(String filePath) {
    final bytes = File(filePath).readAsBytesSync();
    final parsed = parseBytes(bytes, filePath);
    pendingBytes = bytes;
    return parsed;
  }

  TextDocument loadReference(String filePath) => parseBytes(File(filePath).readAsBytesSync(), filePath);
  String? referenceText(TextDocument reference, int id) => id < reference.length ? reference.texts[id] : null;
  List<String> languagesFor(String filePath) => siblingLanguages(filePath);

  int get count => document?.length ?? 0;
  int entryCount() => document == null ? 0 : (count + blockSize - 1) ~/ blockSize;
  int fieldCount(int entry) => math.max(0, math.min(blockSize, count - entry * blockSize));
  int idOf(int entry, int field) => entry * blockSize + field;
  (int, int) locationOf(int id) => (id ~/ blockSize, id % blockSize);
  String idText(int id) => padId(id);
  int jumpValue(int id) => id;
  int? jumpTarget(int value) => value >= 0 && value < count ? value : null;
  String lineLabel(int id) => previewText(document!.texts[id], fieldPreviewLimit);
  String detailPrefix(int id) => '$idNoun ${idText(id)}';
  String languageTag() {
    final lang = path == null ? null : languageOf(path!);
    return lang == null ? '' : '[${lang.toUpperCase()}] ';
  }

  String infoText() {
    final d = document!;
    final name = fileNameOf(path ?? defaultFileName);
    return '${languageTag()}$name$dirtyMarker\n${grouped(d.length)} lines|${grouped(d.changedCount)} edited';
  }

  String entryLabel(int entry) {
    final d = document!;
    final start = entry * blockSize;
    final end = start + fieldCount(entry);
    var preview = '';
    var edited = false;
    for (var id = start; id < end; id++) {
      if (preview.isEmpty && d.texts[id].trim().isNotEmpty) preview = d.texts[id];
      if (!edited && d.changed(id)) edited = true;
    }
    return '${edited ? '*' : ' '}${idText(start)}-${idText(end - 1)} ${previewText(preview, entryPreviewLimit)}';
  }

  String fieldLabel(int entry, int field) {
    final id = idOf(entry, field);
    return '${document!.changed(id) ? '*' : ' '}${idText(id)} ${lineLabel(id)}';
  }

  String get dirtyMarker => dirty ? ' *' : '';
  int get dialogOwner => panelVisible ? hwnd : host.fallbackOwner();

  void showError(String title, String message) => messageBox(dialogOwner, message, title, MB_OK | MB_ICONERROR);
  bool askYesNo(String title, String message) =>
      messageBox(dialogOwner, message, title, MB_YESNO | MB_ICONQUESTION) == IDYES;

  String describe(Object error) {
    if (error is FileSystemException) {
      final os = error.osError?.message.trim() ?? '';
      return os.isEmpty ? '${error.message}: ${error.path}' : '$os: ${error.path}';
    }
    if (error is RangeError) return 'The file ended before the data it describes.';
    return error.toString();
  }

  String? startFolder() {
    final base = lastSavedPath ?? path;
    return base == null ? null : File(base).parent.path;
  }

  bool confirmDiscard(String action) {
    if (!commitCurrentValue(announce: false)) return false;
    if (!dirty) return true;
    return askYesNo(titleNoun, 'Discard the current $titleNoun edits and $action?');
  }

  void showPanel() {
    if (document != null) host.showExclusive(this);
  }

  bool openDocument() {
    final file = fileDialog(dialogOwner, title: 'Open $titleNoun', filters: openFilters, startIn: startFolder());
    if (file == null || !confirmDiscard('open another file')) return false;
    return loadDocument(file);
  }

  bool loadDocument(String filePath, {int? focusId}) {
    final TextDocument parsed;
    pendingBytes = null;
    try {
      parsed = readDocument(filePath);
    } catch (error) {
      showError(errorTitle, describe(error));
      return false;
    }
    final previousLanguage = path == null ? null : languageOf(path!);
    document = parsed;
    sourceBytes = pendingBytes;
    pendingBytes = null;
    path = filePath;
    lastSavedPath = null;
    dirty = false;
    entryIndex = 0;
    fieldIndex = 0;
    if (focusId != null && focusId < parsed.length) {
      final (entry, field) = locationOf(focusId);
      entryIndex = entry;
      fieldIndex = field;
    }
    referenceCache.clear();
    pickReference(previousLanguage);
    documentLoaded();
    status = '${fileNameOf(filePath)} loaded.';
    searchIndex.invalidate();
    refresh();
    host.showExclusive(this);
    return true;
  }

  void closeDocument() {
    if (document != null && !confirmDiscard('close it')) return;
    document = null;
    sourceBytes = null;
    path = null;
    lastSavedPath = null;
    dirty = false;
    entryIndex = 0;
    fieldIndex = 0;
    referenceCache.clear();
    status = idleStatus;
    documentLoaded();
    searchIndex.invalidate();
    refresh();
    hide();
  }

  void reloadAllValues() {
    final d = document;
    if (d == null) return;
    commitCurrentValue(announce: false);
    if (d.changedCount > 0 &&
        !askYesNo('Reload $titleNoun', 'Discard all current $titleNoun edits and reload the original text?')) {
      return;
    }
    d.texts.setAll(0, d.original);
    dirty = false;
    status = 'Reloaded every line from the file as it was opened.';
    searchIndex.invalidate();
    refresh();
  }

  void saveAs() {
    final d = document;
    if (d == null) return;
    if (!commitCurrentValue(announce: false)) return;
    final base = lastSavedPath ?? path ?? defaultFileName;
    final output = fileDialog(dialogOwner,
        save: true, filters: openFilters, fileName: fileNameOf(base), defaultExtension: 'bin', startIn: startFolder());
    if (output == null) return;
    final Uint8List bytes;
    var backupNote = '';
    try {
      bytes = d.toBytes();
      final check = parseBytes(bytes, output);
      var same = check.length == d.length;
      for (var i = 0; same && i < d.length; i++) {
        same = check.texts[i] == d.texts[i];
      }
      if (!same) throw FormatError('The rebuilt file didnt read back the same text, so nothing was written.');
      final target = File(output);
      final backup = File('$output.bak');
      if (target.existsSync() && !backup.existsSync()) {
        target.copySync(backup.path);
        backupNote = ' Old file kept as ${fileNameOf(backup.path)}.';
      }
      target.writeAsBytesSync(bytes, flush: true);
    } catch (error) {
      showError('Save Failed', describe(error));
      return;
    }
    referenceCache.remove(output);
    lastSavedPath = output;
    dirty = false;
    final change = bytes.length - (sourceBytes?.length ?? bytes.length);
    status = 'Saved ${grouped(bytes.length)} bytes to ${shortenPathSmart(output)} (${signedGrouped(change)} vs original).'
        '$backupNote';
    refresh();
  }

  void applyValue() => commitCurrentValue(announce: true, force: true);

  static const jsonFilters = [FileFilter('JSON', '*.json'), FileFilter('All files', '*.*')];
  late final JsonMenu jsonMenu = JsonMenu(this);
  bool importTouchedDocument = false;

  String get jsonHeading => '${languageTag()}${fileNameOf(path ?? defaultFileName)}';
  List<String> get jsonDescriptions => const [
        'Save this file\'s text as one JSON.',
        'Save every text file in this gametext folder as JSON.',
        'Pick a JSON and save it back as its .bin.',
        'Pick a folder of JSON and save them back as .bin files.',
      ];
  String? get language => path == null ? null : languageOf(path!);
  String get baseFolder => File(path!).parent.path;

  void showJsonMenu() {
    if (document == null) return;
    if (!commitCurrentValue(announce: false)) return;
    jsonMenu.open();
  }

  void finishJson(String message, List<String> problems) {
    status = message;
    if (problems.isNotEmpty) {
      final shown = problems.take(12).join('\n');
      final more = problems.length > 12 ? '\n...and ${problems.length - 12} more' : '';
      showError('JSON', '$shown$more');
    }
    refresh();
  }

  void exportJson() {
    final d = document;
    if (d == null) return;
    final file = fileNameOf(path!);
    final out = fileDialog(dialogOwner,
        save: true, title: 'Export JSON', filters: jsonFilters, fileName: jsonNameFor(file), defaultExtension: 'json', startIn: startFolder());
    if (out == null) return;
    final lines = collectLines(documentKeys(d), d.texts);
    try {
      File(out).writeAsStringSync(encodeJsonText(kind, file, language, lines));
    } catch (error) {
      showError('Export Failed', describe(error));
      return;
    }
    finishJson('Exported ${grouped(lines.length)} lines to ${shortenPathSmart(out)}.', const []);
  }

  void exportAllJson() {
    final d = document;
    if (d == null) return;
    final out = fileDialog(dialogOwner, folder: true, title: 'Export JSON into which folder?', startIn: startFolder());
    if (out == null) return;
    exportAllInto(out);
  }

  void exportAllInto(String out) {
    final d = document;
    if (d == null) return;
    var files = 0, lines = 0;
    final problems = <String>[];
    for (final MapEntry(key: fileKind, value: name) in gametextFolderFiles.entries) {
      TextDocument source;
      if (fileKind == kind) {
        source = d;
      } else {
        final file = File('$baseFolder${Platform.pathSeparator}$name');
        if (!file.existsSync()) continue;
        try {
          source = parseKind(fileKind, file.readAsBytesSync(), file.path);
        } catch (error) {
          problems.add('$name: ${describe(error)}');
          continue;
        }
      }
      final map = collectLines(documentKeys(source), source.texts);
      try {
        File('$out${Platform.pathSeparator}${jsonNameFor(name)}').writeAsStringSync(encodeJsonText(fileKind, name, language, map));
      } catch (error) {
        problems.add('$name: ${describe(error)}');
        continue;
      }
      files++;
      lines += map.length;
    }
    finishJson('Exported $files JSON file(s), ${grouped(lines)} lines, to ${shortenPathSmart(out)}.', problems);
  }

  BuiltFile buildImport(JsonText item) {
    if (!gametextFolderFiles.containsKey(item.kind)) {
      throw FormatError('it holds ${item.kind} text, import it from Script Text instead');
    }
    final d = document!;
    if (item.kind == kind && item.file.toLowerCase() == fileNameOf(path!).toLowerCase()) {
      importTouchedDocument = true;
      dirty = true;
      return buildFromDocument(item, d);
    }
    final base = File('$baseFolder${Platform.pathSeparator}${item.file}');
    if (!base.existsSync()) throw FormatError('the original ${item.file} isnt in ${shortenPathSmart(baseFolder)}');
    return buildFromDocument(item, parseKind(item.kind, base.readAsBytesSync(), base.path));
  }

  void importJson() {
    if (document == null) return;
    final source = fileDialog(dialogOwner, title: 'Import JSON', filters: jsonFilters, startIn: startFolder());
    if (source == null) return;
    final JsonText item;
    try {
      item = JsonText.read(source);
    } catch (error) {
      showError('Import Failed', describe(error));
      return;
    }
    final out = fileDialog(dialogOwner,
        save: true, title: 'Save ${item.file} as', filters: openFilters, fileName: item.file, defaultExtension: 'bin', startIn: startFolder());
    if (out == null) return;
    runImport([item], (built) => out, []);
  }

  void importAllJson() {
    if (document == null) return;
    final folder = fileDialog(dialogOwner, folder: true, title: 'Pick the folder of JSON files to import', startIn: startFolder());
    if (folder == null) return;
    importAllFrom(folder, null);
  }

  void importAllFrom(String folder, String? output) {
    final problems = <String>[];
    final items = <JsonText>[];
    for (final path in jsonFilesIn(folder)) {
      try {
        items.add(JsonText.read(path));
      } catch (error) {
        problems.add('${fileNameOf(path)}: ${describe(error)}');
      }
    }
    if (items.isEmpty) {
      finishJson('No JSON files were found in ${shortenPathSmart(folder)}.', problems);
      return;
    }
    final out = output ??
        fileDialog(dialogOwner,
            folder: true, title: 'Save the ${items.length} rebuilt .bin file(s) into which folder?', startIn: startFolder());
    if (out == null) return;
    runImport(items, (built) => '$out${Platform.pathSeparator}${built.file}', problems);
  }

  String savedLocation(String file) => file;

  void runImport(List<JsonText> items, String Function(BuiltFile built) target, List<String> problems) {
    importTouchedDocument = false;
    var written = 0, applied = 0, unknown = 0, backups = 0, failed = 0;
    String? lastTarget;
    for (final item in items) {
      try {
        final built = buildImport(item);
        final path = target(built);
        backups += writeWithBackup(path, built.bytes);
        lastTarget = path;
        written++;
        applied += built.applied;
        unknown += built.unknown.length;
        if (built.unknown.isNotEmpty) {
          problems.add('${fileNameOf(item.source)}: ${built.unknown.length} key(s) not found, like ${built.unknown.first}');
        }
      } catch (error) {
        failed++;
        problems.add('${fileNameOf(item.source)}: ${describe(error)}');
      }
    }
    if (importTouchedDocument) {
      searchIndex.invalidate();
      if (failed == 0) dirty = false;
    }
    if (lastTarget != null) lastSavedPath = savedLocation(lastTarget);
    final where = lastTarget == null ? '' : ' to ${shortenPathSmart(File(lastTarget).parent.path)}';
    final extra = [if (unknown > 0) '$unknown unknown keys', if (backups > 0) '$backups old file(s) kept as .bak'];
    finishJson('Imported $written of ${items.length} JSON file(s), ${grouped(applied)} lines$where'
        '${extra.isEmpty ? '' : ' (${extra.join(', ')})'}.', problems);
  }

  bool commitCurrentValue({bool announce = true, bool force = false}) {
    final d = document;
    final id = currentId();
    if (d == null || id == null) return true;
    final value = editor.text;
    if (value == loadedText && !force) return true;
    final stored = storeBreaks(value);
    if (stored != d.texts[id]) {
      try {
        d.setText(id, stored);
      } catch (error) {
        showError(errorTitle, describe(error));
        return false;
      }
      dirty = true;
      final (entry, field) = locationOf(id);
      searchIndex.update(entry, field, showBreaks(stored));
    }
    loadedText = value;
    if (announce) status = 'Updated $idNoun ${idText(id)}.';
    refresh();
    return true;
  }

  void restoreSelectedValue() {
    final d = document;
    final id = currentId();
    if (d == null || id == null) return;
    d.texts[id] = d.original[id];
    dirty = true;
    final (entry, field) = locationOf(id);
    searchIndex.update(entry, field, showBreaks(d.texts[id]));
    status = 'Restored $idNoun ${idText(id)} from the file as it was opened.';
    refresh();
  }

  int? currentId() {
    if (entryCount() <= 0) return null;
    entryIndex = math.max(0, math.min(entryIndex, entryCount() - 1));
    final fields = fieldCount(entryIndex);
    if (fields <= 0) return null;
    fieldIndex = math.max(0, math.min(fieldIndex, fields - 1));
    return idOf(entryIndex, fieldIndex);
  }

  void refresh() {
    languageButton.text = 'Lang ${path == null ? '--' : (languageOf(path!) ?? '--').toUpperCase()}';
    referenceButton.text = referenceLanguage == null ? 'Ref Off' : 'Ref ${referenceLanguage!.toUpperCase()}';
    statusLabel.set(status);
    if (document == null) {
      infoLabel.set(emptyInfo);
      setJump('');
      entriesList.setItems(0, null);
      fieldsList.setItems(0, null);
    } else {
      final entries = entryCount();
      entryIndex = math.max(0, math.min(entryIndex, entries - 1));
      entriesList.setItems(entries, entryLabel, entries > 0 ? entryIndex : -1);
      populateFields();
      infoLabel.set(infoText());
    }
    loadSelectedValue();
    runSearch(keepPosition: true);
    layout();
  }

  void setJump(String value) {
    if (jumpBox.text != value) jumpBox.text = value;
  }

  void populateFields() {
    if (entryCount() <= 0) {
      fieldsList.setItems(0, null);
      return;
    }
    final entry = entryIndex;
    final fields = fieldCount(entry);
    fieldIndex = math.max(0, math.min(fieldIndex, fields - 1));
    fieldsList.setItems(fields, (index) => fieldLabel(entry, index), fields > 0 ? fieldIndex : -1);
  }

  void restoreSelection() {
    entriesList.select(entryIndex);
    fieldsList.select(fieldIndex);
  }

  void selectEntry(int index, {int? field, bool updateJump = true}) {
    final entries = entryCount();
    if (entries <= 0) return;
    if (!commitCurrentValue(announce: false)) {
      restoreSelection();
      return;
    }
    entryIndex = math.max(0, math.min(index, entries - 1));
    fieldIndex = field ?? 0;
    entriesList.select(entryIndex);
    populateFields();
    loadSelectedValue(updateJump: updateJump);
  }

  void onFieldSelect(int index) {
    if (!commitCurrentValue(announce: false)) {
      restoreSelection();
      return;
    }
    fieldIndex = index;
    fieldsList.select(index);
    loadSelectedValue();
  }

  void goToId(int id, {bool updateJump = true}) {
    if (id < 0 || id >= count) return;
    final (entry, field) = locationOf(id);
    selectEntry(entry, field: field, updateJump: updateJump);
  }

  void stepLine(int delta) {
    final id = currentId();
    if (id != null) goToId(math.max(0, math.min(count - 1, id + delta)));
  }

  void onJumpChange() {
    final raw = jumpBox.text.trim();
    if (document == null || raw.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(raw)) return;
    final target = jumpTarget(int.parse(raw));
    if (target != null && target != currentId()) goToId(target, updateJump: false);
  }

  void loadSelectedValue({bool updateJump = true}) {
    final d = document;
    final id = currentId();
    final text = d == null || id == null ? '' : showBreaks(d.texts[id]);
    editor.text = text;
    loadedText = editor.text;
    loadedBytes = d == null || id == null ? 0 : d.original[id].length * 2;
    if (updateJump && id != null) setJump(padId(jumpValue(id), jumpDigits));
    updateLengthLabel();
    updateReference();
    highlightEditorMatches();
  }

  void updateLengthLabel() {
    final d = document;
    final id = currentId();
    if (d == null || id == null) {
      lengthLabel.set('');
      return;
    }
    final stored = storeBreaks(editor.text);
    final bytes = stored.length * 2;
    final limit = d.maxChars;
    var details = '${detailPrefix(id)}|${grouped(stored.length)}${limit == null ? '' : '/$limit'} chars|'
        '${grouped(bytes)} bytes';
    if (bytes != loadedBytes) details += ' (${signedGrouped(bytes - loadedBytes)})';
    if (stored != d.texts[id]) {
      details += '|unapplied';
    } else if (d.changed(id)) {
      details += '|edited';
    }
    lengthLabel.set(details);
  }

  List<String> referenceChoices() => path == null ? const [] : languagesFor(path!);

  void pickReference(String? previousLanguage) {
    if (!supportsReference || path == null) {
      referenceLanguage = null;
      return;
    }
    final choices = referenceChoices();
    if (referenceTouched && referenceLanguage == null) return;
    if (referenceLanguage != null && choices.contains(referenceLanguage)) return;
    if (previousLanguage != null && choices.contains(previousLanguage)) {
      referenceLanguage = previousLanguage;
    } else if (choices.contains('jp')) {
      referenceLanguage = 'jp';
    } else {
      referenceLanguage = choices.isEmpty ? null : choices.first;
    }
  }

  void cycleReference() {
    if (document == null || path == null) return;
    final choices = <String?>[...referenceChoices(), null];
    final at = choices.indexOf(referenceLanguage);
    referenceLanguage = choices[(at + 1) % choices.length];
    referenceTouched = true;
    status = referenceLanguage == null
        ? 'Reference text hidden.'
        : 'Showing the ${referenceLanguage!.toUpperCase()} line with the same ID as reference.';
    refresh();
  }

  TextDocument? referenceDocument() {
    final lang = referenceLanguage;
    final current = path;
    if (lang == null || current == null) return null;
    final sibling = siblingPath(current, lang);
    if (sibling == null) return null;
    return referenceCache.putIfAbsent(sibling, () {
      try {
        return loadReference(sibling);
      } catch (error) {
        return null;
      }
    });
  }

  void updateReference() {
    final lang = referenceLanguage;
    final active = supportsReference && document != null && lang != null;
    if (referenceBox.visible != active) {
      referenceBox.show(active);
      layout();
    }
    if (!active) return;
    final reference = referenceDocument();
    final id = currentId();
    final String text;
    final found = reference == null || id == null ? null : referenceText(reference, id);
    if (reference == null) {
      text = '(the ${lang.toUpperCase()} $titleNoun file couldnt be read)';
    } else if (found == null) {
      text = '(no matching ${lang.toUpperCase()} line)';
    } else {
      text = showBreaks(found);
    }
    referenceBox.text = text;
    referenceLabel.set('Reference ${lang.toUpperCase()}');
  }

  void switchLanguage() {
    final current = path;
    if (document == null || current == null) return;
    final language = languageOf(current);
    final others = languagesFor(current);
    if (language == null || others.isEmpty) {
      status = 'No other lang_xx folder has a ${fileNameOf(current)} next to this one.';
      refresh();
      return;
    }
    final ordered = [for (final code in languageCodes) if (code == language || others.contains(code)) code];
    final next = ordered[(ordered.indexOf(language) + 1) % ordered.length];
    if (!confirmDiscard('switch to ${next.toUpperCase()}')) return;
    loadDocument(siblingPath(current, next)!, focusId: currentId());
  }

  void focusSearch() => searchBox.focus(selectAll: true);

  void clearSearch() {
    searchBox.text = '';
    runSearch();
  }

  void scheduleSearch() {
    searchPending = true;
    SetTimer(hwnd, searchTimerId, searchDelayMs, nullptr);
  }

  @override
  void timer(int id) {
    if (id == searchTimerId) {
      KillTimer(hwnd, searchTimerId);
      if (searchPending) runSearch();
    }
  }

  Iterable<List<String>> searchTexts() sync* {
    final d = document!;
    for (var entry = 0; entry < entryCount(); entry++) {
      yield [for (var field = 0; field < fieldCount(entry); field++) showBreaks(d.texts[idOf(entry, field)])];
    }
  }

  void runSearch({bool keepPosition = false}) {
    searchPending = false;
    KillTimer(hwnd, searchTimerId);
    final query = searchBox.text.replaceAll(searchSeparator, '');
    final previous = keepPosition ? resultsList.selected : -1;
    if (query.isEmpty || document == null) {
      searchQuery = '';
      searchMatches = [];
      searchTruncated = false;
    } else {
      if (searchIndex.stale) searchIndex.rebuild(searchTexts());
      searchQuery = query;
      final (matches, truncated) =
          searchIndex.search(query, exact: exactToggle.value, caseSensitive: caseToggle.value);
      searchMatches = matches;
      searchTruncated = truncated;
    }
    final found = searchMatches.length;
    if (searchQuery.isNotEmpty) {
      final overflow = searchTruncated ? '+' : '';
      resultsHeadingLabel.set('Results  ${grouped(found)}$overflow ${found == 1 ? 'match' : 'matches'}');
    } else {
      resultsHeadingLabel.set('Results');
    }
    resultsList.setItems(found, resultLabel, math.min(previous, found - 1));
    highlightEditorMatches();
  }

  String resultLabel(int index) {
    final record = searchMatches[index];
    if (record >= searchIndex.texts.length) return '';
    final (entry, field) = searchIndex.locate(record);
    final snippet = buildSnippet(searchIndex.textAt(record), searchQuery, caseToggle.value);
    return '${idText(idOf(entry, field))}|$snippet';
  }

  void onResultSelect(int index) {
    if (index >= searchMatches.length) return;
    final record = searchMatches[index];
    if (record >= searchIndex.texts.length) return;
    final (entry, field) = searchIndex.locate(record);
    selectEntry(entry, field: field);
  }

  void stepResult(int delta) {
    if (searchPending) runSearch();
    final found = searchMatches.length;
    if (found == 0) return;
    final current = resultsList.selected;
    final target = current >= 0 ? (current + delta) % found : (delta > 0 ? 0 : found - 1);
    resultsList.choose(target < 0 ? target + found : target);
  }

  List<(int, int)> matchRanges(String label, [int from = 0]) {
    final query = searchQuery;
    if (query.isEmpty || from >= label.length) return const [];
    var haystack = label;
    var needle = query;
    if (!caseToggle.value) {
      final lowered = label.toLowerCase();
      if (lowered.length == label.length) {
        haystack = lowered;
        needle = query.toLowerCase();
      }
    }
    final ranges = <(int, int)>[];
    var start = from;
    while (ranges.length < 16) {
      final at = haystack.indexOf(needle, start);
      if (at < 0) break;
      ranges.add((at, at + needle.length));
      start = at + needle.length;
    }
    return ranges;
  }

  List<(int, int)> lineMarks(int index, String label) {
    if (searchQuery.isEmpty) return const [];
    final from = label.indexOf(' ', 1) + 1;
    if (!exactToggle.value) return matchRanges(label, from);
    final rest = label.substring(from).trim();
    final same = caseToggle.value ? rest == searchQuery : rest.toLowerCase() == searchQuery.toLowerCase();
    if (!same) return const [];
    final start = label.indexOf(rest, from);
    return [(start, start + rest.length)];
  }

  void highlightEditorMatches() {
    final query = searchQuery;
    if (query.isEmpty || document == null) {
      editor.highlight(const [], searchHitColor);
      return;
    }
    final text = editor.text;
    final caseSensitive = caseToggle.value;
    if (exactToggle.value) {
      final same = caseSensitive ? text == query : text.toLowerCase() == query.toLowerCase();
      editor.highlight(same ? [(0, text.length)] : const [], searchHitColor);
      return;
    }
    var haystack = text;
    var needle = query;
    if (!caseSensitive) {
      final lowered = text.toLowerCase();
      if (lowered.length == text.length) {
        haystack = lowered;
        needle = query.toLowerCase();
      }
    }
    final ranges = <(int, int)>[];
    var start = 0;
    while (ranges.length < highlightLimit && needle.isNotEmpty) {
      final at = haystack.indexOf(needle, start);
      if (at < 0) break;
      ranges.add((at, at + needle.length));
      start = at + needle.length;
    }
    editor.highlight(ranges, searchHitColor);
  }

  void dragColumn(int which, double delta) {
    final total = bodyRect.$3 - 16 - 12;
    if (which == 0) {
      columnA = (columnA + delta).clamp(90.0, math.max(90.0, total - columnB - 160));
    } else {
      columnB = (columnB + delta).clamp(120.0, math.max(120.0, total - columnA - 160));
    }
    layout();
  }

  void dragSplit(double delta) {
    columnsHeight += delta;
    layout();
  }

  void dragReference(double delta) {
    final total = editor.h + referenceBox.h;
    if (total <= 0) return;
    referenceShare = (referenceShare - delta / total).clamp(0.12, 0.88);
    layout();
  }

  @override
  void layoutBody(double bx, double by, double bw, double bh) {
    final left = bx + 8;
    final inner = bw - 16;
    var y = by + 6;
    final infoH = math.max(16.0, infoLabel.heightFor(inner));
    infoLabel.place(left, y, inner, infoH);
    y += infoH + 2;
    final statusH = math.max(14.0, statusLabel.heightFor(inner));
    statusLabel.place(left, y, inner, statusH);
    y += statusH + 6;

    const rowH = 24.0;
    final searchW = Direct2D.measure('Search', labelBoldStyle).$1.ceilToDouble();
    searchLabel.place(left, y, searchW, rowH);
    const jumpW = 70.0;
    var right = left + inner;
    jumpBox.place(right - jumpW, y + 1, jumpW, rowH - 2);
    right -= jumpW + 8;
    final jumpLabelW = Direct2D.measure(jumpHeading, labelBoldStyle).$1.ceilToDouble() + 2;
    jumpLabel.place(right - jumpLabelW, y, jumpLabelW, rowH);
    right -= jumpLabelW + 16;
    caseToggle.place(right - 30, y + 1, 30, rowH - 2);
    right -= 30 + 4;
    exactToggle.place(right - 46, y + 1, 46, rowH - 2);
    right -= 46 + 8;
    searchBox.place(left + searchW + 8, y + 1, right - (left + searchW + 8), rowH - 2);
    y += rowH + 6;

    final areaBottom = by + bh - 2;
    final available = areaBottom - y;
    columnsHeight = columnsHeight.clamp(110.0, math.max(110.0, available - 6 - 140));
    final columnsTop = y;
    final total = inner - 12;
    columnA = columnA.clamp(90.0, math.max(90.0, total - 120 - 160));
    columnB = columnB.clamp(120.0, math.max(120.0, total - columnA - 160));
    final resultsW = math.max(0.0, total - columnA - columnB);
    const headingH = 18.0;
    final listH = columnsHeight - headingH;
    var cx = left;
    for (final (heading, list, width) in [
      (entriesHeadingLabel, entriesList, columnA),
      (fieldsHeadingLabel, fieldsList, columnB),
      (resultsHeadingLabel, resultsList, resultsW),
    ]) {
      heading.place(cx, columnsTop, width, headingH - 2);
      list.place(cx, columnsTop + headingH, width, listH);
      list.clampTop();
      cx += width + 6;
    }
    columnSashA.place(left + columnA, columnsTop, 6, columnsHeight);
    columnSashB.place(left + columnA + 6 + columnB, columnsTop, 6, columnsHeight);
    splitSash.place(left, columnsTop + columnsHeight, inner, 6);

    var vy = columnsTop + columnsHeight + 6 + 6;
    const buttonH = 22.0;
    final valueW = Direct2D.measure('Value', labelBoldStyle).$1.ceilToDouble() + 2;
    valueLabel.place(left, vy, valueW, buttonH);
    var buttonRight = left + inner;
    for (final button in valueButtons.reversed) {
      final width = button.text.length > 1 ? 34.0 : 28.0;
      button.place(buttonRight - width, vy, width, buttonH);
      buttonRight -= width + 4;
    }
    lengthLabel.place(left + valueW + 10, vy, math.max(0, buttonRight - (left + valueW + 10)), buttonH);
    vy += buttonH + 4;

    final areaH = math.max(20.0, areaBottom - vy);
    final showReference = referenceBox.visible;
    referenceSash.visible = showReference;
    referenceLabel.visible = showReference;
    if (!showReference) {
      editor.place(left, vy, inner, areaH);
      return;
    }
    const labelH = 18.0;
    final usable = math.max(40.0, areaH - 6 - labelH);
    final referenceH = (usable * referenceShare).roundToDouble();
    final editorH = usable - referenceH;
    editor.place(left, vy, inner, editorH);
    referenceSash.place(left, vy + editorH, inner, 6);
    referenceLabel.place(left, vy + editorH + 6, inner, labelH);
    referenceBox.place(left, vy + editorH + 6 + labelH, inner, referenceH);
  }

  @override
  void paintBody(Graphics g) {
    for (final box in [searchBox, jumpBox, editor, if (referenceBox.visible) referenceBox]) {
      g.fillRect(box.x, box.y, box.w, box.h, fieldBg);
    }
  }

  bool sharedKey(int vk) {
    if (vk == VK_F1) {
      host.toggleTopmost();
      return true;
    }
    if (vk == 0x46 && keyDown(VK_CONTROL)) {
      focusSearch();
      return true;
    }
    if (vk == 0x53 && keyDown(VK_CONTROL)) {
      saveAs();
      return true;
    }
    if ((vk == VK_UP || vk == VK_DOWN) && keyDown(VK_CONTROL)) {
      stepLine(vk == VK_UP ? -1 : 1);
      return true;
    }
    return false;
  }

  @override
  bool panelKey(int vk) {
    if (vk == VK_ESCAPE) {
      host.closeApp();
      return true;
    }
    return sharedKey(vk);
  }

  @override
  bool textBoxKey(TextBox box, int msg, int vk) {
    if (msg == WM_CHAR) {
      if (box != editor && (vk == 13 || vk == 27 || vk == 6 || vk == 19)) return true;
      return box == editor && (vk == 27 || vk == 6 || vk == 19 || vk == 10);
    }
    if (box == editor && vk == VK_RETURN && keyDown(VK_CONTROL)) {
      applyValue();
      return true;
    }
    if (sharedKey(vk)) return true;
    if (box == searchBox) {
      if (vk == VK_RETURN) {
        stepResult(keyDown(VK_SHIFT) ? -1 : 1);
        return true;
      }
      if (vk == VK_ESCAPE) {
        clearSearch();
        return true;
      }
    }
    if (box == jumpBox && vk == VK_RETURN) {
      onJumpChange();
      return true;
    }
    if (vk == VK_ESCAPE) {
      host.closeApp();
      return true;
    }
    return false;
  }

  @override
  void textBoxChanged(TextBox box) {
    if (box == searchBox) {
      scheduleSearch();
    } else if (box == jumpBox) {
      onJumpChange();
    } else if (box == editor) {
      updateLengthLabel();
      if (searchQuery.isNotEmpty) highlightEditorMatches();
    }
  }
}

class GameTextEditor extends TextEditorPanel {
  Map<int, int> hashes = {};

  GameTextEditor(EditorHost host) : super('Game Text', host);

  GameTextDocument? get doc => document as GameTextDocument?;

  @override
  String get kind => 'gametext';
  @override
  String get titleNoun => 'Game Text';
  @override
  String get defaultFileName => 'gametext.bin';
  @override
  String get idleStatus => 'Open a lang_xx\\gametext\\gametext.bin to start editing.';
  @override
  List<FileFilter> get openFilters => const [
        FileFilter('Game text', 'gametext*.bin'),
        FileFilter('BIN files', '*.bin'),
        FileFilter('All files', '*.*'),
      ];

  @override
  void documentLoaded() => hashes = path == null ? {} : loadHashTable(path!);

  @override
  String lineLabel(int id) {
    final d = doc!;
    if (!d.changed(id) && d.isPlaceholder(id)) return '(unused)';
    return super.lineLabel(id);
  }

  @override
  String detailPrefix(int id) {
    final hash = hashes[id];
    var details = super.detailPrefix(id);
    if (hash != null) details += '|UI hash ${hex8(hash)}';
    if (doc!.isPlaceholder(id)) details += '|unused slot';
    return details;
  }

  @override
  String infoText() {
    final d = doc!;
    final name = fileNameOf(path ?? defaultFileName);
    return '${languageTag()}$name$dirtyMarker\n${grouped(d.length)} lines|${grouped(d.changedCount)} edited';
  }
}

class TaskTextEditor extends TextEditorPanel {
  TaskTextEditor(EditorHost host) : super('Task Text', host);

  @override
  String get kind => 'task';
  @override
  String get titleNoun => 'Task Text';
  @override
  String get defaultFileName => 'TaskChangeText.bin';
  @override
  String get idleStatus => 'Open a lang_xx\\gametext\\TaskChangeText.bin to start editing NPC talk lines.';
  @override
  List<FileFilter> get openFilters => const [
        FileFilter('Task change text', 'TaskChangeText*.bin'),
        FileFilter('BIN files', '*.bin'),
        FileFilter('All files', '*.*'),
      ];
}

class NameTemplateEditor extends TextEditorPanel {
  NameTemplateEditor(EditorHost host) : super('Name Templates', host);

  NameTemplateDocument? get doc => document as NameTemplateDocument?;

  @override
  String get kind => 'names';
  @override
  String get titleNoun => 'Name Templates';
  @override
  String get defaultFileName => 'gametext_name.bin';
  @override
  String get idleStatus => 'Open a lang_xx\\gametext\\gametext_name.bin to edit the name and honorific templates.';
  @override
  List<FileFilter> get openFilters => const [
        FileFilter('Name templates', 'gametext_name*.bin'),
        FileFilter('BIN files', '*.bin'),
        FileFilter('All files', '*.*'),
      ];
  @override
  String get entriesHeading => 'Rows';
  @override
  String get fieldsHeading => 'Slots';
  @override
  String get jumpHeading => 'Jump to Row';
  @override
  String get idNoun => 'Slot';
  @override
  int get jumpDigits => 2;
  @override
  bool get supportsReference => false;
  @override
  (double, double) get columnWidths => (300, 300);
  @override
  int get blockSize => doc?.slotsPerRow ?? 4;

  @override
  String idText(int id) => 'R${padId(id ~/ blockSize, 2)}.${id % blockSize}';
  @override
  int jumpValue(int id) => id ~/ blockSize;
  @override
  int? jumpTarget(int value) => value >= 0 && value * blockSize < count ? value * blockSize : null;

  Map<int, String> characters = const {};
  static const feelingRanges = ['feeling 0-24', 'feeling 25-49', 'feeling 50-74', 'feeling 75-99'];

  @override
  void documentLoaded() => characters = path == null ? const {} : characterNamesFor(path!);

  @override
  String entryLabel(int entry) {
    final d = doc!;
    final start = entry * blockSize;
    final edited = [for (var i = start; i < start + fieldCount(entry); i++) if (d.changed(i)) i].isNotEmpty;
    final who = characters[entry];
    final values = [for (var i = start; i < start + fieldCount(entry); i++) d.texts[i].isEmpty ? '-' : d.texts[i]];
    return '${edited ? '*' : ' '}Row ${padId(entry, 2)} ${who == null ? '' : '$who: '}${values.join(' | ')}';
  }

  @override
  String fieldLabel(int entry, int field) {
    final id = idOf(entry, field);
    final text = doc!.texts[id];
    final range = field < feelingRanges.length ? feelingRanges[field] : 'slot $field';
    return '${doc!.changed(id) ? '*' : ' '}${range.padRight(13)} ${text.isEmpty ? '(empty)' : text}';
  }

  @override
  String detailPrefix(int id) {
    final row = id ~/ blockSize;
    final slot = id % blockSize;
    final who = characters[row];
    final next = slot == 0 && row > 0 ? '|also used for ${characters[row - 1] ?? 'row ${row - 1}'} at feeling 100' : '';
    return 'Row $row${who == null ? '' : ' $who'}|slot $slot${slot < feelingRanges.length ? ', ${feelingRanges[slot]}' : ''}$next';
  }

  @override
  String infoText() {
    final d = doc!;
    final name = fileNameOf(path ?? defaultFileName);
    return '${languageTag()}$name$dirtyMarker\n${d.rows} rows|${grouped(d.changedCount)} edited';
  }
}

class TalkEventEditor extends TextEditorPanel {
  TalkEventEditor(EditorHost host) : super('Script Text', host);

  TalkFolderDocument? get doc => document as TalkFolderDocument?;

  @override
  String get kind => 'talkevent';
  @override
  String get titleNoun => 'Script Text';
  @override
  String get defaultFileName => 'talkevent';
  @override
  String get idleStatus => 'Open a lang_xx\\script\\talkevent folder to edit event dialogue and choices.';
  @override
  List<FileFilter> get openFilters => const [FileFilter('Talk event', '*.bin'), FileFilter('All files', '*.*')];
  @override
  String get entriesHeading => 'Files';
  @override
  String get fieldsHeading => 'Lines';
  @override
  String get jumpHeading => 'Jump to File';
  @override
  String get idNoun => 'Line';
  @override
  int get jumpDigits => 3;
  @override
  (double, double) get columnWidths => (260, 440);

  @override
  TextDocument readDocument(String filePath) => TalkFolderDocument.load(filePath);
  @override
  TextDocument loadReference(String filePath) => TalkFolderDocument.load(filePath);
  @override
  List<String> languagesFor(String filePath) => siblingTalkLanguages(filePath);
  @override
  String? referenceText(TextDocument reference, int id) => (reference as TalkFolderDocument).textForKey(doc!.keyOf(id));

  @override
  int entryCount() => doc?.files.length ?? 0;
  @override
  int fieldCount(int entry) => doc!.lineCount(entry);
  @override
  int idOf(int entry, int field) => doc!.starts[entry] + field;
  @override
  (int, int) locationOf(int id) => doc!.locate(id);
  @override
  String idText(int id) {
    final (file, line) = doc!.locate(id);
    return '${padId(file, 3)}.${padId(line, 3)}';
  }

  @override
  int jumpValue(int id) => doc!.locate(id).$1;
  @override
  int? jumpTarget(int value) => value >= 0 && value < entryCount() ? doc!.starts[value] : null;

  String roleName(String role) => switch (role) {
        'line' => 'line',
        'ask' => 'choice prompt',
        _ => 'choice ${role.substring(3)}',
      };

  String stem(String name) => name.toLowerCase().endsWith('.bin') ? name.substring(0, name.length - 4) : name;

  @override
  String entryLabel(int entry) {
    final d = doc!;
    final start = d.starts[entry];
    final end = start + d.lineCount(entry);
    var preview = '';
    var edited = false;
    for (var id = start; id < end; id++) {
      if (preview.isEmpty && d.texts[id].trim().isNotEmpty) preview = d.texts[id];
      if (!edited && d.changed(id)) edited = true;
    }
    return '${edited ? '*' : ' '}${stem(d.files[entry].name).padRight(20)} ${previewText(preview, entryPreviewLimit)}';
  }

  @override
  String fieldLabel(int entry, int field) {
    final d = doc!;
    final id = d.starts[entry] + field;
    final line = d.files[entry].lines[field];
    final mark = d.changed(id) ? '*' : ' ';
    final text = previewText(d.texts[id], fieldPreviewLimit);
    if (line.role.startsWith('opt')) return '$mark${padId(line.record, 3)}   ${line.role.substring(3)}> $text';
    final speaker = d.speakerNames.isEmpty ? '' : '${d.speakerName(line.speaker)}: ';
    return '$mark${padId(line.record, 3)} ${line.role == 'ask' ? '?' : ' '} $speaker$text';
  }

  @override
  String detailPrefix(int id) {
    final d = doc!;
    final (file, index) = d.locate(id);
    final line = d.files[file].lines[index];
    final voice = line.voice == 0xFFFF ? 'no voice' : 'voice ${line.voice.toRadixString(16).toUpperCase()}';
    final name = d.files[file].name;
    final event = d.eventIdOf(name);
    final listed = !d.hasList ? '' : (event == null ? '|not in list' : '|event $event');
    final speaker = d.speakerNames.isEmpty ? '${line.speaker}' : '${line.speaker} ${d.speakerName(line.speaker)}';
    if (line.role.startsWith('opt')) return '$name$listed|record ${line.record}|${roleName(line.role)}${extrasText(d, line)}';
    return '$name$listed|record ${line.record}|${roleName(line.role)}|speaker $speaker|$voice${extrasText(d, line)}';
  }

  String extrasText(TalkFolderDocument d, TalkLine line) {
    final e = line.extras;
    if (e == null) return '';
    final parts = <String>[];
    if (line.role.startsWith('opt')) {
      if (e.jump != 0x7FFF) parts.add('jumps to record ${e.jump}');
      if (e.feelingSpeaker >= 0 && e.feelingChange != 0) {
        parts.add('feeling ${e.feelingChange >= 0 ? '+' : ''}${e.feelingChange} ${d.speakerName(e.feelingSpeaker)}');
      }
    } else {
      if (e.expression >= 0) {
        parts.add('face ${e.expression < portraitExpressions.length ? portraitExpressions[e.expression] : e.expression}');
      }
      if (e.size >= 0) parts.add('portrait ${e.size < portraitSizes.length ? portraitSizes[e.size] : e.size}');
      final mouth = e.mouth < mouthModes.length ? mouthModes[e.mouth] : 'mouth ${e.mouth}';
      parts.add(e.mouth == 0 ? (e.lipSync == 0xFFFF ? 'no lip sync' : 'lip sync ${e.lipSync}') : mouth);
      if (e.next != 0x7FFF) parts.add('then record ${e.next}');
    }
    return parts.isEmpty ? '' : '|${parts.join('|')}';
  }

  @override
  String infoText() {
    final d = doc!;
    final editedFiles = [for (var f = 0; f < d.files.length; f++) if (d.fileChanged(f)) f].length;
    final edited = editedFiles == 0 ? '0 edited' : '${grouped(d.changedCount)} edited in $editedFiles files';
    return '${languageTag()}talkevent$dirtyMarker\n${grouped(d.files.length)} files|${grouped(d.length)} lines|$edited';
  }

  String fileStatus(int entry) {
    final d = doc!;
    final name = d.files[entry].name;
    final event = d.eventIdOf(name);
    final listed = !d.hasList ? '' : (event == null ? '|not in list' : '|event $event');
    return '$name|${grouped(d.lineCount(entry))} lines$listed';
  }

  @override
  void selectEntry(int index, {int? field, bool updateJump = true}) {
    final before = entryIndex;
    super.selectEntry(index, field: field, updateJump: updateJump);
    if (document == null || entryIndex == before) return;
    status = fileStatus(entryIndex);
    statusLabel.set(status);
    layout();
  }

  @override
  bool loadDocument(String filePath, {int? focusId}) {
    if (!super.loadDocument(filePath, focusId: focusId)) return false;
    status = fileStatus(entryIndex);
    statusLabel.set(status);
    layout();
    return true;
  }

  @override
  String? startFolder() => lastSavedPath ?? path;

  @override
  String get jsonHeading => '${languageTag()}talkevent|selected ${doc!.files[entryIndex].name}';
  @override
  List<String> get jsonDescriptions => const [
        'Save the selected file\'s text as one JSON.',
        'Save every file in this folder, one JSON each.',
        'Pick a JSON and save it back as its .bin.',
        'Pick a folder of JSON and save them back as .bin files.',
      ];
  @override
  String get baseFolder => path!;
  @override
  String savedLocation(String file) => File(file).parent.path;

  List<String> fileTexts(int f) => doc!.texts.sublist(doc!.starts[f], doc!.starts[f] + doc!.lineCount(f));

  @override
  void exportJson() {
    final d = doc;
    if (d == null) return;
    final file = d.files[entryIndex];
    final out = fileDialog(dialogOwner,
        save: true,
        title: 'Export JSON',
        filters: TextEditorPanel.jsonFilters,
        fileName: jsonNameFor(file.name),
        defaultExtension: 'json',
        startIn: startFolder());
    if (out == null) return;
    final lines = collectLines(talkKeys(file), fileTexts(entryIndex));
    try {
      File(out).writeAsStringSync(encodeJsonText(kind, file.name, language, lines));
    } catch (error) {
      showError('Export Failed', describe(error));
      return;
    }
    finishJson('Exported ${grouped(lines.length)} lines of ${file.name} to ${shortenPathSmart(out)}.', const []);
  }

  @override
  void exportAllJson() {
    final d = doc;
    if (d == null) return;
    final out = fileDialog(dialogOwner, folder: true, title: 'Export JSON into which folder?', startIn: startFolder());
    if (out == null) return;
    exportAllInto(out);
  }

  @override
  void exportAllInto(String out) {
    final d = doc;
    if (d == null) return;
    var files = 0, lines = 0;
    final problems = <String>[];
    for (var f = 0; f < d.files.length; f++) {
      final file = d.files[f];
      final map = collectLines(talkKeys(file), fileTexts(f));
      if (map.isEmpty) continue;
      try {
        File('$out${Platform.pathSeparator}${jsonNameFor(file.name)}')
            .writeAsStringSync(encodeJsonText(kind, file.name, language, map));
      } catch (error) {
        problems.add('${file.name}: ${describe(error)}');
        continue;
      }
      files++;
      lines += map.length;
    }
    finishJson('Exported $files JSON files, ${grouped(lines)} lines, to ${shortenPathSmart(out)}.', problems);
  }

  @override
  BuiltFile buildImport(JsonText item) {
    if (item.kind != 'talkevent') throw FormatError('it holds ${item.kind} text, import it from that editor instead');
    final d = doc!;
    final f = d.fileIndex[item.file.toLowerCase()];
    if (f == null) throw FormatError('${item.file} isnt in the loaded talkevent folder');
    final start = d.starts[f];
    final file = d.files[f];
    final result = applyLines(talkKeys(file), item.lines, (i, text) => d.texts[start + i] = text);
    importTouchedDocument = true;
    dirty = true;
    final bytes = d.fileBytes(f);
    checkReadBack('talkevent', item.file, bytes, fileTexts(f));
    return BuiltFile(item.file, bytes, result.applied, result.unknown);
  }

  @override
  bool openDocument() {
    final folder = fileDialog(dialogOwner, folder: true, title: 'Pick a lang_xx\\script\\talkevent folder', startIn: startFolder());
    if (folder == null || !confirmDiscard('open another folder')) return false;
    return loadDocument(folder);
  }

  bool openSingleFile() {
    final file = fileDialog(dialogOwner, title: 'Pick a talk event .bin', filters: openFilters, startIn: startFolder());
    if (file == null) return false;
    return focusFile(file);
  }

  bool focusFile(String file) {
    final folder = File(file).parent.path;
    if (path == null || folder.toLowerCase() != path!.toLowerCase()) {
      if (!confirmDiscard('open another folder')) return false;
      if (!loadDocument(folder)) return false;
    }
    final index = doc!.fileIndex[fileNameOf(file).toLowerCase()];
    if (index == null) {
      status = '${fileNameOf(file)} has no editable text${doc!.noText.contains(fileNameOf(file)) ? ' (voice only)' : ''}.';
      refresh();
      return false;
    }
    selectEntry(index);
    status = fileStatus(entryIndex);
    statusLabel.set(status);
    layout();
    return true;
  }

  @override
  void saveAs() {
    final d = doc;
    if (d == null) return;
    if (!commitCurrentValue(announce: false)) return;
    final changedFiles = [for (var f = 0; f < d.files.length; f++) if (d.fileChanged(f)) f];
    if (changedFiles.isEmpty) {
      status = 'No file has edits to save.';
      refresh();
      return;
    }
    final output = fileDialog(dialogOwner,
        folder: true, title: 'Save ${changedFiles.length} edited talk event file(s) into which folder?', startIn: startFolder());
    if (output == null) return;
    saveInto(output, changedFiles);
  }

  bool saveInto(String output, [List<int>? only]) {
    final d = doc;
    if (d == null) return false;
    final changedFiles = only ?? [for (var f = 0; f < d.files.length; f++) if (d.fileChanged(f)) f];
    final built = <int, Uint8List>{};
    try {
      for (final f in changedFiles) {
        final bytes = d.fileBytes(f);
        final check = TalkFile.parse(bytes, d.files[f].name);
        var same = check.lines.length == d.lineCount(f);
        for (var i = 0; same && i < check.lines.length; i++) {
          same = check.originalText(check.lines[i]) == d.texts[d.starts[f] + i];
        }
        if (!same) throw FormatError('${d.files[f].name} didnt read back the same text, so nothing was written.');
        built[f] = bytes;
      }
    } catch (error) {
      showError('Save Failed', describe(error));
      return false;
    }
    var backups = 0;
    try {
      for (final MapEntry(key: f, value: bytes) in built.entries) {
        final target = File('$output${Platform.pathSeparator}${d.files[f].name}');
        final backup = File('${target.path}.bak');
        if (target.existsSync() && !backup.existsSync()) {
          target.copySync(backup.path);
          backups++;
        }
        target.writeAsBytesSync(bytes, flush: true);
      }
    } catch (error) {
      showError('Save Failed', describe(error));
      return false;
    }
    referenceCache.remove(output);
    lastSavedPath = output;
    dirty = false;
    status = 'Saved ${built.length} edited file(s) to ${shortenPathSmart(output)}.'
        '${backups > 0 ? ' Kept $backups old file(s) as .bak.' : ''}';
    refresh();
    return true;
  }
}
