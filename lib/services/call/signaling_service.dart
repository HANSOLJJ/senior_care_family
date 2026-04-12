import 'dart:async';
import 'package:firebase_database/firebase_database.dart';

/// (`Service`) Firebase Realtime DB 시그널링 서비스
///
/// WebRTC 연결 수립에 필요한 SDP offer/answer 및 ICE candidate를 RTDB를 통해 교환.
/// Family(발신) ↔ Senior(수신) 간의 시그널링 채널 역할.
///
/// RTDB 경로: `/calls/{callId}/`
///   - `offer`: SDP offer (발신자 → 수신자)
///   - `answer`: SDP answer (수신자 → 발신자)
///   - `callerCandidates/`: ICE candidates (발신자)
///   - `calleeCandidates/`: ICE candidates (수신자)
///   - `status`: `"ringing"` | `"connected"` | `"ended"`
///   - `targetDeviceId`: 수신 대상 기기 ID
///   - `callType`: `"call"` | `"monitor"` (모니터링/통화 구분)
///   - `upgradeRequest`: `"call"` (모니터링→통화 전환 시)
///   - `renegotiateOffer/renegotiateAnswer`: SDP renegotiation (양방향 전환)
///
/// 주요 흐름:
///   1. [createCall] — 발신자가 offer + 메타데이터 RTDB에 저장
///   2. [sendAnswer] — 수신자가 answer 전송 + status="connected"
///   3. [addCandidate] — 양측 ICE candidate 교환
///   4. [endCall] — 통화 종료 (status="ended" + callStatus 초기화)
///   5. [cleanupCall] — RTDB 노드 삭제 (종료 후 정리)
class SignalingService {
  /// RTDB 루트 참조
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  /// 수신 통화 감시 구독 (dispose 시 해제)
  StreamSubscription? _callListener;

  /// 현재 활성 통화 ID
  String? _currentCallId;

  /// 현재 통화의 대상 가족 그룹 ID (callStatus 초기화에 사용)
  String? _currentFamilyId;

  // ─── 수신 감시 ───

  /// (`Method`) 새로운 통화 요청 감시 (수신측) — targetDeviceId 필터링
  ///
  /// `/calls` 하위에 새 노드가 추가되면 status="ringing"이고
  /// targetDeviceId가 내 기기 ID와 일치하는 경우에만 콜백 호출.
  /// - **Params**:
  ///   - [myDeviceId] — 수신 기기의 고유 ID
  ///   - [onCallReceived] — 통화 수신 시 콜백 (callId, offer 데이터)
  /// - **Side Effects**: _callListener 구독 시작
  /// - **호출**: Senior 앱의 수신 대기 로직
  void listenForIncomingCalls({
    required String myDeviceId,
    required void Function(String callId, Map<String, dynamic> offer)
    onCallReceived,
  }) {
    _callListener = _db.child('calls').onChildAdded.listen((event) {
      final callId = event.snapshot.key;
      final data = event.snapshot.value as Map?;
      if (callId == null || data == null) return;

      final status = data['status'];
      if (status != 'ringing') return;

      // targetDeviceId 필터링: 내 기기 ID와 일치해야만 수신
      final targetId = data['targetDeviceId'] as String?;
      if (targetId != null && targetId != myDeviceId) {
        print('시그널링: 다른 기기 대상 통화 무시 (target=$targetId, me=$myDeviceId)');
        return;
      }

      final offer = data['offer'] as Map?;
      if (offer == null) return;

      print('시그널링: 새 통화 수신 callId=$callId (target=$targetId)');
      onCallReceived(callId, Map<String, dynamic>.from(offer));
    });
  }

  // ─── SDP 교환 ───

  /// (`Stream`) SDP offer 감시 (수신측 — 통화 ID로 직접 접근)
  ///
  /// - **Params**:
  ///   - [callId] — 감시할 통화 ID
  ///   - [onOffer] — offer 수신 시 콜백
  /// - **Side Effects**: _currentCallId 설정
  /// - **호출**: Senior 앱 (통화 수신 시)
  void listenForOffer(
    String callId,
    void Function(Map<String, dynamic> offer) onOffer,
  ) {
    _currentCallId = callId;
    _db.child('calls/$callId/offer').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      onOffer(Map<String, dynamic>.from(data));
    });
  }

  /// (`Stream`) SDP answer 감시 (발신측)
  ///
  /// 수신자가 answer를 RTDB에 저장하면 콜백 호출.
  /// - **Params**:
  ///   - [callId] — 감시할 통화 ID
  ///   - [onAnswer] — answer 수신 시 콜백
  /// - **호출**: WebRtcService.makeCall, startMonitoring, startCall
  void listenForAnswer(
    String callId,
    void Function(Map<String, dynamic> answer) onAnswer,
  ) {
    _db.child('calls/$callId/answer').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      onAnswer(Map<String, dynamic>.from(data));
    });
  }

  /// (`Stream`) 통화 종료 감시 (발신측 — 상대방이 끊었는지 확인)
  ///
  /// status가 "ended"로 변경되면 콜백 호출.
  /// - **Params**:
  ///   - [callId] — 감시할 통화 ID
  ///   - [onCallEnded] — 종료 감지 시 콜백
  /// - **호출**: WebRtcService.makeCall, answerCall, startMonitoring, startCall
  void listenForCallEnd(String callId, void Function() onCallEnded) {
    _db.child('calls/$callId/status').onValue.listen((event) {
      final status = event.snapshot.value as String?;
      if (status == 'ended') {
        print('시그널링: 상대방이 통화 종료 callId=$callId');
        onCallEnded();
      }
    });
  }

  // ─── ICE candidate 교환 ───

  /// (`Stream`) ICE candidate 감시 (상대방 candidate 수신)
  ///
  /// - **Params**:
  ///   - [callId] — 통화 ID
  ///   - [path] — RTDB 하위 경로 (`"callerCandidates"` 또는 `"calleeCandidates"`)
  ///   - [onCandidate] — candidate 수신 시 콜백
  /// - **호출**: WebRtcService (양측 ICE candidate 교환)
  void listenForCandidates(
    String callId,
    String path,
    void Function(Map<String, dynamic> candidate) onCandidate,
  ) {
    _db.child('calls/$callId/$path').onChildAdded.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      onCandidate(Map<String, dynamic>.from(data));
    });
  }

  // ─── 통화 생성/종료 ───

  /// (`Method`, async) SDP offer 저장 + 통화 생성 (발신측)
  ///
  /// RTDB `/calls/{callId}` 에 offer, caller 정보, callType 등을 기록.
  /// callType="call"인 경우 `families/{fid}/callStatus`에 통화 상태도 기록.
  /// - **Params**:
  ///   - [offer] — SDP offer 데이터 (`{sdp, type}`)
  ///   - [targetDeviceId] — 수신 대상 Senior 기기 ID
  ///   - [callerUid] — 발신자 Firebase UID
  ///   - [callerName] — 발신자 표시 이름
  ///   - [callerDeviceId] — 발신자 기기 ID
  ///   - [targetFamilyId] — 대상 가족 그룹 ID
  ///   - [callType] — `"call"` 또는 `"monitor"`
  /// - **Returns**: `String` — 생성된 callId
  /// - **Side Effects**: RTDB에 통화 노드 생성, _currentCallId/_currentFamilyId 설정
  /// - **호출**: WebRtcService.makeCall, startMonitoring, startCall
  Future<String> createCall(
    Map<String, dynamic> offer, {
    required String targetDeviceId,
    String? callerUid,
    String? callerName,
    String? callerDeviceId,
    String? targetFamilyId,
    String callType = 'call',
  }) async {
    final callRef = _db.child('calls').push();
    final callId = callRef.key!;
    final name = callerName ?? '가족';
    final label = '$name → $targetDeviceId ($callType) ringing';
    await callRef.set({
      '_label': label,
      'offer': offer,
      'targetDeviceId': targetDeviceId,
      'targetFamilyId': targetFamilyId,
      'callerUid': callerUid,
      'callerName': name,
      'callerDeviceId': callerDeviceId,
      'callType': callType,
      'status': 'ringing',
      'createdAt': ServerValue.timestamp,
    });
    _currentCallId = callId;
    _currentFamilyId = targetFamilyId;

    // families/{fid}/callStatus 기록 (통화 중 표시 — callType="call" 전용)
    // 모니터링은 Senior MonitoringSession이 count-aware하게 관리하므로 Family에서 건드리지 않음
    if (targetFamilyId != null && callType == 'call') {
      await _db.child('families/$targetFamilyId/callStatus').set({
        'active': true,
        'type': callType,
        'callId': callId,
        'callerName': name,
        'startedAt': ServerValue.timestamp,
      });
    }

    print('시그널링: ${callType == "monitor" ? "모니터링" : "통화"} 생성 callId=$callId → target=$targetDeviceId');
    return callId;
  }

  /// (`Method`, async) SDP answer 저장 + 연결 상태 업데이트 (수신측)
  ///
  /// - **Params**:
  ///   - [callId] — 통화 ID
  ///   - [answer] — SDP answer 데이터 (`{sdp, type}`)
  /// - **Side Effects**: RTDB answer 저장 + status를 "connected"로 변경
  /// - **호출**: WebRtcService.answerCall
  Future<void> sendAnswer(String callId, Map<String, dynamic> answer) async {
    await _db.child('calls/$callId/answer').set(answer);
    await _db.child('calls/$callId/status').set('connected');
    print('시그널링: answer 전송 callId=$callId');
  }

  /// (`Method`, async) ICE candidate 추가
  ///
  /// - **Params**:
  ///   - [callId] — 통화 ID
  ///   - [path] — RTDB 하위 경로 (`"callerCandidates"` 또는 `"calleeCandidates"`)
  ///   - [candidate] — ICE candidate 데이터
  /// - **호출**: WebRtcService (PeerConnection의 onIceCandidate 콜백)
  Future<void> addCandidate(
    String callId,
    String path,
    Map<String, dynamic> candidate,
  ) async {
    await _db.child('calls/$callId/$path').push().set(candidate);
  }

  /// (`Method`, async) 통화 응답 시 onDisconnect 설정 (비정상 종료 대비)
  ///
  /// 앱이 비정상 종료되면 RTDB가 자동으로 통화 노드를 삭제.
  /// - **Params**:
  ///   - [callId] — 통화 ID
  /// - **Side Effects**: RTDB onDisconnect 핸들러 등록
  /// - **호출**: WebRtcService.answerCall, makeCall, startMonitoring, startCall
  Future<void> setCallCleanupOnDisconnect(String callId) async {
    await _db.child('calls/$callId').onDisconnect().remove();
    print('시그널링: onDisconnect 설정 callId=$callId');
  }

  /// (`Method`, async) 통화 종료 — status="ended" + callStatus 초기화
  ///
  /// 정상 종료이므로 onDisconnect 핸들러를 먼저 취소한 뒤 status 업데이트.
  /// - **Params**:
  ///   - [callId] — 종료할 통화 ID
  /// - **Side Effects**: RTDB status="ended", callStatus.active=false, _currentFamilyId 초기화
  /// - **호출**: WebRtcService.hangUp
  Future<void> endCall(String callId) async {
    // onDisconnect 취소 (정상 종료이므로)
    await _db.child('calls/$callId').onDisconnect().cancel();
    await _db.child('calls/$callId/status').set('ended');

    // families/{fid}/callStatus 초기화
    if (_currentFamilyId != null) {
      await _db.child('families/$_currentFamilyId/callStatus').update({'active': false});
      _currentFamilyId = null;
    }

    print('시그널링: 통화 종료 callId=$callId');
  }

  /// (`Method`, async) 통화 데이터 삭제 (종료 후 정리)
  ///
  /// - **Params**:
  ///   - [callId] — 삭제할 통화 ID
  /// - **Side Effects**: RTDB `/calls/{callId}` 노드 삭제
  /// - **호출**: WebRtcService.hangUp (endCall 후 2초 딜레이)
  Future<void> cleanupCall(String callId) async {
    await _db.child('calls/$callId').remove();
  }

  // ─── 모니터링 → 통화 전환 ───

  /// (`Method`, async) 모니터링 → 통화 전환 요청
  ///
  /// RTDB에 upgradeRequest="call"을 기록하여 Senior에게 전환 의사를 알림.
  /// - **Params**:
  ///   - [callId] — 통화 ID
  /// - **Side Effects**: RTDB upgradeRequest 필드 설정
  /// - **호출**: WebRtcService.upgradeToCall
  Future<void> requestUpgrade(String callId) async {
    await _db.child('calls/$callId/upgradeRequest').set('call');
    print('시그널링: 통화 전환 요청 callId=$callId');
  }

  /// (`Method`, async) Renegotiation offer 전송 (모니터링→통화 전환 시)
  ///
  /// RecvOnly에서 SendRecv로 전환하기 위한 새로운 SDP offer.
  /// - **Params**:
  ///   - [callId] — 통화 ID
  ///   - [offer] — renegotiation SDP offer (`{sdp, type}`)
  /// - **Side Effects**: RTDB renegotiateOffer 필드 설정
  /// - **호출**: WebRtcService.upgradeToCall
  Future<void> sendRenegotiateOffer(String callId, Map<String, dynamic> offer) async {
    await _db.child('calls/$callId/renegotiateOffer').set(offer);
    print('시그널링: renegotiate offer 전송 callId=$callId');
  }

  /// (`Stream`) Renegotiation answer 감시
  ///
  /// Senior가 renegotiation answer를 보내면 콜백 호출.
  /// - **Params**:
  ///   - [callId] — 통화 ID
  ///   - [onAnswer] — answer 수신 시 콜백
  /// - **호출**: WebRtcService.upgradeToCall
  void listenForRenegotiateAnswer(
    String callId,
    void Function(Map<String, dynamic> answer) onAnswer,
  ) {
    _db.child('calls/$callId/renegotiateAnswer').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      onAnswer(Map<String, dynamic>.from(data));
    });
  }

  // ─── 정리 ───

  /// (`Utility`, static, async) 앱 시작 시 잔존 통화 정리 (5분 이상 지난 통화 삭제)
  ///
  /// 비정상 종료 등으로 남아있는 오래된 통화 노드를 일괄 삭제.
  /// - **Side Effects**: RTDB `/calls/` 하위 5분 초과 노드 삭제
  /// - **호출**: 앱 초기화 시 (main.dart 또는 app.dart)
  static Future<void> cleanupStaleCalls() async {
    try {
      final db = FirebaseDatabase.instance.ref();
      final snapshot = await db.child('calls').get();
      if (!snapshot.exists) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      final calls = snapshot.value as Map;
      int cleaned = 0;

      for (final entry in calls.entries) {
        final data = entry.value as Map?;
        if (data == null) continue;

        final createdAt = data['createdAt'] as int?;
        if (createdAt != null && (now - createdAt) > 5 * 60 * 1000) {
          await db.child('calls/${entry.key}').remove();
          cleaned++;
        }
      }

      if (cleaned > 0) {
        print('시그널링: 잔존 통화 $cleaned개 정리 완료');
      }
    } catch (e) {
      print('시그널링: 잔존 통화 정리 실패: $e');
    }
  }

  /// (`Lifecycle`) 리소스 해제 — 수신 통화 감시 구독 취소
  ///
  /// - **호출**: MonitoringScreen.dispose 등
  void dispose() {
    _callListener?.cancel();
  }
}
