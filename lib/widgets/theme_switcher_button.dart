import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../theme/theme_presets.dart';

/// 테마 프리셋 런타임 전환 버튼 (`Widget`)
///
/// AppBar actions 에 넣으면 팔레트 아이콘 표시 → 탭 시 프리셋 목록 팝업 →
/// 선택 시 [ThemeController]가 갱신되어 앱 전체 색상 즉시 전환.
///
/// - **호출**: AppBar 등 actions 영역
class ThemeSwitcherButton extends StatelessWidget {
  const ThemeSwitcherButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemePreset>(
      valueListenable: ThemeController.current,
      builder: (context, current, _) => PopupMenuButton<ThemePreset>(
        icon: const Icon(Icons.palette_outlined),
        tooltip: '테마 변경',
        onSelected: (preset) {
          HapticFeedback.selectionClick();
          ThemeController.set(preset);
        },
        itemBuilder: (_) => allPresets.map((preset) {
          final selected = preset.runtimeType == current.runtimeType;
          return PopupMenuItem<ThemePreset>(
            value: preset,
            child: Row(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: preset.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white24),
                  ),
                ),
                const SizedBox(width: 12),
                Text(preset.name),
                if (selected) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.check, size: 16),
                ],
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}
