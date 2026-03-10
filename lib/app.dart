import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
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
  StreamSubscription<DatabaseEvent>? _membershipSub;

  @override
  void initState() {
    super.initState();
    _checkPairing();
  }

  Future<void> _checkPairing() async {
    // 기존 리스너 정리
    _membershipSub?.cancel();
    _membershipSub = null;

    try {
      final ids = await _familyService.getMyFamilyIds();
      if (mounted) {
        setState(() { _familyIds = ids; _loading = false; });
        // 멤버십 실시간 감시 시작
        if (ids.isNotEmpty) {
          _watchMembership(ids.first);
        }
      }
    } catch (e) {
      print('페어링 확인 실패: $e');
      if (mounted) setState(() { _familyIds = []; _loading = false; });
    }
  }

  /// Senior에서 멤버 삭제 시 실시간 감지
  void _watchMembership(String familyId) {
    _membershipSub = _familyService.watchMyMembership(familyId).listen((event) {
      if (!event.snapshot.exists) {
        // 멤버에서 제거됨
        print('멤버십 제거 감지: familyId=$familyId');
        _membershipSub?.cancel();
        _membershipSub = null;

        // 로컬 familyId 정리
        _familyService.leaveFamily(familyId);

        if (mounted) {
          setState(() { _familyIds = []; });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('시니어 기기에서 연결이 해제되었습니다'),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _membershipSub?.cancel();
    super.dispose();
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
