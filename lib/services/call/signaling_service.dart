import 'dart:async';
import 'package:firebase_database/firebase_database.dart';

/// Firebase Realtime DB 시그널링 서비스
/// 경로: /calls/{callId}/
///   - offer: SDP offer (발신자 → 수신자)
///   - answer: SDP answer (수신자 → 발신자)
///   - callerCandidates/: ICE candidates (발신자)
///   - calleeCandidates/: ICE candidates (수신자)
///   - status: "ringing" | "connected" | "ended"
///   - targetDeviceId: 수신 대상 기기 ID
///   - callType: "call" | "monitor" (모니터링/통화 구분)
///   - upgradeRequest: "call" (모니터링→통화 전환 시)
///   - renegotiateOffer/renegotiateAnswer: SDP renegotiation
class SignalingService {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  StreamSubscription? _callListener;
  String? _currentCallId;

  /// 새로운 통화 요청 감시 (수신측) — targetDeviceId 필터링
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

  /// SDP offer 감시 (수신측 — 통화 ID로 직접 접근)
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

  /// SDP answer 감시 (발신측)
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

  /// 통화 종료 감시 (발신측 — 상대방이 끊었는지 확인)
  void listenForCallEnd(String callId, void Function() onCallEnded) {
    _db.child('calls/$callId/status').onValue.listen((event) {
      final status = event.snapshot.value as String?;
      if (status == 'ended') {
        print('시그널링: 상대방이 통화 종료 callId=$callId');
        onCallEnded();
      }
    });
  }

  /// ICE candidate 감시 (상대방)
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

  /// SDP offer 저장 (발신측) — targetDeviceId + caller 정보 포함
  Future<String> createCall(
    Map<String, dynamic> offer, {
    required String targetDeviceId,
    String? callerUid,
    String? callerName,
    String callType = 'call',
  }) async {
    final callRef = _db.child('calls').push();
    final callId = callRef.key!;
    await callRef.set({
      'offer': offer,
      'targetDeviceId': targetDeviceId,
      'callerUid': callerUid,
      'callerName': callerName ?? '가족',
      'callType': callType,
      'status': 'ringing',
      'createdAt': ServerValue.timestamp,
    });
    _currentCallId = callId;
    print('시그널링: ${callType == "monitor" ? "모니터링" : "통화"} 생성 callId=$callId → target=$targetDeviceId');
    return callId;
  }

  /// SDP answer 저장 (수신측)
  Future<void> sendAnswer(String callId, Map<String, dynamic> answer) async {
    await _db.child('calls/$callId/answer').set(answer);
    await _db.child('calls/$callId/status').set('connected');
    print('시그널링: answer 전송 callId=$callId');
  }

  /// ICE candidate 추가
  Future<void> addCandidate(
    String callId,
    String path,
    Map<String, dynamic> candidate,
  ) async {
    await _db.child('calls/$callId/$path').push().set(candidate);
  }

  /// 통화 응답 시 onDisconnect 설정 (비정상 종료 대비)
  Future<void> setCallCleanupOnDisconnect(String callId) async {
    await _db.child('calls/$callId').onDisconnect().remove();
    print('시그널링: onDisconnect 설정 callId=$callId');
  }

  /// 통화 종료
  Future<void> endCall(String callId) async {
    // onDisconnect 취소 (정상 종료이므로)
    await _db.child('calls/$callId').onDisconnect().cancel();
    await _db.child('calls/$callId/status').set('ended');
    print('시그널링: 통화 종료 callId=$callId');
  }

  /// 통화 데이터 삭제 (정리)
  Future<void> cleanupCall(String callId) async {
    await _db.child('calls/$callId').remove();
  }

  /// 모니터링 → 통화 전환 요청
  Future<void> requestUpgrade(String callId) async {
    await _db.child('calls/$callId/upgradeRequest').set('call');
    print('시그널링: 통화 전환 요청 callId=$callId');
  }

  /// Renegotiation offer 전송 (모니터링→통화 전환 시)
  Future<void> sendRenegotiateOffer(String callId, Map<String, dynamic> offer) async {
    await _db.child('calls/$callId/renegotiateOffer').set(offer);
    print('시그널링: renegotiate offer 전송 callId=$callId');
  }

  /// Renegotiation answer 감시
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

  /// 앱 시작 시 잔존 통화 정리 (5분 이상 지난 통화 삭제)
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

  /// 리소스 해제
  void dispose() {
    _callListener?.cancel();
  }
}
