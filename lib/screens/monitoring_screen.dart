import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call/signaling_service.dart';
import '../services/call/webrtc_service.dart';

/// (`StatefulWidget`) 모니터링 / 통화 통합 화면
///
/// Senior 기기에 대한 CCTV 모니터링 또는 양방향 영상통화를 수행하는 화면.
/// [callType] 파라미터에 따라 동작 모드가 결정된다:
///   - `"monitor"`: 무음 CCTV (Senior 인지 불가, 단방향 영상 수신)
///   - `"call"`: 벨소리 + Senior 수락 대기 → 양방향 영상통화 전환
///
/// 화면 구성:
///   - 전체화면 원격 영상 (Senior 카메라)
///   - 로컬 PIP (통화 모드 또는 업그레이드 후)
///   - 상단 상태 배지 (모니터링/수락 대기/통화 중)
///   - 하단 버튼 (통화 전환, 종료)
class MonitoringScreen extends StatefulWidget {
  /// 연결 대상 Senior 기기 ID (RTDB `/devices/{deviceId}`)
  final String targetDeviceId;

  /// 연결 대상 기기 표시 이름 (연결 대기 UI에 표시)
  final String targetDeviceName;

  /// 통화 유형: `"monitor"` (CCTV) 또는 `"call"` (영상통화)
  final String callType;

  /// 소속 가족 그룹 ID (callStatus 감시에 사용)
  final String? familyId;

  const MonitoringScreen({
    super.key,
    required this.targetDeviceId,
    required this.targetDeviceName,
    this.callType = 'monitor',
    this.familyId,
  });

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

/// (`State`) [MonitoringScreen]의 State
///
/// WebRTC 연결 수립, 로컬/원격 비디오 렌더링, 통화 전환(monitor→call), 종료 처리를 담당.
/// 생명주기: initState → _startMonitoring/_startCall → 연결 대기 → 연결 완료 → dispose
class _MonitoringScreenState extends State<MonitoringScreen> {
  // ─── 서비스 ───

  /// RTDB 시그널링 서비스 인스턴스
  final SignalingService _signaling = SignalingService();

  /// WebRTC 피어 연결 + 미디어 스트림 관리 서비스
  late final WebRtcService _webrtc;

  // ─── 상태 필드 ───

  /// 원격 영상 스트림 수신 완료 여부
  bool _connected = false;

  /// 연결 시도 중 여부 (로딩 UI 표시 제어)
  bool _connecting = true;

  /// 모니터링 → 양방향 통화 전환 완료 여부
  bool _upgraded = false;

  /// callType="call" 전용: Senior 수락 대기 중 여부
  bool _waitingAcceptance = false;

  /// 다른 가족 구성원이 이미 통화 중인지 여부 (통화 전환 버튼 숨김 제어)
  bool _callActiveByOther = false;

  // ─── 타이머 / 구독 ───

  /// 연결 타임아웃 타이머 (모니터링 30초, 통화 60초)
  Timer? _timeoutTimer;

  /// 원격 스트림 수신 확인용 폴링 타이머 (500ms 주기)
  Timer? _connectionCheckTimer;

  /// 양방향 전환 완료 감지용 폴링 타이머 (300ms 주기)
  Timer? _upgradeCheckTimer;

  /// `families/{fid}/callStatus/active` 실시간 감시 구독
  StreamSubscription? _callStatusSub;

  // ─── 계산 속성 ───

  /// (`Getter`) 현재 모드가 통화(call)인지 여부
  bool get _isCall => widget.callType == 'call';

  // ─── 생명주기 ───

  /// (`Lifecycle`) 초기화 — WebRTC 서비스 생성 + 모드별 연결 시작
  ///
  /// - **Side Effects**: _webrtc 인스턴스 생성, 콜백 등록, 모드별 연결 시작
  /// - **호출**: Flutter 프레임워크 (위젯 생성 시)
  @override
  void initState() {
    super.initState();
    _webrtc = WebRtcService(_signaling);
    _webrtc.onCallEnded = _onRemoteEnd;
    if (_isCall) {
      _startCall();
    } else {
      _startMonitoring();
    }
    // 모니터링 중 다른 가족이 통화 시작하면 전환 버튼 숨김
    if (!_isCall && widget.familyId != null) {
      _callStatusSub = FirebaseDatabase.instance
          .ref('families/${widget.familyId}/callStatus/active')
          .onValue
          .listen((event) {
        if (mounted) {
          setState(() {
            _callActiveByOther = event.snapshot.value == true;
          });
        }
      });
    }
  }

  // ─── 연결 메서드 ───

  /// (`Method`, async) CCTV 모니터링 시작 — 단방향 영상 수신
  ///
  /// - **Side Effects**: WebRTC 초기화 + 모니터링 발신 + 연결 대기 타이머 시작
  /// - **호출**: [initState] (callType="monitor" 시)
  Future<void> _startMonitoring() async {
    try {
      await _webrtc.initialize();
      final user = FirebaseAuth.instance.currentUser;
      await _webrtc.startMonitoring(
        widget.targetDeviceId,
        callerUid: user?.uid,
        callerName: user?.displayName ?? '가족',
        familyId: widget.familyId,
      );
      _waitForConnection();
    } catch (e) {
      _handleError(e);
    }
  }

  /// (`Method`, async) 영상통화 발신 — RecvOnly로 시작 → Senior 수락 후 양방향 전환
  ///
  /// - **Side Effects**: WebRTC 초기화 + 통화 발신 + 연결/수락 대기 타이머 시작
  /// - **호출**: [initState] (callType="call" 시)
  Future<void> _startCall() async {
    try {
      await _webrtc.initialize();
      final user = FirebaseAuth.instance.currentUser;
      await _webrtc.startCall(
        widget.targetDeviceId,
        callerUid: user?.uid,
        callerName: user?.displayName ?? '가족',
        familyId: widget.familyId,
      );

      // 연결되면 수락 대기 UI 표시
      _connectionCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (!mounted) { timer.cancel(); return; }
        if (_webrtc.remoteRenderer.srcObject != null && !_connected) {
          timer.cancel();
          setState(() {
            _connected = true;
            _connecting = false;
            _waitingAcceptance = true; // Senior 수락 대기
          });
          _timeoutTimer?.cancel();
          // Senior 수락 후 upgradeToCall 완료 감지
          _watchUpgrade();
        }
      });

      // 60초 타임아웃
      _timeoutTimer = Timer(const Duration(seconds: 60), () {
        if (_connecting && !_connected && mounted) _hangUp();
      });
    } catch (e) {
      _handleError(e);
    }
  }

  /// (`Method`) 연결 대기 — 원격 스트림 수신까지 폴링 + 타임아웃 설정
  ///
  /// - **Side Effects**: _timeoutTimer (30초), _connectionCheckTimer (500ms 폴링) 시작
  /// - **호출**: [_startMonitoring]
  void _waitForConnection() {
    // 30초 타임아웃
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_connecting && !_connected && mounted) _hangUp();
    });

    _connectionCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_webrtc.remoteRenderer.srcObject != null && !_connected) {
        timer.cancel();
        setState(() { _connected = true; _connecting = false; });
        _timeoutTimer?.cancel();
      }
    });
  }

  /// (`Method`) Senior 수락 후 양방향 전환 완료 감지
  ///
  /// WebRTC의 isMonitoring이 false로 변하면 양방향 전환 완료로 판단.
  /// - **Side Effects**: _upgradeCheckTimer (300ms 폴링) 시작, _upgraded/_waitingAcceptance 상태 변경
  /// - **호출**: [_startCall] (연결 확인 후)
  void _watchUpgrade() {
    _upgradeCheckTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (!_webrtc.isMonitoring && _waitingAcceptance) {
        timer.cancel();
        setState(() {
          _upgraded = true;
          _waitingAcceptance = false;
        });
      }
    });
  }

  // ─── 통화 제어 ───

  /// (`Callback`) 상대방(Senior)이 통화를 종료했을 때 호출
  ///
  /// - **Side Effects**: 현재 화면 pop
  /// - **호출**: WebRtcService.onCallEnded 콜백
  void _onRemoteEnd() {
    if (mounted) Navigator.of(context).pop();
  }

  /// (`Method`, async) 통화/모니터링 종료 — 리소스 정리 + 화면 pop
  ///
  /// - **Side Effects**: 타이머 취소, WebRTC hangUp, 화면 pop
  /// - **호출**: 종료 버튼, 타임아웃
  Future<void> _hangUp() async {
    _timeoutTimer?.cancel();
    await _webrtc.hangUp();
    if (mounted) Navigator.of(context).pop();
  }

  /// (`Method`, async) 모니터링 → 양방향 통화 수동 전환
  ///
  /// 모니터링 화면의 "통화 전환" 버튼을 누를 때 호출.
  /// WebRTC renegotiation을 통해 SendRecv로 전환 후 양방향 완료를 폴링 감지.
  /// - **Side Effects**: _upgraded 상태 변경, WebRTC upgradeToCall 호출
  /// - **호출**: 하단 "통화 전환" 버튼 onPressed
  Future<void> _upgradeToCall() async {
    if (_upgraded) return;
    setState(() => _upgraded = true);
    try {
      await _webrtc.upgradeToCall();
      _upgradeCheckTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
        if (!mounted) { timer.cancel(); return; }
        if (!_webrtc.isMonitoring) {
          timer.cancel();
          setState(() {});
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('통화 전환 실패: $e')),
        );
        setState(() => _upgraded = false);
      }
    }
  }

  // ─── 에러 처리 ───

  /// (`Method`) 연결 실패 에러 처리 — SnackBar 표시 + 화면 pop
  ///
  /// - **Params**:
  ///   - [e] — 발생한 에러 객체
  /// - **Side Effects**: SnackBar 표시, 화면 pop
  /// - **호출**: [_startMonitoring], [_startCall]
  void _handleError(Object e) {
    print('연결 실패: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('연결 실패: $e')),
      );
      Navigator.of(context).pop();
    }
  }

  // ─── 생명주기 ───

  /// (`Lifecycle`) 리소스 해제 — 타이머, 구독, WebRTC, 시그널링 정리
  ///
  /// - **호출**: Flutter 프레임워크 (위젯 소멸 시)
  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _connectionCheckTimer?.cancel();
    _upgradeCheckTimer?.cancel();
    _callStatusSub?.cancel();
    _webrtc.dispose();
    _signaling.dispose();
    super.dispose();
  }

  // ─── UI 빌드 ───

  /// (`Widget Builder`) 전체 화면 구성 — 원격 영상 + 로컬 PIP + 상태 배지 + 하단 버튼
  ///
  /// - **Returns**: `Widget` — 검은 배경 Scaffold에 Stack 레이아웃
  /// - **호출**: Flutter 프레임워크 (렌더링 시)
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 원격 영상 (전체 화면)
          if (_connected)
            Positioned.fill(
              child: RTCVideoView(
                _webrtc.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),

          // 로컬 PIP: callType="call"이면 수락 전부터 표시 / 모니터링은 업그레이드 후만
          if (_isCall
              ? (_connected && _webrtc.localRenderer.srcObject != null)
              : (_upgraded && !_webrtc.isMonitoring))
            Positioned(
              top: 40,
              right: 16,
              child: Container(
                width: 120,
                height: 160,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                clipBehavior: Clip.hardEdge,
                child: RTCVideoView(
                  _webrtc.localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),

          // 연결 대기 UI
          if (_connecting)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isCall ? Icons.videocam : Icons.camera_outdoor,
                    color: Colors.white,
                    size: 64,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    widget.targetDeviceName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _isCall ? '연결 중...' : '모니터링 연결 중...',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(color: Colors.white),
                ],
              ),
            ),

          // 상단 상태 배지
          if (_connected)
            Positioned(
              top: 40,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _upgraded
                          ? Icons.videocam
                          : (_waitingAcceptance ? Icons.hourglass_top : Icons.remove_red_eye),
                      color: _upgraded
                          ? Colors.green
                          : (_waitingAcceptance ? Colors.amber : Colors.orange),
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _upgraded
                          ? '통화 중'
                          : (_waitingAcceptance ? '수락 대기 중...' : '모니터링'),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),

          // 하단 버튼
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 통화 전환 버튼 (모니터링 중 + 다른 가족이 통화 중이지 않을 때)
                if (_connected && !_isCall && !_upgraded && !_callActiveByOther)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FloatingActionButton.extended(
                      heroTag: 'upgrade',
                      onPressed: _upgradeToCall,
                      backgroundColor: Colors.green,
                      icon: const Icon(Icons.videocam),
                      label: const Text('통화 전환'),
                    ),
                  ),
                // 종료 버튼
                FloatingActionButton(
                  heroTag: 'hangup',
                  onPressed: _hangUp,
                  backgroundColor: Colors.red,
                  child: const Icon(Icons.call_end, size: 32),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
