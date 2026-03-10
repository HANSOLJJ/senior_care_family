import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call/signaling_service.dart';
import '../services/call/webrtc_service.dart';

/// 양방향 영상 통화 화면
class VideoCallScreen extends StatefulWidget {
  final String callId;
  final Map<String, dynamic> offer;

  const VideoCallScreen({
    super.key,
    required this.callId,
    required this.offer,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  final SignalingService _signaling = SignalingService();
  late final WebRtcService _webrtc;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _webrtc = WebRtcService(_signaling);
    _webrtc.onCallEnded = _onRemoteHangUp;
    _startCall();
  }

  Future<void> _startCall() async {
    await _webrtc.initialize();
    await _webrtc.answerCall(widget.callId, widget.offer);
    if (mounted) {
      setState(() => _connected = true);
    }
  }

  /// 상대방이 끊었거나 연결 끊김 감지 시
  void _onRemoteHangUp() {
    print('VideoCallScreen: 상대방 끊김 → 슬라이드쇼 복귀');
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _hangUp() async {
    await _webrtc.hangUp();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
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
          // 원격 영상 (전체 화면)
          Positioned.fill(
            child: RTCVideoView(
              _webrtc.remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),

          // 로컬 영상 (우측 상단 PIP)
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

          // 연결 상태
          if (!_connected)
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text(
                    '연결 중...',
                    style: TextStyle(color: Colors.white, fontSize: 20),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
