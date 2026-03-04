import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../main.dart';
import '../services/face_detection_service.dart';
import '../widgets/photo_frame_view.dart';
import 'device_list_screen.dart';

/// 슬라이드쇼 화면.
/// - assets/images/ 폴더의 모든 이미지를 자동으로 불러옴
/// - 10초마다 다음 사진으로 페이드 전환
/// - 화면 꺼짐 방지 (WakelockPlus)
/// - 전체화면 몰입 모드 (상태바/네비게이션바 숨김)
/// - 터치 → 기기 선택 → 영상통화 발신
class SlideshowScreen extends StatefulWidget {
  const SlideshowScreen({super.key});

  @override
  State<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends State<SlideshowScreen> {
  List<String> _imagePaths = [];
  int _currentIndex = 0;
  Timer? _timer;
  bool _loaded = false;

  static const _imageExtensions = ['.png', '.jpg', '.jpeg', '.gif', '.webp'];

  @override
  void initState() {
    super.initState();

    // 1. 화면 꺼짐 방지
    WakelockPlus.enable();

    // 2. 전체화면 몰입 모드 (Android: 상태바 + 네비게이션바 숨김)
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // 3. 이미지 목록 로드 후 슬라이드쇼 시작
    _loadImagePaths();
  }

  Future<void> _loadImagePaths() async {
    try {
      final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final allAssets = assetManifest.listAssets();

      final images = allAssets
          .where((path) => path.startsWith('assets/images/'))
          .where((path) => _imageExtensions.any((ext) => path.toLowerCase().endsWith(ext)))
          .toList()
        ..sort();

      print('슬라이드쇼 이미지 ${images.length}개 로드: $images');

      if (!mounted) return;
      setState(() {
        _imagePaths = images;
        _loaded = true;
      });
    } catch (e) {
      print('이미지 목록 로드 실패: $e');
      // 폴백: 하드코딩 목록
      if (!mounted) return;
      setState(() {
        _imagePaths = ['assets/images/photo1.png', 'assets/images/photo2.png', 'assets/images/photo3.png'];
        _loaded = true;
      });
    }

    // 카메라 + ML Kit 워밍업 (첫 통화 속도 개선, 백그라운드)
    if (AppConfig.enableFaceDetection) {
      FaceDetectionService().warmUp();
    }

    // 슬라이드쇼 타이머 시작 (10초 간격)
    if (_imagePaths.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 10), (_) {
        final nextIndex = (_currentIndex + 1) % _imagePaths.length;
        print('사진 전환: ${_imagePaths[_currentIndex]} → ${_imagePaths[nextIndex]}');
        setState(() {
          _currentIndex = nextIndex;
        });
      });
    }
  }

  void _openDeviceList() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DeviceListScreen()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _imagePaths.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return Scaffold(
      body: GestureDetector(
        onTap: _openDeviceList,
        child: Stack(
          children: [
            PhotoFrameView(
              imagePath: _imagePaths[_currentIndex],
            ),
            // 기기 ID 표시 (임시)
            Positioned(
              left: 12,
              bottom: 12,
              child: Opacity(
                opacity: 0.4,
                child: Text(
                  '${AppConfig.deviceModel} (${AppConfig.deviceId.length > 8 ? AppConfig.deviceId.substring(0, 8) : AppConfig.deviceId})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
