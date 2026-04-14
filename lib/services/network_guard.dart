import 'dart:async';

/// 네트워크 오프라인 시 쓰기가 Firebase 로컬 큐에 쌓여
/// 복구 시점에 한꺼번에 flush되는 문제를 방지하기 위한 예외.
class NetworkException implements Exception {
  final String message;
  NetworkException(this.message);
  @override
  String toString() => 'NetworkException: $message';
}

/// 사용자 직접 탭으로 트리거되는 "진입 쓰기"에 기본 적용할 타임아웃.
/// 서버 ACK가 [defaultWriteTimeout] 내에 오지 않으면 오프라인으로 판단.
const Duration defaultWriteTimeout = Duration(seconds: 5);

/// Firebase 쓰기를 타임아웃으로 감싸 오프라인 큐잉을 차단한다.
///
/// Firebase RTDB의 `set()`/`update()`/`remove()`는 offline 상태에서
/// 즉시 성공 Future를 반환하지 않고, 서버 ACK 후에야 resolve된다.
/// 따라서 일정 시간 안에 resolve되지 않으면 네트워크 문제로 간주할 수 있다.
///
/// - [op] 실행할 쓰기 Future (예: `() => ref.set(...)`).
/// - [label] 실패 메시지에 쓸 작업 이름.
/// - [timeout] 기본 5초.
/// - [onTimeoutCleanup] 타임아웃 시 추가 정리 (예: 부분 생성된 노드 제거).
/// 실패 시 [NetworkException] throw.
Future<T> writeOrTimeout<T>(
  Future<T> Function() op, {
  required String label,
  Duration timeout = defaultWriteTimeout,
  Future<void> Function()? onTimeoutCleanup,
}) async {
  try {
    return await op().timeout(timeout);
  } on TimeoutException {
    if (onTimeoutCleanup != null) {
      try {
        await onTimeoutCleanup();
      } catch (_) {
        // cleanup 실패는 무시 (복구 시 서버에서 처리됨)
      }
    }
    throw NetworkException('$label 전송 실패 — 네트워크를 확인해주세요');
  }
}
