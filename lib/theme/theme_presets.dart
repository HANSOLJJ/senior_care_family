import 'package:flutter/material.dart';
import 'app_theme.dart';

/// 앰버 (따뜻한 오렌지 계열 — 시니어 케어 친근감)
class AmberPreset extends ThemePreset {
  @override String get name => '앰버';
  @override Color get primary => const Color(0xFFFBBF24);         // amber-400
  @override Color get background => const Color(0xFF111111);
  @override Color get surface => const Color(0xFF1E1E1E);
  @override Color get error => const Color(0xFFEF4444);
  @override Color get success => const Color(0xFF10B981);         // emerald-500
  @override Color get warning => const Color(0xFFF59E0B);         // amber-500 (조금 어두운)
  @override Color get textSecondary => const Color(0xFF9CA3AF);
}

/// 민트 (차갑고 모던 — 헬스케어)
class MintPreset extends ThemePreset {
  @override String get name => '민트';
  @override Color get primary => const Color(0xFF2DD4BF);         // teal-400
  @override Color get background => const Color(0xFF0F1419);
  @override Color get surface => const Color(0xFF1A2229);
  @override Color get error => const Color(0xFFF87171);           // red-400 (조금 소프트)
  @override Color get success => const Color(0xFF14B8A6);         // teal-500
  @override Color get warning => const Color(0xFFFB923C);         // orange-400
  @override Color get textSecondary => const Color(0xFF94A3B8);
}

/// 모노 (미니멀 — Planfit 스타일)
class MonoPreset extends ThemePreset {
  @override String get name => '모노';
  @override Color get primary => Colors.white;
  @override Color get background => const Color(0xFF0A0A0A);
  @override Color get surface => const Color(0xFF1A1A1A);
  @override Color get error => const Color(0xFFDC2626);           // red-600 (진한 빨강)
  @override Color get success => const Color(0xFF9CA3AF);         // gray-400 (무채색)
  @override Color get warning => const Color(0xFFA3A3A3);         // neutral-400
  @override Color get textSecondary => const Color(0xFF737373);
}

/// 오션 (차가운 파랑 — 신뢰감)
class OceanPreset extends ThemePreset {
  @override String get name => '오션';
  @override Color get primary => const Color(0xFF60A5FA);         // blue-400
  @override Color get background => const Color(0xFF0B1220);      // 깊은 네이비
  @override Color get surface => const Color(0xFF1A2332);
  @override Color get error => const Color(0xFFF87171);
  @override Color get success => const Color(0xFF22D3EE);         // cyan-400 (파랑 계열 조화)
  @override Color get warning => const Color(0xFFFBBF24);
  @override Color get textSecondary => const Color(0xFF94A3B8);
}

/// 로즈 (분홍-보라 — 따뜻하면서 모던)
class RosePreset extends ThemePreset {
  @override String get name => '로즈';
  @override Color get primary => const Color(0xFFF472B6);         // pink-400
  @override Color get background => const Color(0xFF140A14);      // 보라빛 다크
  @override Color get surface => const Color(0xFF241620);
  @override Color get error => const Color(0xFFEF4444);
  @override Color get success => const Color(0xFF34D399);
  @override Color get warning => const Color(0xFFC084FC);         // violet-400 (핑크 계열 조화)
  @override Color get textSecondary => const Color(0xFF9CA3AF);   // gray-400 (다른 프리셋과 통일)
}

/// 전역 프리셋 목록 — 여기 추가하면 dev 스위처에 자동 노출
final List<ThemePreset> allPresets = [
  AmberPreset(),
  MintPreset(),
  OceanPreset(),
  RosePreset(),
  MonoPreset(),
];
