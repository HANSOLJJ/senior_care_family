import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';
import '../services/face_detection_service.dart';
import '../services/fcm_service.dart';
import 'video_call_screen.dart';

/// 수신 화면: 벨소리 + 전면 카메라 + 얼굴 감지
/// 얼굴 감지 시 → 3초 카운트다운 → 영상 통화 연결
/// 타임아웃 시 → TTS 안내 → 슬라이드쇼 복귀
class IncomingCallScreen extends StatefulWidget {
  final FcmService fcmService;
  final String? callId;
  final Map<String, dynamic>? offer;

  const IncomingCallScreen({
    super.key,
    required this.fcmService,
    this.callId,
    this.offer,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  final FaceDetectionService _faceService = FaceDetectionService();
  final FlutterTts _tts = FlutterTts();
  CameraController? _cameraController;

  String _statusText = '전화가 왔습니다';
  int? _countdown;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // 얼굴 감지 비활성화 시 바로 영상 통화 연결
    if (!AppConfig.enableFaceDetection) {
      print('얼굴 감지 OFF (${AppConfig.deviceModel}) → 바로 연결');
      _connectVideoCall();
      return;
    }

    // 2. 카메라 권한 요청
    final cameraStatus = await Permission.camera.request();
    print('카메라 권한: $cameraStatus');
    if (!cameraStatus.isGranted) {
      print('카메라 권한 거부됨');
      if (_disposed) return;
      _handleTimeout();
      return;
    }

    // 3. 워밍업 중이면 카메라 해제 후 진행
    await FaceDetectionService.cancelWarmup();

    // 4. 카메라 초기화 + 얼굴 감지 시작
    try {
      final controller = await _faceService.initCamera();
      if (_disposed) return;
      setState(() {
        _cameraController = controller;
      });

      await _faceService.startDetection(
        onFaceDetected: (faceCount) {
          if (_disposed) return;
          print('얼굴 $faceCount개 감지 → ${AppConfig.countdownSeconds}초 카운트다운 시작');
              _startCountdown();
        },
        onTimeout: () {
          if (_disposed) return;
          print('얼굴 감지 타임아웃 → TTS 안내');
              _handleTimeout();
        },
        timeoutSeconds: AppConfig.faceDetectionTimeout,
      );
    } catch (e) {
      print('카메라/얼굴감지 초기화 실패: $e');
      if (_disposed) return;
      _handleTimeout();
    }
  }

  /// 얼굴 감지 후 3초 카운트다운
  void _startCountdown() {
    setState(() {
      _statusText = '연결 중...';
      _countdown = AppConfig.countdownSeconds;
    });

    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }

      setState(() {
        _countdown = _countdown! - 1;
      });

      if (_countdown! <= 0) {
        timer.cancel();
        _connectVideoCall();
      }
    });
  }

  /// 영상 통화 연결
  Future<void> _connectVideoCall() async {
    if (_disposed || !mounted) return;

    // face detection 카메라를 먼저 완전히 해제 (WebRTC 카메라와 충돌 방지)
    await _faceService.dispose();
    _cameraController = null;
    print('얼굴 감지 카메라 해제 완료');

    if (!mounted) return;

    if (widget.callId != null && widget.offer != null) {
      // WebRTC 영상 통화 화면으로 전환
      print('영상 통화 연결! callId=${widget.callId}');
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => VideoCallScreen(
            callId: widget.callId!,
            offer: widget.offer!,
          ),
        ),
      );
    } else {
      // callId/offer 없으면 슬라이드쇼로 복귀 (FCM 콘솔 테스트 등)
      print('영상 통화 연결 — callId 없음, 슬라이드쇼 복귀');
      Navigator.of(context).pop();
    }
  }

  /// 타임아웃 → TTS 안내 → 슬라이드쇼 복귀
  Future<void> _handleTimeout() async {
    setState(() {
      _statusText = '연결할 수 없습니다';
    });

    try {
      await _tts.setLanguage('ko-KR');
      await _tts.setSpeechRate(0.5);
      await _tts.speak('지금은 연결할 수 없습니다');
      // TTS 완료 대기
      await Future.delayed(const Duration(seconds: 3));
    } catch (e) {
      print('TTS 실패: $e');
      await Future.delayed(const Duration(seconds: 2));
    }

    if (!_disposed && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _faceService.dispose();
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 카메라 프리뷰 (영상 송출 X, 로컬만)
          if (_cameraController != null &&
              _cameraController!.value.isInitialized &&
              !_cameraController!.value.hasError)
            Builder(
              builder: (context) {
                try {
                  return Center(
                    child: Opacity(
                      opacity: 0.3,
                      child: CameraPreview(_cameraController!),
                    ),
                  );
                } catch (e) {
                  print('카메라 프리뷰 에러: $e');
                  return const SizedBox.shrink();
                }
              },
            ),

          // 상태 텍스트 + 카운트다운
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.phone_in_talk, size: 80, color: Colors.white),
                const SizedBox(height: 24),
                Text(
                  _statusText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_countdown != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '$_countdown',
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 64,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
