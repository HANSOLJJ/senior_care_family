import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../theme/theme_presets.dart';

/// 테마 hue 런타임 전환 버튼 (`Widget`)
///
/// AppBar actions 에 넣으면 팔레트 아이콘 표시 → 탭 시 hue 목록 팝업 →
/// 선택 시 [ThemeController]가 갱신되어 앱 전체 색상 즉시 전환.
/// 다크/라이트 변형은 OS 시스템 모드가 결정 (사용자 선택 없음).
///
/// - **호출**: AppBar 등 actions 영역
class ThemeSwitcherButton extends StatelessWidget {
  const ThemeSwitcherButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeHue>(
      valueListenable: ThemeController.currentHue,
      builder: (context, current, _) {
        // 미리보기 점은 현재 OS 모드 기준 primary 사용 — 사용자에게 보이는 색과 일치
        final brightness = MediaQuery.platformBrightnessOf(context);
        final isDark = brightness == Brightness.dark;
        final borderColor = isDark ? Colors.white24 : Colors.black26;
        return PopupMenuButton<ThemeHue>(
          icon: const Icon(Icons.palette_outlined),
          tooltip: '테마 변경',
          onSelected: (hue) {
            HapticFeedback.selectionClick();
            ThemeController.set(hue);
          },
          itemBuilder: (_) => allHues.map((hue) {
            final selected = hue.runtimeType == current.runtimeType;
            final swatch = isDark ? hue.dark.primary : hue.light.primary;
            return PopupMenuItem<ThemeHue>(
              value: hue,
              child: Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: swatch,
                      shape: BoxShape.circle,
                      border: Border.all(color: borderColor),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(hue.name),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.check, size: 16),
                  ],
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }
}
