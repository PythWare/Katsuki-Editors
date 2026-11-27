import 'd2d.dart'; import 'editors.dart'; import 'ui.dart'; import 'win.dart';

const guidePanelWidth = 640.0;
const guidePanelHeight = 520.0;
const sidePanelX = 540.0;

class JsonMenu extends Panel {
  final TextEditorPanel owner;
  late final Label heading = add(Label('', labelBoldStyle.copy(wrap: true, vAlign: vAlignNear), white));
  final rows = <(Button, Label)>[];

  JsonMenu(this.owner) : super('JSON', 470, 270, 0, 0, owner.originProvider, () {}, minWidth: 360, minHeight: 220) {
    onClose = hide;
    final actions = <(String, void Function(), int, int)>[
      ('Export', owner.exportJson, 0xFF4D6D4F, 0xFF66956A),
      ('Export All', owner.exportAllJson, 0xFF4D6D4F, 0xFF66956A),
      ('Import', owner.importJson, 0xFF4D5C71, 0xFF6E83A1),
      ('Import All', owner.importAllJson, 0xFF4D5C71, 0xFF6E83A1),
    ];
    for (final (name, action, color, active) in actions) {
      final button = add(Button(name, () {
        hide();
        action();
      }, color, active));
      rows.add((button, add(Label('', labelStyle.copy(wrap: true), mutedFg))));
    }
  }

  void prepare() {
    final texts = owner.jsonDescriptions;
    heading.set(owner.jsonHeading);
    for (var i = 0; i < rows.length; i++) {
      rows[i].$2.set(texts[i]);
    }
  }

  void open() {
    prepare();
    if (!panelVisible) {
      offsetX = owner.offsetX + owner.width - width - 24;
      offsetY = owner.offsetY + 90;
    }
    setTopmost(owner.topmost);
    show();
  }

  @override
  void layoutBody(double bx, double by, double bw, double bh) {
    final left = bx + 10;
    final inner = bw - 20;
    var y = by + 8;
    final headingH = heading.heightFor(inner);
    heading.place(left, y, inner, headingH);
    y += headingH + 10;
    const buttonW = 92.0, rowH = 30.0;
    for (final (button, label) in rows) {
      button.place(left, y, buttonW, rowH - 4);
      label.place(left + buttonW + 12, y, inner - buttonW - 12, rowH - 4);
      y += rowH + 4;
    }
  }

  @override
  bool panelKey(int vk) {
    if (vk == VK_ESCAPE) {
      hide();
      return true;
    }
    if (vk == VK_F1) {
      owner.host.toggleTopmost();
      return true;
    }
    return false;
  }
}

class GuidePanel extends Panel {
  final EditorHost host;
  late final TextBox body;

  GuidePanel(this.host, void Function() close)
      : super('Guide', guidePanelWidth, guidePanelHeight, sidePanelX, 76, host.origin, close) {
    body = TextBox(this, 301, multiline: true, readOnly: true, face: uiFont, points: 10, padX: 10, padY: 8);
    fitToScreen();
  }

  void showPage(String newTitle, String text) {
    title = newTitle;
    body.text = text;
    invalidate();
  }

  @override
  void layoutBody(double bx, double by, double bw, double bh) => body.place(bx + 8, by + 8, bw - 16, bh - 16);

  @override
  void paintBody(Graphics g) => g.fillRect(body.x, body.y, body.w, body.h, fieldBg);

  @override
  bool panelKey(int vk) {
    if (vk == VK_ESCAPE) {
      host.closeApp();
      return true;
    }
    if (vk == VK_F1) {
      host.toggleTopmost();
      return true;
    }
    return false;
  }

  @override
  bool textBoxKey(TextBox box, int msg, int vk) {
    if (msg == WM_CHAR) return vk == 27;
    return panelKey(vk);
  }
}
