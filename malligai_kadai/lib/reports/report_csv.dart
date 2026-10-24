String encodeReportCsv(List<List<Object?>> rows) =>
    '\uFEFF${rows.map((row) => row.map(_csvCell).join(',')).join('\r\n')}';

String _csvCell(Object? value) {
  var text = value?.toString() ?? '';
  if (RegExp(r'^[\s]*[=+\-@]').hasMatch(text)) {
    text = "'$text";
  }
  return '"${text.replaceAll('"', '""')}"';
}
