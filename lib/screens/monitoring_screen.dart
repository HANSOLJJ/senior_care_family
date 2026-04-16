import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call/call_state_machine.dart';
import '../services/call/signaling_service.dart';
import '../services/call/webrtc_service.dart';
import '../services/network_guard.dart';
import '../widgets/tap_guard.dart';
import '../widgets/press_scale.dart';

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

  /// 연결 대상 기기 표시 이름 (디버그 fallback 용)
  final String targetDeviceName;

  /// 사용자가 지정한 가족 라벨 (예: "부모님"). UI/다이얼로그에서 기본 표시.
  /// null이면 [targetDeviceName]로 fallback.
  final String? familyLabel;

  /// 통화 유형: `"monitor"` (CCTV) 또는 `"call"` (영상통화)
  final String callType;

  /// 소속 가족 그룹 ID (callStatus 감시에 사용)
  final String? familyId;

  const MonitoringScreen({
    super.key,
    required this.targetDeviceId,
    required this.targetDeviceName,
    this.familyLabel,
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
  late WebRtcService _webrtc;

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

  // ─── TapGuard ───
  final _hangUpGuard = TapGuard();
  final _upgradeGuard = TapGuard();

  // ─── 타이머 / 구독 ───

  /// Phase 1: Senior 도달 확인 (5초). answer 수신 안 오면 다이얼로그.
  Timer? _phase1Timer;

  /// Phase 2: Senior 수락 대기 (20초, 통화만). 수락 안 오면 다이얼로그.
  Timer? _phase2Timer;

  /// Phase 2 카운트다운 표시용 (1초마다 _phase2RemainingSec 감소)
  Timer? _countdownTimer;

  /// Phase 2 남은 초 (UI 표시용)
  int _phase2RemainingSec = 20;

  /// 원격 스트림 수신 확인용 폴링 타이머 (500ms 주기)
  Timer? _connectionCheckTimer;

  /// 양방향 전환 완료 감지용 폴링 타이머 (300ms 주기)
  Timer? _upgradeCheckTimer;

  /// `families/{fid}/callStatus/active` 실시간 감시 구독
  StreamSubscription? _callStatusSub;

  /// 다이얼로그 중복 표시 방지 (같은 phase 내 한 번만)
  bool _dialogShown = false;

  // ─── Phase 상수 ───

  static const _phase1TimeoutSec = 5;   // Senior 도달 확인 타임아웃
  static const _phase2TimeoutSec = 20;  // Senior 수락 대기 타임아웃

  // ─── 계산 속성 ───

  /// (`Getter`) 현재 모드가 통화(call)인지 여부
  bool get _isCall => widget.callType == 'call';

  /// (`Getter`) 표시용 상대 라벨 — familyLabel 우선, 없으면 targetDeviceName
  String get _displayName => widget.familyLabel ?? widget.targetDeviceName;

  // ─── 생명주기 ───

  /// (`Lifecycle`) 초기화 — WebRTC 서비스 생성 + 모드별 연결 시작
  ///
  /// - **Side Effects**: _webrtc 인스턴스 생성, 콜백 등록, 모드별 연결 시작
  /// - **호출**: Flutter 프레임워크 (위젯 생성 시)
  @override
  void initState() {
    super.initState();
    _webrtc = WebRtcService(_signaling);
    // FSM terminated 감지 — reason 기반으로 dialog/snackbar/pop 분기
    _webrtc.phase.addListener(_onPhaseChanged);
    // Phase 1 종료 신호 — Senior 도달 (SDP answer 수신) 감지
    _webrtc.answerReceived.addListener(_onAnswerReceived);
    if (_isCall) {
      _startCall();
    } else {
      _startMonitoring();
    }
    // 모니터링 중 다른 가족이 '통화'(call) 시작하면 전환 버튼 숨김.
    // 모니터링(monitor)은 N명 동시 가능하므로 막지 않는다 — 내가 모니터링 중이면
    // Senior가 callStatus.active=true/type=monitor를 쓰는데 그걸 "다른 사람이 통화 중"으로
    // 오판하지 않도록 type까지 확인.
    if (!_isCall && widget.familyId != null) {
      _callStatusSub = FirebaseDatabase.instance
          .ref('families/${widget.familyId}/callStatus')
          .onValue
          .listen((event) {
        if (mounted) {
          final data = event.snapshot.value as Map?;
          final active = data?['active'] == true;
          final type = data?['type'] as String?;
          setState(() {
            _callActiveByOther = active && type == 'call';
          });
        }
      });
    }
  }

  // ─── 연결 메서드 ───

  /// (`Method`, async) CCTV 모니터링 시작 — 단방향 영상 수신
  ///
  /// - **Side Effects**: WebRTC 초기화 + 모니터링 발신 + Phase 1 타이머 시작
  /// - **호출**: [initState] (callType="monitor" 시)
  Future<void> _startMonitoring() async {
    try {
      _startPhase1Timer();
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
  /// - **Side Effects**: WebRTC 초기화 + 통화 발신 + Phase 1 타이머 시작
  /// - **호출**: [initState] (callType="call" 시)
  Future<void> _startCall() async {
    try {
      _startPhase1Timer();
      await _webrtc.initialize();
      final user = FirebaseAuth.instance.currentUser;
      await _webrtc.startCall(
        widget.targetDeviceId,
        callerUid: user?.uid,
        callerName: user?.displayName ?? '가족',
        familyId: widget.familyId,
      );

      // 연결되면 수락 대기 UI 표시 (Phase 2 시작은 _onAnswerReceived에서 처리)
      _connectionCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (!mounted) { timer.cancel(); return; }
        if (_webrtc.remoteRenderer.srcObject != null && !_connected) {
          timer.cancel();
          setState(() {
            _connected = true;
            _connecting = false;
            _waitingAcceptance = true;
          });
          // Senior 수락 후 upgradeToCall 완료 감지
          _watchUpgrade();
        }
      });
    } catch (e) {
      _handleError(e);
    }
  }

  /// (`Method`) 모니터링 연결 대기 — 원격 스트림 수신까지 폴링
  ///
  /// 모니터링은 Phase 2 없음. answer 수신 → ICE 교환 → 영상 도착 → _connected=true.
  /// - **Side Effects**: _connectionCheckTimer (500ms 폴링) 시작
  /// - **호출**: [_startMonitoring]
  void _waitForConnection() {
    _connectionCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_webrtc.remoteRenderer.srcObject != null && !_connected) {
        timer.cancel();
        setState(() { _connected = true; _connecting = false; });
      }
    });
  }

  // ─── Phase 머신 ───

  /// (`Method`) Phase 1 타이머 시작 — 5초 안에 SDP answer 도착 안 하면 unreachable 종결
  void _startPhase1Timer() {
    _phase1Timer?.cancel();
    _phase1Timer = Timer(const Duration(seconds: _phase1TimeoutSec), () {
      if (!mounted) return;
      if (_webrtc.answerReceived.value) return; // 거의 동시 도착 가드
      _webrtc.hangUp(reason: TerminateReason.unreachable);
    });
  }

  /// (`Listener`) WebRtcService.answerReceived 변경 감지 — Phase 1 → Phase 2 전이
  void _onAnswerReceived() {
    if (!_webrtc.answerReceived.value) return; // false 리셋 무시
    if (!mounted) return;
    _phase1Timer?.cancel();
    if (_isCall) {
      _startPhase2Timer();
    }
    // monitor: Phase 2 없음. _connectionCheckTimer가 _connected 처리.
  }

  /// (`Method`) Phase 2 타이머 시작 — 20초 안에 Senior 수락 안 하면 다이얼로그 + 카운트다운
  void _startPhase2Timer() {
    _phase2Timer?.cancel();
    _countdownTimer?.cancel();
    setState(() { _phase2RemainingSec = _phase2TimeoutSec; });
    _phase2Timer = Timer(const Duration(seconds: _phase2TimeoutSec), () {
      if (!mounted) return;
      if (_upgraded) return; // 거의 동시 수락 가드
      _webrtc.hangUp(reason: TerminateReason.noAcceptance);
    });
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _phase2RemainingSec = (_phase2RemainingSec - 1).clamp(0, _phase2TimeoutSec);
      });
      if (_phase2RemainingSec <= 0) t.cancel();
    });
  }

  // ─── FSM phase 리스너 + 종결 UX 핸들러 ───

  /// (`Listener`) [WebRtcService.phase] 변경 감지 — terminated 시 `_handleTerminated` 호출.
  ///
  /// terminated 로 전이한 순간 FSM 의 `reason` 필드가 세팅되어 있음.
  /// addPostFrameCallback 으로 감싸 build 중 setState/dialog race 방지.
  void _onPhaseChanged() {
    if (!mounted) return;
    if (_webrtc.phase.value != CallPhase.terminated) return;
    final reason = _webrtc.terminateReason;
    if (reason == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handleTerminated(reason);
    });
  }

  /// (`Method`, async) terminated 사유별 UX 매핑 — dialog/snackbar/pop.
  ///
  /// 매핑 정책 (plan 의 "terminated.reason → UX 반응 매핑" 표와 동일):
  /// - userHangup / remoteEnded / orphanCleaned → 즉시 pop
  /// - unreachable / noAcceptance → 다이얼로그 + 재시도 버튼 → 재시도 or pop
  /// - iceFailed / networkOffline / remoteBusy / endedByOtherCall / capacityExceeded → 다이얼로그 → pop
  /// - upgradeFailed → SnackBar 만 (화면 유지)
  Future<void> _handleTerminated(TerminateReason reason) async {
    if (_dialogShown || !mounted) return;

    // 즉시 pop — 사용자 의사 표시 or 상대 종료 or race 정리
    switch (reason) {
      case TerminateReason.userHangup:
      case TerminateReason.remoteEnded:
      case TerminateReason.orphanCleaned:
        Navigator.of(context).pop();
        return;
      case TerminateReason.upgradeFailed:
        // SnackBar 만 — 화면 유지 (모니터링 계속)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('통화 전환에 실패했습니다')),
        );
        return;
      default:
        break;
    }

    // 다이얼로그 필요 — reason 별 문구 매핑
    _dialogShown = true;
    final (title, message, retryable) = _dialogContent(reason);
    final retry = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('확인'),
          ),
          if (retryable)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('재시도'),
            ),
        ],
      ),
    );
    _dialogShown = false;
    if (!mounted) return;
    if (retry == true) {
      _restartCall();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// (`Utility`) terminated reason → (title, message, retryable) 매핑
  (String, String, bool) _dialogContent(TerminateReason reason) {
    switch (reason) {
      case TerminateReason.unreachable:
        return (
          '$_displayName과(와) 통신 연결이 되지 않습니다',
          '기기가 꺼져 있거나 인터넷이 끊겨 있을 수 있습니다.',
          true,
        );
      case TerminateReason.noAcceptance:
        return (
          '$_displayName이(가) 받지 않습니다',
          '잠시 후 다시 시도해보세요.',
          true,
        );
      case TerminateReason.iceFailed:
        return (
          '연결이 끊어졌습니다',
          '네트워크 상태를 확인해주세요.',
          false,
        );
      case TerminateReason.networkOffline:
        return (
          '네트워크에 연결되어 있지 않습니다',
          '인터넷 연결을 확인하고 다시 시도해주세요.',
          false,
        );
      case TerminateReason.remoteBusy:
        return (
          '$_displayName이(가) 통화 중입니다',
          '다른 가족이 통화 중입니다. 잠시 후 다시 시도해주세요.',
          false,
        );
      case TerminateReason.endedByOtherCall:
        return (
          '모니터링이 종료되었습니다',
          '가족이 영상통화를 시작하여 모니터링이 종료되었습니다.',
          false,
        );
      case TerminateReason.capacityExceeded:
        return (
          '모니터링 가능 인원 초과',
          '현재 최대 인원(3명)이 모니터링 중입니다.',
          false,
        );
      default:
        return ('연결 종료', '세션이 종료되었습니다.', false);
    }
  }

  /// (`Method`) 재시도 — WebRtcService 재생성 + 모든 상태/타이머 리셋 + 발신 재시작
  void _restartCall() {
    _phase1Timer?.cancel();
    _phase2Timer?.cancel();
    _countdownTimer?.cancel();
    _connectionCheckTimer?.cancel();
    _upgradeCheckTimer?.cancel();
    _webrtc.answerReceived.removeListener(_onAnswerReceived);
    _webrtc.phase.removeListener(_onPhaseChanged);
    _webrtc.dispose();

    setState(() {
      _connected = false;
      _connecting = true;
      _upgraded = false;
      _waitingAcceptance = false;
      _phase2RemainingSec = _phase2TimeoutSec;
    });

    _webrtc = WebRtcService(_signaling);
    _webrtc.phase.addListener(_onPhaseChanged);
    _webrtc.answerReceived.addListener(_onAnswerReceived);
    if (_isCall) {
      _startCall();
    } else {
      _startMonitoring();
    }
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
        // Senior 수락 완료 — Phase 2 종료
        _phase2Timer?.cancel();
        _countdownTimer?.cancel();
        setState(() {
          _upgraded = true;
          _waitingAcceptance = false;
        });
      }
    });
  }

  // ─── 통화 제어 ───

  /// (`Method`, async) 통화/모니터링 종료 — 리소스 정리 + 화면 pop
  ///
  /// FSM terminated 전이는 [WebRtcService.hangUp] 이 수행. 본 함수에선
  /// 타이머 취소만 하고 hangUp 호출. Navigator.pop 은 `_handleTerminated` 가 담당.
  /// - **호출**: 종료 버튼
  Future<void> _hangUp() async {
    _phase1Timer?.cancel();
    _phase2Timer?.cancel();
    _countdownTimer?.cancel();
    await _webrtc.hangUp(reason: TerminateReason.userHangup);
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
        // FSM 은 termintate 하지 않고 SnackBar 만 — plan 의 "upgradeFailed" UX 정책
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('통화 전환에 실패했습니다')),
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
      final msg = e is NetworkException ? e.message : '연결 실패: $e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      Navigator.of(context).pop();
    }
  }

  // ─── 생명주기 ───

  /// (`Lifecycle`) 리소스 해제 — 타이머, 구독, WebRTC, 시그널링 정리
  ///
  /// - **호출**: Flutter 프레임워크 (위젯 소멸 시)
  @override
  void dispose() {
    _hangUpGuard.dispose();
    _upgradeGuard.dispose();
    _phase1Timer?.cancel();
    _phase2Timer?.cancel();
    _countdownTimer?.cancel();
    _connectionCheckTimer?.cancel();
    _upgradeCheckTimer?.cancel();
    _callStatusSub?.cancel();
    _webrtc.answerReceived.removeListener(_onAnswerReceived);
    _webrtc.phase.removeListener(_onPhaseChanged);
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
                    _displayName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _isCall ? '호출 중...' : '모니터링 연결 중...',
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
                          : (_waitingAcceptance
                              ? '$_displayName 수락 대기 ($_phase2RemainingSec초)'
                              : '모니터링'),
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
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _upgradeGuard.isBusy,
                      builder: (context, busy, _) => PressScale(
                        onTap: busy
                            ? null
                            : () {
                                HapticFeedback.lightImpact();
                                _upgradeGuard.run(_upgradeToCall);
                              },
                        child: FloatingActionButton.extended(
                          heroTag: 'upgrade',
                          onPressed: busy
                              ? null
                              : () {
                                  HapticFeedback.lightImpact();
                                  _upgradeGuard.run(_upgradeToCall);
                                },
                          backgroundColor: Colors.green,
                          icon: const Icon(Icons.videocam),
                          label: const Text('통화 전환'),
                        ),
                      ),
                    ),
                  ),
                // 종료 버튼
                ValueListenableBuilder<bool>(
                  valueListenable: _hangUpGuard.isBusy,
                  builder: (context, busy, _) => FloatingActionButton(
                    heroTag: 'hangup',
                    onPressed: busy
                        ? null
                        : () {
                            HapticFeedback.mediumImpact();
                            _hangUpGuard.run(_hangUp);
                          },
                    backgroundColor: Colors.red,
                    child: const Icon(Icons.call_end, size: 32),
                  ),
                ),
              ],
            ),
          ),

          // 재연결 오버레이 — FSM phase==reconnecting 시 표시 (plan UX 계약 매핑).
          // Positioned.fill 로 감싸지 않으면 builder 가 반환하는 SizedBox.shrink 가
          // non-positioned child 로 취급되어 Stack 이 0×0 으로 collapse 됨 (전체 black 버그).
          Positioned.fill(
            child: IgnorePointer(
              ignoring: true,
              child: ValueListenableBuilder<CallPhase>(
                valueListenable: _webrtc.phase,
                builder: (context, phase, _) {
                  if (phase != CallPhase.reconnecting) return const SizedBox.shrink();
                  return Container(
                    color: Colors.black.withOpacity(0.6),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text(
                          '연결이 불안정해요',
                          style: TextStyle(color: Colors.white, fontSize: 18),
                        ),
                        SizedBox(height: 8),
                        Text(
                          '잠시만 기다려 주세요...',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
