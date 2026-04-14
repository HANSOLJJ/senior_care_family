import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import '../services/pairing_helper.dart';
import '../widgets/safe_state_mixin.dart';
import 'family_detail_screen.dart';
import 'pairing_screen.dart';

/// 홈 화면 — 가족 1명이면 바로 상세 진입, 2명+이면 가족 목록 표시 (`StatefulWidget`)
///
/// familyIds 1개 → FamilyDetailScreen 직접 렌더링 (목록 건너뜀)
/// familyIds 2개+ → Card 목록 표시, 각 카드에 온라인 상태(초록/회색 원)
///
/// 온라인 감시 구조:
///   /families/{fid}/devices/ onValue → deviceId 목록 추출
///   → 각 /devices/{did}/online onValue → _updateOnlineStatus()
///   → 가족 그룹 내 하나라도 online이면 초록 원
///
/// 메뉴: 가족 추가(PairingScreen), 로그아웃
///
/// ## 섹션 구성
/// - **상태 관리**: 가족 이름 맵, 온라인 상태 맵, RTDB 구독 목록
/// - **데이터 감시**: 기기 목록 + 온라인 상태 실시간 구독
/// - **네비게이션**: 가족 추가(PairingScreen), 가족 상세(FamilyDetailScreen)
/// - **UI**: 단일 가족 시 직접 렌더링, 복수 가족 시 카드 목록
class DeviceListScreen extends StatefulWidget {
  /// 현재 사용자가 속한 가족 그룹 ID 목록
  final List<String> familyIds;

  /// 가족 추가 완료 후 부모 위젯에 알리는 콜백 (PairingGate 갱신용)
  final VoidCallback? onAddFamily;

  const DeviceListScreen({super.key, required this.familyIds, this.onAddFamily});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

/// [DeviceListScreen]의 State (`State`)
///
/// 가족 이름 로드, 기기 온라인 상태 감시, 가족 추가/상세 화면 전환 처리.
///
/// ## 섹션 구성
/// - **데이터 로드**: 가족 이름 조회, RTDB 구독 관리
/// - **온라인 감시**: 2단계 구독 (기기 목록 → 각 기기 online 필드)
/// - **네비게이션**: 가족 추가, 가족 상세 화면 전환
/// - **UI**: build() — 단일/복수 가족 분기 렌더링
class _DeviceListScreenState extends State<DeviceListScreen> with SafeStateMixin {
  /// 가족 관련 CRUD 서비스
  final _familyService = FamilyService();

  /// familyId → 가족 이름 매핑 (FamilyService에서 로드)
  Map<String, String> _familyNames = {};

  /// familyId → 온라인 기기 존재 여부
  final Map<String, bool> _onlineStatus = {};

  /// /families/{fid}/devices/ 목록 감시 구독 (1단계)
  final List<StreamSubscription<DatabaseEvent>> _subs = [];

  /// 데이터 초기 로딩 중 여부
  bool _loading = true;

  // ─── 라이프사이클 ───

  /// 초기화 — 가족 이름 로드 + 기기 온라인 감시 시작 (`Lifecycle`)
  ///
  /// - **Side Effects**: _familyNames 설정, RTDB 구독 시작
  /// - **호출**: 위젯 최초 생성 시 Flutter 프레임워크에 의해
  @override
  void initState() {
    super.initState();
    _loadFamilyNames();
    _watchAllDevices();
  }

  /// familyIds 변경 감지 — 구독 재설정 (`Lifecycle`)
  ///
  /// - **Params**:
  ///   - [oldWidget] — 이전 위젯 인스턴스
  /// - **Side Effects**: 기존 구독 해제 후 새 familyIds로 재구독
  /// - **호출**: 부모 위젯이 familyIds를 변경할 때
  @override
  void didUpdateWidget(DeviceListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.familyIds.length != widget.familyIds.length) {
      for (final sub in _subs) {
        sub.cancel();
      }
      _subs.clear();
      _onlineStatus.clear();
      _loadFamilyNames();
      _watchAllDevices();
    }
  }

  // ─── 데이터 로드 ───

  /// 가족 이름 맵 로드 (`Method`, async)
  ///
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: _familyNames 갱신 → setState
  /// - **호출**: initState(), didUpdateWidget(), _addFamily(), _openFamily() 콜백
  Future<void> _loadFamilyNames() async {
    final names = await _familyService.getFamilyNames();
    safeSetState(() => _familyNames = names);
  }

  // ─── 온라인 감시 ───

  /// familyId → 해당 가족의 각 기기 online 감시 구독 목록 (2단계)
  final Map<String, List<StreamSubscription>> _deviceOnlineSubs = {};

  /// 모든 가족 그룹의 기기 온라인 상태를 2단계로 실시간 감시 (`Method`)
  ///
  /// 1단계: /families/{fid}/devices/ onValue → 기기 목록 추출
  /// 2단계: 각 /devices/{did}/online onValue → _updateOnlineStatus() 호출
  ///
  /// - **Side Effects**: _subs, _deviceOnlineSubs에 구독 추가, _loading → false
  /// - **호출**: initState(), didUpdateWidget()
  void _watchAllDevices() {
    for (final familyId in widget.familyIds) {
      // 1) /families/{fid}/devices/ 목록 감시 (기기 추가/삭제 감지)
      final sub = FirebaseDatabase.instance
          .ref('families/$familyId/devices')
          .onValue
          .listen((event) {
        final data = event.snapshot.value;
        // 기존 기기 online 구독 해제
        for (final s in _deviceOnlineSubs[familyId] ?? []) {
          s.cancel();
        }
        _deviceOnlineSubs[familyId] = [];

        if (data != null && data is Map) {
          // 2) 각 /devices/{did}/online 실시간 감시
          for (final deviceId in data.keys) {
            final onlineSub = FirebaseDatabase.instance
                .ref('devices/$deviceId/online')
                .onValue
                .listen((onlineEvent) {
              _updateOnlineStatus(familyId);
            });
            _deviceOnlineSubs[familyId]!.add(onlineSub);
          }
        }
        // 초기 로딩 완료
        safeSetState(() => _loading = false);
      });
      _subs.add(sub);
    }
  }

  /// 특정 가족 그룹의 온라인 기기 존재 여부를 RTDB에서 재확인 (`Method`, async)
  ///
  /// /families/{fid}/devices/ 목록을 순회하며 하나라도 online이면 true.
  ///
  /// - **Params**:
  ///   - [familyId] — 확인할 가족 그룹 ID
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: _onlineStatus[familyId] 갱신 → setState
  /// - **호출**: _watchAllDevices() 내부 onValue 리스너
  Future<void> _updateOnlineStatus(String familyId) async {
    final devicesSnap = await FirebaseDatabase.instance
        .ref('families/$familyId/devices').get();
    final data = devicesSnap.value;
    bool hasOnline = false;
    if (data != null && data is Map) {
      for (final deviceId in data.keys) {
        final snap = await FirebaseDatabase.instance.ref('devices/$deviceId/online').get();
        if (snap.value == true) {
          hasOnline = true;
          break;
        }
      }
    }
    if (mounted) {
      setState(() => _onlineStatus[familyId] = hasOnline);
    }
  }

  // ─── 유틸리티 ───

  /// 가족 카드에 표시할 라벨 반환 (`Utility`)
  ///
  /// _familyNames에 이름이 있으면 해당 이름, 없으면 '가족 N' 형식.
  ///
  /// - **Params**:
  ///   - [familyId] — 가족 그룹 ID
  ///   - [index] — 목록 내 인덱스 (0부터)
  /// - **Returns**: `String` — 표시할 가족 이름
  /// - **호출**: build() 내 ListView.builder
  String _familyLabel(String familyId, int index) {
    final name = _familyNames[familyId];
    if (name != null && name.isNotEmpty) return name;
    return '가족 ${index + 1}';
  }

  // ─── 네비게이션 ───

  /// 가족 추가 — PairingScreen으로 이동 (`Callback`)
  ///
  /// 페어링 완료 시 PairingHelper.onPairingComplete() 호출 후 목록 갱신.
  ///
  /// - **Side Effects**: Navigator push, onAddFamily 콜백, _familyNames 갱신
  /// - **호출**: PopupMenuButton 'add' 선택 시
  void _addFamily() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PairingScreen(
          onPairedWithId: (familyId) async {
            await PairingHelper.onPairingComplete(context, familyId);
            if (context.mounted) Navigator.of(context).pop();
            widget.onAddFamily?.call();
            _loadFamilyNames();
          },
        ),
      ),
    );
  }


  /// 가족 상세 화면으로 이동 (`Callback`)
  ///
  /// - **Params**:
  ///   - [familyId] — 선택한 가족 그룹 ID
  ///   - [name] — 가족 이름 (AppBar 제목용)
  /// - **Side Effects**: Navigator push
  /// - **호출**: 가족 카드 onTap
  void _openFamily(String familyId, String name) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FamilyDetailScreen(
          familyId: familyId,
          familyName: name,
          onAddFamily: () {
            widget.onAddFamily?.call();
            _loadFamilyNames();
          },
        ),
      ),
    );
  }

  /// 모든 RTDB 구독 해제 (`Lifecycle`)
  ///
  /// - **Side Effects**: _subs, _deviceOnlineSubs 모든 구독 cancel
  /// - **호출**: 위젯 제거 시 Flutter 프레임워크에 의해
  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    for (final subs in _deviceOnlineSubs.values) {
      for (final s in subs) {
        s.cancel();
      }
    }
    super.dispose();
  }

  // ─── UI ───

  /// 메인 빌드 — 가족 수에 따라 분기 렌더링 (`Widget Builder`)
  ///
  /// - 가족 1명: FamilyDetailScreen 직접 반환 (목록 건너뜀)
  /// - 가족 2명+: Scaffold + AppBar(메뉴) + ListView(카드 목록)
  ///
  /// - **Returns**: `Widget` — 전체 화면 위젯
  /// - **호출**: Flutter 프레임워크 (setState 시 재호출)
  @override
  Widget build(BuildContext context) {
    // 가족 1명 → 바로 상세 페이지
    if (widget.familyIds.length == 1) {
      final familyId = widget.familyIds[0];
      final name = _familyNames[familyId];
      return FamilyDetailScreen(
        familyId: familyId,
        familyName: name ?? '가족',
        isRoot: true,
        onAddFamily: () {
          widget.onAddFamily?.call();
          _loadFamilyNames();
        },
      );
    }

    // 가족 2명+ → 목록
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('가족 선택'),
        automaticallyImplyLeading: false,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: Colors.grey[900],
            onSelected: (value) {
              if (value == 'add') _addFamily();
              if (value == 'logout') AuthService().signOut();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'add',
                child: Text('가족 추가', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Text('로그아웃', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: widget.familyIds.length,
              itemBuilder: (context, index) {
                final familyId = widget.familyIds[index];
                final name = _familyLabel(familyId, index);
                final isOnline = _onlineStatus[familyId] ?? false;

                return Card(
                  color: Colors.grey[900],
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    trailing: Icon(
                      Icons.circle,
                      color: isOnline ? Colors.green : Colors.grey[600],
                      size: 14,
                    ),
                    onTap: () => _openFamily(familyId, name),
                  ),
                );
              },
            ),
    );
  }
}
