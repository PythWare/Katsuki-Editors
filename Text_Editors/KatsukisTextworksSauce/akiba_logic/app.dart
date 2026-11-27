import 'dart:async'; import 'dart:ffi'; import 'dart:io';
import 'd2d.dart'; import 'editors.dart'; import 'launcher.dart'; import 'native.dart'; import 'side_panels.dart';
import 'ui.dart'; import 'win.dart';

const appTitle = "Katsuki's Textworks";
const mainButtons = ['Tools', 'Guide'];
const subOptions = {
  'Tools': ['Game Text', 'Script Text', 'Task Text', 'Name Templates'],
  'Guide': ['Formats', 'Usage Docs'],
};
const subSubOptions = {
  'Game Text': ['Open', 'Close'],
  'Script Text': ['Open Folder', 'Open File', 'Close'],
  'Task Text': ['Open', 'Close'],
  'Name Templates': ['Open', 'Close'],
  'Formats': ['gametext.bin', 'Talk events', 'TaskChangeText', 'Names + Hashes'],
  'Usage Docs': ['Usage', 'Keys'],
};
const closeMessage = WM_APP + 1;

const guideContent = {
  'Formats/gametext.bin': (
    'Formats, gametext.bin',
    'lang_xx\\gametext\\gametext.bin holds the UI, menu, item, tweet, mail and story text. Every language has the same '
        '12,059 IDs in the same order, so ID 00024 is the same line in US, JP, CH, SC and KR.\n\n'
        'Layout, little endian:\n'
        '0x00  u32  line count\n'
        '0x04  u32  offset of the offset table (always 8)\n'
        '0x08  u32[count]  string offsets, relative to the offset table, 0 means null\n'
        'then  UTF-16LE strings, each ending in one 0x0000\n\n'
        'CGameText in the exe adds the table address to every offset at load time, so any string length works and the file '
        'can grow freely. Unused IDs all share the empty string at ID 00000, the editor shows them as (unused). Editing '
        'one gives it its own string, the others stay shared.\n\n'
        'Saving keeps the original string order and only appends edited lines next to the string they replaced, so an '
        'unedited save is identical to the original.',
  ),
  'Formats/Talk events': (
    'Formats, talk events',
    'lang_xx\\script\\talkevent\\*.bin holds the event dialogue and choices the scripts play with '
        'TalkEvent.PlayTalkEvent(id). Everything below is confirmed in the exe unless it says otherwise.\n\n'
        'Layout, little endian:\n'
        '0x00  12 zero bytes, then u32 record count at 0x0C\n'
        '0x10  records of 0x50 bytes, one command each\n'
        'then  UTF-16LE strings, each ending in one 0x0000\n\n'
        'The loader at 0x641188 sets records = file + 0x10 and pool = records + count * 0x50. The record size is fixed '
        'in code, so the few test files with 0x40 byte records wont play. None of them are in the list.\n\n'
        'The dispatcher at 0x459420 reads the command as s16 at record +0x02. Command 1 runs 0x45A8B0, a spoken line. '
        'Command 2 runs 0x45AA60, a choice. The u16 0x63 at +0x00 isnt read by the talk event code.\n\n'
        'Every record: +0x0A is the record to go to next, 0x7FFF means the following one (0x45A7A3).\n\n'
        'Line and choice prompt:\n'
        '+0x04  speaker index into the list file\n'
        '+0x06  portrait face, -1 keeps it: 0 Normal, 1 Joyful, 2 Anger, 3 Pensive, 4 Tere, 5 Tanoshii, 6 Kurushimi, '
        '7 Hazukashii, 8 to 16 Tokusyu_01 to 09, 17 eAnger, 18 eHeart, 19 eMusicNote, 20 eLight (table at 0x997428)\n'
        '+0x08  portrait size, -1 keeps it: 0 Small, 1 Middle, 2 Large, not range checked (0x601D10)\n'
        '+0x20  s16 text offset from the pool start\n'
        '+0x22  voice id, -1 for none\n'
        '+0x24  mouth: 0 lip sync, 1 MouthClose, 2 MouthOpen, 3 default (0x457070)\n'
        '+0x26  lip sync entry in script\\wavemouth\\wavemouth.bin, used when +0x24 is 0. Usually the voice id + 1 '
        'but not always.\n\n'
        'Choice answers 1 to 3:\n'
        '+0x28 +0x2A +0x2C  s16 text offsets\n'
        '+0x2E  answer count, above 3 or below 0 is treated as 1\n'
        '+0x30 +0x32 +0x34  record to jump to after that answer, 0x7FFF to carry on\n'
        '+0x36 +0x38 +0x3A  speaker whose feeling changes, -1 for none\n'
        '+0x3C +0x3E +0x40  s16 feeling change, the total is clamped to 0 to 100 (0x4F8E00)\n\n'
        'wavemouth.bin: u32 count, count x {u32 start, u32 length}, then s16 keyframes. Each keyframe lasts |value| / 30 '
        'seconds, positive is MouthTalk and negative is MouthClose. US has its own copy for the English dub.\n\n'
        'Offsets are signed 16 bit, so one file can hold up to 32,767 bytes of text. The biggest US file uses about 16 KB. '
        'The editor refuses to save past the limit.\n\n'
        'Speakers: the index at +0x04 picks a 16 byte entry in script_talkevent_list.bin. Entry +0x02 is the character '
        'used for feeling and name templates, +0x04 the portrait character, +0x06 the gametext ID of the name the game '
        'shows, through CGameText at 0x501450. Index 2 is <player>, used for the inner thought lines. Indexes 15 and up '
        'reuse a character with the name ???.\n\n'
        'script_talkevent_list.bin: u32 speaker entry size 0x10, u32 file entry size 0x20, u32 file count, u32 speaker '
        'count, then the speaker table, then the file names. A PlayTalkEvent id is the index into the file names.\n\n'
        'The record order and count are the same in every language, so the reference pane matches lines by file, '
        'record and role. Some US files are voice only and have no text at all.',
  ),
  'Formats/TaskChangeText': (
    'Formats, TaskChangeText.bin',
    'lang_xx\\gametext\\TaskChangeText.bin holds the NPC talk lines used by the task change system. 7,318 lines per '
        'language, same IDs in every language.\n\n'
        'Layout, little endian:\n'
        '0x00  u32  line count, then 12 zero bytes\n'
        '0x10  {u32 file offset, u32 byte size, u32 runtime pointer slot}[count]\n'
        'then  UTF-16LE strings in ID order, each ending in two 0x0000 units\n\n'
        'The byte size counts the terminator. The third field is overwritten with a real pointer when CTaskChangeText '
        'loads, so it stays zero on disk. Saving lays the strings out again in ID order and rewrites every offset and '
        'size.\n\n'
        'The size is never read it seemss. A getter for it exists at 0x558D10 but nothing calls it. The line getter is used by '
        'the talk code at 0x552190, which runs the line through the same tag replacement as gametext, so <name>, '
        '<first>, <last> and the other tags work here too.',
  ),
  'Formats/Names and Hashes': (
    'Formats, names, hashes',
    'gametext_name.bin holds 14 rows of name templates such as <last>-san. Each row has four 32 byte slots of UTF-16LE '
        'text, so a slot fits 15 characters (0x5027E0 addresses rows + (row * 4 + slot) * 32).\n\n'
        'When text contains <name>, 0x502B50 picks a template and puts it in place of <name>, then fills <last> and '
        '<first> with the player name. The row is the character, the same number as +0x02 of a talk event speaker. '
        'The slot is that character\'s feeling times 0.04: 0 to 24 uses slot 0, 25 to 49 slot 1, 50 to 74 slot 2, 75 to '
        '99 slot 3. At 100 the slot is 4, which lands on slot 0 of the next row. Rows go up to '
        '16 in code, the file has 14.\n\n'
        'Tags the game replaces in text (0x502AB0 and nearby): <player>, <heroine>, <sister>, <nick>, <name>, <first>, '
        '<last>, <trophy>, <sm16nm>, <sm16pl>, <grade> and numbered values written <\$1>, <\$2> and so on.\n\n'
        'gametext_hash.bin.l: u32 count, 12 zero bytes, then count x {u32 hash, u32 gametext ID}. 0x5014B0 searches it '
        'one entry at a time, so order doesnt matter. UI text elements keep the hash at +0x48 and look it up through '
        '0x5A65D0, which is why the .ui layout files hold these hashes. Text edits never change hashes or IDs, so the '
        'editor only reads this file to show the UI hash for a line.\n\n'
        'Line breaks: most text uses \\n. Some JP and KR lines use \\r\\n or a lone \\r. The editor shows every \\r as '
        '{CR} so it saves back exactly as it was. Type {CR} yourself if you need one.',
  ),
  'Usage Docs/Usage': (
    'Usage Docs, Usage',
    'Tools has one editor per file type. Open picks a file, Close unloads it. Open the file inside a lang_xx\\gametext '
        'folder so the language features work.\n\n'
        'Blocks on the left group lines by hundreds, Lines in the middle lists every line in the block and Results lists '
        'search hits. A * in front of a block or line means it differs from the file as it was opened.\n\n'
        'Value is the selected line. Edits are applied automatically when you move to another line or right away with '
        'Ctrl+Enter. The line above the Value box shows the ID, the UI hash for gametext lines, the character and '
        'byte count, and how many bytes the line grew or shrank.\n\n'
        'Ref shows the line with the same ID from another language folder under the Value box, handy for translating '
        'from JP. Click it to cycle through the languages that exist or turn it off. Lang reopens the same file from '
        'the next language folder and keeps the current ID selected.\n\n'
        'Script Text works on a whole lang_xx\\script\\talkevent folder. Open Folder loads every talk event file, Open '
        'File loads the folder of the file you pick and jumps to it. Blocks are files and Lines are the spoken lines '
        'and choices numbered by record. C asks for a folder and writes only the files you edited into it.\n\n'
        'C saves a new file. If you overwrite an existing file, the first overwrite copies the old one to .bak next to '
        'it. Every save is read back before writing and nothing is written if the text doesnt match.\n\n'
        'RA reloads all lines from the file as it was opened. R restores only the selected line.\n\n'
        'J opens JSON import and export, handy for machine translation tools like DeepL. Export saves the open file '
        'or the selected file in Script Text. Export All saves every text file in the loaded gametext folder or every '
        'talk event file with one JSON each. Import and Import All turn JSON back into .bin files. The text is put onto '
        'the original .bin from the loaded folder, so everything that isnt text stays as it was. Each rebuilt file is '
        'read back before it\'s written and the first overwrite keeps a .bak.\n\n'
        'A JSON holds an akiba block naming the file and a lines object of key and text pairs. Only translate the '
        'text values and keep the keys. Lines missing from a JSON are left unchanged, a partial translation works. '
        'Keep tags like <player> and <\$1> as theyre. If a tool changes the akiba block, the JSON file name is used '
        'instead. So keep names like mm_c1_0010_00.json.\n\n'
        'Search looks through every line. Exact only matches whole lines, Aa makes it case sensitive. Enter jumps to the '
        'next result, Shift+Enter to the previous one, Esc clears it. Jump to ID selects a line by number as you type.',
  ),
  'Usage Docs/Keys': (
    'Usage Docs, Keys',
    'Ctrl+Enter  apply the Value box\n'
        'Ctrl+Up, Ctrl+Down  previous or next line, applying the current one\n'
        'Ctrl+F  focus search\n'
        'Ctrl+S  save as\n'
        'Enter, Shift+Enter in search  next or previous result\n'
        'Esc in search  clear search\n'
        'Esc elsewhere  close the app\n'
        'F1  toggle always on top\n\n'
        'Panels: drag the title bar to move a panel, drag the corner grip to resize it, and drag the gaps between the '
        'lists, above the Value box, or above the Reference box to give any part more room.\n\n'
        'Launcher: right drag anywhere on it or drag the title to move it along with its panels.',
  ),
};

String appDirectory() {
  final exe = Platform.resolvedExecutable.toLowerCase();
  if (exe.endsWith('dart.exe') || exe.endsWith('dartvm.exe')) return Directory.current.path;
  return File(Platform.resolvedExecutable).parent.path;
}

class AkibaApp {
  late final LauncherWindow launcher;
  late final EditorHost host;
  late final GameTextEditor gameTextEditor;
  late final TalkEventEditor talkEventEditor;
  late final TaskTextEditor taskTextEditor;
  late final NameTemplateEditor nameEditor;
  late final GuidePanel guidePanel;
  late final Map<String, TextEditorPanel> editors;
  late final List<Panel> panels;
  bool topmost = true;
  bool quitting = false;

  void start() {
    SetProcessDpiAwarenessContext(-4);
    CoInitializeEx(nullptr, 0x2 | 0x4);
    scoped((a) => LoadLibraryW(wstr('Msftedit.dll', a)));
    Direct2D.start();
    errorReporter = (error) => messageBox(launcher.hwnd, 'Unexpected error:\n$error', appTitle, MB_OK | MB_ICONERROR);

    launcher = LauncherWindow(appTitle, mainButtons, subOptions, subSubOptions, onLauncherClick, closeApp,
        toggleTopmost, (dx, dy) => followLauncher());
    host = EditorHost(showExclusive, () => launcher.hwnd, () => launcher.origin, requestClose, toggleTopmost);
    gameTextEditor = GameTextEditor(host);
    talkEventEditor = TalkEventEditor(host);
    taskTextEditor = TaskTextEditor(host);
    nameEditor = NameTemplateEditor(host);
    editors = {
      'Game Text': gameTextEditor,
      'Script Text': talkEventEditor,
      'Task Text': taskTextEditor,
      'Name Templates': nameEditor,
    };
    guidePanel = GuidePanel(host, () => guidePanel.hide());
    panels = [...editors.values, guidePanel];
    launcher.show();
  }

  void followLauncher() {
    for (final panel in panels) {
      if (panel.panelVisible) panel.applyGeometry(launcher.origin);
    }
  }

  void showExclusive(Panel panel) {
    for (final other in panels) {
      if (other != panel) other.hide();
    }
    panel.show();
  }

  void hideAll() {
    for (final panel in panels) {
      panel.hide();
    }
  }

  void onLauncherClick(String kind, String name) {
    switch (kind) {
      case 'main':
        launcher.main = launcher.main == name ? null : name;
        launcher.sub = null;
        hideAll();
        launcher.stateChanged();
      case 'sub':
        launcher.sub = launcher.sub == name ? null : name;
        hideAll();
        final sub = launcher.sub;
        if (sub != null) editors[sub]?.showPanel();
        launcher.stateChanged();
      case 'subsub':
        runSubSubAction(launcher.sub ?? '', name);
    }
  }

  void runSubSubAction(String sub, String name) {
    final guide = guideContent['$sub/$name'];
    if (guide != null) {
      guidePanel.showPage(guide.$1, guide.$2);
      showExclusive(guidePanel);
      return;
    }
    final editor = editors[sub];
    if (editor == null) return;
    switch (name) {
      case 'Open':
      case 'Open Folder':
        editor.openDocument();
      case 'Open File':
        if (editor is TalkEventEditor) editor.openSingleFile();
      case 'Close':
        editor.closeDocument();
    }
  }

  void requestClose() => PostMessageW(launcher.hwnd, closeMessage, 0, 0);

  void closeApp() {
    if (quitting) return;
    for (final editor in editors.values) {
      editor.commitCurrentValue(announce: false);
    }
    if (editors.values.any((editor) => editor.dirty)) {
      final answer = messageBox(
          launcher.hwnd, 'There are unsaved edits. Discard them and exit?', 'Exit', MB_YESNO | MB_ICONQUESTION);
      if (answer != IDYES) return;
    }
    quitting = true;
    for (final panel in panels) {
      panel.hide();
      DestroyWindow(panel.hwnd);
    }
    DestroyWindow(launcher.hwnd);
  }

  void toggleTopmost() {
    topmost = !topmost;
    launcher.setTopmost(topmost);
    for (final panel in panels) {
      panel.setTopmost(topmost);
    }
  }

  void openFromArguments(List<String> args) {
    for (var i = 0; i + 1 < args.length; i += 2) {
      final sub = switch (args[i]) {
        '--gametext' => 'Game Text',
        '--talk' => 'Script Text',
        '--talk-file' => 'Script Text',
        '--task' => 'Task Text',
        '--names' => 'Name Templates',
        _ => null,
      };
      if (sub == null) continue;
      launcher.main = 'Tools';
      launcher.sub = sub;
      if (args[i] == '--talk-file') {
        talkEventEditor.focusFile(args[i + 1]);
      } else {
        editors[sub]!.loadDocument(args[i + 1]);
      }
    }
    launcher.stateChanged();
  }

  Future<void> run([List<String> args = const []]) async {
    start();
    if (args.isNotEmpty) openFromArguments(args);
    final msg = heap<MSG>();
    var running = true;
    while (running) {
      while (PeekMessageW(msg, 0, 0, 0, PM_REMOVE) != 0) {
        if (msg.ref.message == WM_QUIT) {
          running = false;
          break;
        }
        if (msg.ref.message == closeMessage && msg.ref.hwnd == launcher.hwnd) {
          closeApp();
          continue;
        }
        TranslateMessage(msg);
        DispatchMessageW(msg);
      }
      if (!running) break;
      MsgWaitForMultipleObjectsEx(0, nullptr, 200, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
      await Future<void>.delayed(Duration.zero);
    }
    heap.free(msg);
  }
}
