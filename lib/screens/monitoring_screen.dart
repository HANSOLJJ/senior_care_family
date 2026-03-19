import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call/signaling_service.dart';
import '../services/call/webrtc_service.dart';

/// 모니터링 / 통화 통합 화면
///
/// callType="monitor": 무음 CCTV (Senior 인지 불가)
/// callType="call": 벨소리 + 수락 대기 → 양방향 전환
class MonitoringScreen extends StatefulWidget {
  final String targetDeviceId;
  final String targetDeviceName;
  final String callType; // "monitor" | "call"
  final String? familyId;

  const MonitoringScreen({
    super.key,
    required this.targetDeviceId,
    required this.targetDeviceName,
    this.callType = 'monitor',
    this.familyId,
  });

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  final SignalingService _signaling = SignalingService();
  late final WebRtcService _webrtc;
  bool _connected = false;
  bool _connecting = true;
  bool _upgraded = false;       // 양방향 전환 완료
  bool _waitingAcceptance = false; // callType="call": 수락 대기 중
  Timer? _timeoutTimer;
  Timer? _connectionCheckTimer;
  Timer? _upgradeCheckTimer;

  bool get _isCall => widget.callType == 'call';

  @override
  void initState() {
    super.initState();
    _webrtc = WebRtcService(_signaling);
    _webrtc.onCallEnded = _onRemoteEnd;
    if (_isCall) {
      _startCall();
    } else {
      _startMonitoring();
    }
  }

  Future<void> _startMonitoring() async {
    try {
      await _webrtc.initialize();
      final user = FirebaseAuth.instance.currentUser;
      await _webrtc.startMonitoring(
        widget.targetDeviceId,
        callerUid: user?.uid,
        callerName: user?.displayName ?? '가족',
        familyId: widget.familyId,
      );
      _waitForConnection();
    } catch (e) {
      _handleError(e);
    }
  }

  Future<void> _startCall() async {
    try {
      await _webrtc.initialize();
      final user = FirebaseAuth.instance.currentUser;
      await _webrtc.startCall(
        widget.targetDeviceId,
        callerUid: user?.uid,
        callerName: user?.displayName ?? '가족',
        familyId: widget.familyId,
      );

      // 연결되면 수락 대기 UI 표시
      _connectionCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        if (!mounted) { timer.cancel(); return; }
        if (_webrtc.remoteRenderer.srcObject != null && !_connected) {
          timer.cancel();
          setState(() {
            _connected = true;
            _connecting = false;
            _waitingAcceptance = true; // Senior 수락 대기
          });
          _timeoutTimer?.cancel();
          // Senior 수락 후 upgradeToCall 완료 감지
          _watchUpgrade();
        }
      });

      // 60초 타임아웃
      _timeoutTimer = Timer(const Duration(seconds: 60), () {
        if (_connecting && !_connected && mounted) _hangUp();
      });
    } catch (e) {
      _handleError(e);
    }
  }

  void _waitForConnection() {
    // 30초 타임아웃
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_connecting && !_connected && mounted) _hangUp();
    });

    _connectionCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_webrtc.remoteRenderer.srcObject != null && !_connected) {
        timer.cancel();
        setState(() { _connected = true; _connecting = false; });
        _timeoutTimer?.cancel();
      }
    });
  }

  /// Senior 수락 후 양방향 전환 완료 감지 (upgradeToCall이 자동 호출됨)
  void _watchUpgrade() {
    _upgradeCheckTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (!_webrtc.isMonitoring && _waitingAcceptance) {
        timer.cancel();
        setState(() {
          _upgraded = true;
          _waitingAcceptance = false;
        });
      }
    });
  }

  void _onRemoteEnd() {
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _hangUp() async {
    _timeoutTimer?.cancel();
    await _webrtc.hangUp();
    if (mounted) Navigator.of(context).pop();
  }

  /// 모니터링 중 수동으로 통화 전환 (모니터링 화면에서 버튼 누를 때)
  Future<void> _upgradeToCall() async {
    if (_upgraded) return;
    setState(() => _upgraded = true);
    try {
      await _webrtc.upgradeToCall();
      _upgradeCheckTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
        if (!mounted) { timer.cancel(); return; }
        if (!_webrtc.isMonitoring) {
          timer.cancel();
          setState(() {});
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('통화 전환 실패: $e')),
        );
        setState(() => _upgraded = false);
      }
    }
  }

  void _handleError(Object e) {
    print('연결 실패: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('연결 실패: $e')),
      );
      Navigator.of(context).pop();
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

          // 로컬 PIP: callType="call"이면 수락 전부터 표시 / 모니터링은 업그레이드 후만
          if (_isCall
              ? (_connected && _webrtc.localRenderer.srcObject != null)
              : (_upgraded && !_webrtc.isMonitoring))
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
                  Icon(
                    _isCall ? Icons.videocam : Icons.camera_outdoor,
                    color: Colors.white,
                    size: 64,
                  ),
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
                  Text(
                    _isCall ? '연결 중...' : '모니터링 연결 중...',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  const CircularProgressIndicator(color: Colors.white),
                ],
              ),
            ),

          // 상단 상태 배지
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
                      _upgraded
                          ? Icons.videocam
                          : (_waitingAcceptance ? Icons.hourglass_top : Icons.remove_red_eye),
                      color: _upgraded
                          ? Colors.green
                          : (_waitingAcceptance ? Colors.amber : Colors.orange),
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _upgraded
                          ? '통화 중'
                          : (_waitingAcceptance ? '수락 대기 중...' : '모니터링'),
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
                if (_connected && !_isCall && !_upgraded)
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
