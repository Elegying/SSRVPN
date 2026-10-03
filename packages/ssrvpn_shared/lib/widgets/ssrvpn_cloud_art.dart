import 'dart:math' as math;
import 'package:flutter/material.dart';

class SsrvpnCloudIcon extends StatelessWidget {
  const SsrvpnCloudIcon(this.name, {super.key, this.size = 40});
  final String name;
  final double size;
  @override
  Widget build(BuildContext context) =>
      Image.asset('assets/themes/cloud-$name.webp',
          package: 'ssrvpn_shared',
          width: size,
          height: size,
          excludeFromSemantics: true,
          filterQuality: FilterQuality.medium);
}

/// One illustrated scene, with a live button aligned to the blank blue disk.
class SsrvpnCloudHero extends StatelessWidget {
  const SsrvpnCloudHero(
      {super.key,
      required this.connecting,
      required this.connected,
      required this.onTap,
      this.header});
  final Widget? header;
  final bool connecting, connected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        // Full scene coordinates are independent of the narrow content column.
        // Cap the illustration scale on short landscape screens so the live
        // disk remains inside its available height.
        final imageWidth = math.min(
            math.max(box.maxWidth * 1.04, box.maxHeight * 2),
            box.maxHeight * 3.1);
        final imageHeight = imageWidth / 2;
        final imageTop = (box.maxHeight - imageHeight) / 2;
        final diameter = imageWidth * .27;
        final label = connecting
            ? '取消当前连接操作'
            : connected
                ? '断开连接'
                : '连接';
        return Stack(children: [
          Positioned.fill(
              child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white,
                            Colors.white,
                            Colors.white,
                            Colors.transparent
                          ],
                          stops: [
                            0,
                            .2,
                            .84,
                            1
                          ]).createShader(rect),
                  child: ClipRect(
                      child: Stack(children: [
                    Positioned(
                        left: box.maxWidth / 2 - imageWidth * .515,
                        top: imageTop,
                        width: imageWidth,
                        height: imageHeight,
                        child: ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (rect) => const LinearGradient(
                                    colors: [
                                      Colors.transparent,
                                      Colors.white,
                                      Colors.white,
                                      Colors.transparent
                                    ],
                                    stops: [
                                      0,
                                      .06,
                                      .94,
                                      1
                                    ]).createShader(rect),
                            child: Image.asset('assets/themes/cloud-hero.webp',
                                package: 'ssrvpn_shared',
                                fit: BoxFit.fill,
                                excludeFromSemantics: true))),
                  ])))),
          Positioned(
              left: (box.maxWidth - diameter) / 2,
              top: imageTop + imageHeight * .525 - diameter / 2,
              width: diameter,
              height: diameter,
              child: Semantics(
                  button: true,
                  label: label,
                  child: Tooltip(
                      message: label,
                      child: Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(),
                          child: InkWell(
                              key: const Key('ssrvpn-power-button'),
                              customBorder: const CircleBorder(),
                              onTap: onTap,
                              child: Center(
                                  child: connecting
                                      ? SizedBox(
                                          width: box.maxWidth * .14,
                                          height: box.maxWidth * .14,
                                          child:
                                              const CircularProgressIndicator(
                                                  color: Colors.white,
                                                  strokeWidth: 5))
                                      : SsrvpnCloudIcon('power',
                                          size: diameter * .62))))))),
          if (header != null)
            Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: header!))),
        ]);
      });
}
