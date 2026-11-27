import 'dart:typed_data';

const crToken = '{CR}';

class FormatError implements Exception {
  final String message;
  FormatError(this.message);
  @override
  String toString() => message;
}

int readU32(Uint8List data, int offset) {
  if (offset < 0 || offset + 4 > data.length) throw FormatError('The file ended before offset 0x${offset.toRadixString(16)}.');
  return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | (data[offset + 3] << 24);
}

void writeU32(Uint8List data, int offset, int value) {
  data[offset] = value & 0xFF;
  data[offset + 1] = (value >> 8) & 0xFF;
  data[offset + 2] = (value >> 16) & 0xFF;
  data[offset + 3] = (value >> 24) & 0xFF;
}

int wideEnd(Uint8List data, int start, [int? limit]) {
  final end = limit ?? data.length;
  for (var i = start; i + 1 < end; i += 2) {
    if (data[i] == 0 && data[i + 1] == 0) return i;
  }
  return -1;
}

String decodeWide(Uint8List data, int start, int end) {
  final units = Uint16List((end - start) >> 1);
  for (var i = 0; i < units.length; i++) {
    units[i] = data[start + i * 2] | (data[start + i * 2 + 1] << 8);
  }
  return String.fromCharCodes(units);
}

Uint8List encodeWide(String text, [int terminatorBytes = 2]) {
  final out = Uint8List(text.length * 2 + terminatorBytes);
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    out[i * 2] = unit & 0xFF;
    out[i * 2 + 1] = unit >> 8;
  }
  return out;
}

String showBreaks(String text) => text.replaceAll('\r', crToken);
String storeBreaks(String text) => text.replaceAll(crToken, '\r');

String padId(int n, [int width = 5]) => n.toString().padLeft(width, '0');

String hex8(int value) => value.toRadixString(16).toUpperCase().padLeft(8, '0');

String previewText(String value, [int limit = 40]) {
  final flattened = value.trim().split(RegExp(r'\s+')).where((part) => part.isNotEmpty).join(' ');
  return flattened.length <= limit ? flattened : '${flattened.substring(0, limit - 3)}...';
}

bool sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
