import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'services/connectivity_service.dart';
import 'services/family_service.dart';
import 'services/pairing_helper.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';
import 'widgets/offline_overlay.dart';
import 'screens/login_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/device_list_screen.dart';

/// 전역 네비게이터 키
/// — FCM 알림 탭 등 context 없는 곳에서 화면 전환할 때 사용
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// 앱 최상위 위젯 (`StatefulWidget`)
///
/// MaterialApp + FirebaseAuth 상태 감시.
/// 로그인 상태에 따라 LoginScreen / _PairingGate 분기:
///   미로그인 → LoginScreen
///   로그인됨 → _PairingGate (페어링 여부 확인 후 PairingScreen / DeviceListScreen)
///
/// - **섹션 구성**:
///   - 서비스 초기화 — _initServices()
///   - UI 빌드 — build() (StreamBuilder로 인증 상태 분기)
class SeniorCareFamily extends StatefulWidget {
  const SeniorCareFamily({super.key});

  @override
  State<SeniorCareFamily> createState() => _SeniorCareFamilyState();
}

/// [SeniorCareFamily]의 `State`
///
/// FirebaseAuth.authStateChanges()를 StreamBuilder로 감시하여
/// 로그인 여부에 따라 LoginScreen / _PairingGate를 렌더링.
class _SeniorCareFamilyState extends State<SeniorCareFamily> {

  // ─── 라이프사이클 ───

  /// 위젯 초기화 (`Lifecycle`)
  ///
  /// - **Params**: 없음
  /// - **Returns**: `void`
  /// - **Side Effects**: [_initServices] 호출
  /// - **호출**: 프레임워크에 의해 위젯 트리 삽입 시 자동 호출
  @override
  void initState() {
    super.initState();
    _initServices();
  }

  // ─── 서비스 초기화 ───

  /// 서비스 초기화 (`Method`, async)
  ///
  /// Family 기기는 /devices/에 등록하지 않음.
  /// 사용자 정보는 /users/{uid}에서 관리.
  ///
  /// - **Params**: 없음
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: 없음 (현재 빈 메서드, 향후 확장용)
  /// - **호출**: [initState]에서 호출
  Future<void> _initServices() async {
    // Family 기기는 /devices/에 등록하지 않음
    // 사용자 정보는 /users/{uid}에서 관리
    ConnectivityService.instance.start();
  }

  // ─── UI 빌드 ───

  /// 앱 루트 위젯 빌드 (`Widget Builder`)
  ///
  /// MaterialApp을 반환하며, home에 StreamBuilder를 배치하여
  /// FirebaseAuth 인증 상태를 실시간 감시.
  ///
  /// - **Params**:
  ///   - [context] — BuildContext
  /// - **Returns**: `Widget` — MaterialApp (다크 테마)
  /// - **Side Effects**: 없음
  /// - **호출**: 프레임워크에 의해 위젯 트리 빌드 시 자동 호출
  ///
  /// 분기 로직:
  ///   - ConnectionState.waiting → 로딩 스피너 (검은 배경)
  ///   - snapshot.data == null → LoginScreen (미로그인)
  ///   - snapshot.data != null → _PairingGate (로그인됨)
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: ThemeController.currentHue,
      builder: (context, hue, _) => MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Senior Care Family',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(hue.light),
        darkTheme: AppTheme.build(hue.dark),
        themeMode: ThemeMode.system,
        builder: (context, child) => OfflineOverlay(child: child ?? const SizedBox()),
        home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            // 로딩 중 (배경/스피너 색상은 테마 자동 적용)
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(),
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
      ),
    );
  }
}

/// 페어링 상태에 따라 PairingScreen / DeviceListScreen 분기 (`StatefulWidget`)
///
/// 로그인된 사용자의 /users/{uid}/familyIds 를 조회하여:
///   - familyIds 비어있음 → PairingScreen (시니어 기기와 연결)
///   - familyIds 존재 → DeviceListScreen (가족 목록 / 상세)
///
/// 페어링 직후 PairingHelper.onPairingComplete()로 가족이름/내이름 설정 다이얼로그 표시.
/// Senior에서 멤버 삭제 시 watchMyMembership()으로 실시간 감지 → 자동 탈퇴 처리.
///
/// - **섹션 구성**:
///   - 상태 필드 — 가족 ID 목록, 로딩 상태, 멤버십 구독
///   - 라이프사이클 — initState(), dispose()
///   - 페어링 확인 — _checkPairing()
///   - 멤버십 감시 — _watchMembership()
///   - UI 빌드 — build()
class _PairingGate extends StatefulWidget {
  const _PairingGate();

  @override
  State<_PairingGate> createState() => _PairingGateState();
}

/// [_PairingGate]의 `State`
///
/// familyIds 조회 → 페어링 화면/기기 목록 분기 + 멤버십 실시간 감시.
class _PairingGateState extends State<_PairingGate> {

  // ─── 상태 필드 ───

  /// 가족 그룹 CRUD 서비스
  final _familyService = FamilyService();

  /// 현재 사용자가 속한 가족 그룹 ID 목록 (null이면 아직 미조회)
  List<String>? _familyIds;

  /// 페어링 상태 조회 중 여부 (true면 로딩 스피너 표시)
  bool _loading = true;

  /// 각 familyId별 멤버십 감시 구독 목록 (dispose 시 해제용)
  final List<StreamSubscription<DatabaseEvent>> _membershipSubs = [];

  /// 페어링 직후 이름 설정 다이얼로그를 띄울 familyId (대기 상태)
  String? _pendingFamilyId; // 이름 설정 대기 중인 familyId

  // ─── 라이프사이클 ───

  /// 위젯 초기화 (`Lifecycle`)
  ///
  /// - **Params**: 없음
  /// - **Returns**: `void`
  /// - **Side Effects**: [_checkPairing] 호출
  /// - **호출**: 프레임워크에 의해 위젯 트리 삽입 시 자동 호출
  @override
  void initState() {
    super.initState();
    _checkPairing();
  }

  // ─── 페어링 확인 ───

  /// 현재 사용자의 페어링 상태 조회 (`Method`, async)
  ///
  /// RTDB /users/{uid}/familyIds 에서 가족 그룹 ID 목록을 가져온 후,
  /// 각 familyId에 대해 멤버십 실시간 감시를 시작.
  /// _pendingFamilyId가 있으면 이름 설정 다이얼로그를 표시.
  ///
  /// - **Params**: 없음
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**:
  ///   - [_familyIds] 갱신
  ///   - [_loading] → false
  ///   - [_membershipSubs] 기존 구독 해제 후 재등록
  ///   - [_pendingFamilyId] 소비 후 null로 초기화
  /// - **호출**: [initState], [PairingScreen.onPairedWithId] 콜백, [DeviceListScreen.onAddFamily] 콜백
  Future<void> _checkPairing() async {
    // 기존 리스너 정리
    for (final sub in _membershipSubs) {
      sub.cancel();
    }
    _membershipSubs.clear();

    try {
      final ids = await _familyService.getMyFamilyIds();
      if (mounted) {
        // 페어링 직후 이름 설정 다이얼로그를 DeviceListScreen 렌더 전에 실행
        // (렌더 후 실행하면 _loadFamilyNames/_loadMembers가 먼저 돌아 빈 값 표시됨)
        if (_pendingFamilyId != null) {
          final fid = _pendingFamilyId!;
          _pendingFamilyId = null;
          await PairingHelper.onPairingComplete(context, fid);
        }

        if (!mounted) return;
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

  // ─── 멤버십 감시 ───

  /// Senior에서 멤버 삭제 시 실시간 감지 (`Method`)
  ///
  /// /families/{familyId}/members/{uid} 경로를 onValue로 감시.
  /// 노드가 삭제되면(exists == false) 로컬 familyId를 정리하고
  /// 사용자에게 SnackBar로 알림.
  ///
  /// - **Params**:
  ///   - [familyId] — 감시할 가족 그룹 ID
  /// - **Returns**: `void`
  /// - **Side Effects**:
  ///   - [_membershipSubs]에 구독 추가
  ///   - 멤버십 제거 시 [_familyIds] 갱신 + [FamilyService.leaveFamily] 호출
  ///   - SnackBar 표시 ("시니어 기기에서 연결이 해제되었습니다")
  /// - **호출**: [_checkPairing]에서 각 familyId마다 호출
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

  /// 위젯 해제 (`Lifecycle`)
  ///
  /// - **Params**: 없음
  /// - **Returns**: `void`
  /// - **Side Effects**: [_membershipSubs] 전체 구독 취소
  /// - **호출**: 프레임워크에 의해 위젯 트리에서 제거 시 자동 호출
  @override
  void dispose() {
    for (final sub in _membershipSubs) {
      sub.cancel();
    }
    super.dispose();
  }

  // ─── UI 빌드 ───

  /// 페어링 상태에 따른 화면 분기 빌드 (`Widget Builder`)
  ///
  /// - **Params**:
  ///   - [context] — BuildContext
  /// - **Returns**: `Widget` — 로딩 스피너 / PairingScreen / DeviceListScreen
  /// - **Side Effects**: 없음
  /// - **호출**: 프레임워크에 의해 위젯 트리 빌드 시 자동 호출
  ///
  /// 분기 로직:
  ///   - _loading == true → 로딩 스피너
  ///   - _familyIds 비어있음 → PairingScreen (onPairedWithId 콜백으로 _checkPairing 재호출)
  ///   - _familyIds 존재 → DeviceListScreen (familyIds 전달)
  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // 페어링된 가족 그룹이 없으면 → 페어링 화면
    if (_familyIds == null || _familyIds!.isEmpty) {
      return PairingScreen(
        onPairedWithId: (familyId) async {
          _pendingFamilyId = familyId;
          _checkPairing();
        },
      );
    }

    // 페어링됨 → 기기 목록
    return DeviceListScreen(familyIds: _familyIds!, onAddFamily: _checkPairing);
  }
}
