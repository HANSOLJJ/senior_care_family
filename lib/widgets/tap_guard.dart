import 'package:flutter/foundation.dart';

/// (`Utility`) 비동기 액션의 중복 호출 방지 + busy 상태 감시
///
/// 버튼을 빠르게 두 번 탭해도 `run()` 내부 action은 한 번만 실행됨.
/// UI는 [isBusy] ValueNotifier를 구독해서 disabled 상태 / 스피너 표시.
///
/// - 각 State에서 버튼별 가드 객체 1개 생성
/// - State.dispose()에서 반드시 `guard.dispose()` 호출
///
/// 예시:
/// ```
/// final _callGuard = TapGuard();
/// ...
/// AsyncActionButton(guard: _callGuard, onPressed: _callDevice, ...);
/// ...
/// @override void dispose() { _callGuard.dispose(); super.dispose(); }
/// ```
class TapGuard {
  /// busy 상태 — true 동안 [run] 호출 무시됨
  final ValueNotifier<bool> isBusy = ValueNotifier(false);

  /// (`Method`, async) action 실행 — 진행 중이면 무시
  ///
  /// - **Params**:
  ///   - [action] — 실행할 비동기 함수
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: isBusy true/false 토글, 예외 발생해도 finally에서 복원
  Future<void> run(Future<void> Function() action) async {
    if (isBusy.value) return;
    isBusy.value = true;
    try {
      await action();
    } finally {
      isBusy.value = false;
    }
  }

  /// (`Lifecycle`) ValueNotifier 해제
  void dispose() => isBusy.dispose();
}
