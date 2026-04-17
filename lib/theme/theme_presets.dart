import 'package:flutter/material.dart';
import 'app_theme.dart';

// ─────────────────────────────────────────────────────────────────
// 공통 라이트 토큰
// ─────────────────────────────────────────────────────────────────
const _lightOnSurface = Color(0xFF111827);       // gray-900
const _lightTextSecondary = Color(0xFF6B7280);   // gray-500
const _lightSnackBg = Color(0xFF1F2937);         // gray-800 (라이트에서 SnackBar 는 다크)
const _darkSnackBg = Color(0xFF2A2A2A);

// ─────────────────────────────────────────────────────────────────
// 앰버 (따뜻한 오렌지 — 시니어 케어 친근감)
// ─────────────────────────────────────────────────────────────────
class AmberDarkPreset extends ThemePreset {
  @override String get name => '앰버 다크';
  @override Brightness get brightness => Brightness.dark;
  @override Color get primary => const Color(0xFFFBBF24);
  @override Color get background => const Color(0xFF111111);
  @override Color get surface => const Color(0xFF1E1E1E);
  @override Color get error => const Color(0xFFEF4444);
  @override Color get success => const Color(0xFF10B981);
  @override Color get warning => const Color(0xFFF59E0B);
  @override Color get textSecondary => const Color(0xFF9CA3AF);
  @override Color get onSurface => Colors.white;
  @override Color get onPrimary => Colors.black;
  @override Color get snackBarBackground => _darkSnackBg;
}
class AmberLightPreset extends ThemePreset {
  @override String get name => '앰버 라이트';
  @override Brightness get brightness => Brightness.light;
  @override Color get primary => const Color(0xFFD97706);          // amber-600 (라이트 대비)
  @override Color get background => const Color(0xFFFFFBEB);       // amber-50
  @override Color get surface => Colors.white;
  @override Color get error => const Color(0xFFDC2626);
  @override Color get success => const Color(0xFF059669);
  @override Color get warning => const Color(0xFFD97706);
  @override Color get textSecondary => _lightTextSecondary;
  @override Color get onSurface => _lightOnSurface;
  @override Color get onPrimary => Colors.white;
  @override Color get snackBarBackground => _lightSnackBg;
}
class AmberHue extends ThemeHue {
  @override String get name => '앰버';
  @override ThemePreset get light => AmberLightPreset();
  @override ThemePreset get dark => AmberDarkPreset();
}

// ─────────────────────────────────────────────────────────────────
// 민트 (차갑고 모던 — 헬스케어)
// ─────────────────────────────────────────────────────────────────
class MintDarkPreset extends ThemePreset {
  @override String get name => '민트 다크';
  @override Brightness get brightness => Brightness.dark;
  @override Color get primary => const Color(0xFF2DD4BF);
  @override Color get background => const Color(0xFF0F1419);
  @override Color get surface => const Color(0xFF1A2229);
  @override Color get error => const Color(0xFFF87171);
  @override Color get success => const Color(0xFF14B8A6);
  @override Color get warning => const Color(0xFFFB923C);
  @override Color get textSecondary => const Color(0xFF94A3B8);
  @override Color get onSurface => Colors.white;
  @override Color get onPrimary => Colors.black;
  @override Color get snackBarBackground => _darkSnackBg;
}
class MintLightPreset extends ThemePreset {
  @override String get name => '민트 라이트';
  @override Brightness get brightness => Brightness.light;
  @override Color get primary => const Color(0xFF0D9488);          // teal-600
  @override Color get background => const Color(0xFFF0FDFA);       // teal-50
  @override Color get surface => Colors.white;
  @override Color get error => const Color(0xFFDC2626);
  @override Color get success => const Color(0xFF0D9488);
  @override Color get warning => const Color(0xFFEA580C);
  @override Color get textSecondary => _lightTextSecondary;
  @override Color get onSurface => _lightOnSurface;
  @override Color get onPrimary => Colors.white;
  @override Color get snackBarBackground => _lightSnackBg;
}
class MintHue extends ThemeHue {
  @override String get name => '민트';
  @override ThemePreset get light => MintLightPreset();
  @override ThemePreset get dark => MintDarkPreset();
}

// ─────────────────────────────────────────────────────────────────
// 오션 (차가운 파랑 — 신뢰감)
// ─────────────────────────────────────────────────────────────────
class OceanDarkPreset extends ThemePreset {
  @override String get name => '오션 다크';
  @override Brightness get brightness => Brightness.dark;
  @override Color get primary => const Color(0xFF60A5FA);
  @override Color get background => const Color(0xFF0B1220);
  @override Color get surface => const Color(0xFF1A2332);
  @override Color get error => const Color(0xFFF87171);
  @override Color get success => const Color(0xFF22D3EE);
  @override Color get warning => const Color(0xFFFBBF24);
  @override Color get textSecondary => const Color(0xFF94A3B8);
  @override Color get onSurface => Colors.white;
  @override Color get onPrimary => Colors.black;
  @override Color get snackBarBackground => _darkSnackBg;
}
class OceanLightPreset extends ThemePreset {
  @override String get name => '오션 라이트';
  @override Brightness get brightness => Brightness.light;
  @override Color get primary => const Color(0xFF2563EB);          // blue-600
  @override Color get background => const Color(0xFFEFF6FF);       // blue-50
  @override Color get surface => Colors.white;
  @override Color get error => const Color(0xFFDC2626);
  @override Color get success => const Color(0xFF0891B2);
  @override Color get warning => const Color(0xFFD97706);
  @override Color get textSecondary => _lightTextSecondary;
  @override Color get onSurface => _lightOnSurface;
  @override Color get onPrimary => Colors.white;
  @override Color get snackBarBackground => _lightSnackBg;
}
class OceanHue extends ThemeHue {
  @override String get name => '오션';
  @override ThemePreset get light => OceanLightPreset();
  @override ThemePreset get dark => OceanDarkPreset();
}

// ─────────────────────────────────────────────────────────────────
// 로즈 (분홍-보라 — 따뜻하면서 모던)
// ─────────────────────────────────────────────────────────────────
class RoseDarkPreset extends ThemePreset {
  @override String get name => '로즈 다크';
  @override Brightness get brightness => Brightness.dark;
  @override Color get primary => const Color(0xFFF472B6);
  @override Color get background => const Color(0xFF140A14);
  @override Color get surface => const Color(0xFF241620);
  @override Color get error => const Color(0xFFEF4444);
  @override Color get success => const Color(0xFF34D399);
  @override Color get warning => const Color(0xFFC084FC);
  @override Color get textSecondary => const Color(0xFF9CA3AF);
  @override Color get onSurface => Colors.white;
  @override Color get onPrimary => Colors.black;
  @override Color get snackBarBackground => _darkSnackBg;
}
class RoseLightPreset extends ThemePreset {
  @override String get name => '로즈 라이트';
  @override Brightness get brightness => Brightness.light;
  @override Color get primary => const Color(0xFFDB2777);          // pink-600
  @override Color get background => const Color(0xFFFDF2F8);       // pink-50
  @override Color get surface => Colors.white;
  @override Color get error => const Color(0xFFDC2626);
  @override Color get success => const Color(0xFF059669);
  @override Color get warning => const Color(0xFF9333EA);          // violet-600 (로즈 계열 조화)
  @override Color get textSecondary => _lightTextSecondary;
  @override Color get onSurface => _lightOnSurface;
  @override Color get onPrimary => Colors.white;
  @override Color get snackBarBackground => _lightSnackBg;
}
class RoseHue extends ThemeHue {
  @override String get name => '로즈';
  @override ThemePreset get light => RoseLightPreset();
  @override ThemePreset get dark => RoseDarkPreset();
}

// ─────────────────────────────────────────────────────────────────
// 라벤더 (보라 — 차분하면서 고급감) — 신규
// ─────────────────────────────────────────────────────────────────
class LavenderDarkPreset extends ThemePreset {
  @override String get name => '라벤더 다크';
  @override Brightness get brightness => Brightness.dark;
  @override Color get primary => const Color(0xFFA78BFA);          // violet-400
  @override Color get background => const Color(0xFF0F0A1A);
  @override Color get surface => const Color(0xFF1A1428);
  @override Color get error => const Color(0xFFEF4444);
  @override Color get success => const Color(0xFF34D399);
  @override Color get warning => const Color(0xFFFBBF24);
  @override Color get textSecondary => const Color(0xFF9CA3AF);
  @override Color get onSurface => Colors.white;
  @override Color get onPrimary => Colors.black;
  @override Color get snackBarBackground => _darkSnackBg;
}
class LavenderLightPreset extends ThemePreset {
  @override String get name => '라벤더 라이트';
  @override Brightness get brightness => Brightness.light;
  @override Color get primary => const Color(0xFF7C3AED);          // violet-600
  @override Color get background => const Color(0xFFF5F3FF);       // violet-50
  @override Color get surface => Colors.white;
  @override Color get error => const Color(0xFFDC2626);
  @override Color get success => const Color(0xFF059669);
  @override Color get warning => const Color(0xFFD97706);
  @override Color get textSecondary => _lightTextSecondary;
  @override Color get onSurface => _lightOnSurface;
  @override Color get onPrimary => Colors.white;
  @override Color get snackBarBackground => _lightSnackBg;
}
class LavenderHue extends ThemeHue {
  @override String get name => '라벤더';
  @override ThemePreset get light => LavenderLightPreset();
  @override ThemePreset get dark => LavenderDarkPreset();
}

// ─────────────────────────────────────────────────────────────────
// 세이지 (자연 초록 — Notion/Things 감성) — 신규
// ─────────────────────────────────────────────────────────────────
class SageDarkPreset extends ThemePreset {
  @override String get name => '세이지 다크';
  @override Brightness get brightness => Brightness.dark;
  @override Color get primary => const Color(0xFF34D399);          // emerald-400
  @override Color get background => const Color(0xFF0A1410);
  @override Color get surface => const Color(0xFF162018);
  @override Color get error => const Color(0xFFEF4444);
  @override Color get success => const Color(0xFF10B981);
  @override Color get warning => const Color(0xFFF59E0B);
  @override Color get textSecondary => const Color(0xFF9CA3AF);
  @override Color get onSurface => Colors.white;
  @override Color get onPrimary => Colors.black;
  @override Color get snackBarBackground => _darkSnackBg;
}
class SageLightPreset extends ThemePreset {
  @override String get name => '세이지 라이트';
  @override Brightness get brightness => Brightness.light;
  @override Color get primary => const Color(0xFF059669);          // emerald-600
  @override Color get background => const Color(0xFFF0FDF4);       // green-50
  @override Color get surface => Colors.white;
  @override Color get error => const Color(0xFFDC2626);
  @override Color get success => const Color(0xFF059669);
  @override Color get warning => const Color(0xFFD97706);
  @override Color get textSecondary => _lightTextSecondary;
  @override Color get onSurface => _lightOnSurface;
  @override Color get onPrimary => Colors.white;
  @override Color get snackBarBackground => _lightSnackBg;
}
class SageHue extends ThemeHue {
  @override String get name => '세이지';
  @override ThemePreset get light => SageLightPreset();
  @override ThemePreset get dark => SageDarkPreset();
}

// ─────────────────────────────────────────────────────────────────
// 모노 (미니멀 — Planfit 스타일, 무채색 컨셉)
// ─────────────────────────────────────────────────────────────────
class MonoDarkPreset extends ThemePreset {
  @override String get name => '모노 다크';
  @override Brightness get brightness => Brightness.dark;
  @override Color get primary => Colors.white;
  @override Color get background => const Color(0xFF0A0A0A);
  @override Color get surface => const Color(0xFF1A1A1A);
  @override Color get error => const Color(0xFFDC2626);
  @override Color get success => const Color(0xFF9CA3AF);          // 무채색 컨셉 유지
  @override Color get warning => const Color(0xFFA3A3A3);
  @override Color get textSecondary => const Color(0xFF737373);
  @override Color get onSurface => Colors.white;
  @override Color get onPrimary => Colors.black;
  @override Color get snackBarBackground => _darkSnackBg;
}
class MonoLightPreset extends ThemePreset {
  @override String get name => '모노 라이트';
  @override Brightness get brightness => Brightness.light;
  @override Color get primary => Colors.black;
  @override Color get background => const Color(0xFFFAFAFA);
  @override Color get surface => Colors.white;
  @override Color get error => const Color(0xFFDC2626);
  @override Color get success => const Color(0xFF6B7280);          // 무채색 컨셉 유지
  @override Color get warning => const Color(0xFF737373);
  @override Color get textSecondary => _lightTextSecondary;
  @override Color get onSurface => _lightOnSurface;
  @override Color get onPrimary => Colors.white;
  @override Color get snackBarBackground => _lightSnackBg;
}
class MonoHue extends ThemeHue {
  @override String get name => '모노';
  @override ThemePreset get light => MonoLightPreset();
  @override ThemePreset get dark => MonoDarkPreset();
}

// ─────────────────────────────────────────────────────────────────
// 전역 hue 목록 — 여기 추가하면 스위처에 자동 노출
// ─────────────────────────────────────────────────────────────────
final List<ThemeHue> allHues = [
  AmberHue(),
  MintHue(),
  OceanHue(),
  RoseHue(),
  LavenderHue(),
  SageHue(),
  MonoHue(),
];
