import 'package:yaml/yaml.dart';

import '../constants/app_constants.dart';

/// Raised before YAML parsing when an input exceeds SSRVPN's resource budget.
final class YamlResourceLimitException extends FormatException {
  const YamlResourceLimitException(super.message);
}

/// Applies cheap, allocation-light limits before handing YAML to `package:yaml`.
///
/// Subscription YAML is untrusted input. The byte ceiling preserves the
/// existing 20 MB compatibility envelope, while depth and alias limits prevent
/// compact inputs from creating disproportionately expensive parser work.
abstract final class BoundedYaml {
  static const int maxInputBytes = AppConstants.maxSubscriptionBytes;
  static const int maxNestingDepth = 64;
  static const int maxAliasReferences = 256;
  static const int maxCollectionItems = 100000;

  static dynamic load(String source) {
    validate(source);
    return loadYaml(source);
  }

  static void validate(String source) {
    _validateUtf8Length(source);

    final indentationStack = <int>[];
    final flowClosers = <int>[];
    var aliasReferences = 0;
    var collectionItems = 0;
    int? blockScalarIndent;
    var inSingleQuote = false;
    var inDoubleQuote = false;
    var escaped = false;

    void addCollectionItems([int count = 1]) {
      collectionItems += count;
      if (collectionItems > maxCollectionItems) {
        throw const YamlResourceLimitException(
          'YAML 集合元素过多（最多 100000 个）',
        );
      }
    }

    for (final rawLine in _lines(source)) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      final trimmedLeft = line.trimLeft();
      if (trimmedLeft.isEmpty) continue;
      final indent = line.length - trimmedLeft.length;

      final scalarIndent = blockScalarIndent;
      if (scalarIndent != null) {
        if (indent > scalarIndent) continue;
        blockScalarIndent = null;
      }

      final continuedQuotedScalar = inSingleQuote || inDoubleQuote;
      var leadingSequenceDepth = 0;
      if (!continuedQuotedScalar && !trimmedLeft.startsWith('#')) {
        addCollectionItems();
        while (indentationStack.isNotEmpty && indent <= indentationStack.last) {
          indentationStack.removeLast();
        }
        indentationStack.add(indent);
        leadingSequenceDepth = _leadingSequenceDepth(trimmedLeft);
        if (leadingSequenceDepth > 1) {
          addCollectionItems(leadingSequenceDepth - 1);
        }
      }

      final visible = StringBuffer();
      for (var index = 0; index < trimmedLeft.length; index++) {
        final codeUnit = trimmedLeft.codeUnitAt(index);

        if (inDoubleQuote) {
          if (escaped) {
            escaped = false;
          } else if (codeUnit == _backslash) {
            escaped = true;
          } else if (codeUnit == _doubleQuote) {
            inDoubleQuote = false;
          }
          continue;
        }
        if (inSingleQuote) {
          if (codeUnit == _singleQuote) {
            final doubled = index + 1 < trimmedLeft.length &&
                trimmedLeft.codeUnitAt(index + 1) == _singleQuote;
            if (doubled) {
              index++;
            } else {
              inSingleQuote = false;
            }
          }
          continue;
        }

        if (codeUnit == _hash &&
            (index == 0 || _isWhitespace(trimmedLeft.codeUnitAt(index - 1)))) {
          break;
        }
        if (codeUnit == _doubleQuote) {
          inDoubleQuote = true;
          escaped = false;
          continue;
        }
        if (codeUnit == _singleQuote) {
          inSingleQuote = true;
          continue;
        }

        visible.writeCharCode(codeUnit);
        if (codeUnit == _openSquare) {
          flowClosers.add(_closeSquare);
        } else if (codeUnit == _openBrace) {
          flowClosers.add(_closeBrace);
        } else if ((codeUnit == _closeSquare || codeUnit == _closeBrace) &&
            flowClosers.isNotEmpty &&
            flowClosers.last == codeUnit) {
          flowClosers.removeLast();
        } else if (codeUnit == _comma && flowClosers.isNotEmpty) {
          addCollectionItems();
        } else if (codeUnit == _asterisk &&
            _isYamlTokenStart(trimmedLeft, index)) {
          aliasReferences++;
          if (aliasReferences > maxAliasReferences) {
            throw const YamlResourceLimitException(
              'YAML 别名引用过多（最多 256 个）',
            );
          }
        }

        _checkDepth(
          indentationStack.length + leadingSequenceDepth + flowClosers.length,
        );
      }

      if (!continuedQuotedScalar &&
          !inSingleQuote &&
          !inDoubleQuote &&
          _endsWithBlockScalarMarker(visible.toString())) {
        blockScalarIndent = indent;
      }
    }
  }

  static void _validateUtf8Length(String source) {
    var bytes = 0;
    for (final rune in source.runes) {
      bytes += rune <= 0x7f
          ? 1
          : rune <= 0x7ff
              ? 2
              : rune <= 0xffff
                  ? 3
                  : 4;
      if (bytes > maxInputBytes) {
        throw const YamlResourceLimitException(
          'YAML 内容超过 20 MB 解析上限',
        );
      }
    }
  }

  static Iterable<String> _lines(String source) sync* {
    var start = 0;
    while (true) {
      final end = source.indexOf('\n', start);
      if (end < 0) {
        yield source.substring(start);
        return;
      }
      yield source.substring(start, end);
      start = end + 1;
    }
  }

  static int _leadingSequenceDepth(String value) {
    var cursor = 0;
    var depth = 0;
    while (cursor < value.length && value.codeUnitAt(cursor) == _dash) {
      final next = cursor + 1;
      if (next < value.length && !_isWhitespace(value.codeUnitAt(next))) {
        break;
      }
      depth++;
      cursor = next;
      while (cursor < value.length && _isWhitespace(value.codeUnitAt(cursor))) {
        cursor++;
      }
    }
    return depth;
  }

  static bool _isYamlTokenStart(String value, int index) {
    if (index + 1 >= value.length ||
        _isWhitespace(value.codeUnitAt(index + 1))) {
      return false;
    }
    if (index == 0) return true;
    final previous = value.codeUnitAt(index - 1);
    return _isWhitespace(previous) ||
        previous == _openSquare ||
        previous == _openBrace ||
        previous == _comma ||
        previous == _colon ||
        previous == _dash ||
        previous == _question;
  }

  static bool _endsWithBlockScalarMarker(String value) {
    return RegExp(
      r'(?:^|:\s+|-\s+)[>|](?:[1-9][+-]?|[+-][1-9]?)?\s*$',
    ).hasMatch(value.trimRight());
  }

  static void _checkDepth(int depth) {
    if (depth > maxNestingDepth) {
      throw const YamlResourceLimitException(
        'YAML 嵌套层级过深（最多 64 层）',
      );
    }
  }

  static bool _isWhitespace(int codeUnit) =>
      codeUnit == _space || codeUnit == _tab;

  static const int _tab = 0x09;
  static const int _space = 0x20;
  static const int _hash = 0x23;
  static const int _asterisk = 0x2a;
  static const int _comma = 0x2c;
  static const int _dash = 0x2d;
  static const int _colon = 0x3a;
  static const int _question = 0x3f;
  static const int _openSquare = 0x5b;
  static const int _backslash = 0x5c;
  static const int _closeSquare = 0x5d;
  static const int _openBrace = 0x7b;
  static const int _closeBrace = 0x7d;
  static const int _doubleQuote = 0x22;
  static const int _singleQuote = 0x27;
}
