import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:kakao_flutter_sdk_user/kakao_flutter_sdk_user.dart' as kakao;
import 'config/app_config.dart';
import 'app.dart';

/// 앱 진입점
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // RTDB 디스크 캐시: cold start 시 로컬 캐시에서 즉시 로드
  FirebaseDatabase.instance.setPersistenceEnabled(true);

  // 카카오 SDK 초기화
  kakao.KakaoSdk.init(nativeAppKey: 'b086e6e5742edeccfa15f54aaea419a2');

  await AppConfig.initialize();

  ErrorWidget.builder = (FlutterErrorDetails details) {
    print('ErrorWidget: ${details.exception}');
    return const SizedBox.shrink();
  };

  runApp(const SeniorCareFamily());
}
