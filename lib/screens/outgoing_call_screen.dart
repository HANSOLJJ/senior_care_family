import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/signaling_service.dart';
import '../services/webrtc_service.dart';

/// 발신 대기 → 영상통화 화면
class OutgoingCallScreen extends StatefulWidget {
  final String targetDeviceId;
  final String targetDeviceName;

  const OutgoingCallScreen({
    super.key,
    required this.targetDeviceId,
    required this.targetDeviceName,
  });

  @override
  State<OutgoingCallScreen> createState() => _OutgoingCallScreenState();
}

class _OutgoingCallScreenState extends State<OutgoingCallScreen> {
  final SignalingService _signaling = SignalingService();
  late final WebRtcService _webrtc;
  bool _connected = false;
  bool _calling = true;
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _webrtc = WebRtcService(_signaling);
    _webrtc.onCallEnded = _onRemoteHangUp;
    _startCall();
  }

  Future<void> _startCall() async {
    try {
      await _webrtc.initialize();
      await _webrtc.makeCall(widget.targetDeviceId);

      // 30초 타임아웃
      _timeoutTimer = Timer(const Duration(seconds: 30), () {
        if (_calling && !_connected && mounted) {
          print('OutgoingCall: 30초 타임아웃');
          _hangUp();
        }
      });

      // 연결 상태 주기적 확인
      Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (!mounted) { timer.cancel(); return; }
        if (_webrtc.remoteRenderer.srcObject != null && !_connected) {
          timer.cancel();
          setState(() { _connected = true; _calling = false; });
          _timeoutTimer?.cancel();
        }
      });
    } catch (e) {
      print('OutgoingCall: 발신 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('발신 실패: $e')),
        );
        Navigator.of(context).pop();
      }
    }
  }

  void _onRemoteHangUp() {
    print('OutgoingCall: 상대방 끊김 → 복귀');
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _hangUp() async {
    _timeoutTimer?.cancel();
    await _webrtc.hangUp();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _webrtc.dispose();
    _signaling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 원격 영상 (전체 화면) — 연결 후
          if (_connected)
            Positioned.fill(
              child: RTCVideoView(
                _webrtc.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),

          // 로컬 영상 PIP (연결 후)
          if (_connected)
            Positioned(
              top: 40,
              right: 16,
              child: Container(
                width: 120,
                height: 160,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                clipBehavior: Clip.hardEdge,
                child: RTCVideoView(
                  _webrtc.localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),
            ),

          // 발신 대기 UI
          if (_calling)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.videocam, color: Colors.white, size: 64),
                  const SizedBox(height: 24),
                  Text(
                    widget.targetDeviceName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '연결 중...',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(color: Colors.white),
                ],
              ),
            ),

          // 통화 종료 버튼
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton(
                onPressed: _hangUp,
                backgroundColor: Colors.red,
                child: const Icon(Icons.call_end, size: 32),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
