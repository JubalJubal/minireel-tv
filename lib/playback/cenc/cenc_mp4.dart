import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// CENC（cenc-aes-ctr）MP4 的索引：把加密的 sample 表解析成
/// 「哪些字节区间要解密」「哪些 box 要改成明文标记」，供流式转发时逐块处理。
///
/// 移植自参考实现 api-example/internal/app/cenc_mp4.go。只接受
/// 单个 moov 位于文件头、mdat 在后的普通 MP4；分片 MP4（moof）不支持。
const cencMetadataLimit = 32 << 20;
const cencSampleLimit = 500000;

final class CencFormatException implements Exception {
  const CencFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class _Box {
  const _Box(this.kind, this.start, this.body, this.end);
  final String kind;
  final int start;
  final int body;
  final int end;
}

final class CencPatch {
  const CencPatch(this.offset, this.data);
  final int offset;
  final Uint8List data;
}

final class CencSpan {
  const CencSpan({
    required this.start,
    required this.end,
    required this.counterOffset,
    required this.iv,
  });
  final int start;
  final int end;
  final int counterOffset;
  final Uint8List iv;
}

final class CencMp4Index {
  CencMp4Index({
    required this.total,
    required this.patches,
    required this.spans,
  });

  final int total;
  final List<CencPatch> patches;
  final List<CencSpan> spans;

  static const _formatError = '该 MP4 的加密结构暂不支持安全转发';

  /// [moov] 是从 [base] 偏移开始、长度为整个 moov box 的字节。
  factory CencMp4Index.parse(Uint8List moov, int base, int total) {
    final roots = _boxes(moov, 0, moov.length);
    if (roots.length != 1 || roots.first.kind != 'moov') {
      throw const CencFormatException(_formatError);
    }
    final root = roots.first;
    final rows = _boxes(moov, root.body, root.end);
    final index = _index(total);
    for (final box in rows) {
      switch (box.kind) {
        case 'mvex':
          throw const CencFormatException('$_formatError：分片 MP4');
        case 'pssh':
          index._patch(base + box.start + 4, 'free');
        case 'trak':
          index._track(moov, box, base);
      }
    }
    index.spans.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 0; i < index.spans.length; i++) {
      final span = index.spans[i];
      if (span.start < 0 ||
          span.end > total ||
          span.start >= span.end ||
          (i > 0 && index.spans[i - 1].end > span.start)) {
        throw const CencFormatException(_formatError);
      }
    }
    if (index.spans.isEmpty) {
      throw const CencFormatException('$_formatError：没有加密采样');
    }
    return index;
  }

  static List<_Box> _boxes(Uint8List data, int start, int end) {
    if (start < 0 || end > data.length || start > end) {
      throw const CencFormatException(_formatError);
    }
    final view = ByteData.sublistView(data);
    final out = <_Box>[];
    while (start < end) {
      if (end - start < 8) {
        throw const CencFormatException(_formatError);
      }
      var size = view.getUint32(start);
      var header = 8;
      if (size == 1) {
        if (end - start < 16) {
          throw const CencFormatException(_formatError);
        }
        size = view.getUint64(start + 8);
        header = 16;
      }
      if (size == 0) {
        size = end - start;
      }
      if (size < header || size > end - start) {
        throw const CencFormatException(_formatError);
      }
      out.add(
        _Box(
          String.fromCharCodes(data.sublist(start + 4, start + 8)),
          start,
          start + header,
          start + size,
        ),
      );
      start += size;
    }
    return out;
  }

  static _Box _child(Uint8List data, _Box parent, String kind) {
    for (final row in _boxes(data, parent.body, parent.end)) {
      if (row.kind == kind) return row;
    }
    throw CencFormatException('$_formatError：缺少 $kind');
  }

  static _Box? _find(List<_Box> rows, String kind) {
    for (final row in rows) {
      if (row.kind == kind) return row;
    }
    return null;
  }

  static CencMp4Index _index(int total) =>
      CencMp4Index(total: total, patches: [], spans: []);

  void _patch(int offset, String value) {
    patches.add(
      CencPatch(offset, Uint8List.fromList(value.codeUnits)),
    );
  }

  void _track(Uint8List data, _Box trak, int base) {
    var box = trak;
    for (final kind in const ['mdia', 'minf', 'stbl']) {
      box = _child(data, box, kind);
    }
    final rows = _boxes(data, box.body, box.end);
    final view = ByteData.sublistView(data);
    final stsd = _find(rows, 'stsd');
    if (stsd == null || stsd.end - stsd.body < 8) {
      throw const CencFormatException(_formatError);
    }
    final entries = _boxes(data, stsd.body + 8, stsd.end);
    var encrypted = false;
    var ivSize = 0;
    for (var entryNumber = 0; entryNumber < entries.length; entryNumber++) {
      final entry = entries[entryNumber];
      if (entry.kind != 'encv' && entry.kind != 'enca') continue;
      if (encrypted || entryNumber != 0 || entries.length != 1) {
        throw const CencFormatException(_formatError);
      }
      var skip = 78;
      if (entry.kind == 'enca') {
        skip = 28;
        if (entry.end - entry.body < 28 ||
            view.getUint16(entry.body + 8) != 0) {
          throw const CencFormatException(_formatError);
        }
      }
      final children = _boxes(data, entry.body + skip, entry.end);
      final sinf = _find(children, 'sinf');
      if (sinf == null) {
        throw const CencFormatException(_formatError);
      }
      final frma = _child(data, sinf, 'frma');
      if (frma.end - frma.body != 4) {
        throw const CencFormatException(_formatError);
      }
      final schm = _child(data, sinf, 'schm');
      if (schm.end - schm.body < 8 ||
          String.fromCharCodes(data.sublist(schm.body + 4, schm.body + 8)) !=
              'cenc') {
        throw const CencFormatException(_formatError);
      }
      final schi = _child(data, sinf, 'schi');
      final tenc = _child(data, schi, 'tenc');
      if (tenc.end - tenc.body < 24) {
        throw const CencFormatException(_formatError);
      }
      if (data[tenc.body] > 1 ||
          data[tenc.body + 5] != 0 ||
          data[tenc.body + 6] != 1) {
        throw const CencFormatException(_formatError);
      }
      ivSize = data[tenc.body + 7];
      if (ivSize != 8 && ivSize != 16) {
        throw const CencFormatException(_formatError);
      }
      _patch(
        base + entry.start + 4,
        String.fromCharCodes(data.sublist(frma.body, frma.end)),
      );
      _patch(base + sinf.start + 4, 'free');
      encrypted = true;
    }
    if (!encrypted) return;
    for (final row in rows) {
      if ((row.kind == 'sgpd' || row.kind == 'sbgp') &&
          row.end - row.body >= 8 &&
          String.fromCharCodes(data.sublist(row.body + 4, row.body + 8)) ==
              'seig') {
        throw const CencFormatException(_formatError);
      }
    }
    final sizes = _sizes(data, rows);
    final offsets = _offsets(data, rows, sizes, total);
    final senc = _find(rows, 'senc');
    if (senc == null || senc.end - senc.body < 8) {
      throw const CencFormatException('$_formatError：缺少采样加密表');
    }
    final flags = view.getUint32(senc.body);
    if (flags & ~2 != 0 || view.getUint32(senc.body + 4) != sizes.length) {
      throw const CencFormatException(_formatError);
    }
    var position = senc.body + 8;
    for (var i = 0; i < sizes.length; i++) {
      final size = sizes[i];
      if (position + ivSize > senc.end) {
        throw const CencFormatException(_formatError);
      }
      final iv = Uint8List.fromList(data.sublist(position, position + ivSize));
      final counterIv = Uint8List(16);
      counterIv.setRange(0, ivSize, iv);
      position += ivSize;
      if (flags & 2 == 0) {
        if (size > 0) {
          spans.add(
            CencSpan(
              start: offsets[i],
              end: offsets[i] + size,
              counterOffset: 0,
              iv: counterIv,
            ),
          );
        }
        continue;
      }
      if (position + 2 > senc.end) {
        throw const CencFormatException(_formatError);
      }
      final count = view.getUint16(position);
      position += 2;
      if (count == 0 || count > (senc.end - position) ~/ 6) {
        throw const CencFormatException(_formatError);
      }
      var samplePosition = offsets[i];
      var encryptedOffset = 0;
      for (var j = 0; j < count; j++) {
        final clear = view.getUint16(position);
        final length = view.getUint32(position + 2);
        position += 6;
        samplePosition += clear;
        if (samplePosition > offsets[i] + size ||
            length > offsets[i] + size - samplePosition) {
          throw const CencFormatException(_formatError);
        }
        if (length > 0) {
          spans.add(
            CencSpan(
              start: samplePosition,
              end: samplePosition + length,
              counterOffset: encryptedOffset,
              iv: counterIv,
            ),
          );
        }
        samplePosition += length;
        encryptedOffset += length;
        if (spans.length > cencSampleLimit * 4) {
          throw const CencFormatException(_formatError);
        }
      }
      if (samplePosition != offsets[i] + size) {
        throw const CencFormatException(_formatError);
      }
    }
    if (position != senc.end) {
      throw const CencFormatException(_formatError);
    }
    for (final row in rows) {
      if (row.kind == 'senc' || row.kind == 'saiz' || row.kind == 'saio') {
        _patch(base + row.start + 4, 'free');
      }
    }
  }

  static List<int> _sizes(Uint8List data, List<_Box> rows) {
    final b = _find(rows, 'stsz');
    if (b == null || b.end - b.body < 12) {
      throw const CencFormatException(_formatError);
    }
    final view = ByteData.sublistView(data);
    final uniform = view.getUint32(b.body + 4);
    final count = view.getUint32(b.body + 8);
    if (count < 1 ||
        count > cencSampleLimit ||
        (uniform == 0 && count > (b.end - b.body - 12) ~/ 4)) {
      throw const CencFormatException(_formatError);
    }
    final sizes = List<int>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      sizes[i] = uniform != 0 ? uniform : view.getUint32(b.body + 12 + i * 4);
    }
    return sizes;
  }

  static List<int> _offsets(
    Uint8List data,
    List<_Box> rows,
    List<int> sizes,
    int total,
  ) {
    final view = ByteData.sublistView(data);
    var b = _find(rows, 'stco');
    var width = 4;
    if (b == null) {
      b = _find(rows, 'co64');
      width = 8;
    }
    if (b == null || b.end - b.body < 8) {
      throw const CencFormatException(_formatError);
    }
    final count = view.getUint32(b.body + 4);
    if (count < 1 ||
        count > cencSampleLimit ||
        count > (b.end - b.body - 8) ~/ width) {
      throw const CencFormatException(_formatError);
    }
    final sc = _find(rows, 'stsc');
    if (sc == null || sc.end - sc.body < 8) {
      throw const CencFormatException(_formatError);
    }
    final n = view.getUint32(sc.body + 4);
    if (n < 1 || n > count || n > (sc.end - sc.body - 8) ~/ 12) {
      throw const CencFormatException(_formatError);
    }
    final firsts = List<int>.filled(n, 0);
    final samplesPerChunk = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final p = sc.body + 8 + i * 12;
      firsts[i] = view.getUint32(p);
      samplesPerChunk[i] = view.getUint32(p + 4);
      if (samplesPerChunk[i] < 1 ||
          firsts[i] < 1 ||
          firsts[i] > count ||
          (i == 0 && firsts[i] != 1) ||
          (i > 0 && firsts[i] <= firsts[i - 1]) ||
          view.getUint32(p + 8) != 1) {
        throw const CencFormatException(_formatError);
      }
    }
    final offsets = List<int>.filled(sizes.length, 0);
    var sample = 0;
    var rule = 0;
    for (var chunk = 1; chunk <= count; chunk++) {
      if (rule + 1 < firsts.length && chunk >= firsts[rule + 1]) {
        rule++;
      }
      final p = b.body + 8 + (chunk - 1) * width;
      var offset = width == 8 ? view.getUint64(p) : view.getUint32(p);
      for (var j = 0; j < samplesPerChunk[rule]; j++) {
        if (sample >= sizes.length ||
            offset > total ||
            sizes[sample] > total - offset) {
          throw const CencFormatException(_formatError);
        }
        offsets[sample] = offset;
        offset += sizes[sample];
        sample++;
      }
    }
    if (sample != sizes.length) {
      throw const CencFormatException(_formatError);
    }
    return offsets;
  }

  /// 就地把 [offset] 起、长度为 [data.length] 的密文块解密，并覆盖要改成明文的 box 标记。
  void transform(Uint8List data, int offset, Uint8List key) {
    final end = offset + data.length;
    var searchFrom = 0;
    for (var i = 0; i < spans.length; i++) {
      if (spans[i].end > offset) {
        searchFrom = i;
        break;
      }
      searchFrom = i + 1;
    }
    final cipher = AESEngine()..init(true, KeyParameter(key));
    for (var i = searchFrom; i < spans.length && spans[i].start < end; i++) {
      final span = spans[i];
      final start = offset > span.start ? offset : span.start;
      final stop = end < span.end ? end : span.end;
      if (start >= stop) continue;
      final position = span.counterOffset + start - span.start;
      _xorCtr(
        cipher,
        span.iv,
        position,
        Uint8List.sublistView(data, start - offset, stop - offset),
      );
    }
    for (final patch in patches) {
      final a = offset > patch.offset ? offset : patch.offset;
      final patchEnd = patch.offset + patch.data.length;
      final b = end < patchEnd ? end : patchEnd;
      if (a >= b) continue;
      data.setRange(
        a - offset,
        b - offset,
        patch.data,
        a - patch.offset,
      );
    }
  }

  static void _xorCtr(
    AESEngine cipher,
    Uint8List iv,
    int position,
    Uint8List target,
  ) {
    final counter = Uint8List.fromList(iv);
    var carry = position ~/ 16;
    for (var j = 15; j >= 0 && carry > 0; j--) {
      final sum = counter[j] + (carry & 0xFF);
      counter[j] = sum & 0xFF;
      carry = (carry >> 8) + (sum >> 8);
    }
    final block = Uint8List(16);
    var skip = position % 16;
    var index = 0;
    while (index < target.length) {
      cipher.processBlock(counter, 0, block, 0);
      for (var j = 15; j >= 0; j--) {
        counter[j] = (counter[j] + 1) & 0xFF;
        if (counter[j] != 0) break;
      }
      for (var b = skip; b < 16 && index < target.length; b++, index++) {
        target[index] ^= block[b];
      }
      skip = 0;
    }
  }
}
