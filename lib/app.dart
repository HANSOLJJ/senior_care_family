import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'config/app_config.dart';
import 'services/family_service.dart';
import 'screens/login_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/device_list_screen.dart';

/// 전역 네비게이터 키
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 앱 최상위 위젯
class SeniorCareFamily extends StatefulWidget {
  const SeniorCareFamily({super.key});

  @override
  State<SeniorCareFamily> createState() => _SeniorCareFamilyState();
}

class _SeniorCareFamilyState extends State<SeniorCareFamily> {
  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    try {
      await AppConfig.registerDevice().timeout(const Duration(seconds: 10));
    } catch (e) {
      print('기기 등록 실패/타임아웃: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Senior Care Family',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          // 로딩 중
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: Colors.black,
              body: Center(child: CircularProgressIndicator(color: Colors.white)),
            );
          }

          // 미로그인 → 로그인 화면
          if (snapshot.data == null) {
            return const LoginScreen();
          }

          // 로그인됨 → 페어링 상태 확인
          return const _PairingGate();
        },
      ),
    );
  }
}

/// 페어링 상태에 따라 PairingScreen / DeviceListScreen 분기
class _PairingGate extends StatefulWidget {
  const _PairingGate();

  @override
  State<_PairingGate> createState() => _PairingGateState();
}

class _PairingGateState extends State<_PairingGate> {
  final _familyService = FamilyService();
  List<String>? _familyIds;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _checkPairing();
  }

  Future<void> _checkPairing() async {
    try {
      final ids = await _familyService.getMyFamilyIds();
      if (mounted) setState(() { _familyIds = ids; _loading = false; });
    } catch (e) {
      print('페어링 확인 실패: $e');
      if (mounted) setState(() { _familyIds = []; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    // 페어링된 가족 그룹이 없으면 → 페어링 화면
    if (_familyIds == null || _familyIds!.isEmpty) {
      return PairingScreen(onPaired: _checkPairing);
    }

    // 페어링됨 → 기기 목록 (첫 번째 가족 그룹)
    return DeviceListScreen(familyId: _familyIds!.first);
  }
}
