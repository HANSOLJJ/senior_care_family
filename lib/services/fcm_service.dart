import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:just_audio/just_audio.dart';
import '../config/app_config.dart';

/// 백그라운드 FCM 메시지 핸들러 (`Utility`, top-level)
///
/// Flutter 엔진이 백그라운드 isolate에서 호출하므로 반드시 top-level 함수여야 한다.
/// `@pragma('vm:entry-point')`로 트리셰이킹 방지.
///
/// - **Params**:
///   - [message] — 수신된 FCM 메시지
/// - **호출**: main.dart에서 `FirebaseMessaging.onBackgroundMessage()`로 등록
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print('FCM 백그라운드 메시지 수신: ${message.messageId}');
}

/// FCM 푸시 알림 서비스 (`Service`) — 알림 수신·벨소리·토큰 관리
///
/// 역할:
/// - 알림 권한 요청 + FCM 토큰을 RTDB에 저장
/// - 포그라운드 메시지 수신 → [onCallReceived] 콜백 호출
/// - 백그라운드 알림 탭 → 앱 열기 + 통화 처리
/// - 벨소리 재생/정지 (just_audio 루프 모드)
///
/// RTDB 경로:
///   - `/devices/{deviceId}/fcmToken` — FCM 토큰 저장
///     (현재 Family는 `/devices/`에 미등록이므로 이 경로는 비활성 상태)
///
/// 주요 흐름:
///   [initialize] → 권한 요청 → 토큰 저장 → 메시지 리스너 등록
///   포그라운드 메시지 → data['type'] == 'call' → onCallReceived 콜백
///   백그라운드 알림 탭 → onMessageOpenedApp → _handleIncomingCall
class FcmService {
  /// Firebase Messaging 싱글턴 인스턴스
  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  /// 벨소리 재생용 오디오 플레이어 (just_audio)
  final AudioPlayer _ringtonePlayer = AudioPlayer();

  // ─── 초기화 ───

  /// FCM 초기화: 권한 요청 + 토큰 저장 + 메시지 리스너 등록 (`Method`, async)
  ///
  /// 앱 시작 시 1회 호출. 알림 권한을 요청하고, FCM 토큰을 RTDB에 저장한 뒤,
  /// 포그라운드/백그라운드 메시지 리스너를 등록한다.
  ///
  /// - **Params**:
  ///   - [onCallReceived] — 통화 메시지 수신 시 호출할 콜백 함수
  /// - **Side Effects**:
  ///   - 알림 권한 다이얼로그 표시 (최초 1회)
  ///   - RTDB `/devices/{deviceId}/fcmToken` 에 토큰 기록
  ///   - FirebaseMessaging.onMessage, onMessageOpenedApp, onTokenRefresh 리스너 등록
  /// - **호출**: device_list_screen.dart 초기화 시
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

  // ─── 토큰 관리 ───

  /// FCM 토큰을 RTDB에 저장 (`Method`, async, private)
  ///
  /// `/devices/{deviceId}/fcmToken` 경로에 토큰을 기록한다.
  /// deviceId가 비어있거나 토큰이 null이면 무시.
  ///
  /// - **Params**:
  ///   - [token] — FCM 토큰 문자열 (null이면 저장 안 함)
  /// - **Side Effects**: RTDB `/devices/{deviceId}/fcmToken` 쓰기
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

  // ─── 메시지 처리 ───

  /// 백그라운드 알림 탭 시 통화 메시지 처리 (`Method`, private)
  ///
  /// data['type'] == 'call'인 메시지만 통화로 간주하여 콜백 호출.
  ///
  /// - **Params**:
  ///   - [message] — 수신된 FCM 메시지
  ///   - [onCallReceived] — 통화 수신 콜백
  void _handleIncomingCall(
    RemoteMessage message,
    void Function(RemoteMessage) onCallReceived,
  ) {
    // 'type' 필드가 'call'인 메시지만 통화로 처리
    if (message.data['type'] == 'call') {
      onCallReceived(message);
    }
  }

  // ─── 벨소리 ───

  /// 벨소리 재생 시작 (`Method`, async)
  ///
  /// `assets/sounds/ringtone.mp3`를 루프 모드로 재생.
  /// `play()`는 루프 모드에서 영원히 끝나지 않으므로 await하지 않는다.
  ///
  /// - **Side Effects**: 오디오 출력 시작 (LoopMode.one)
  /// - **호출**: 영상통화 수신 시 (현재 Family는 발신 전용이라 미사용 가능)
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

  /// 벨소리 정지 (`Method`, async)
  ///
  /// - **Side Effects**: 오디오 출력 정지
  /// - **호출**: 통화 응답/거절 시
  Future<void> stopRingtone() async {
    await _ringtonePlayer.stop();
    print('벨소리 정지');
  }

  // ─── 리소스 해제 ───

  /// 오디오 플레이어 리소스 해제 (`Method`, async)
  ///
  /// 앱 종료 또는 서비스 폐기 시 호출하여 네이티브 리소스를 정리한다.
  ///
  /// - **Side Effects**: AudioPlayer 네이티브 리소스 해제
  Future<void> dispose() async {
    await _ringtonePlayer.dispose();
  }
}
