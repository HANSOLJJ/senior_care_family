import 'package:flutter/foundation.dart';
import 'app_theme.dart';
import 'theme_presets.dart';

/// 전역 테마 컨트롤러 — 런타임 hue 스왑
///
/// `ThemeController.currentHue.value` 를 변경하면 MaterialApp 이 자동 재빌드되어
/// 전체 앱 색상이 즉시 전환됨. light/dark 베리언트는 hue 가 들고 있으며,
/// 실제 적용은 OS 시스템 모드(`MaterialApp.themeMode = system`)가 결정.
///
/// 사용법:
///   - 읽기: `ThemeController.currentHue.value`
///   - 쓰기: `ThemeController.set(MintHue())`
///   - 구독: `ValueListenableBuilder<ThemeHue>(valueListenable: ThemeController.currentHue, ...)`
class ThemeController {
  ThemeController._();

  /// 현재 활성 hue (기본: 앰버)
  static final ValueNotifier<ThemeHue> currentHue =
      ValueNotifier<ThemeHue>(AmberHue());

  /// hue 변경
  static void set(ThemeHue hue) {
    currentHue.value = hue;
  }
}
