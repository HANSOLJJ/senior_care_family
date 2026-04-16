import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tap_guard.dart';
import 'press_scale.dart';

/// (`Enum`) 탭 시 햅틱 피드백 강도
enum HapticStrength { light, medium, heavy, selection }

void _triggerHaptic(HapticStrength s) {
  switch (s) {
    case HapticStrength.light:
      HapticFeedback.lightImpact();
      break;
    case HapticStrength.medium:
      HapticFeedback.mediumImpact();
      break;
    case HapticStrength.heavy:
      HapticFeedback.heavyImpact();
      break;
    case HapticStrength.selection:
      HapticFeedback.selectionClick();
      break;
  }
}

/// (`Widget`) 비동기 액션용 ElevatedButton — double-tap 차단 + 스피너 + 햅틱
///
/// [TapGuard]로 중복 호출 방지. busy 동안 자동 disabled + CircularProgressIndicator 표시.
/// 탭 시 [HapticFeedback.lightImpact] (기본), 위험 액션은 [haptic] prop으로 mediumImpact 지정.
class AsyncActionButton extends StatelessWidget {
  final TapGuard guard;
  final Future<void> Function() onPressed;
  final IconData? icon;
  final String label;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final ButtonStyle? style;
  final HapticStrength haptic;

  const AsyncActionButton({
    super.key,
    required this.guard,
    required this.onPressed,
    required this.label,
    this.icon,
    this.backgroundColor,
    this.foregroundColor,
    this.style,
    this.haptic = HapticStrength.light,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: guard.isBusy,
      builder: (context, busy, _) {
        final resolvedStyle = style ??
            ElevatedButton.styleFrom(
              backgroundColor: backgroundColor,
              foregroundColor: foregroundColor,
            );
        final tap = busy
            ? null
            : () {
                _triggerHaptic(haptic);
                guard.run(onPressed);
              };
        final btn = icon != null
            ? ElevatedButton.icon(
                onPressed: tap,
                icon: Icon(icon),
                label: Text(label),
                style: resolvedStyle,
              )
            : ElevatedButton(
                onPressed: tap,
                style: resolvedStyle,
                child: Text(label),
              );
        return PressScale(onTap: tap, child: btn);
      },
    );
  }
}

/// (`Widget`) 비동기 IconButton — double-tap 차단 + 스피너 + 햅틱
class AsyncIconButton extends StatelessWidget {
  final TapGuard guard;
  final Future<void> Function() onPressed;
  final IconData icon;
  final Color? color;
  final double? size;
  final String? tooltip;
  final HapticStrength haptic;

  const AsyncIconButton({
    super.key,
    required this.guard,
    required this.onPressed,
    required this.icon,
    this.color,
    this.size,
    this.tooltip,
    this.haptic = HapticStrength.light,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: guard.isBusy,
      builder: (context, busy, _) {
        final tap = busy
            ? null
            : () {
                _triggerHaptic(haptic);
                guard.run(onPressed);
              };
        return PressScale(
          onTap: tap,
          child: IconButton(
            onPressed: tap,
            tooltip: tooltip,
            icon: Icon(icon, color: color, size: size),
          ),
        );
      },
    );
  }
}
