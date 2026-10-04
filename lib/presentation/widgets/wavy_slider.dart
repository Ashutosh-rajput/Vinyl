import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Material 3 Expressive style progress track for a [Slider].
///
/// The played part is a wavy line (the snake's body) that travels along the
/// track while music plays; the remaining part is a flat rounded line that
/// starts just in front of the snake's head and ends in a small dot. When
/// music is paused the wave eases out to a straight line.
class WavySliderTrackShape extends SliderTrackShape {
  /// Phase of the travelling wave, 0..1 (one full wavelength per cycle).
  final double waveAnimationValue;

  /// True while music is playing and the wave is enabled.
  final bool isPlaying;

  /// Current wave height, 0 (straight) .. 1 (full). Animate this to ease
  /// the wave in and out.
  final double amplitude;

  /// Radius of the snake head the track connects to.
  final double headRadius;

  const WavySliderTrackShape({
    required this.waveAnimationValue,
    required this.isPlaying,
    this.amplitude = 1.0,
    this.headRadius = 11.0,
  });

  static const double _strokeWidth = 4.5;
  static const double _inactiveStrokeWidth = 4.0;
  static const double _waveHeight = 3.2;
  static const double _wavelength = 36.0;
  static const double _stopDotRadius = 2.0;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const trackHeight = 14.0; // room for the wave
    final top = offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(offset.dx, top, parentBox.size.width, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final canvas = context.canvas;
    final activeColor = sliderTheme.activeTrackColor ?? Colors.purpleAccent;
    final inactiveColor = sliderTheme.inactiveTrackColor ?? Colors.white24;

    final cy = rect.center.dy;
    final left = rect.left + _strokeWidth / 2;
    final right = rect.right - _strokeWidth / 2;
    // The wavy body runs into the back of the snake's head; the flat
    // remainder starts a little in front of its nose.
    final activeEnd = thumbCenter.dx - headRadius * 0.55;
    final inactiveStart = thumbCenter.dx + headRadius * 1.2 + 5;

    // Remaining (flat) part, with a stop dot at its end.
    if (inactiveStart < right) {
      canvas.drawLine(
        Offset(inactiveStart, cy),
        Offset(right, cy),
        Paint()
          ..color = inactiveColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = _inactiveStrokeWidth
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(
        Offset(right - _stopDotRadius, cy),
        _stopDotRadius,
        Paint()..color = activeColor,
      );
    }

    // Played part: wavy while playing, a straight line otherwise.
    if (activeEnd > left) {
      final activePaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      final height = _waveHeight * amplitude.clamp(0.0, 1.0);
      if (height < 0.05) {
        canvas.drawLine(Offset(left, cy), Offset(activeEnd, cy), activePaint);
      } else {
        final k = 2 * math.pi / _wavelength;
        final phase = waveAnimationValue * 2 * math.pi;
        final path = Path()..moveTo(left, cy + math.sin(-phase) * height);
        for (double x = left + 1.5; x < activeEnd; x += 1.5) {
          path.lineTo(x, cy + math.sin((x - left) * k - phase) * height);
        }
        path.lineTo(activeEnd, cy + math.sin((activeEnd - left) * k - phase) * height);
        canvas.drawPath(path, activePaint);
      }
    }
  }
}

/// The snake head that rides at the end of the wavy body: the seek handle.
///
/// Its tail is the wavy track painted by [WavySliderTrackShape].
class SnakeHeadSliderThumbShape extends SliderComponentShape {
  final double thumbRadius;
  final double waveAnimationValue;
  final bool isPlaying;

  const SnakeHeadSliderThumbShape({
    this.thumbRadius = 11.0,
    required this.waveAnimationValue,
    required this.isPlaying,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size.fromRadius(thumbRadius);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;
    final primaryColor = sliderTheme.thumbColor ?? Colors.purpleAccent;

    canvas.save();
    canvas.translate(center.dx, center.dy);

    if (isPlaying) {
      final tilt = math.sin(waveAnimationValue * 2 * math.pi) * 0.12;
      canvas.rotate(tilt);
    }

    // 1. Draw Snake Head Path (pointing forward ->)
    final headPath = Path();
    headPath.moveTo(-thumbRadius * 0.8, -thumbRadius * 0.5);
    headPath.cubicTo(
      -thumbRadius * 0.2,
      -thumbRadius * 0.9,
      thumbRadius * 0.6,
      -thumbRadius * 0.7,
      thumbRadius * 1.2,
      0.0,
    );
    headPath.cubicTo(
      thumbRadius * 0.6,
      thumbRadius * 0.7,
      -thumbRadius * 0.2,
      thumbRadius * 0.9,
      -thumbRadius * 0.8,
      thumbRadius * 0.5,
    );
    headPath.close();

    final headPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(headPath, headPaint);

    // 2. Draw Snake Eyes
    final eyePaint = Paint()
      ..color = isPlaying ? Colors.white : Colors.black87
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      Offset(thumbRadius * 0.4, -thumbRadius * 0.3),
      1.8,
      eyePaint,
    );
    canvas.drawCircle(
      Offset(thumbRadius * 0.4, thumbRadius * 0.3),
      1.8,
      eyePaint,
    );

    if (isPlaying) {
      final pupilPaint = Paint()
        ..color = Colors.black
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(thumbRadius * 0.45, -thumbRadius * 0.3),
        0.8,
        pupilPaint,
      );
      canvas.drawCircle(
        Offset(thumbRadius * 0.45, thumbRadius * 0.3),
        0.8,
        pupilPaint,
      );

      // Flickering red tongue when playing
      final tonguePhase = math.sin(waveAnimationValue * 4 * math.pi);
      if (tonguePhase > 0.2) {
        final tonguePaint = Paint()
          ..color = Colors.redAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeCap = StrokeCap.round;

        final tonguePath = Path();
        tonguePath.moveTo(thumbRadius * 1.2, 0.0);
        tonguePath.lineTo(thumbRadius * 1.55, 0.0);
        tonguePath.lineTo(thumbRadius * 1.75, -thumbRadius * 0.22);
        tonguePath.moveTo(thumbRadius * 1.55, 0.0);
        tonguePath.lineTo(thumbRadius * 1.75, thumbRadius * 0.22);

        canvas.drawPath(tonguePath, tonguePaint);
      }
    }

    canvas.restore();
  }
}
