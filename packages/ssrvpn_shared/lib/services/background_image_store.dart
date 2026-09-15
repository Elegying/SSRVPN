import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_selector/file_selector.dart';

/// Keeps a bounded, decoded static image in the app's own data directory.
class BackgroundImageStore {
  static const maxBytes = 20 * 1024 * 1024;

  static Future<File> importImage(XFile source, String dataDirectory) async {
    if (await source.length() > maxBytes) {
      throw const FormatException('请选择不超过 20 MB 的图片');
    }
    final bytes = await source.readAsBytes();
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('图片为空或超过 20 MB');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 40000000) {
        throw const FormatException('图片分辨率过大，请选择 4000 万像素以内的图片');
      }
      final longest = descriptor.width > descriptor.height
          ? descriptor.width
          : descriptor.height;
      final ratio = longest > 2048 ? 2048 / longest : 1.0;
      codec = await descriptor.instantiateCodec(
          targetWidth: (descriptor.width * ratio).round().clamp(1, 2048),
          targetHeight: (descriptor.height * ratio).round().clamp(1, 2048));
      if (codec.frameCount != 1) throw const FormatException('请选择静态图片');
      image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw const FormatException('无法读取这张图片');
      final root = Directory('$dataDirectory/backgrounds');
      await root.create(recursive: true);
      final folder = await root.createTemp('image-');
      final file = File('${folder.path}/background.png');
      try {
        await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
        return file;
      } catch (_) {
        await folder.delete(recursive: true);
        rethrow;
      }
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  static Future<void> removeOwned(String path, String dataDirectory) async {
    if (path.isEmpty) return;
    final file = File(path);
    final root = Directory('$dataDirectory/backgrounds').absolute.path;
    if (file.parent.parent.absolute.path != root ||
        !file.parent.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('image-') ||
        file.uri.pathSegments.last != 'background.png') {
      return;
    }
    if (await file.exists()) await file.delete();
    if (await file.parent.exists() && await file.parent.list().isEmpty) {
      await file.parent.delete();
    }
  }
}
