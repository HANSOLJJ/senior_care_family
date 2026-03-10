import 'dart:async';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'signaling_service.dart';

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

/// WebRTC 피어 연결 + 미디어 스트림 관리
class WebRtcService {
  final SignalingService _signaling;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  String? _callId;
  bool _isHungUp = false;
  Timer? _disconnectTimer;
  Timer? _aecStatsTimer;

  /// 상대방 끊김 감지 시 호출되는 콜백
  void Function()? onCallEnded;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  WebRtcService(this._signaling);

  Future<void> initialize() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
  }

  /// 로컬 미디어 스트림 획득
  Future<MediaStream> _getLocalStream() async {
    return await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'user',
        'width': 640,
        'height': 480,
      },
    });
  }

  /// PeerConnection 공통 설정
  Future<RTCPeerConnection> _createPc(String callId, {required String myCandidatesPath}) async {
    final pc = await createPeerConnection(_iceServers);

    // 로컬 트랙 추가
    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    // 원격 스트림 수신
    pc.onTrack = (RTCTrackEvent event) {
      print('WebRTC: 원격 트랙 수신 kind=${event.track.kind}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        remoteRenderer.srcObject = _remoteStream;
      }
    };

    // ICE candidate → 시그널링 서버에 전송
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      _signaling.addCandidate(callId, myCandidatesPath, {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    // 연결 상태 감시 — 끊김 감지 → 5초 후 자동 종료
    pc.onConnectionState = (RTCPeerConnectionState state) {
      print('WebRTC: 연결 상태 = $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _disconnectTimer?.cancel();
        _disconnectTimer = Timer(const Duration(seconds: 5), () {
          final currentState = _peerConnection?.connectionState;
          if (currentState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
              currentState == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
            print('WebRTC: 5초간 복구 안 됨 → 자동 종료');
            hangUp();
            onCallEnded?.call();
          }
        });
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _disconnectTimer?.cancel();
        print('WebRTC: 연결 실패 → 자동 종료');
        hangUp();
        onCallEnded?.call();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _disconnectTimer?.cancel();
      }
    };

    return pc;
  }

  /// 수신 처리: offer를 받아 answer를 보내고 연결
  Future<void> answerCall(String callId, Map<String, dynamic> offer) async {
    _isHungUp = false;
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

    // 7. 발신자 통화 종료 감시
    _signaling.listenForCallEnd(callId, () {
      print('WebRTC: 발신자가 통화 종료');
      hangUp();
      onCallEnded?.call();
    });

    print('WebRTC: 통화 연결 완료');
    _startAecStats();
  }

  /// AEC 메트릭 로깅 시작 (5초 간격)
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

  void _stopAecStats() {
    _aecStatsTimer?.cancel();
    _aecStatsTimer = null;
  }

  /// 발신 처리: offer를 생성하여 전송하고 answer를 기다림
  Future<String> makeCall(String targetDeviceId) async {
    _isHungUp = false;
    print('WebRTC: 발신 시작 → target=$targetDeviceId');

    // 1. 로컬 미디어 스트림
    _localStream = await _getLocalStream();
    localRenderer.srcObject = _localStream;

    // 2. ICE candidate 큐 (callId 확정 전에 수집)
    final pendingCandidates = <RTCIceCandidate>[];
    String? resolvedCallId;

    // 3. PeerConnection 생성 — onIceCandidate를 먼저 등록
    final pc = await createPeerConnection(_iceServers);
    _peerConnection = pc;

    for (final track in _localStream!.getTracks()) {
      await pc.addTrack(track, _localStream!);
    }

    pc.onTrack = (RTCTrackEvent event) {
      print('WebRTC: 원격 트랙 수신 kind=${event.track.kind}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams[0];
        remoteRenderer.srcObject = _remoteStream;
      }
    };

    // ICE candidate → callId 있으면 즉시 전송, 없으면 큐에 저장
    pc.onIceCandidate = (RTCIceCandidate candidate) {
      if (resolvedCallId != null) {
        _signaling.addCandidate(resolvedCallId, 'callerCandidates', {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      } else {
        pendingCandidates.add(candidate);
      }
    };

    // 연결 상태 감시
    pc.onConnectionState = (RTCPeerConnectionState state) {
      print('WebRTC: 연결 상태 = $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _disconnectTimer?.cancel();
        _disconnectTimer = Timer(const Duration(seconds: 5), () {
          final currentState = _peerConnection?.connectionState;
          if (currentState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
              currentState == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
            print('WebRTC: 5초간 복구 안 됨 → 자동 종료');
            hangUp();
            onCallEnded?.call();
          }
        });
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _disconnectTimer?.cancel();
        print('WebRTC: 연결 실패 → 자동 종료');
        hangUp();
        onCallEnded?.call();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _disconnectTimer?.cancel();
      }
    };

    // 4. SDP offer 생성
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    // 5. 시그널링 서버에 통화 생성 (targetDeviceId 포함)
    final callId = await _signaling.createCall(
      {'sdp': offer.sdp, 'type': offer.type},
      targetDeviceId: targetDeviceId,
    );
    _callId = callId;
    resolvedCallId = callId;

    // onDisconnect 설정
    await _signaling.setCallCleanupOnDisconnect(callId);

    // 큐에 쌓인 ICE candidate 전송
    print('WebRTC: 대기 중 ICE candidate ${pendingCandidates.length}개 전송');
    for (final c in pendingCandidates) {
      _signaling.addCandidate(callId, 'callerCandidates', {
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    }
    pendingCandidates.clear();

    // 6. 수신자의 answer 감시
    _signaling.listenForAnswer(callId, (answer) async {
      if (_peerConnection?.signalingState ==
          RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        print('WebRTC: SDP answer 수신');
        await _peerConnection?.setRemoteDescription(
          RTCSessionDescription(answer['sdp'], answer['type']),
        );
      }
    });

    // 7. 수신자의 ICE candidates 감시
    _signaling.listenForCandidates(callId, 'calleeCandidates', (candidate) {
      print('WebRTC: 수신자 ICE candidate 수신');
      _peerConnection?.addCandidate(RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'],
        candidate['sdpMLineIndex'],
      ));
    });

    // 8. 상대방 통화 종료 감시
    _signaling.listenForCallEnd(callId, () {
      print('WebRTC: 상대방이 통화 종료');
      hangUp();
      onCallEnded?.call();
    });

    print('WebRTC: 발신 완료, answer 대기 중 callId=$callId');
    _startAecStats();
    return callId;
  }

  /// 통화 종료
  Future<void> hangUp() async {
    if (_isHungUp) return;
    _isHungUp = true;
    _disconnectTimer?.cancel();
    _disconnectTimer = null;
    _stopAecStats();
    print('WebRTC: 통화 종료');

    // 로컬 트랙 정지
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _localStream = null;

    // PeerConnection 종료
    await _peerConnection?.close();
    _peerConnection = null;

    // 시그널링 종료: status='ended' 설정 후 2초 대기 → 상대방이 감지할 시간 확보
    if (_callId != null) {
      final cid = _callId!;
      _callId = null;
      await _signaling.endCall(cid);
      Future.delayed(const Duration(seconds: 2), () {
        _signaling.cleanupCall(cid);
      });
    }

    _remoteStream = null;
    try {
      remoteRenderer.srcObject = null;
      localRenderer.srcObject = null;
    } catch (_) {}
  }

  /// 리소스 해제
  Future<void> dispose() async {
    await hangUp();
    await localRenderer.dispose();
    await remoteRenderer.dispose();
  }
}
