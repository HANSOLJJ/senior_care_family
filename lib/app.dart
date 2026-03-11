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
              body: Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
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
  final List<StreamSubscription<DatabaseEvent>> _membershipSubs = [];

  @override
  void initState() {
    super.initState();
    _checkPairing();
  }

  Future<void> _checkPairing() async {
    // 기존 리스너 정리
    for (final sub in _membershipSubs) {
      sub.cancel();
    }
    _membershipSubs.clear();

    try {
      final ids = await _familyService.getMyFamilyIds();
      if (mounted) {
        setState(() {
          _familyIds = ids;
          _loading = false;
        });
        // 모든 가족 그룹의 멤버십 실시간 감시
        for (final id in ids) {
          _watchMembership(id);
        }
      }
    } catch (e) {
      print('페어링 확인 실패: $e');
      if (mounted)
        setState(() {
          _familyIds = [];
          _loading = false;
        });
    }
  }

  /// Senior에서 멤버 삭제 시 실시간 감지
  void _watchMembership(String familyId) {
    final sub = _familyService.watchMyMembership(familyId).listen((event) {
      if (!event.snapshot.exists) {
        print('멤버십 제거 감지: familyId=$familyId');

        // 로컬 familyId 정리
        _familyService.leaveFamily(familyId);

        if (mounted) {
          // 해당 familyId만 제거
          final updated = List<String>.from(_familyIds ?? [])..remove(familyId);
          setState(() {
            _familyIds = updated;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('시니어 기기에서 연결이 해제되었습니다'),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    });
    _membershipSubs.add(sub);
  }

  Future<void> _promptFamilyName(String familyId) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('가족 이름 지정', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: '예: 부모님, 장인어른',
            hintStyle: TextStyle(color: Colors.grey[600]),
            filled: true,
            fillColor: Colors.grey[800],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('건너뛰기'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.isNotEmpty) {
      await _familyService.setFamilyName(familyId, name);
    }
  }

  @override
  void dispose() {
    for (final sub in _membershipSubs) {
      sub.cancel();
    }
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
      return PairingScreen(
        onPairedWithId: (familyId) async {
          await _promptFamilyName(familyId);
          _checkPairing();
        },
      );
    }

    // 페어링됨 → 기기 목록
    return DeviceListScreen(familyIds: _familyIds!, onAddFamily: _checkPairing);
  }
}
