import 'package:flutter/material.dart';

/// 테마 프리셋 추상 클래스 — 색상 토큰 정의
///
/// 새 프리셋 추가 방법:
///   1. [theme_presets.dart]에 `extends ThemePreset` 클래스 추가
///   2. `allPresets` 리스트에 인스턴스 추가
///   3. 끝 — 화면 코드 수정 불필요
abstract class ThemePreset {
  String get name;
  Color get primary;
  Color get background;
  Color get surface;
  Color get error;         // 삭제/에러 (cs.error 로도 노출)
  Color get success;       // 온라인/완료 (ext.success)
  Color get warning;       // 경고/pending (ext.warning)
  Color get textSecondary;
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
/// InputDecoration 등)를 프리셋 색상 기반으로 일관 생성.
class AppTheme {
  static ThemeData build(ThemePreset p) {
    return ThemeData(
      useMaterial3: true,
      fontFamily: 'Pretendard',
      brightness: Brightness.dark,
      colorScheme: ColorScheme.dark(
        primary: p.primary,
        onPrimary: Colors.black,
        surface: p.surface,
        onSurface: Colors.white,
        error: p.error,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: p.background,
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        foregroundColor: Colors.white,
        elevation: 0,
        titleTextStyle: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF2A2A2A),
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
              : Colors.grey.shade400,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.primary.withValues(alpha: 0.4)
              : Colors.grey.shade800,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: Colors.black,
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
          foregroundColor: Colors.white,
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
        labelStyle: const TextStyle(
          fontFamily: 'Pretendard',
          color: Colors.white,
        ),
        secondaryLabelStyle: const TextStyle(
          fontFamily: 'Pretendard',
          color: Colors.black,
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
        textStyle: const TextStyle(
          fontFamily: 'Pretendard',
          color: Colors.white,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.primary,
        linearTrackColor: Colors.white.withValues(alpha: 0.15),
        circularTrackColor: Colors.white.withValues(alpha: 0.15),
      ),
      listTileTheme: ListTileThemeData(
        textColor: Colors.white,
        iconColor: Colors.white,
        titleTextStyle: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 16,
          color: Colors.white,
        ),
        subtitleTextStyle: TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 13,
          color: p.textSecondary,
        ),
      ),
      iconTheme: const IconThemeData(color: Colors.white),
      dividerTheme: DividerThemeData(
        color: p.textSecondary.withValues(alpha: 0.2),
        thickness: 0.5,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        titleTextStyle: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        contentTextStyle: const TextStyle(
          fontFamily: 'Pretendard',
          fontSize: 14,
          color: Colors.white,
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
