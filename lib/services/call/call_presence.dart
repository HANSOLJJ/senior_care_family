import 'package:flutter/widgets.dart';

/// 앱 전역 통화 활성 상태 (`Service`, singleton-style static)
///
/// [MonitoringScreen] 이 initState 에서 true, dispose 에서 false 로 설정한다.
///
/// [OfflineOverlay] 가 구독해 통화 중에는 자신을 숨김 — MonitoringScreen 의
/// reconnecting 오버레이(call-specific 맥락)와 전역 오프라인 오버레이가
/// 동시에 쌓이는 UX 중복을 방지. 통화 중 네트워크 끊김 시엔
/// "연결이 불안정해요" 오버레이만 남고, 오프라인 오버레이는 비통화 화면
/// (FamilyDetail/사진/알림 등)에서만 블로킹 가드 역할을 계속 수행한다.
///
/// 패턴은 [ConnectivityService.instance.isOnline] 과 동일.
class CallPresence {
  CallPresence._();

  /// 현재 MonitoringScreen 이 live 상태인지 여부.
  /// 구독: `ValueListenableBuilder<bool>(valueListenable: CallPresence.inCall, ...)`
  static final ValueNotifier<bool> inCall = ValueNotifier<bool>(false);
}
