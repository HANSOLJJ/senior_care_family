import 'dart:async';
import 'package:firebase_database/firebase_database.dart';
import '../network_guard.dart';

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
  /// - **Returns**: `StreamSubscription` — 호출자가 보관 후 hangUp/dispose 시 cancel
  /// - **호출**: WebRtcService.makeCall, startMonitoring, startCall
  StreamSubscription listenForAnswer(
    String callId,
    void Function(Map<String, dynamic> answer) onAnswer,
  ) {
    return _db.child('calls/$callId/answer').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      onAnswer(Map<String, dynamic>.from(data));
    });
  }

  /// (`Stream`) 통화 종료 감시 (발신측 — 상대방이 끊었는지 확인)
  ///
  /// `/calls/{cid}/status` 가 `"ended"` 로 변경되면 콜백 호출.
  /// `endReason` 서브필드도 함께 읽어 콜백에 전달하여 세부 사유 (`remoteBusy`/
  /// `capacityExceeded`/`otherCallStarted`/`normal`) 를 매핑할 수 있게 한다.
  /// - **Params**:
  ///   - [callId] — 감시할 통화 ID
  ///   - [onCallEnded] — 종료 감지 시 콜백. endReason 전달 (없으면 null).
  /// - **Returns**: `StreamSubscription` — 호출자가 보관 후 hangUp/dispose 시 cancel
  /// - **호출**: WebRtcService.makeCall, answerCall, startMonitoring, startCall
  StreamSubscription listenForCallEnd(
    String callId,
    void Function(String? endReason) onCallEnded,
  ) {
    // status 경로만 구독 (ICE candidate push 등 무관한 변경에 안 반응).
    // "ended" 감지 시 endReason 을 1회 get 으로 조회.
    return _db.child('calls/$callId/status').onValue.listen((event) async {
      final status = event.snapshot.value as String?;
      if (status != 'ended') return;
      String? endReason;
      try {
        final snap = await _db.child('calls/$callId/endReason').get();
        endReason = snap.value as String?;
      } catch (_) {
        endReason = null;
      }
      print('시그널링: 상대방이 통화 종료 callId=$callId endReason=$endReason');
      onCallEnded(endReason);
    });
  }

  // ─── ICE candidate 교환 ───

  /// (`Stream`) ICE candidate 감시 (상대방 candidate 수신)
  ///
  /// - **Params**:
  ///   - [callId] — 통화 ID
  ///   - [path] — RTDB 하위 경로 (`"callerCandidates"` 또는 `"calleeCandidates"`)
  ///   - [onCandidate] — candidate 수신 시 콜백
  /// - **Returns**: `StreamSubscription` — 호출자가 보관 후 hangUp/dispose 시 cancel
  /// - **호출**: WebRtcService (양측 ICE candidate 교환)
  StreamSubscription listenForCandidates(
    String callId,
    String path,
    void Function(Map<String, dynamic> candidate) onCandidate,
  ) {
    return _db.child('calls/$callId/$path').onChildAdded.listen((event) {
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
  ///   - [targetFamilyId] — 대상 가족 그룹 ID
  ///   - [callType] — `"call"` 또는 `"monitor"`
  /// - **Returns**: `String` — 생성된 callId
  /// - **Side Effects**: RTDB에 통화 노드 생성, _currentCallId 설정
  /// - **호출**: WebRtcService.makeCall, startMonitoring, startCall
  Future<String> createCall(
    Map<String, dynamic> offer, {
    required String targetDeviceId,
    String? callerUid,
    String? callerName,
    String? targetFamilyId,
    String callType = 'call',
  }) async {
    final callRef = _db.child('calls').push();
    final callId = callRef.key!;
    final name = callerName ?? '가족';
    await writeOrTimeout(
      () => callRef.set({
        'offer': offer,
        'targetDeviceId': targetDeviceId,
        'targetFamilyId': targetFamilyId,
        'callerUid': callerUid,
        'callerName': name,
        'callType': callType,
        'status': 'ringing',
        'createdAt': ServerValue.timestamp,
      }),
      label: callType == 'monitor' ? '모니터링 요청' : '통화 요청',
      onTimeoutCleanup: () => callRef.remove(),
    );
    _currentCallId = callId;

    // `callStatus` 는 Senior 가 유일 writer (plan v2). Family 는 write 안 함.

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
  /// 앱이 비정상 종료 (wifi 끊김 / 앱 크래시) 되면 RTDB 가 hasFlapMarker=true set.
  /// 상대 측 listenForFlapMarker 가 grace 진입을 담당.
  /// - **Params**:
  ///   - [callId] — 통화 ID
  /// - **Side Effects**: RTDB onDisconnect 핸들러 등록 (hasFlapMarker=true)
  /// - **호출**: WebRtcService.answerCall, makeCall, startMonitoring, startCall
  Future<void> setCallCleanupOnDisconnect(String callId) async {
    await _db.child('calls/$callId').onDisconnect().update({
      'hasFlapMarker': true,
    });
    print('시그널링: onDisconnect hasFlapMarker 등록 callId=$callId');
  }

  /// (`Method`, async) wifi 복귀 후 자기 hasFlapMarker clear
  ///
  /// 자기 마커를 clear 해서 상대 grace timer 를 cancel 시킴.
  /// best-effort — 실패해도 Senior 측 자체 clear + CF stub cleanup 으로 회복.
  /// RTDB SDK 가 reconnect 시 자동 재전송하므로 writeOrTimeout 불필요.
  /// - **Params**:
  ///   - [callId] — 통화 ID
  /// - **Side Effects**: RTDB hasFlapMarker 필드 제거
  /// - **호출**: WebRtcService _flapMarkerSub (자기 마커 받았을 때)
  Future<void> clearFlapMarker(String callId) async {
    await _db.child('calls/$callId/hasFlapMarker').remove();
    print('시그널링: hasFlapMarker clear callId=$callId');
  }

  /// (`Stream`) hasFlapMarker 변경 감시
  ///
  /// 상대방 (또는 자기) wifi 끊김으로 Firebase onDisconnect 가 set 한 마커 감지.
  /// - **Params**:
  ///   - [callId] — 감시할 통화 ID
  ///   - [onFlap] — 마커 변경 시 콜백 (true=마커 set, false/null=clear)
  /// - **Returns**: `StreamSubscription` — 호출자가 보관 후 hangUp/dispose 시 cancel
  /// - **호출**: WebRtcService (자기 마커 감지), Senior MonitoringSession (상대 마커 감지)
  StreamSubscription listenForFlapMarker(
    String callId,
    void Function(bool hasFlap) onFlap,
  ) {
    return _db.child('calls/$callId/hasFlapMarker').onValue.listen((event) {
      final value = event.snapshot.value;
      onFlap(value == true);
    });
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
    // 노드 존재 확인 후 status + endReason 업데이트 — 이미 cleanup 된 노드 부활 방지
    final snap = (await _db.child('calls/$callId').once()).snapshot;
    if (snap.exists) {
      // R2 fix: status="ended" 와 함께 endReason="remoteEnded" 도 set.
      // Senior server-side onDisconnect 가 남긴 stale endReason="seniorDisconnect"
      // 마커를 덮어써서, Senior 가 wifi 복귀 후 자기 결과로 오판하고
      // restoreActiveStatus 호출하는 좀비 race 차단.
      // 호출자의 TerminateReason 과 무관하게 항상 "remoteEnded" 단일 값 — Senior
      // 입장에선 Family 가 어떤 이유로 끝냈든 후속 동작 동일 (stopPeer + 정리).
      await writeOrTimeout(
        () => _db.child('calls/$callId').update({
          'status': 'ended',
          'endReason': 'remoteEnded',
        }),
        label: '통화 종료 신호',
        timeout: const Duration(seconds: 2),
      );
    }
    // callStatus write 제거 — Senior 가 유일 writer (setValue(null))
    // Family UI 즉시 반영은 MonitoringScreen pop 으로 이미 처리됨.
    print('시그널링: 통화 종료 callId=$callId');
  }

  /// (`Method`, async) 통화 데이터 삭제 (지연 fire-and-forget)
  ///
  /// `endCall` 이 `status="ended"` 를 쓴 뒤 즉시 노드를 지우면,
  /// Senior `MonitoringPeer` 의 status 리스너가 "ended" 를 받기 전에
  /// 노드가 사라져 버려서 (status=null 로 관측) dispose 되지 않고 좀비가 됨.
  /// 그 결과 다음 call/monitor 요청이 `remoteBusy` 로 거절되는 버그가 발생.
  ///
  /// → 10 초 지연 후 remove 를 실행하여 Senior 가 안정적으로 "ended" 를 수신.
  /// 호출자는 즉시 반환받고, 실제 remove 는 백그라운드에서 수행.
  /// Family 앱이 10 초 내 종료되면 노드가 남지만 Cloud Function
  /// `cleanupOrphanedData` (매일 3시) 가 정리.
  ///
  /// - **Params**:
  ///   - [callId] — 삭제할 통화 ID
  /// - **Side Effects**: 10 초 후 RTDB `/calls/{callId}` 노드 삭제 (백그라운드)
  /// - **호출**: WebRtcService.hangUp, orphan cleanup 경로
  Future<void> cleanupCall(String callId) async {
    Future.delayed(const Duration(seconds: 10), () async {
      try {
        await _db.child('calls/$callId').remove();
      } catch (e) {
        print('시그널링: cleanupCall 지연 remove 실패 (무시) $e');
      }
    });
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
    // 노드 존재 + status 체크 — cleanup 된 노드에 set 하면 orphan 부활
    final snap = (await _db.child('calls/$callId/status').once()).snapshot;
    if (snap.value == null || snap.value == 'ended') {
      print('시그널링: upgrade skip — node gone/ended callId=$callId');
      return;
    }
    await writeOrTimeout(
      () => _db.child('calls/$callId/upgradeRequest').set('call'),
      label: '통화 전환 요청',
      timeout: const Duration(seconds: 3),
    );
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
    final snap = (await _db.child('calls/$callId/status').once()).snapshot;
    if (snap.value == null || snap.value == 'ended') {
      print('시그널링: renegotiate skip — node gone/ended callId=$callId');
      return;
    }
    await writeOrTimeout(
      () => _db.child('calls/$callId/renegotiateOffer').set(offer),
      label: 'renegotiate offer',
      timeout: const Duration(seconds: 3),
    );
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

  // ─── ICE Restart (네트워크 일시 단절 후 재협상) ───

  /// (`Method`, async) ICE restart offer 전송
  ///
  /// IN_CALL 중 peer가 DISCONNECTED/FAILED 상태가 되면 Family가 새 offer를
  /// 생성해 Senior에게 보낸다. SDP는 `pc.restartIce() + createOffer()` 결과.
  /// - **Params**:
  ///   - [callId] — 통화 ID
  ///   - [offer] — restart offer SDP (`{sdp, type}`)
  /// - **Side Effects**: RTDB `calls/{cid}/iceRestartOffer` 노드 set
  /// - **호출**: WebRtcService._triggerIceRestart
  Future<void> sendIceRestartOffer(String callId, Map<String, dynamic> offer) async {
    // ICE restart 는 오프라인 상태에서 작동해야 하므로 status 체크 안 함.
    // onTimeoutCleanup 은 쓰지 않음 — 오프라인 동안 큐잉된 set(offer) 가
    // 복구 시 flush 되어 Senior 에 도달하는 것이 복구 경로이기 때문.
    // remove() 를 cleanup 으로 넣으면 set 과 race 를 유발하고 throw 시점도
    // 7~10초 밀림 (onTimeoutCleanup 자체가 offline 큐에 hang).
    // stale offer 노드 정리는:
    //   - 정상 복구: Senior sendIceRestartAnswer 가 answer 쓰기 전 offer 선제 삭제
    //   - 실패 종결: hangUp → cleanupCall 이 calls/{cid} 통째 삭제
    //   - 앱 크래시: Family onDisconnect 가 calls/{cid} 통째 삭제
    await writeOrTimeout(
      () => _db.child('calls/$callId/iceRestartOffer').set(offer),
      label: 'ICE restart offer',
      timeout: const Duration(seconds: 3),
    );
    print('시그널링: ICE restart offer 전송 callId=$callId');
  }

  /// (`Stream`) ICE restart answer 감시
  ///
  /// Senior가 새 answer를 RTDB에 쓰면 콜백 호출. 호출자가 setRemoteDescription 수행.
  /// - **Params**:
  ///   - [callId] — 통화 ID
  ///   - [onAnswer] — answer 수신 시 콜백
  /// - **Returns**: `StreamSubscription` — 호출자가 보관 후 hangUp/dispose 시 cancel
  /// - **호출**: WebRtcService.startCall/makeCall/startMonitoring (PC 생성 직후 1회)
  StreamSubscription listenForIceRestartAnswer(
    String callId,
    void Function(Map<String, dynamic> answer) onAnswer,
  ) {
    return _db.child('calls/$callId/iceRestartAnswer').onValue.listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) return;
      onAnswer(Map<String, dynamic>.from(data));
    });
  }

  // ─── 정리 ───

  // 잔존 calls 정리는 CF `cleanupOrphanedData` (매일 3시) 의 Step 7 에서 처리.
  // 과거 `cleanupStaleCalls` 는 호출자 부재 + 다른 사용자 활성 통화 잘못 삭제 위험으로 제거됨 (2026-04-28).

  /// (`Lifecycle`) 리소스 해제 — 수신 통화 감시 구독 취소
  ///
  /// - **호출**: MonitoringScreen.dispose 등
  void dispose() {
    _callListener?.cancel();
  }
}
