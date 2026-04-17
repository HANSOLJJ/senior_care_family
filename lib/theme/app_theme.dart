import 'package:flutter/material.dart';

/// 테마 프리셋 — hue × brightness 조합 1개 (light 또는 dark)
///
/// 새 hue 추가 방법:
///   1. [theme_presets.dart]에 `extends ThemePreset` Light/Dark 두 클래스 + Hue 클래스 추가
///   2. `allHues` 리스트에 Hue 인스턴스 추가
///   3. 끝 — 화면 코드 수정 불필요
abstract class ThemePreset {
  String get name;
  Brightness get brightness;
  Color get primary;
  Color get background;
  Color get surface;
  Color get error;
  Color get success;       // 온라인/완료 (ext.success)
  Color get warning;       // 경고/pending (ext.warning)
  Color get textSecondary;
  Color get onSurface;     // 본문 텍스트
  Color get onPrimary;     // primary 위 텍스트 (버튼 라벨 등)
  Color get snackBarBackground;
}

/// Hue (색상 계열) — light/dark 두 ThemePreset 을 묶음
///
/// 사용자는 hue 만 선택, brightness 는 OS 가 결정 (`MaterialApp.themeMode = system`).
abstract class ThemeHue {
  String get name;
  ThemePreset get light;
  ThemePreset get dark;
}

/// ColorScheme에 없는 커스텀 토큰을 ThemeExtension으로 주입
///
/// 사용법: `Theme.of(context).extension<AppColorExt>()!.success`
class AppColorExt extends ThemeExtension<AppColorExt> {
  final Color textSecondary;
  final Color success;
  final Color warning;

  const AppColorExt({
    required this.textSecondary,
    required this.success,
    required this.warning,
  });

  @override
  AppColorExt copyWith({Color? textSecondary, Color? success, Color? warning}) =>
      AppColorExt(
        textSecondary: textSecondary ?? this.textSecondary,
        success: success ?? this.success,
        warning: warning ?? this.warning,
      );

  @override
  AppColorExt lerp(ThemeExtension<AppColorExt>? other, double t) {
    if (other is! AppColorExt) return this;
    return AppColorExt(
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}

/// ThemePreset → ThemeData 변환 빌더
///
/// 모든 앱 전역 위젯 테마(SnackBar, Switch, ElevatedButton, OutlinedButton,
/// InputDecoration 등)를 프리셋 색상 기반으로 일관 생성. light/dark 모두 동일 빌더로 처리.
class AppTheme {
  static ThemeData build(ThemePreset p) {
    final isDark = p.brightness == Brightness.dark;
    final disabledTrackColor = isDark
        ? Colors.grey.shade800
        : Colors.grey.shade300;
    final inactiveThumbColor = isDark
        ? Colors.grey.shade400
        : Colors.grey.shade500;
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Pretendard',
      brightness: p.brightness,
      colorScheme: isDark
          ? ColorScheme.dark(
              primary: p.primary,
              onPrimary: p.onPrimary,
              surface: p.surface,
              onSurface: p.onSurface,
              error: p.error,
              onError: Colors.white,
            )
          : ColorScheme.light(
              primary: p.primary,
              onPrimary: p.onPrimary,
              surface: p.surface,
              onSurface: p.onSurface,
              error: p.error,
              onError: Colors.white,
            ),
      scaffoldBackgroundColor: p.background,
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        foregroundColor: p.onSurface,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: p.onSurface,
        ),
        iconTheme: IconThemeData(color: p.onSurface),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.snackBarBackground,
        // snackBarBackground 는 light/dark 모두 어두운 계열 → 텍스트 흰색 고정
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontFamily: 'Pretendard',
          fontSize: 14,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.primary
              : inactiveThumbColor,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.primary.withValues(alpha: 0.4)
              : disabledTrackColor,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          textStyle: const TextStyle(
            fontFamily: 'Pretendard',
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.onSurface,
          side: BorderSide(color: p.textSecondary.withValues(alpha: 0.5)),
          textStyle: const TextStyle(fontFamily: 'Pretendard'),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.primary,
          textStyle: const TextStyle(fontFamily: 'Pretendard'),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: p.primary, width: 2),
        ),
        labelStyle: TextStyle(color: p.textSecondary),
        hintStyle: TextStyle(color: p.textSecondary.withValues(alpha: 0.6)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surface,
        selectedColor: p.primary,
        labelStyle: TextStyle(
          fontFamily: 'Pretendard',
          color: p.onSurface,
        ),
        secondaryLabelStyle: TextStyle(
          fontFamily: 'Pretendard',
          color: p.onPrimary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        textStyle: TextStyle(
          fontFamily: 'Pretendard',
          color: p.onSurface,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.primary,
        linearTrackColor: p.onSurface.withValues(alpha: 0.15),
        circularTrackColor: p.onSurface.withValues(alpha: 0.15),
      ),
      listTileTheme: ListTileThemeData(
        textColor: p.onSurface,
        iconColor: p.onSurface,
        titleTextStyle: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 16,
          color: p.onSurface,
        ),
        subtitleTextStyle: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 13,
          color: p.textSecondary,
        ),
      ),
      iconTheme: IconThemeData(color: p.onSurface),
      dividerTheme: DividerThemeData(
        color: p.textSecondary.withValues(alpha: 0.2),
        thickness: 0.5,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        titleTextStyle: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: p.onSurface,
        ),
        contentTextStyle: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 14,
          color: p.onSurface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      extensions: [
        AppColorExt(
          textSecondary: p.textSecondary,
          success: p.success,
          warning: p.warning,
        ),
      ],
    );
  }
}
