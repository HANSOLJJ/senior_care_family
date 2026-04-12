import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;
import 'config/app_config.dart';
import 'app.dart';

/// 앱 진입점 (`Function`, async)
///
/// 초기화 순서:
/// 1. Firebase SDK 초기화 (Auth, RTDB, Storage, Functions)
/// 2. RTDB persistence 활성화 — 오프라인 캐시로 cold start 시 즉시 로드
/// 3. 카카오 SDK 초기화 — Dart 코드에서 앱 키 주입 필요 (Google/Naver/Apple은 설정 파일로 자동)
/// 4. AppConfig — 기기 정보(모델, deviceId) 수집
/// 5. SeniorCareFamily 위젯 실행
///
/// - **Params**: 없음
/// - **Returns**: `void`
/// - **Side Effects**:
///   - Firebase 전역 인스턴스 초기화
///   - RTDB 디스크 캐시 활성화
///   - 카카오 SDK 네이티브 앱 키 설정
///   - [AppConfig] 싱글톤 초기화 (deviceModel, deviceId)
///   - [ErrorWidget.builder] 커스텀 에러 핸들러 등록
/// - **호출**: OS에 의해 앱 프로세스 시작 시 자동 호출
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // RTDB 디스크 캐시: cold start 시 로컬 캐시에서 즉시 로드
  FirebaseDatabase.instance.setPersistenceEnabled(true);

  // 카카오 SDK 초기화 (Dart-first 설계라 코드에서 앱 키 전달 필요)
  kakao.KakaoSdk.init(nativeAppKey: 'b086e6e5742edeccfa15f54aaea419a2');

  await AppConfig.initialize();

  // 위젯 빌드 에러 시 빈 화면 표시 (프로덕션에서 에러 위젯 숨김)
  ErrorWidget.builder = (FlutterErrorDetails details) {
    print('ErrorWidget: ${details.exception}');
    return const SizedBox.shrink();
  };

  runApp(const SeniorCareFamily());
}
