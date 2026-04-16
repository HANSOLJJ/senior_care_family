import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../network_guard.dart';
import 'call_state_machine.dart';
import 'signaling_service.dart';

/// ICE 서버 설정 — STUN(Google) + TURN(metered.ca)
///
/// NAT/방화벽 환경에서 P2P 연결을 위해 STUN으로 공인 IP 확인,
/// STUN 실패 시 TURN 릴레이 서버를 통해 미디어 중계.

const _iceServers = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {
      'urls': 'turn:a.relay.metered.ca:80',
      'username': 'e8dd65e92f6e86cfe1ef0635',
      'credential': 'dktMDqpJIcMw4VYz',
    },
    {
      'urls': 'turn:a.relay.metered.ca:443',
      'username': 'e8dd65e92f6e86cfe1ef0635',
      'credential': 'dktMDqpJIcMw4VYz',
    },
    {
      'urls': 'turn:a.relay.metered.ca:443?transport=tcp',
      'username': 'e8dd65e92f6e86cfe1ef0635',
      'credential': 'dktMDqpJIcMw4VYz',
    },
  ],
};

/// (`Service`) WebRTC 피어 연결 + 미디어 스트림 관리
///
/// Family 앱에서 Senior 기기로 영상통화/모니터링을 발신하는 핵심 서비스.
/// SignalingService를 통해 RTDB로 SDP/ICE를 교환하고,
/// PeerConnection으로 실시간 영상/음성 스트림을 송수신.
///
/// 주요 메서드:
///   - [makeCall] — 양방향 영상통화 발신: offer 생성 → RTDB 전송 → answer 대기 → ICE 교환
///   - [startMonitoring] — CCTV 모니터링 발신: 단방향(Senior→Family 영상만, RecvOnly)
///   - [startCall] — 통화 발신 (RecvOnly 시작 → Senior 수락 후 양방향 전환)
///   - [upgradeToCall] — 모니터링 → 양방향 통화 전환 (SDP renegotiation)
///   - [hangUp] — 통화 종료: 미디어/PeerConnection 정리 + RTDB status="ended"
///
/// 끊김 감지: connectionState DISCONNECTED 시 5초 대기 후 복구 안 되면 자동 종료
class WebRtcService {
  // ─── 의존성 ───

  /// RTDB 시그널링 서비스 (SDP/ICE 교환 담당)
  final SignalingService _signaling;

  // ─── WebRTC 핵심 객체 ───

  /// RTCPeerConnection 인스턴스 (연결당 1개)
  RTCPeerConnection? _peerConnection;

  /// 로컬 카메라/마이크 미디어 스트림
  MediaStream? _localStream;

  /// 원격(Senior) 미디어 스트림
  MediaStream? _remoteStream;

  // ─── 상태 필드 ───

  /// 현재 활성 통화 ID
  String? _callId;

  /// 통화 생명주기 상태 머신 — async race 차단 + UX 종결 사유 매핑.
  ///
  /// `terminate(reason)` 이 가장 먼저 세팅 → 다른 async 경로가 `_isEnding` 가드로 즉시 종료.
  /// MonitoringScreen 이 `phase` ValueNotifier 를 구독하여 배너/다이얼로그/pop 분기.
  final CallStateMachine _fsm = CallStateMachine();

  /// 다른 async 경로의 early-return 가드 — `terminating`/`terminated` 면 true.
  bool get _isEnding => _fsm.isEnding;

  /// (`Getter`) MonitoringScreen 구독용 — 현재 phase
  ValueNotifier<CallPhase> get phase => _fsm.phase;

  /// (`Getter`) MonitoringScreen 구독용 — 종결 사유 (terminated 이후에만 유효)
  TerminateReason? get terminateReason => _fsm.reason;

  /// 현재 모니터링(RecvOnly) 모드인지 여부
  bool _isMonitoring = false;

  // ─── 타이머 / 구독 ───

  /// 연결 끊김 감지 후 grace 타이머 (만료 시 ICE restart 트리거)
  Timer? _disconnectTimer;

  /// CONNECTED 안정 유지 확인 타이머 (만료 시 flap 카운터 리셋)
  Timer? _stableTimer;

  /// ICE restart offer 전송 후 answer 수신 대기 타이머 (만료 시 _iceRestartInProgress 리셋 + 재시도)
  Timer? _iceRestartAnswerTimer;

  /// AEC(에코 제거) 메트릭 로깅 타이머 (5초 간격)
  Timer? _aecStatsTimer;

  /// Senior 수락 감지용 RTDB 구독 (`calls/{callId}/seniorAccepted`)
  StreamSubscription? _seniorAcceptedSub;

  /// SDP answer 감시 구독
  StreamSubscription? _answerSub;

  /// 상대방 ICE candidate 감시 구독 (`calleeCandidates`)
  StreamSubscription? _calleeCandidatesSub;

  /// 통화 종료(`status=ended`) 감시 구독
  StreamSubscription? _callEndSub;

  /// ICE restart answer 감시 구독 (`iceRestartAnswer`)
  StreamSubscription? _iceRestartAnswerSub;

  // ─── ICE candidate 큐 / 경로 ───

  /// callId 확정 전 수집된 ICE candidate 큐. `_callId` 세팅 시 [_flushPendingCandidates]로 비움.
  final List<RTCIceCandidate> _pendingCandidates = [];

  /// 내가 쓰는 ICE candidate RTDB 경로. Family는 항상 `callerCandidates`,
  /// `_createPc`(answerCall 경로)에서만 `calleeCandidates`로 세팅.
  String _myIceCandidatePath = 'callerCandidates';

  // ─── ICE Restart 상태 ───

  /// ICE restart 진행 중 여부 (중복 트리거 방지). setRemote(answer) 완료 finally에서 reset.
  bool _iceRestartInProgress = false;

  /// 누적 ICE restart 시도 횟수. CONNECTED 안정 5초 유지 시 0으로 리셋.
  int _iceRestartAttempts = 0;

  /// 최초 DISCONNECTED 진입 시각(ms). flap window 계산용. CONNECTED 안정 시 null.
  int? _flapWindowStart;

  /// 재연결 진행 여부 ValueNotifier — MonitoringScreen이 ValueListenableBuilder로 구독.
  final ValueNotifier<bool> isReconnecting = ValueNotifier(false);

  /// SDP answer 수신 + setRemoteDescription 완료 여부 (Senior 도달 신호)
  /// MonitoringScreen이 Phase 1 (도달 확인) 종료 신호로 사용.
  final ValueNotifier<bool> answerReceived = ValueNotifier(false);

  // ─── 상수 ───

  static const _graceMs = 4000;             // DISCONNECTED → ICE restart trigger 까지 대기
  static const _maxFlapWindowMs = 60000;    // 최초 disconnect 이후 세션 상한
  static const _stableResetMs = 5000;       // CONNECTED 유지 시 flap 카운터 리셋
  static const _maxIceRestartAttempts = 5;
  static const _iceRestartAnswerTimeoutMs = 10000; // offer 전송 후 answer 대기 시간

  // ─── 콜백 ───

  /// 상대방 끊김/연결 실패 감지 시 호출되는 콜백
  void Function()? onCallEnded;

  // ─── 렌더러 ───

  /// 로컬 카메라 영상 렌더러 (PIP 표시용)
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();

  /// 원격(Senior) 영상 렌더러 (전체화면 표시용)
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  // ─── 생성자 ───

  /// (`Factory`) WebRtcService 생성
  ///
  /// - **Params**:
  ///   - [_signaling] — RTDB 시그널링 서비스 인스턴스
  WebRtcService(this._signaling);

  // ─── 초기화 ───

  /// (`Method`, async) 비디오 렌더러 초기화
  ///
  /// localRenderer와 remoteRenderer를 사용 가능 상태로 준비.
  /// - **Side Effects**: 렌더러 초기화
  /// - **호출**: MonitoringScreen._startMonitoring, _startCall
  Future<void> initialize() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
  }

  // ─── 미디어 스트림 ───

  /// (`Method`, async) 로컬 미디어 스트림 획득 — 카메라(전면) + 마이크
  ///
  /// - **Returns**: `MediaStream` — 로컬 카메라/마이크 스트림 (1280x720)
  /// - **호출**: [_createPc], [makeCall], [upgradeToCall], [_startLocalPreviewOnly]
  Future<MediaStream> _getLocalStream() async {
    return await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'user',
        'width': 1280,
        'height': 720,
      },
    });
  }

  // ─── PeerConnection 생성 ───

  /// (`Method`, async) PeerConnection 공통 설정 — 로컬 트랙 추가 + 이벤트 핸들러 등록
  ///
  /// 로컬 스트림의 모든 트랙을 PC에 추가하고, 원격 트랙 수신/ICE candidate 전송/
  /// 연결 상태 감시 콜백을 설정. 양방향 통화(makeCall, answerCall)에서 사용.
  /// - **Params**:
  ///   - [callId] — 통화 ID (ICE candidate 전송 경로)
  ///   - [myCandidatesPath] — 내 ICE candidate RTDB 경로 (`"callerCandidates"` 또는 `"calleeCandidates"`)
  /// - **Returns**: `RTCPeerConnection` — 설정 완료된 PeerConnection
  /// - **Side Effects**: 비트레이트 설정 (4Mbps), 원격 스트림 수신 시 remoteRenderer 연결
  /// - **호출**: [answerCall]
  Future<RTCPeerConnection> _createPc(String callId, {required String myCandidatesPath}) async {
    _myIceCandidatePath = myCandidatesPath;
    final pc = await createPeerConnection(_iceServers);

    // 로컬 트랙 추가
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    await _setVideoBitrate(pc, 4000);

    pc.onTrack = _onTrack;
    pc.onIceCandidate = _onIceCandidate;
    pc.onConnectionState = _onPeerConnectionStateChanged;

    return pc;
  }

  // ─── 비트레이트 설정 ───

  /// (`Utility`, async) 비디오 sender의 maxBitrate 설정 (화질 개선)
  ///
  /// degradationPreference를 MAINTAIN_RESOLUTION으로 설정하여 해상도 유지 우선.
  /// - **Params**:
  ///   - [pc] — 대상 PeerConnection
  ///   - [maxBitrateKbps] — 최대 비트레이트 (kbps)
  /// - **Side Effects**: sender의 encoding 파라미터 변경 (min=1Mbps, max=지정값)
  /// - **호출**: [_createPc], [makeCall], [startCall], [upgradeToCall]
  Future<void> _setVideoBitrate(RTCPeerConnection pc, int maxBitrateKbps) async {
    final senders = await pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        final params = sender.parameters;
        if (params.encodings == null || params.encodings!.isEmpty) {
          params.encodings = [RTCRtpEncoding()];
        }
        params.encodings![0].maxBitrate = maxBitrateKbps * 1000;
        params.encodings![0].minBitrate = 1000 * 1000;
        params.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
        await sender.setParameters(params);
        print('WebRTC: 비디오 설정 → min=1000kbps, max=${maxBitrateKbps}kbps, MAINTAIN_RESOLUTION');
      }
    }
  }

  // ─── 수신 처리 ───

  /// (`Method`, async) 수신 처리 — offer를 받아 answer를 보내고 연결
  ///
  /// Senior 앱에서 사용하는 메서드. Family 앱에서는 직접 호출하지 않음.
  /// 1. 로컬 미디어 스트림 획득
  /// 2. PeerConnection 생성 (calleeCandidates 경로)
  /// 3. Remote offer 설정 → Answer 생성 → 시그널링 전송
  /// 4. 발신자 ICE candidates 감시 + 종료 감시
  /// - **Params**:
  ///   - [callId] — 수신한 통화 ID
  ///   - [offer] — 발신자의 SDP offer (`{sdp, type}`)
  /// - **Side Effects**: PeerConnection 생성, 로컬/원격 스트림 연결, AEC 모니터링 시작
  /// - **호출**: Senior 앱 수신 로직
  Future<void> answerCall(String callId, Map<String, dynamic> offer) async {
    _fsm.to(CallPhase.connecting, reason: 'answerCall');
    _callId = callId;
    print('WebRTC: 통화 응답 시작 callId=$callId');

    // onDisconnect 설정 (비정상 종료 대비)
    await _signaling.setCallCleanupOnDisconnect(callId);

    // 1. 로컬 미디어 스트림
    _localStream = await _getLocalStream();
    localRenderer.srcObject = _localStream;

    // 2. PeerConnection 생성
    _peerConnection = await _createPc(callId, myCandidatesPath: 'calleeCandidates');

    // 3. Remote offer 설정
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offer['sdp'], offer['type']),
    );

    // 4. Answer 생성 + 설정
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    // 5. Answer를 시그널링 서버에 전송
    await _signaling.sendAnswer(callId, {
      'sdp': answer.sdp,
      'type': answer.type,
    });

    // 6. 발신자의 ICE candidates 감시
    _signaling.listenForCandidates(callId, 'callerCandidates', (candidate) {
      print('WebRTC: 발신자 ICE candidate 수신');
      _peerConnection?.addCandidate(RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'],
        candidate['sdpMLineIndex'],
      ));
    });

    // 7. 발신자 통화 종료 감시 — answerCall 은 Senior 측 코드지만 유지
    _signaling.listenForCallEnd(callId, (endReason) {
      print('WebRTC: 발신자가 통화 종료 endReason=$endReason');
      hangUp(reason: _mapEndReason(endReason));
      onCallEnded?.call();
    });

    print('WebRTC: 통화 연결 완료');
    _startAecStats();
  }

  // ─── AEC 모니터링 ───

  /// (`Utility`) AEC(에코 제거) 메트릭 로깅 시작 (5초 간격)
  ///
  /// PeerConnection의 getStats()로 ERL/ERLE, audioLevel 등을 추출하여 콘솔에 출력.
  /// 에코 문제 디버깅용.
  /// - **Side Effects**: _aecStatsTimer 시작 (5초 주기)
  /// - **호출**: [answerCall], [makeCall], [startCall]
  void _startAecStats() {
    _aecStatsTimer?.cancel();
    _aecStatsTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      final pc = _peerConnection;
      if (pc == null) return;
      try {
        final stats = await pc.getStats();
        for (final report in stats) {
          final v = report.values;
          if (v.containsKey('echoReturnLoss')) {
            print('AEC stats: ERL=${v['echoReturnLoss']}dB ERLE=${v['echoReturnLossEnhancement']}dB');
          }
          if (report.type == 'media-source' && v.containsKey('audioLevel')) {
            print('AEC stats: audioLevel=${v['audioLevel']} totalAudioEnergy=${v['totalAudioEnergy']}');
          }
        }
      } catch (_) {}
    });
  }

  /// (`Utility`) AEC 메트릭 로깅 중지
  ///
  /// - **Side Effects**: _aecStatsTimer 취소 및 null 처리
  /// - **호출**: [hangUp]
  void _stopAecStats() {
    _aecStatsTimer?.cancel();
    _aecStatsTimer = null;
  }

  // ─── PC 콜백 헬퍼 (4개 PC 생성 지점 공통) ───

  /// (`Callback`) 원격 트랙 수신 — `_remoteStream`/`remoteRenderer` 세팅
  void _onTrack(RTCTrackEvent event) {
    print('WebRTC: 원격 트랙 수신 kind=${event.track.kind}');
    if (event.streams.isNotEmpty) {
      _remoteStream = event.streams[0];
      remoteRenderer.srcObject = _remoteStream;
    }
  }

  /// (`Callback`) ICE candidate 생성 — `_callId` 있으면 즉시 전송, 없으면 큐잉
  void _onIceCandidate(RTCIceCandidate candidate) {
    if (_callId != null) {
      _signaling.addCandidate(_callId!, _myIceCandidatePath, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    } else {
      _pendingCandidates.add(candidate);
    }
  }

  /// (`Utility`) `_callId` 확정 후 큐에 쌓인 ICE candidate 일괄 전송
  void _flushPendingCandidates() {
    if (_callId == null || _pendingCandidates.isEmpty) return;
    print('WebRTC: 대기 중 ICE candidate ${_pendingCandidates.length}개 전송');
    for (final c in _pendingCandidates) {
      _signaling.addCandidate(_callId!, _myIceCandidatePath, {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    }
    _pendingCandidates.clear();
  }

  /// (`Callback`) PeerConnection 상태 변화 — DISCONNECTED/FAILED 시 ICE restart 트리거
  ///
  /// - DISCONNECTED: grace 4초 대기 후 [_triggerIceRestart] (이미 진행 중이면 skip)
  /// - FAILED: 즉시 [_triggerIceRestart]
  /// - CONNECTED: grace/state 리셋, 5초 안정 유지 시 flap 카운터 리셋
  void _onPeerConnectionStateChanged(RTCPeerConnectionState state) {
    print('WebRTC: 연결 상태 = $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      if (_iceRestartInProgress) return;
      isReconnecting.value = true;
      _disconnectTimer?.cancel();
      _disconnectTimer = Timer(const Duration(milliseconds: _graceMs), () {
        _triggerIceRestart();
      });
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      _disconnectTimer?.cancel();
      isReconnecting.value = true;
      _triggerIceRestart();
    } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _disconnectTimer?.cancel();
      _iceRestartInProgress = false; // 안전망
      _iceRestartAnswerTimer?.cancel();
      _iceRestartAnswerTimer = null;
      isReconnecting.value = false;
      // reconnecting → connected 복귀 (ICE restart 후)
      if (_fsm.phase.value == CallPhase.reconnecting) {
        _fsm.to(CallPhase.connected, reason: 'ice_restored');
      }
      _stableTimer?.cancel();
      _stableTimer = Timer(const Duration(milliseconds: _stableResetMs), () {
        if (_peerConnection?.connectionState ==
            RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _iceRestartAttempts = 0;
          _flapWindowStart = null;
        }
      });
    }
  }

  // ─── ICE Restart 트리거 ───

  /// (`Method`, async) ICE restart offer 생성 + 전송
  ///
  /// flap window/attempts 한도 체크 후 `pc.restartIce() + createOffer + setLocalDescription`,
  /// SignalingService를 통해 RTDB `iceRestartOffer` 노드에 SDP 기록.
  /// - **Side Effects**: `_iceRestartInProgress=true`, `_iceRestartAttempts++`, RTDB write.
  ///   한도 초과 시 [hangUp] + `onCallEnded` 호출.
  /// - **호출**: [_onPeerConnectionStateChanged] (DISCONNECTED grace 만료 / FAILED 즉시)
  Future<void> _triggerIceRestart() async {
    if (_isEnding) return;
    if (_iceRestartInProgress) return;
    if (_peerConnection == null || _callId == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    _flapWindowStart ??= now;
    if (now - _flapWindowStart! > _maxFlapWindowMs) {
      print('WebRTC: flap window($_maxFlapWindowMs ms) 초과 → iceFailed 종결');
      await hangUp(reason: TerminateReason.iceFailed);
      onCallEnded?.call();
      return;
    }
    if (_iceRestartAttempts >= _maxIceRestartAttempts) {
      print('WebRTC: ICE restart 한도($_maxIceRestartAttempts) 초과 → iceFailed 종결');
      await hangUp(reason: TerminateReason.iceFailed);
      onCallEnded?.call();
      return;
    }

    // 첫 진입 시 connected → reconnecting 전이 (MonitoringScreen 배너용)
    if (_fsm.phase.value == CallPhase.connected ||
        _fsm.phase.value == CallPhase.upgrading) {
      _fsm.to(CallPhase.reconnecting, reason: 'ice_restart_start');
    }

    _iceRestartAttempts++;
    _iceRestartInProgress = true;

    try {
      await _peerConnection!.restartIce();
      if (_isEnding) return;
      final offer = await _peerConnection!.createOffer();
      if (_isEnding) return;
      await _peerConnection!.setLocalDescription(offer);
      if (_isEnding) return;
      // signaling_service.sendIceRestartOffer 가 writeOrTimeout (3s) + onTimeoutCleanup 으로
      // offline hang / orphan offer 를 모두 방어. 여기서는 별도 timeout 불필요.
      await _signaling.sendIceRestartOffer(_callId!, {
        'sdp': offer.sdp,
        'type': offer.type,
      });
      print('WebRTC: ICE restart offer 전송 (attempt=$_iceRestartAttempts)');

      // answer 수신 대기 타이머 — 만료 시 _iceRestartInProgress 리셋 + 자동 재시도.
      // 재시도는 _triggerIceRestart 재호출로, 한도/flap window 자동 체크됨.
      _iceRestartAnswerTimer?.cancel();
      _iceRestartAnswerTimer = Timer(
        const Duration(milliseconds: _iceRestartAnswerTimeoutMs),
        () {
          if (!_iceRestartInProgress) return;
          print('WebRTC: ICE restart answer 미수신 (${_iceRestartAnswerTimeoutMs}ms) → 재시도 트리거');
          _iceRestartInProgress = false;
          // 여전히 DISCONNECTED/FAILED면 재시도. CONNECTED 복귀했으면 _triggerIceRestart 초입 가드로 skip.
          final state = _peerConnection?.connectionState;
          if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
            _triggerIceRestart();
          }
        },
      );
    } catch (e) {
      print('WebRTC: ICE restart 실패: $e');
      _iceRestartInProgress = false; // 다음 DISCONNECTED 때 재시도 가능
    }
  }

  // ─── 발신 처리 ───

  /// (`Method`, async) 양방향 영상통화 발신 — offer 생성 → RTDB 전송 → answer 대기
  ///
  /// 1. 로컬 미디어 스트림 획득 + 렌더러 연결
  /// 2. PeerConnection 생성 (ICE candidate 큐 방식 — callId 확정 전 수집)
  /// 3. SDP offer 생성 + 시그널링 서버에 통화 생성
  /// 4. 큐에 쌓인 ICE candidate 일괄 전송
  /// 5. 수신자 answer/ICE candidates/종료 감시
  /// - **Params**:
  ///   - [targetDeviceId] — 수신 대상 Senior 기기 ID
  ///   - [callerUid] — 발신자 Firebase UID
  ///   - [callerName] — 발신자 표시 이름
  ///   - [familyId] — 소속 가족 그룹 ID
  /// - **Returns**: `String` — 생성된 callId
  /// - **Side Effects**: PeerConnection 생성, 로컬/원격 스트림 연결, AEC 모니터링 시작
  /// - **호출**: (현재 미사용 — startCall로 대체됨)
  Future<String> makeCall(String targetDeviceId, {String? callerUid, String? callerName, String? familyId}) async {
    if (!_fsm.to(CallPhase.connecting, reason: 'makeCall')) return '';
    _myIceCandidatePath = 'callerCandidates';
    print('WebRTC: 발신 시작 → target=$targetDeviceId');

    // 1. 로컬 미디어 스트림
    _localStream = await _getLocalStream();
    localRenderer.srcObject = _localStream;

    // 2. PeerConnection 생성 — onIceCandidate를 먼저 등록 (callId 확정 전 candidate는 _pendingCandidates에 큐잉)
    final pc = await createPeerConnection(_iceServers);
    if (_isEnding) { await pc.close(); return ''; }
    _peerConnection = pc;

    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }
    if (_isEnding) return '';
    await _setVideoBitrate(pc, 4000);
    if (_isEnding) return '';

    pc.onTrack = _onTrack;
    pc.onIceCandidate = _onIceCandidate;
    pc.onConnectionState = _onPeerConnectionStateChanged;

    // 4. SDP offer 생성
    final offer = await pc.createOffer();
    if (_isEnding) return '';
    await pc.setLocalDescription(offer);
    if (_isEnding) return '';

    // 5. 시그널링 서버에 통화 생성 (targetDeviceId + caller 정보 포함)
    final callId = await _signaling.createCall(
      {'sdp': offer.sdp, 'type': offer.type},
      targetDeviceId: targetDeviceId,
      callerUid: callerUid,
      callerName: callerName,

      targetFamilyId: familyId,
    );
    // hangUp이 createCall 진행 중에 호출된 경우 — orphan call 생성된 상태. 즉시 정리.
    if (_isEnding) {
      print('WebRTC: makeCall 중 hangUp 감지 → orphan call 정리 callId=$callId');
      await _signaling.endCall(callId);
      await _signaling.cleanupCall(callId);
      return '';
    }
    _callId = callId;

    // onDisconnect 설정
    await _signaling.setCallCleanupOnDisconnect(callId);
    if (_isEnding) {
      await _signaling.endCall(callId);
      await _signaling.cleanupCall(callId);
      return '';
    }

    // 큐에 쌓인 ICE candidate 전송
    _flushPendingCandidates();

    // 6. 시그널링 리스너 등록 (구독은 hangUp/dispose에서 cancel)
    _registerSignalingListeners(callId);

    print('WebRTC: 발신 완료, answer 대기 중 callId=$callId');
    _startAecStats();
    return callId;
  }

  // ─── endReason → TerminateReason 매핑 ───

  /// (`Utility`) Senior 가 `/calls/{cid}/endReason` 에 쓴 문자열을 [TerminateReason] 으로 매핑.
  ///
  /// - `"remoteBusy"` → Senior 가 다른 가족과 통화 중
  /// - `"capacityExceeded"` → 모니터링 MAX_PEERS 초과
  /// - `"otherCallStarted"` → 다른 가족이 통화 시작하여 내 모니터가 displaced
  /// - `"normal"` / `null` / 기타 → 정상 종료 (remoteEnded)
  TerminateReason _mapEndReason(String? endReason) {
    switch (endReason) {
      case 'remoteBusy':
        return TerminateReason.remoteBusy;
      case 'capacityExceeded':
        return TerminateReason.capacityExceeded;
      case 'otherCallStarted':
        return TerminateReason.endedByOtherCall;
      default:
        return TerminateReason.remoteEnded;
    }
  }

  // ─── 시그널링 리스너 통합 등록 (3개 발신 메서드 공통) ───

  /// (`Method`) callId 확정 후 answer/candidates/callEnd/iceRestartAnswer 4종 구독 등록
  ///
  /// 모든 구독은 인스턴스 필드에 보관되어 [hangUp]에서 일괄 cancel.
  /// - **Side Effects**: `_answerSub`/`_calleeCandidatesSub`/`_callEndSub`/`_iceRestartAnswerSub` 세팅
  /// - **호출**: [makeCall], [startMonitoring], [startCall]
  void _registerSignalingListeners(String callId) {
    _answerSub?.cancel();
    _calleeCandidatesSub?.cancel();
    _callEndSub?.cancel();
    _iceRestartAnswerSub?.cancel();

    _answerSub = _signaling.listenForAnswer(callId, (answer) async {
      if (_peerConnection?.signalingState ==
          RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        print('WebRTC: SDP answer 수신');
        await _peerConnection?.setRemoteDescription(
          RTCSessionDescription(answer['sdp'], answer['type']),
        );
        // Phase 1 (Senior 도달 확인) 종료 신호 — MonitoringScreen이 구독
        answerReceived.value = true;
        if (_fsm.phase.value == CallPhase.connecting) {
          _fsm.to(CallPhase.connected, reason: 'answer_received');
        }
      }
    });

    _calleeCandidatesSub =
        _signaling.listenForCandidates(callId, 'calleeCandidates', (candidate) {
      _peerConnection?.addCandidate(RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'],
        candidate['sdpMLineIndex'],
      ));
    });

    _callEndSub = _signaling.listenForCallEnd(callId, (endReason) {
      hangUp(reason: _mapEndReason(endReason));
      onCallEnded?.call();
    });

    _iceRestartAnswerSub =
        _signaling.listenForIceRestartAnswer(callId, (answer) async {
      if (_peerConnection == null) return;
      if (_peerConnection!.signalingState ==
          RTCSignalingState.RTCSignalingStateStable) {
        print('WebRTC: ICE restart answer 무시 (stable, 이미 적용됨)');
        return;
      }
      try {
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(answer['sdp'], answer['type']),
        );
        print('WebRTC: ICE restart answer 적용 완료');
      } catch (e) {
        print('WebRTC: ICE restart setRemote 실패: $e');
      } finally {
        _iceRestartInProgress = false;
        _iceRestartAnswerTimer?.cancel();
        _iceRestartAnswerTimer = null;
      }
    });
  }

  // ─── 모니터링 발신 ───

  /// (`Method`, async) CCTV 모니터링 발신 — RecvOnly (카메라/마이크 OFF, Senior 영상만 수신)
  ///
  /// 로컬 미디어 없이 RecvOnly transceiver로 Senior 영상/음성만 수신.
  /// 연결 후 [upgradeToCall]로 양방향 전환 가능.
  /// - **Params**:
  ///   - [targetDeviceId] — 수신 대상 Senior 기기 ID
  ///   - [callerUid] — 발신자 Firebase UID
  ///   - [callerName] — 발신자 표시 이름
  ///   - [familyId] — 소속 가족 그룹 ID
  /// - **Returns**: `String` — 생성된 callId
  /// - **Side Effects**: PeerConnection 생성 (RecvOnly), _isMonitoring=true
  /// - **호출**: MonitoringScreen._startMonitoring
  Future<String> startMonitoring(String targetDeviceId, {String? callerUid, String? callerName, String? familyId}) async {
    if (!_fsm.to(CallPhase.connecting, reason: 'startMonitoring')) return '';
    _isMonitoring = true;
    _myIceCandidatePath = 'callerCandidates';
    print('WebRTC: 모니터링 시작 → target=$targetDeviceId');

    // PeerConnection 생성 — 로컬 미디어 없음
    final pc = await createPeerConnection(_iceServers);
    if (_isEnding) { await pc.close(); return ''; }
    _peerConnection = pc;

    // recvonly transceiver 추가 (영상+음성 수신만)
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    if (_isEnding) return '';
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    if (_isEnding) return '';

    pc.onTrack = _onTrack;
    pc.onIceCandidate = _onIceCandidate;
    pc.onConnectionState = _onPeerConnectionStateChanged;

    // SDP offer 생성
    final offer = await pc.createOffer();
    if (_isEnding) return '';
    await pc.setLocalDescription(offer);
    if (_isEnding) return '';

    // 시그널링: callType="monitor"
    final callId = await _signaling.createCall(
      {'sdp': offer.sdp, 'type': offer.type},
      targetDeviceId: targetDeviceId,
      callerUid: callerUid,
      callerName: callerName,

      targetFamilyId: familyId,
      callType: 'monitor',
    );
    // hangUp이 중간에 호출된 경우 orphan 정리
    if (_isEnding) {
      print('WebRTC: startMonitoring 중 hangUp 감지 → orphan call 정리 callId=$callId');
      await _signaling.endCall(callId);
      await _signaling.cleanupCall(callId);
      return '';
    }
    _callId = callId;

    await _signaling.setCallCleanupOnDisconnect(callId);
    if (_isEnding) { await _signaling.endCall(callId); await _signaling.cleanupCall(callId); return ''; }

    _flushPendingCandidates();
    _registerSignalingListeners(callId);

    print('WebRTC: 모니터링 발신 완료 callId=$callId');
    return callId;
  }

  // ─── 통화 발신 (RecvOnly 시작) ───

  /// (`Method`, async) 통화 발신 — RecvOnly로 시작 → Senior 수락 후 양방향 자동 전환
  ///
  /// 모니터링과 동일하게 RecvOnly로 연결을 수립하되, callType="call"로 Senior에 벨소리 표시.
  /// Senior가 수락하면 `seniorAccepted=true`가 RTDB에 기록되고,
  /// [_listenForSeniorAccepted]가 감지하여 [upgradeToCall]을 자동 호출.
  /// 로컬 카메라 프리뷰는 PeerConnection에 미추가 상태로 미리 시작.
  /// - **Params**:
  ///   - [targetDeviceId] — 수신 대상 Senior 기기 ID
  ///   - [callerUid] — 발신자 Firebase UID
  ///   - [callerName] — 발신자 표시 이름
  ///   - [familyId] — 소속 가족 그룹 ID
  /// - **Returns**: `String` — 생성된 callId
  /// - **Side Effects**: PeerConnection 생성 (RecvOnly), 로컬 프리뷰 시작, Senior 수락 감시
  /// - **호출**: MonitoringScreen._startCall
  Future<String> startCall(String targetDeviceId, {String? callerUid, String? callerName, String? familyId}) async {
    if (!_fsm.to(CallPhase.connecting, reason: 'startCall')) return '';
    _isMonitoring = true; // RecvOnly로 시작
    _myIceCandidatePath = 'callerCandidates';
    print('WebRTC: 통화 발신 시작 → target=$targetDeviceId');

    final pc = await createPeerConnection(_iceServers);
    if (_isEnding) { await pc.close(); return ''; }
    _peerConnection = pc;

    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    if (_isEnding) return '';
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    if (_isEnding) return '';

    pc.onTrack = _onTrack;
    pc.onIceCandidate = _onIceCandidate;
    pc.onConnectionState = _onPeerConnectionStateChanged;

    final offer = await pc.createOffer();
    if (_isEnding) return '';
    await pc.setLocalDescription(offer);
    if (_isEnding) return '';

    final callId = await _signaling.createCall(
      {'sdp': offer.sdp, 'type': offer.type},
      targetDeviceId: targetDeviceId,
      callerUid: callerUid,
      callerName: callerName,

      targetFamilyId: familyId,
      callType: 'call',
    );
    // hangUp이 createCall 진행 중에 호출된 경우 — orphan call 생성된 상태.
    // Senior가 받기 전에 즉시 정리.
    if (_isEnding) {
      print('WebRTC: startCall 중 hangUp 감지 → orphan call 정리 callId=$callId');
      await _signaling.endCall(callId);
      await _signaling.cleanupCall(callId);
      return '';
    }
    _callId = callId;

    await _signaling.setCallCleanupOnDisconnect(callId);
    if (_isEnding) { await _signaling.endCall(callId); await _signaling.cleanupCall(callId); return ''; }

    _flushPendingCandidates();
    _registerSignalingListeners(callId);

    // 로컬 카메라 프리뷰 시작 (상대방에게 미전송)
    await _startLocalPreviewOnly();
    if (_isEnding) return callId;

    // Senior 수락 대기
    _listenForSeniorAccepted(callId);

    print('WebRTC: 통화 발신 완료, Senior 수락 대기 callId=$callId');
    _startAecStats();
    return callId;
  }

  // ─── 로컬 프리뷰 ───

  /// (`Utility`, async) 로컬 카메라 프리뷰만 ON (PeerConnection track 미추가)
  ///
  /// 상대방에게 영상이 전송되지 않는 상태로 카메라 프리뷰를 표시.
  /// Senior 수락 전에 Family 쪽 PIP에서 자신의 영상을 미리 볼 수 있도록.
  /// - **Side Effects**: _localStream 생성, localRenderer에 연결
  /// - **호출**: [startCall]
  Future<void> _startLocalPreviewOnly() async {
    try {
      _localStream = await _getLocalStream();
      localRenderer.srcObject = _localStream;
      print('WebRTC: 로컬 프리뷰 시작 (미전송)');
    } catch (e) {
      print('WebRTC: 로컬 프리뷰 실패: $e');
    }
  }

  // ─── Senior 수락 감지 ───

  /// (`Stream`) Senior 수락 감지 → [upgradeToCall] 자동 호출
  ///
  /// RTDB `calls/{callId}/seniorAccepted`가 true로 변경되면 양방향 전환 시작.
  /// - **Params**:
  ///   - [callId] — 감시할 통화 ID
  /// - **Side Effects**: _seniorAcceptedSub 구독 시작
  /// - **호출**: [startCall]
  void _listenForSeniorAccepted(String callId) {
    _seniorAcceptedSub = FirebaseDatabase.instance
        .ref('calls/$callId/seniorAccepted')
        .onValue
        .listen((event) {
      if (event.snapshot.value == true && _callId == callId) {
        print('WebRTC: Senior 수락 감지 → 양방향 전환');
        upgradeToCall();
      }
    });
  }

  // ─── 모니터링 → 통화 전환 ───

  /// (`Method`, async) 모니터링 → 양방향 통화 전환 (SDP renegotiation)
  ///
  /// RecvOnly transceiver를 SendRecv로 변경하고 로컬 트랙을 추가한 뒤,
  /// 새 SDP offer를 생성하여 Senior에 전송. Senior가 renegotiation answer를 보내면 전환 완료.
  /// - **Side Effects**: transceiver 방향 변경, 로컬 트랙 추가, _isMonitoring=false (전환 완료 시)
  /// - **호출**: [_listenForSeniorAccepted] (자동), MonitoringScreen._upgradeToCall (수동)
  Future<void> upgradeToCall() async {
    // 진입 조건: connected 또는 connecting 허용 (connecting 에선 답신 전 race 허용 — 기존 동작 유지)
    final currentPhase = _fsm.phase.value;
    if (currentPhase != CallPhase.connected &&
        currentPhase != CallPhase.connecting) return;
    if (_peerConnection == null || _callId == null) return;
    if (!_fsm.to(CallPhase.upgrading, reason: 'senior_accepted')) return;
    print('WebRTC: 모니터링 → 통화 전환');

    // 로컬 미디어 획득 (startCall에서 이미 프리뷰 시작했으면 재사용)
    if (_localStream == null) {
      _localStream = await _getLocalStream();
      if (_isEnding) return;
      localRenderer.srcObject = _localStream;
    }

    // 기존 transceiver를 sendrecv로 변경 + 로컬 트랙 추가
    final pc = _peerConnection;
    if (pc == null || _isEnding) return;
    final transceivers = await pc.getTransceivers();
    if (_isEnding) return;
    for (final t in transceivers) {
      final kind = t.sender.track?.kind ?? t.receiver.track?.kind;
      if (kind == 'video') {
        final videoTrack = _localStream?.getVideoTracks().firstOrNull;
        if (videoTrack != null) {
          await t.sender.replaceTrack(videoTrack);
          if (_isEnding) return;
          await t.setDirection(TransceiverDirection.SendRecv);
          if (_isEnding) return;
        }
      } else if (kind == 'audio') {
        final audioTrack = _localStream?.getAudioTracks().firstOrNull;
        if (audioTrack != null) {
          await t.sender.replaceTrack(audioTrack);
          if (_isEnding) return;
          await t.setDirection(TransceiverDirection.SendRecv);
          if (_isEnding) return;
        }
      }
    }

    // 비트레이트 설정
    await _setVideoBitrate(pc, 4000);
    if (_isEnding) return;

    // renegotiation offer 생성
    final offer = await pc.createOffer();
    if (_isEnding) return;
    await pc.setLocalDescription(offer);
    if (_isEnding) return;

    // _callId를 로컬 변수로 고정 — hangUp이 null 세팅해도 영향 없음
    final cid = _callId;
    if (cid == null || _isEnding) return;

    // 전환 요청 + renegotiate offer 전송
    // NetworkException (오프라인 등) → upgradeFailed 로 종결, 모니터링은 유지.
    try {
      await _signaling.requestUpgrade(cid);
      if (_isEnding) return;
      await _signaling.sendRenegotiateOffer(cid, {
        'sdp': offer.sdp,
        'type': offer.type,
      });
      if (_isEnding) return;
    } on NetworkException catch (e) {
      print('WebRTC: upgrade 네트워크 실패 → connected 복귀 $e');
      // 통화 죽이지 않음 — upgrading → connected 복귀 (모니터링 유지)
      if (_fsm.phase.value == CallPhase.upgrading) {
        _fsm.to(CallPhase.connected, reason: 'upgrade_network_fail');
      }
      return;
    }

    // renegotiate answer 감시
    _signaling.listenForRenegotiateAnswer(cid, (answer) async {
      if (_isEnding) return;
      await _peerConnection?.setRemoteDescription(
        RTCSessionDescription(answer['sdp'], answer['type']),
      );
      if (_isEnding) return;
      print('WebRTC: 통화 전환 완료 (양방향)');
      _isMonitoring = false;
      if (_fsm.phase.value == CallPhase.upgrading) {
        _fsm.to(CallPhase.connected, reason: 'renegotiate_done');
      }
    });
  }

  // ─── 상태 접근자 ───

  /// (`Getter`) 현재 모니터링(RecvOnly) 모드인지 여부
  ///
  /// - **Returns**: `bool` — true이면 단방향 수신 중, false이면 양방향 통화 중
  /// - **호출**: MonitoringScreen._watchUpgrade, _upgradeToCall
  bool get isMonitoring => _isMonitoring;

  // ─── 통화 종료 ───

  /// (`Method`, async) 통화 종료 — 미디어/PeerConnection 정리 + RTDB status="ended"
  ///
  /// 모든 종결 경로의 단일 진입점. 중복 호출 방지, 로컬 트랙 정지,
  /// PeerConnection 종료, 시그널링 endCall 후 2초 대기하여 상대방 감지 시간 확보 후 RTDB 노드 삭제.
  /// - **Params**:
  ///   - [reason] — 종결 사유 (기본값 userHangup). MonitoringScreen UX 매핑에 사용.
  /// - **Side Effects**: FSM terminating→terminated 전이, 모든 미디어/연결 리소스 해제, RTDB 상태 업데이트
  /// - **호출**: MonitoringScreen._hangUp(userHangup), 연결 끊김/실패 자동(iceFailed/remoteEnded/...)
  Future<void> hangUp({TerminateReason reason = TerminateReason.userHangup}) async {
    if (_fsm.isEnding) return; // 중복 호출 차단
    _fsm.reason = reason; // MonitoringScreen 이 읽기 전에 세팅
    // ★ terminating 먼저 전이 — 다른 async 경로 즉시 차단
    if (!_fsm.to(CallPhase.terminating, reason: 'hangup:${reason.name}')) return;
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _stableTimer?.cancel();
    _stableTimer = null;
    _iceRestartAnswerTimer?.cancel();
    _iceRestartAnswerTimer = null;
    _stopAecStats();

    // 모든 시그널링 구독 해제 (callEnd 콜백이 hangUp을 다시 호출하는 루프 방지)
    await _answerSub?.cancel();
    await _calleeCandidatesSub?.cancel();
    await _callEndSub?.cancel();
    await _iceRestartAnswerSub?.cancel();
    await _seniorAcceptedSub?.cancel();
    _answerSub = null;
    _calleeCandidatesSub = null;
    _callEndSub = null;
    _iceRestartAnswerSub = null;
    _seniorAcceptedSub = null;

    // ICE restart 상태 리셋
    isReconnecting.value = false;
    answerReceived.value = false;
    _iceRestartInProgress = false;
    _iceRestartAttempts = 0;
    _flapWindowStart = null;
    _pendingCandidates.clear();

    // 자기 hangUp 시 listenForCallEnd 콜백 방지
    onCallEnded = null;
    print('WebRTC: 통화 종료');

    // 로컬 트랙 정지
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;

    // PeerConnection 종료
    await _peerConnection?.close();
    _peerConnection = null;

    _remoteStream = null;
    try {
      remoteRenderer.srcObject = null;
      localRenderer.srcObject = null;
    } catch (_) {}

    // ★ UI 즉시 반응: terminated 먼저 전이 (RTDB write 결과와 독립)
    // 오프라인이어도 MonitoringScreen 이 즉시 dialog/pop 하도록.
    if (_callId != null) {
      final cid = _callId!;
      _callId = null;
      _fsm.to(CallPhase.terminated, reason: 'cleanup_done');
      // RTDB 정리는 best-effort background — 실패해도 UI 영향 없음.
      // signaling_service 쪽 writeOrTimeout / 노드 존재 체크로 orphan 방어됨.
      // cleanupCall 은 내부에서 10초 fire-and-forget 지연을 수행하여
      // Senior 가 status="ended" 를 안정적으로 수신할 시간을 확보.
      () async {
        try {
          await _signaling.endCall(cid);
        } catch (e) {
          print('시그널링: endCall 실패 (무시) $e');
        }
        try {
          await _signaling.cleanupCall(cid);
        } catch (e) {
          print('시그널링: cleanupCall 실패 (무시) $e');
        }
      }();
    } else {
      _fsm.to(CallPhase.terminated, reason: 'cleanup_done');
    }
  }

  // ─── 리소스 해제 ───

  /// (`Lifecycle`, async) 리소스 전체 해제 — hangUp + 렌더러 dispose
  ///
  /// - **Side Effects**: 통화 종료 + localRenderer/remoteRenderer 해제
  /// - **호출**: MonitoringScreen.dispose
  Future<void> dispose() async {
    await hangUp();
    await localRenderer.dispose();
    await remoteRenderer.dispose();
    isReconnecting.dispose();
    answerReceived.dispose();
    _fsm.dispose();
  }
}
