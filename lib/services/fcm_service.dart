import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:just_audio/just_audio.dart';
import '../main.dart';

/// 백그라운드 FCM 메시지 핸들러 (top-level 함수여야 함)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('FCM 백그라운드 메시지 수신: ${message.messageId}');
}

class FcmService {
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final AudioPlayer _ringtonePlayer = AudioPlayer();

  /// FCM 초기화: 권한 요청 + 토큰 RTDB 저장 + 메시지 리스너 등록
  Future<void> initialize({
    required void Function(RemoteMessage message) onCallReceived,
  }) async {
    // 알림 권한 요청
    final settings = await _messaging.requestPermission(
      alert: true,
      sound: true,
      badge: false,
    );
    print('FCM 알림 권한: ${settings.authorizationStatus}');

    // FCM 토큰 가져오기 + RTDB 저장
    final token = await _messaging.getToken();
    print('========================================');
    print('FCM 토큰: $token');
    print('========================================');
    await _saveTokenToRtdb(token);

    // 토큰 갱신 리스너
    _messaging.onTokenRefresh.listen((newToken) {
      print('FCM 토큰 갱신: $newToken');
      _saveTokenToRtdb(newToken);
    });

    // 포그라운드 메시지 수신
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      print('FCM 포그라운드 메시지: ${message.data}');
      // 콘솔 테스트용: data 비어있어도 콜백 호출
      if (message.data.isEmpty || message.data['type'] == 'call') {
        onCallReceived(message);
      }
    });

    // 백그라운드에서 알림 탭 → 앱 열림
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      print('FCM 알림 탭으로 앱 열림: ${message.data}');
      _handleIncomingCall(message, onCallReceived);
    });
  }

  /// FCM 토큰을 RTDB /devices/{deviceId}/fcmToken 에 저장
  Future<void> _saveTokenToRtdb(String? token) async {
    if (token == null || AppConfig.deviceId.isEmpty) return;
    try {
      await FirebaseDatabase.instance
          .ref('devices/${AppConfig.deviceId}/fcmToken')
          .set(token);
      print('FCM 토큰 RTDB 저장 완료');
    } catch (e) {
      print('FCM 토큰 RTDB 저장 실패: $e');
    }
  }

  void _handleIncomingCall(
    RemoteMessage message,
    void Function(RemoteMessage) onCallReceived,
  ) {
    // 'type' 필드가 'call'인 메시지만 통화로 처리
    if (message.data['type'] == 'call') {
      onCallReceived(message);
    }
  }

  /// 벨소리 재생 (비동기로 시작, await하지 않음 — 루프 모드라 play()가 끝나지 않으므로)
  Future<void> playRingtone() async {
    try {
      await _ringtonePlayer.setAsset('assets/sounds/ringtone.mp3');
      await _ringtonePlayer.setLoopMode(LoopMode.one);
      _ringtonePlayer.play(); // await 하면 루프 때문에 영원히 안 끝남
      print('벨소리 재생 시작');
    } catch (e) {
      print('벨소리 재생 실패: $e');
    }
  }

  /// 벨소리 정지
  Future<void> stopRingtone() async {
    await _ringtonePlayer.stop();
    print('벨소리 정지');
  }

  /// 리소스 해제
  Future<void> dispose() async {
    await _ringtonePlayer.dispose();
  }
}
