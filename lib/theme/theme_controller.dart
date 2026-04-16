import 'package:flutter/foundation.dart';
import 'app_theme.dart';
import 'theme_presets.dart';

/// 전역 테마 컨트롤러 — 런타임 테마 스왑
///
/// `ThemeController.current.value` 를 변경하면 MaterialApp이 자동 재빌드되어
/// 전체 앱 색상이 즉시 전환됨.
///
/// 사용법:
///   - 읽기: `ThemeController.current.value`
///   - 쓰기: `ThemeController.set(MintPreset())`
///   - 구독: `ValueListenableBuilder<ThemePreset>(valueListenable: ThemeController.current, ...)`
class ThemeController {
  ThemeController._();

  /// 현재 활성 프리셋 (기본: 앰버)
  static final ValueNotifier<ThemePreset> current =
      ValueNotifier<ThemePreset>(AmberPreset());

  /// 프리셋 변경
  static void set(ThemePreset preset) {
    current.value = preset;
  }
}
