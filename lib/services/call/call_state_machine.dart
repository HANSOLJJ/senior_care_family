import 'package:flutter/foundation.dart';

/// (`Enum`) 통화/모니터링 세션의 생명주기 단계
///
/// WebRtcService 가 보유한 CallStateMachine 의 현재 `phase`.
/// - [idle] → [connecting] 으로만 진입 (make\*/start\* 호출).
/// - [connected] 에서 1:1 통화 업그레이드 시 [upgrading], ICE DISCONNECTED 시 [reconnecting] 으로 전이.
/// - 종결은 항상 [terminating] 경유 후 [terminated] terminal.
///
/// Transition matrix:
/// ```
/// idle         → connecting | terminating
/// connecting   → connected  | terminating
/// connected    → upgrading  | reconnecting | terminating
/// upgrading    → connected  | reconnecting | terminating
/// reconnecting → connected  | terminating
/// terminating  → terminated
/// terminated   → (terminal)
/// ```
enum CallPhase {
  idle,
  connecting,
  connected,
  upgrading,
  reconnecting,
  terminating,
  terminated,
}

/// (`Enum`) 세션 종결 사유 — [CallStateMachine.terminate] 에서 세팅되어
/// MonitoringScreen 의 dialog/snackbar/pop 매핑에 사용.
///
/// MonitoringScreen 의 매핑:
/// | reason | 반응 |
/// |---|---|
/// | userHangup, remoteEnded, orphanCleaned | 즉시 pop |
/// | unreachable, noAcceptance, networkLost, networkOffline, remoteBusy, endedByOtherCall, capacityExceeded | 다이얼로그/SnackBar → pop |
/// | upgradeFailed | SnackBar 표시 + pop (hangUp 으로 PC 해제됨) |
enum TerminateReason {
  /// 사용자 종료 버튼
  userHangup,

  /// Senior 측 status="ended" + endReason="normal" 수신
  remoteEnded,

  /// Phase 1 timeout (5s 내 answer 없음)
  unreachable,

  /// Phase 2 timeout (20s 내 수락 없음, call 타입 전용)
  noAcceptance,

  /// ICE restart 1회 시도 실패 (answer 10s 미수신 또는 RTDB write 실패)
  /// 또는 PC DISCONNECTED 상태에서 endReason 수신 (iOS wifi flap 떠받치기)
  networkLost,

  /// monitor → call renegotiate answer 미수신
  upgradeFailed,

  /// createCall 과 hangUp race → 생성된 call 정리됨
  orphanCleaned,

  /// createCall RTDB write timeout (공항모드 등)
  networkOffline,

  /// Senior 가 이미 다른 가족과 통화 중 (endReason="remoteBusy")
  remoteBusy,

  /// 다른 가족이 통화 시작하여 내 모니터링이 displaced (endReason="otherCallStarted")
  endedByOtherCall,

  /// 동시 모니터링 최대치(MAX_PEERS=3) 초과 (endReason="capacityExceeded")
  capacityExceeded,
}

/// 상태별 허용 전이 맵. transition matrix 를 코드로 표현.
const Map<CallPhase, Set<CallPhase>> _allowedTransitions = {
  CallPhase.idle: {CallPhase.connecting, CallPhase.terminating},
  // connecting → upgrading: 이례적이지만 Senior가 answer 보내기 전에 이미 accept 해버린
  // race 시 startCall 경로의 seniorAccepted 감지에서 호출됨. 허용.
  CallPhase.connecting: {
    CallPhase.connected,
    CallPhase.upgrading,
    CallPhase.terminating,
  },
  CallPhase.connected: {
    CallPhase.upgrading,
    CallPhase.reconnecting,
    CallPhase.terminating,
  },
  CallPhase.upgrading: {
    CallPhase.connected,
    CallPhase.reconnecting,
    CallPhase.terminating,
  },
  CallPhase.reconnecting: {CallPhase.connected, CallPhase.terminating},
  CallPhase.terminating: {CallPhase.terminated},
  CallPhase.terminated: <CallPhase>{},
};

/// (`Class`) 통화/모니터링 세션 상태 머신
///
/// WebRtcService 가 내부 `_fsm` 필드로 보유. 모든 상태 전이는
/// [to] (허용 전이) 또는 [terminate] (종결) 로만 수행.
///
/// - **invariant**: [terminated] 진입 후 어떤 상태로도 복귀 불가. [terminate] 는 idempotent.
/// - **observability**: 모든 전이에 `reason` 태깅 + debug 로그 출력.
/// - **UI 구독**: [phase] ValueNotifier 를 MonitoringScreen 이 구독.
class CallStateMachine {
  /// 현재 생명주기 단계 (MonitoringScreen 에 노출 — ValueListenableBuilder 구독).
  final ValueNotifier<CallPhase> phase = ValueNotifier(CallPhase.idle);

  /// [terminated] 진입 직전 [terminate] 가 기록한 사유. MonitoringScreen 이 읽어 UX 매핑.
  TerminateReason? reason;

  /// (`Method`) 다음 상태로 전이. 허용되지 않으면 경고 로그 + false 반환.
  ///
  /// - **Params**:
  ///   - [next] — 전이할 목표 상태
  ///   - [reason] — 전이 이유 (로그용 간결 문자열 — 예: "answer_received", "peer_disconnected")
  /// - **Returns**: `bool` — 전이 성공 여부 (예외 안 던짐, async race 방어)
  /// - **Side Effects**: [phase] notifier 업데이트, debug 로그 출력
  bool to(CallPhase next, {required String reason}) {
    final current = phase.value;
    final allowed = _allowedTransitions[current] ?? const <CallPhase>{};
    if (!allowed.contains(next)) {
      debugPrint('[FSM] ⚠️ INVALID $current → $next (reason: $reason)');
      return false;
    }
    debugPrint('[FSM] $current → $next (reason: $reason)');
    phase.value = next;
    return true;
  }

  /// (`Method`) 세션 종결 — idempotent.
  ///
  /// [terminating] → [terminated] 2단계 전이를 sync 로 실행.
  /// 이미 [terminated] 면 no-op (중복 종결 안전).
  ///
  /// - **Params**:
  ///   - [r] — 종결 사유 ([TerminateReason]). MonitoringScreen 이 읽어 UX 매핑.
  /// - **Side Effects**: [reason] 세팅, [phase] 두 번 업데이트
  void terminate(TerminateReason r) {
    if (phase.value == CallPhase.terminated) return;
    reason = r;
    if (phase.value != CallPhase.terminating) {
      // reason 을 로그에 포함시키기 위해 enum 이름 사용
      to(CallPhase.terminating, reason: 'terminate:${r.name}');
    }
    to(CallPhase.terminated, reason: 'terminate:${r.name}');
  }

  /// (`Getter`) [terminating] 또는 [terminated] 상태인지 — async 경로 early-return 가드용.
  bool get isEnding =>
      phase.value == CallPhase.terminating ||
      phase.value == CallPhase.terminated;

  /// (`Getter`) 완전 종결 여부 ([terminated]).
  bool get isTerminated => phase.value == CallPhase.terminated;

  /// (`Lifecycle`) 리소스 해제 — WebRtcService.dispose 에서 호출.
  void dispose() {
    phase.dispose();
  }
}
