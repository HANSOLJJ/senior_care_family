import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call/signaling_service.dart';
import '../services/call/webrtc_service.dart';

/// CCTV 모니터링 화면 — Senior 카메라 일방향 시청 + 통화 전환
class MonitoringScreen extends StatefulWidget {
  final String targetDeviceId;
  final String targetDeviceName;

  const MonitoringScreen({
    super.key,
    required this.targetDeviceId,
    required this.targetDeviceName,
  });

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  final SignalingService _signaling = SignalingService();
  late final WebRtcService _webrtc;
  bool _connected = false;
  bool _connecting = true;
  bool _upgraded = false;
  Timer? _timeoutTimer;
  Timer? _connectionCheckTimer;
  Timer? _upgradeCheckTimer;

  @override
  void initState() {
    super.initState();
    _webrtc = WebRtcService(_signaling);
    _webrtc.onCallEnded = _onRemoteEnd;
    _startMonitoring();
  }

  Future<void> _startMonitoring() async {
    try {
      await _webrtc.initialize();
      final user = FirebaseAuth.instance.currentUser;
      await _webrtc.startMonitoring(
        widget.targetDeviceId,
        callerUid: user?.uid,
        callerName: user?.displayName ?? '가족',
      );

      // 30초 타임아웃
      _timeoutTimer = Timer(const Duration(seconds: 30), () {
        if (_connecting && !_connected && mounted) {
          _hangUp();
        }
      });

      // 연결 상태 주기적 확인
      _connectionCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (!mounted) { timer.cancel(); return; }
        if (_webrtc.remoteRenderer.srcObject != null && !_connected) {
          timer.cancel();
          setState(() { _connected = true; _connecting = false; });
          _timeoutTimer?.cancel();
        }
      });
    } catch (e) {
      print('모니터링 시작 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('모니터링 시작 실패: $e')),
        );
        Navigator.of(context).pop();
      }
    }
  }

  void _onRemoteEnd() {
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _hangUp() async {
    _timeoutTimer?.cancel();
    await _webrtc.hangUp();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _upgradeToCall() async {
    if (_upgraded) return;
    setState(() => _upgraded = true);
    try {
      await _webrtc.upgradeToCall();
      // upgradeToCall 내부에서 renegotiate answer 수신 시 _isMonitoring=false
      // 주기적으로 상태 확인해서 UI 갱신
      _upgradeCheckTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
        if (!mounted) { timer.cancel(); return; }
        if (!_webrtc.isMonitoring) {
          timer.cancel();
          setState(() {});
        }
      });
    } catch (e) {
      print('통화 전환 실패: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('통화 전환 실패: $e')),
        );
        setState(() => _upgraded = false);
      }
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _connectionCheckTimer?.cancel();
    _upgradeCheckTimer?.cancel();
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
          if (_connected)
            Positioned.fill(
              child: RTCVideoView(
                _webrtc.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),

          // 로컬 영상 PIP (통화 전환 후)
          if (_upgraded && !_webrtc.isMonitoring)
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

          // 연결 대기 UI
          if (_connecting)
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
                    '모니터링 연결 중...',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(color: Colors.white),
                ],
              ),
            ),

          // 상단: 모니터링 표시
          if (_connected)
            Positioned(
              top: 40,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _upgraded ? Icons.videocam : Icons.remove_red_eye,
                      color: _upgraded ? Colors.green : Colors.orange,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _upgraded ? '통화 중' : '모니터링',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),

          // 하단 버튼
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 통화 전환 버튼 (모니터링 중에만)
                if (_connected && !_upgraded)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: FloatingActionButton.extended(
                      heroTag: 'upgrade',
                      onPressed: _upgradeToCall,
                      backgroundColor: Colors.green,
                      icon: const Icon(Icons.videocam),
                      label: const Text('통화 전환'),
                    ),
                  ),
                // 종료 버튼
                FloatingActionButton(
                  heroTag: 'hangup',
                  onPressed: _hangUp,
                  backgroundColor: Colors.red,
                  child: const Icon(Icons.call_end, size: 32),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
