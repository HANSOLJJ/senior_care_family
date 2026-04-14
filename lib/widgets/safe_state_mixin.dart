import 'package:flutter/widgets.dart';

/// async 콜백에서 안전하게 setState 호출 (`Mixin`)
///
/// `if (mounted) setState(...)` 보일러플레이트 제거. State가 이미 dispose된 후
/// async 콜백이 늦게 도착해도 NoSuchMethodError 안 남.
///
/// 사용:
/// ```
/// class _FooState extends State<Foo> with SafeStateMixin { ... }
/// safeSetState(() => _value = newValue);
/// ```
mixin SafeStateMixin<T extends StatefulWidget> on State<T> {
  /// mounted 체크 후 setState 실행. dispose 후엔 no-op.
  void safeSetState(VoidCallback fn) {
    if (mounted) setState(fn);
  }
}
