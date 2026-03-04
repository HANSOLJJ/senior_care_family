import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'screens/slideshow_screen.dart';
import 'screens/incoming_call_screen.dart';
import 'services/fcm_service.dart';
import 'services/signaling_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 장치별 앱 설정 (런타임 감지)
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await AppConfig.initialize();

  // 백그라운드 FCM 핸들러 등록
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // 빨간 에러 화면 대신 빈 화면 표시
  ErrorWidget.builder = (FlutterErrorDetails details) {
    print('ErrorWidget: ${details.exception}');
    return const SizedBox.shrink();
  };

  runApp(const SmartFrameApp());
}

class SmartFrameApp extends StatefulWidget {
  const SmartFrameApp({super.key});

  @override
  State<SmartFrameApp> createState() => _SmartFrameAppState();
}

class _SmartFrameAppState extends State<SmartFrameApp> {
  final FcmService _fcmService = FcmService();
  final SignalingService _signalingService = SignalingService();

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    // FCM + 시그널링은 즉시 시작 (통화 수신 가능하게)
    _initFcm();
    _initSignaling();

    // Firebase RTDB 기기 등록 + 잔존 통화 정리 (백그라운드, 타임아웃 10초)
    try {
      await AppConfig.registerDevice().timeout(const Duration(seconds: 10));
    } catch (e) {
      print('기기 등록 실패/타임아웃: $e');
    }
    try {
      await SignalingService.cleanupStaleCalls().timeout(const Duration(seconds: 5));
    } catch (e) {
      print('잔존 통화 정리 실패: $e');
    }
  }

  Future<void> _initFcm() async {
    await _fcmService.initialize(
      onCallReceived: (message) {
        print('FCM 통화 수신! callerId: ${message.data['callerId']}');
        // FCM으로 온 경우 callId/offer 없이 수신 화면 표시
        _navigateToIncomingCall();
      },
    );
  }

  /// Firebase Realtime DB에서 새 통화 감시 (내 기기만 수신)
  void _initSignaling() {
    _signalingService.listenForIncomingCalls(
      myDeviceId: AppConfig.deviceId,
      onCallReceived: (callId, offer) {
        print('Realtime DB 통화 수신! callId=$callId');
        _navigateToIncomingCall(callId: callId, offer: offer);
      },
    );
  }

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
