import 'package:flutter/material.dart';
import '../services/connectivity_service.dart';

/// 네트워크 오프라인 시 자식 위젯 위에 전체 화면 블로킹 오버레이를 띄우는 래퍼 (`StatelessWidget`)
///
/// [ConnectivityService.isOnline] 값을 감시하여 false면 반투명 오버레이 표시,
/// true면 자식만 표시. MaterialApp의 builder에 래핑하여 앱 전역 적용.
///
/// 오버레이 구성: 📡 아이콘 + "네트워크 연결 끊김" + 자동 복구 안내.
/// 복구 시도 버튼은 별도 동작 없음 — ConnectivityService가 자동 감지 후 사라짐.
class OfflineOverlay extends StatelessWidget {
  /// 감싸는 자식 위젯 (앱 전체)
  final Widget child;

  const OfflineOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.isOnline,
      builder: (context, online, _) {
        return Stack(
          children: [
            child,
            if (!online)
              Positioned.fill(
                child: Material(
                  color: Colors.black.withValues(alpha: 0.85),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.wifi_off,
                          size: 72,
                          color: Colors.white70,
                        ),
                        const SizedBox(height: 24),
                        const Text(
                          '네트워크 연결 끊김',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '연결이 복구되면 자동으로 다시 시작됩니다',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
