import 'package:flutter/material.dart';

/// (`Widget`) 탭 시 살짝 줄어드는 scale 애니메이션 래퍼
///
/// 자식을 [GestureDetector]로 감싸 onTapDown 시 [scaleDown]으로 줄였다가
/// onTapUp/onTapCancel 시 1.0으로 복귀. Material ripple과 별개의
/// 즉각적 시각 피드백 제공.
///
/// - **Params**:
///   - [child] — 감쌀 위젯 (Container, Card 등)
///   - [onTap] — 탭 콜백 (null이면 비활성)
///   - [scaleDown] — 누를 때 scale (기본 0.95)
///   - [duration] — 애니메이션 시간 (기본 80ms)
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scaleDown;
  final Duration duration;

  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scaleDown = 0.95,
    this.duration = const Duration(milliseconds: 80),
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null && widget.onLongPress == null;
    return GestureDetector(
      onTapDown: disabled ? null : (_) => _setPressed(true),
      onTapUp: disabled ? null : (_) => _setPressed(false),
      onTapCancel: disabled ? null : () => _setPressed(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? widget.scaleDown : 1.0,
        duration: widget.duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
