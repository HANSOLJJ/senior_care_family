import 'package:flutter/material.dart';
import '../services/call/call_presence.dart';
import '../services/connectivity_service.dart';

/// 네트워크 오프라인 시 자식 위젯 위에 전체 화면 블로킹 오버레이를 띄우는 래퍼
///
/// [ConnectivityService.isOnline] + [CallPresence.inCall] 두 값을 감시.
///   - `!online && !inCall` → 오버레이 표시 (기존 블로킹 UX)
///   - `!online && inCall` → suppress (MonitoringScreen 의 reconnecting 오버레이가
///     call-specific 맥락을 이미 제공하므로 중복 표시 안 함)
///   - `online` → 자식만 표시
///
/// MaterialApp.builder 에 래핑하여 앱 전역 적용.
class OfflineOverlay extends StatefulWidget {
  final Widget child;

  const OfflineOverlay({super.key, required this.child});

  @override
  State<OfflineOverlay> createState() => _OfflineOverlayState();
}

class _OfflineOverlayState extends State<OfflineOverlay> {
  @override
  void initState() {
    super.initState();
    ConnectivityService.instance.isOnline.addListener(_onConnectivityChanged);
    CallPresence.inCall.addListener(_onCallChanged);
  }

  @override
  void dispose() {
    ConnectivityService.instance.isOnline.removeListener(_onConnectivityChanged);
    CallPresence.inCall.removeListener(_onCallChanged);
    super.dispose();
  }

  // isOnline 은 항상 Timer/RTDB 콜백에서 변경 → idle phase → 즉시 setState 가능
  void _onConnectivityChanged() {
    if (mounted) setState(() {});
  }

  // inCall 은 항상 MonitoringScreen initState/dispose 중 변경 → build phase →
  // addPostFrameCallback 으로 defer 해야 setState 가 처리됨
  void _onCallChanged() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final online = ConnectivityService.instance.isOnline.value;
    final inCall = CallPresence.inCall.value;
    final showOverlay = !online && !inCall;
    return Stack(
      children: [
        widget.child,
        if (showOverlay)
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
  }
}
