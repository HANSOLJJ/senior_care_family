import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_database/firebase_database.dart';

/// 앱 전역 네트워크 연결 상태 감시 서비스 (`Service`, singleton)
///
/// 두 스트림을 OR 결합해서 "현재 네트워크를 통해 RTDB에 도달 가능한지" 판단:
///   - `connectivity_plus`: OS 네트워크 인터페이스 (Wi-Fi/모바일/none). 빠른 감지.
///   - Firebase `/.info/connected`: 실제 RTDB WebSocket 도달 여부. 캡티브 포털/DNS 장애 커버.
///
/// 둘 중 하나라도 offline이면 offline으로 판단. 순간 끊김 오탐 방지를 위해
/// offline 전이는 3초 debounce, online 전이는 즉시 반영.
///
/// 사용: `ConnectivityService.instance.isOnline.value` 또는
/// `ValueListenableBuilder<bool>(valueListenable: ConnectivityService.instance.isOnline, ...)`
class ConnectivityService with WidgetsBindingObserver {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  /// 외부 구독용. true=online, false=offline (debounce 적용 후 최종값).
  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);

  StreamSubscription<List<ConnectivityResult>>? _osSub;
  StreamSubscription<DatabaseEvent>? _rtdbSub;
  Timer? _offlineDebounce;

  bool _osOnline = true;
  bool _rtdbOnline = true;
  bool _started = false;

  /// 포그라운드 복귀 후 RTDB 재연결 유예 시간 (Firebase WebSocket 재연결 버퍼).
  /// 이 기간엔 `/.info/connected=false`는 무시하고 OS 네트워크만 판단 기준으로 사용.
  DateTime? _resumeGraceUntil;
  static const Duration _resumeGrace = Duration(seconds: 5);

  /// 감시 시작. main() 또는 app.dart 초기화 시 1회 호출.
  void start() {
    if (_started) return;
    _started = true;

    WidgetsBinding.instance.addObserver(this);

    _osSub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      _osOnline = online;
      _recompute();
    });
    // 초기 값 조회
    Connectivity().checkConnectivity().then((results) {
      _osOnline = results.any((r) => r != ConnectivityResult.none);
      _recompute();
    });

    _rtdbSub = FirebaseDatabase.instance.ref('.info/connected').onValue.listen((e) {
      _rtdbOnline = e.snapshot.value == true;
      _recompute();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumeGraceUntil = DateTime.now().add(_resumeGrace);
      // grace period 동안 가능한 한 online 유지하도록 재평가
      _recompute();
    }
  }

  /// (`Method`) 두 소스 상태 합쳐 최종 isOnline 갱신
  ///
  /// - offline 전이: 3초 debounce (순간 끊김 필터)
  /// - online 전이: 즉시 반영 (복구는 빠르게)
  void _recompute() {
    // 포그라운드 복귀 직후 grace period 동안은 RTDB 재연결 대기 중이므로
    // /.info/connected=false를 무시하고 OS 네트워크만으로 판단.
    final inGrace = _resumeGraceUntil != null &&
        DateTime.now().isBefore(_resumeGraceUntil!);
    final rtdbEffective = inGrace ? true : _rtdbOnline;
    final combined = _osOnline && rtdbEffective;
    if (combined) {
      _offlineDebounce?.cancel();
      _offlineDebounce = null;
      if (isOnline.value != true) isOnline.value = true;
    } else {
      if (_offlineDebounce != null) return;
      _offlineDebounce = Timer(const Duration(seconds: 3), () {
        if (!(_osOnline && _rtdbOnline)) {
          isOnline.value = false;
        }
      });
    }
  }

  void dispose() {
    _osSub?.cancel();
    _rtdbSub?.cancel();
    _offlineDebounce?.cancel();
  }
}
