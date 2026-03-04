import 'dart:async';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

class FaceDetectionService {
  CameraController? _cameraController;
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: false,
      enableLandmarks: false,
      enableContours: false,
      enableTracking: false,
      performanceMode: FaceDetectorMode.fast,
    ),
  );
  bool _isProcessing = false;

  // 워밍업 카메라 추적 (통화 수신 시 즉시 해제용)
  static bool _isWarmingUp = false;
  static CameraController? _warmupController;

  /// 워밍업 카메라 강제 해제 (통화 수신 시 호출)
  static Future<void> cancelWarmup() async {
    if (!_isWarmingUp) return;
    print('워밍업 취소 (통화 수신)');
    final ctrl = _warmupController;
    _warmupController = null;
    _isWarmingUp = false;
    if (ctrl != null) {
      try {
        if (ctrl.value.isStreamingImages) await ctrl.stopImageStream();
        await ctrl.dispose();
      } catch (_) {}
    }
  }

  /// 전면 카메라 초기화
  Future<CameraController> initCamera() async {
    final cameras = await availableCameras();
    final frontCamera = cameras.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      frontCamera,
      ResolutionPreset.medium, // low는 화각이 좁아 얼굴 감지 어려움
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21, // Android ML Kit 호환 포맷
    );

    await _cameraController!.initialize();
    return _cameraController!;
  }

  /// 카메라 프레임에서 얼굴 감지 시작
  /// [onFaceDetected] 얼굴이 감지되면 호출
  /// [onTimeout] 타임아웃 시 호출
  /// [timeoutSeconds] 타임아웃 (기본 15초)
  Future<void> startDetection({
    required void Function(int faceCount) onFaceDetected,
    required void Function() onTimeout,
    int timeoutSeconds = 15,
  }) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      print('카메라가 초기화되지 않음');
      return;
    }

    // 타임아웃 타이머
    final timer = Timer(Duration(seconds: timeoutSeconds), () {
      print('얼굴 감지 타임아웃 ($timeoutSeconds초)');
      stopDetection();
      onTimeout();
    });

    // 카메라 스트림에서 프레임 분석
    await _cameraController!.startImageStream((CameraImage image) async {
      if (_isProcessing) return;
      _isProcessing = true;

      try {
        final inputImage = _convertCameraImage(image);
        if (inputImage == null) {
          _isProcessing = false;
          return;
        }

        final faces = await _faceDetector.processImage(inputImage);

        if (faces.isNotEmpty) {
          print('얼굴 감지: ${faces.length}개');
          timer.cancel();
          stopDetection();
          onFaceDetected(faces.length);
          return;
        }
      } catch (e) {
        print('얼굴 감지 에러: $e');
      }

      _isProcessing = false;
    });
  }

  /// CameraImage → InputImage 변환
  InputImage? _convertCameraImage(CameraImage image) {
    final plane = image.planes.first;
    final inputImageFormat = InputImageFormatValue.fromRawValue(
      image.format.raw,
    );
    if (inputImageFormat == null) return null;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: InputImageRotation.rotation0deg,
        format: inputImageFormat,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  /// 감지 중지
  Future<void> stopDetection() async {
    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          _cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
    } catch (e) {
      print('이미지 스트림 중지 에러: $e');
    }
    _isProcessing = false;
  }

  /// 앱 시작 시 카메라 + ML Kit 워밍업 (첫 통화 속도 개선)
  /// 카메라를 한 번 열고 → 프레임 1장 분석 → 즉시 해제
  Future<void> warmUp() async {
    _isWarmingUp = true;
    try {
      print('FaceDetection 워밍업 시작');
      final controller = await initCamera();
      _warmupController = controller;

      // 프레임 1장만 받아서 ML Kit 모델 로딩
      final completer = Completer<void>();
      await controller.startImageStream((CameraImage image) async {
        if (completer.isCompleted) return;
        controller.stopImageStream();

        final inputImage = _convertCameraImage(image);
        if (inputImage != null) {
          await _faceDetector.processImage(inputImage);
        }
        completer.complete();
      });

      // 최대 5초 대기
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );

      // cancelWarmup()으로 이미 해제됐으면 skip
      if (_warmupController == controller) {
        await controller.dispose();
        _warmupController = null;
      }
      _cameraController = null;
      print('FaceDetection 워밍업 완료');
    } catch (e) {
      print('FaceDetection 워밍업 실패 (무시): $e');
      _warmupController = null;
      _cameraController?.dispose();
      _cameraController = null;
    } finally {
      _isWarmingUp = false;
    }
  }

  /// 리소스 해제
  Future<void> dispose() async {
    await stopDetection();
    await _cameraController?.dispose();
    _cameraController = null;
    await _faceDetector.close();
  }
}
