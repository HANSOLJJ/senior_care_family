import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'screens/slideshow_screen.dart';
import 'screens/incoming_call_screen.dart';
import 'services/fcm_service.dart';
import 'services/signaling_service.dart';

/// 전역 네비게이터 키: 어디서든 화면 전환 가능하게 해주는 키.
/// MaterialApp에 등록하고, _navigateToIncomingCall() 등에서
/// navigatorKey.currentState?.push(...)로 사용.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 장치별 앱 설정을 담는 싱글톤 클래스.(singleton --> 인스턴스 딱 1개)
/// - initialize(): 기기 모델명/ID를 읽어 static 변수에 저장
/// - registerDevice(): Firebase RTDB에 기기 등록 + 연결 끊김 시 자동 offline 처리
/// 모든 필드가 static이라 AppConfig.deviceId 처럼 어디서든 접근 가능.
class AppConfig {
  static bool enableFaceDetection = true;
  static int countdownSeconds = 3;
  static int faceDetectionTimeout = 15;
  static String deviceModel = 'unknown';
  static String deviceId = '';

  /// 장치 정보를 읽고 설정 자동 분기
  static Future<void> initialize() async {
    final deviceInfo = DeviceInfoPlugin();
    final android = await deviceInfo.androidInfo;
    deviceModel = android.model;
    // android.id (Build.ID)에 Firebase RTDB 경로 금지 문자('.', '#', '$', '[', ']')가 포함될 수 있음
    deviceId = android.id.replaceAll(RegExp(r'[.#$\[\]]'), '_');
    final board = android.board;

    print('AppConfig: model=$deviceModel, id=$deviceId, board=$board');

    enableFaceDetection = true;
    print('AppConfig: 얼굴 감지 ON (model=$deviceModel)');
  }

  /// Firebase RTDB에 기기 등록 + onDisconnect 설정
  static Future<void> registerDevice() async {
    if (deviceId.isEmpty) return;
    final db = FirebaseDatabase.instance;
    final deviceRef = db.ref('devices/$deviceId');

    await deviceRef.update({
      'model': deviceModel,
      'name': deviceModel,
      'lastSeen': ServerValue.timestamp,
      'online': true,
    });
    await deviceRef.onDisconnect().update({
      'online': false,
      'lastSeen': ServerValue.timestamp,
    });
    print('기기 등록 완료: $deviceModel ($deviceId)');

    // RTDB 재연결 감지 → 자동으로 online 복구
    db.ref('.info/connected').onValue.listen((event) async {
      final connected = event.snapshot.value as bool? ?? false;
      if (connected) {
        print('RTDB 재연결 → online 복구');
        await deviceRef.update({
          'online': true,
          'lastSeen': ServerValue.timestamp,
        });
        await deviceRef.onDisconnect().update({
          'online': false,
          'lastSeen': ServerValue.timestamp,
        });
      }
    });
  }
}

/// 앱 진입점. Flutter 프레임워크에서 가장 먼저 호출되는 함수.
/// 순서: Flutter엔진 초기화 → Firebase 초기화 → 기기정보 로드 → FCM 백그라운드 등록 → UI 시작
/// 여기서 await로 호출하는 것들은 runApp() 전에 반드시 완료되어야 하는 작업들.
void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Flutter 엔진 바인딩 (async 사용 전 필수)
  await Firebase.initializeApp(); // Firebase SDK 초기화
  await AppConfig.initialize(); // 기기 model, deviceId 읽기

  // 백그라운드 FCM 핸들러 등록
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // 빨간 에러 화면 대신 빈 화면 표시
  ErrorWidget.builder = (FlutterErrorDetails details) {
    print('ErrorWidget: ${details.exception}');
    return const SizedBox.shrink();
  };

  runApp(const SmartFrameApp());
  //The runApp() function takes the given Widget and makes it the root of the widget tree.
}

/// 앱의 최상위 위젯. StatefulWidget이라 상태(_SmartFrameAppState)를 가짐.
/// Flutter에서 위젯은 UI를 그리는 단위이고, StatefulWidget은 생명주기가 있어서
/// initState(시작), dispose(종료) 시점에 서비스를 켜고 끌 수 있음.
class SmartFrameApp extends StatefulWidget {
  const SmartFrameApp({super.key});

  @override
  State<SmartFrameApp> createState() => _SmartFrameAppState();
}

/// SmartFrameApp의 실제 상태+로직 클래스.
/// - initState(): 위젯이 처음 생성될 때 1번 호출 → 모든 서비스 초기화
/// - dispose(): 위젯이 파괴될 때 호출 → 서비스 정리
/// - build(): 화면을 그릴 때 호출 → MaterialApp + SlideshowScreen 반환
///
/// _fcmService: 푸시 알림(FCM) 수신 담당
/// _signalingService: Firebase RTDB 실시간 통화 감시 담당
class _SmartFrameAppState extends State<SmartFrameApp> {
  final FcmService _fcmService = FcmService();
  final SignalingService _signalingService = SignalingService();

  @override
  void initState() {
    super.initState();
    _initServices(); // 비동기로 서비스 시작 (화면은 먼저 뜸)
  }

  /// 모든 백엔드 서비스를 초기화하는 메서드.
  /// _initFcm()과 _initSignaling()은 await 없이 호출 → 동시에 시작됨.
  /// registerDevice()와 cleanupStaleCalls()는 await → 순서대로 실행 + 타임아웃 보호.
  Future<void> _initServices() async {
    _initFcm(); // FCM 푸시 수신 시작
    _initSignaling(); // RTDB 통화 감시 시작

    // Firebase RTDB 기기 등록 + 잔존 통화 정리 (백그라운드, 타임아웃 10초)
    try {
      await AppConfig.registerDevice().timeout(const Duration(seconds: 10));
    } catch (e) {
      print('기기 등록 실패/타임아웃: $e');
    }
    try {
      await SignalingService.cleanupStaleCalls().timeout(
        const Duration(seconds: 5),
      );
    } catch (e) {
      print('잔존 통화 정리 실패: $e');
    }
  }

  /// FCM(Firebase Cloud Messaging) 초기화.
  /// 토큰을 등록하고, 푸시 알림이 오면 onCallReceived 콜백 실행.
  /// FCM은 RTDB 연결이 안 될 때의 백업 수신 경로.
  Future<void> _initFcm() async {
    await _fcmService.initialize(
      onCallReceived: (message) {
        print('FCM 통화 수신! callerId: ${message.data['callerId']}');
        // FCM으로 온 경우 callId/offer 없이 수신 화면 표시
        _navigateToIncomingCall();
      },
    );
  }

  /// Firebase RTDB에서 /calls/ 노드를 실시간 감시.
  /// 새 통화가 생기고 targetDeviceId가 내 기기면 onCallReceived 콜백 실행.
  /// FCM보다 빠름 (실시간 DB vs 푸시), 메인 수신 경로.
  void _initSignaling() {
    _signalingService.listenForIncomingCalls(
      myDeviceId: AppConfig.deviceId,
      onCallReceived: (callId, offer) {
        print('Realtime DB 통화 수신! callId=$callId');
        _navigateToIncomingCall(callId: callId, offer: offer);
      },
    );
  }

  /// 수신 화면(IncomingCallScreen)으로 이동.
  /// navigatorKey를 통해 현재 화면(슬라이드쇼) 위에 새 화면을 push.
  /// callId/offer가 있으면 RTDB 경유, 없으면 FCM 경유 수신.
  void _navigateToIncomingCall({String? callId, Map<String, dynamic>? offer}) {
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => IncomingCallScreen(
          fcmService: _fcmService,
          callId: callId,
          offer: offer,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _fcmService.dispose();
    _signalingService.dispose();
    super.dispose();
  }

  /// 화면을 그리는 메서드. MaterialApp이 앱 전체를 감싸고,
  /// home: SlideshowScreen이 첫 화면(디지털 액자).
  /// navigatorKey를 등록해서 어디서든 화면 전환 가능.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Smart Frame',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const SlideshowScreen(),
    );
  }
}
