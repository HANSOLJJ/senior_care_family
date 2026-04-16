import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import '../services/pairing_helper.dart';
import '../services/photo_transfer_service.dart';
import '../services/presence_util.dart';
import '../services/reminder/reminder_service.dart';
import '../theme/app_theme.dart';
import '../widgets/safe_state_mixin.dart';
import '../widgets/tap_guard.dart';
import '../widgets/press_scale.dart';
import '../widgets/theme_switcher_button.dart';
// outgoing_call_screen은 MonitoringScreen(callType:"call")으로 통합됨
import 'photo_upload_screen.dart';
import 'monitoring_screen.dart';
import 'pairing_screen.dart';
import 'reminder/reminder_list_screen.dart';

/// 가족 상세 페이지 — 기기 상태 + 액션 버튼 + 사진 + 멤버 (`StatefulWidget`)
///
/// 한 가족 그룹의 모든 정보를 표시하는 메인 화면.
/// 구성:
///   1. 기기 상태 카드 — 온라인/오프라인/통화중 + 저장 용량 바
///   2. 액션 버튼 — 영상통화, 모니터링, 사진 보내기, 영상 알림
///   3. 최근 보낸 사진 — 가로 스크롤 썸네일 (최대 10장)
///   4. 가족 멤버 — Chip 목록 (이름 + 역할)
///
/// RTDB 실시간 감시:
///   - /families/{fid}/devices/ → 기기 목록 + 각 /devices/{did} 상세
///   - /families/{fid}/callStatus/ → 통화 중 여부
///   - /families/{fid}/photoSync/ → 사진 목록 (onValue)
///
/// ## 섹션 구성
/// - **데이터 감시**: 기기 목록, 통화 상태, 사진, 멤버 실시간 구독
/// - **액션**: 영상통화, 모니터링, 사진 업로드, 영상 알림 네비게이션
/// - **UI**: 기기 상태 카드, 액션 버튼, 최근 사진, 멤버 목록
class FamilyDetailScreen extends StatefulWidget {
  /// 대상 가족 그룹 ID
  final String familyId;

  /// 가족 이름 (AppBar 제목용, null이면 '가족' 표시)
  final String? familyName;

  /// true면 루트 화면 (1가족일 때), false면 목록에서 push됨
  final bool isRoot;

  /// 가족 추가 완료 후 부모 위젯에 알리는 콜백
  final VoidCallback? onAddFamily;

  const FamilyDetailScreen({
    super.key,
    required this.familyId,
    this.familyName,
    this.isRoot = false,
    this.onAddFamily,
  });

  @override
  State<FamilyDetailScreen> createState() => _FamilyDetailScreenState();
}

/// [FamilyDetailScreen]의 State (`State`)
///
/// 기기 목록/통화 상태/사진/멤버 실시간 감시 + 액션 버튼 이벤트 처리.
///
/// ## 섹션 구성
/// - **데이터 감시**: _watchDevices, _watchCallStatus, _watchPhotos, _loadMembers
/// - **액션**: _callDevice, _monitorDevice, _openPhotos, _openVideoReminder
/// - **관리**: _confirmUnpair, _addFamily
/// - **UI**: build, _buildDeviceStatusCard, _buildActionButtons 등
class _FamilyDetailScreenState extends State<FamilyDetailScreen>
    with SafeStateMixin, WidgetsBindingObserver {
  /// 가족 관련 CRUD 서비스
  final _familyService = FamilyService();

  /// 사진 전송 서비스 (photoSync 감시용)
  final _photoService = PhotoTransferService();

  /// 알림 서비스 (reminders 카운트 감시용)
  final _reminderService = ReminderService();

  /// 현재 등록된 영상 알림 수 (Hero 카드에 표시)
  int _reminderCount = 0;

  /// 알림 개수 감시 스트림 구독
  StreamSubscription? _reminderCountSub;

  /// 가족 공용 라벨 — `/families/{fid}/_label` 값 (페어링 때 설정, 모든 멤버 공유)
  String? _familyLabel;

  /// _label 실시간 감시 구독
  StreamSubscription<DatabaseEvent>? _labelSub;

  /// Firebase RTDB 인스턴스
  final _db = FirebaseDatabase.instance;

  /// 가족 그룹에 속한 기기 목록 (온라인 우선 정렬)
  List<Map<String, dynamic>> _devices = [];

  /// 현재 통화 상태 ({active: bool, callerName: String?})
  Map<String, dynamic>? _callStatus;

  /// photoId → 사진 메타데이터 맵 (thumbUrl, status, createdAt 등)
  final Map<String, Map<String, dynamic>> _photoMap = {};

  /// 가족 멤버 목록 ({name, role, uid})
  List<Map<String, dynamic>> _members = [];

  /// RTDB 1단계 구독 목록 (기기 목록, 통화 상태, 사진)
  final List<StreamSubscription<DatabaseEvent>> _subs = [];

  /// 데이터 초기 로딩 중 여부
  bool _loading = true;

  // ─── TapGuard (double-tap 차단 + busy 상태) ───
  final _callGuard = TapGuard();
  final _monitorGuard = TapGuard();
  final _photoGuard = TapGuard();
  final _reminderGuard = TapGuard();
  final _menuGuard = TapGuard();

  // ─── Getter ───

  /// 대표 기기 (첫 번째 Senior 기기) (`Getter`)
  ///
  /// - **Returns**: `Map<String, dynamic>?` — 기기 정보 또는 null
  /// - **호출**: _isOnline, _isInCall, _callDevice, _monitorDevice, _buildDeviceStatusCard
  Map<String, dynamic>? get _primaryDevice =>
      _devices.isNotEmpty ? _devices.first : null;

  /// 대표 기기 온라인 여부 (`Getter`)
  ///
  /// - **Returns**: `bool` — connections 자식이 1개라도 있는지 (PresenceUtil 기반)
  /// - **호출**: _buildDeviceStatusCard, _buildActionButtons
  bool get _isOnline => PresenceUtil.isOnlineFromMap(_primaryDevice);

  /// 현재 통화 중 여부 (`Getter`)
  ///
  /// - **Returns**: `bool` — callStatus.active가 true인지
  /// - **호출**: _buildDeviceStatusCard, _buildActionButtons
  bool get _isInCall => _callStatus?['active'] == true;

  // ─── 라이프사이클 ───

  /// 초기화 — 모든 데이터 감시 시작 (`Lifecycle`)
  ///
  /// - **Side Effects**: RTDB 구독 시작, 멤버 로드
  /// - **호출**: 위젯 최초 생성 시 Flutter 프레임워크에 의해
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadData();
  }

  /// (`Lifecycle`) 앱 resume 시 기기 목록/online 상태 강제 재조회
  ///
  /// 백그라운드에서 Firebase WebSocket이 끊겼다 복귀할 때 onValue가 stale
  /// 값을 반환하는 케이스 대응. Senior 측 60s heartbeat와 함께 곧 fresh
  /// 값으로 수렴.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshDeviceList();
    }
  }

  /// 데이터 감시 일괄 시작 (`Method`)
  ///
  /// - **Side Effects**: 기기/통화/사진 구독 + 멤버 조회
  /// - **호출**: initState()
  void _loadData() {
    _watchDevices();
    _watchCallStatus();
    _watchPhotos();
    _watchReminderCount();
    _watchFamilyLabel();
    _loadMembers();
  }

  /// 영상 알림 개수 실시간 감시 (`Method`)
  ///
  /// Hero 카드에 표시할 알림 수. ReminderService 스트림 구독.
  /// - **Side Effects**: _reminderCountSub 등록, _reminderCount 갱신
  void _watchReminderCount() {
    _reminderCountSub = _reminderService
        .watchReminders(widget.familyId)
        .listen((list) => safeSetState(() => _reminderCount = list.length));
  }

  /// 가족 공용 라벨 실시간 감시 (`Method`)
  ///
  /// `/families/{fid}/_label` 값을 Hero 카드에 표시. 페어링 때 저장되며
  /// 모든 멤버가 공유. widget.familyName (user 스코프) 보다 신뢰성 있음.
  void _watchFamilyLabel() {
    _labelSub = _db.ref('families/${widget.familyId}/_label').onValue.listen((event) {
      final v = event.snapshot.value;
      safeSetState(() => _familyLabel = v is String && v.isNotEmpty ? v : null);
    });
  }

  // ─── 데이터 감시 ───

  /// 현재 감시 중인 기기 ID 목록
  List<String> _deviceIds = [];

  /// 각 /devices/{did} 상세 정보 실시간 구독 목록 (2단계)
  final List<StreamSubscription> _deviceDetailSubs = [];

  /// 기기 목록 + 각 기기 상세 2단계 실시간 감시 (`Method`)
  ///
  /// 1단계: /families/{fid}/devices/ onValue → deviceId 목록 추출
  /// 2단계: 각 /devices/{did} onValue → _refreshDeviceList() 호출
  ///
  /// - **Side Effects**: _subs, _deviceDetailSubs에 구독 추가, _devices 갱신
  /// - **호출**: _loadData()
  void _watchDevices() {
    // /families/{fid}/devices/ → deviceId 목록 (값은 true)
    final sub = _db.ref('families/${widget.familyId}/devices').onValue.listen((event) {
      final data = event.snapshot.value;
      // 기존 기기 상세 구독 해제
      for (final s in _deviceDetailSubs) {
        s.cancel();
      }
      _deviceDetailSubs.clear();

      if (data == null) {
        _deviceIds = [];
        safeSetState(() { _devices = []; _loading = false; });
        return;
      }

      // deviceId 목록 추출
      _deviceIds = <String>[];
      if (data is Map) {
        _deviceIds = data.keys.cast<String>().toList();
      }

      // 각 /devices/{did} 실시간 감시
      for (final id in _deviceIds) {
        final detailSub = _db.ref('devices/$id').onValue.listen((_) {
          _refreshDeviceList();
        });
        _deviceDetailSubs.add(detailSub);
      }

      // 초기 로드
      _refreshDeviceList();
    });
    _subs.add(sub);
  }

  /// 기기 상세 정보를 RTDB에서 다시 읽어 목록 갱신 (`Method`, async)
  ///
  /// _deviceIds를 순회하며 /devices/{did} 조회, 온라인 기기 우선 정렬.
  ///
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: _devices 갱신 → setState, _loading → false
  /// - **호출**: _watchDevices() 내부 onValue 리스너
  Future<void> _refreshDeviceList() async {
    final list = <Map<String, dynamic>>[];
    for (final id in _deviceIds) {
      final snap = await _db.ref('devices/$id').get();
      if (!snap.exists) continue;
      final info = Map<String, dynamic>.from(snap.value as Map);
      info['id'] = id;
      list.add(info);
    }

    // 온라인 기기 우선
    list.sort((a, b) {
      final aOn = PresenceUtil.isOnlineFromMap(a) ? 0 : 1;
      final bOn = PresenceUtil.isOnlineFromMap(b) ? 0 : 1;
      return aOn.compareTo(bOn);
    });

    safeSetState(() { _devices = list; _loading = false; });
  }

  /// 통화 상태 실시간 감시 (`Method`)
  ///
  /// /families/{fid}/callStatus/ onValue → _callStatus 갱신
  ///
  /// - **Side Effects**: _callStatus 갱신 → setState
  /// - **호출**: _loadData()
  void _watchCallStatus() {
    final sub = _db.ref('families/${widget.familyId}/callStatus').onValue.listen((event) {
      final data = event.snapshot.value;
      if (mounted) {
        setState(() {
          _callStatus = data is Map ? Map<String, dynamic>.from(data) : null;
        });
      }
    });
    _subs.add(sub);
  }

  /// 사진 동기화 목록 실시간 감시 (`Method`)
  ///
  /// /families/{fid}/photoSync/ onValue → _photoMap 갱신
  /// thumbUrl이 있고 status가 done/pending인 항목만 포함.
  ///
  /// - **Side Effects**: _photoMap 갱신 → setState
  /// - **호출**: _loadData()
  void _watchPhotos() {
    final sub = _photoService.watchPhotoSync(widget.familyId).listen((event) {
      final data = event.snapshot.value;
      final newMap = <String, Map<String, dynamic>>{};
      if (data != null) {
        final raw = Map<String, dynamic>.from(data as Map);
        for (final entry in raw.entries) {
          final id = entry.key;
          final info = Map<String, dynamic>.from(entry.value as Map);
          if (info['thumbUrl'] != null &&
              (info['status'] == 'done' || info['status'] == 'pending')) {
            newMap[id] = info;
          }
        }
      }
      safeSetState(() => _photoMap..clear()..addAll(newMap));
    });
    _subs.add(sub);
  }

  /// 가족 멤버 목록 로드 (`Method`, async)
  ///
  /// FamilyService.getFamilyMembers()로 1회 조회.
  ///
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: _members 갱신 → setState
  /// - **호출**: _loadData()
  Future<void> _loadMembers() async {
    final members = await _familyService.getFamilyMembers(widget.familyId);
    safeSetState(() => _members = members);
  }

  // ─── 액션 ───

  /// 대표 기기에 영상통화 발신 (`Callback`)
  ///
  /// MonitoringScreen(callType:'call')으로 네비게이션.
  ///
  /// - **Side Effects**: Navigator push → MonitoringScreen
  /// - **호출**: _buildActionButtons() 영상통화 버튼 onTap
  Future<void> _callDevice() async {
    final device = _primaryDevice;
    if (device == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MonitoringScreen(
          targetDeviceId: device['id'] as String,
          targetDeviceName: (device['name'] ?? device['id']) as String,
          familyLabel: widget.familyName,
          callType: 'call',
          familyId: widget.familyId,
        ),
      ),
    );
  }

  /// 대표 기기 CCTV 모니터링 시작 (`Callback`)
  ///
  /// MonitoringScreen(callType:'monitor')으로 네비게이션.
  ///
  /// - **Side Effects**: Navigator push → MonitoringScreen
  /// - **호출**: _buildActionButtons() 모니터링 버튼 onTap
  Future<void> _monitorDevice() async {
    final device = _primaryDevice;
    if (device == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MonitoringScreen(
          targetDeviceId: device['id'] as String,
          targetDeviceName: (device['name'] ?? device['id']) as String,
          familyLabel: widget.familyName,
          callType: 'monitor',
          familyId: widget.familyId,
        ),
      ),
    );
  }

  /// 사진 업로드 화면으로 이동 (`Callback`)
  ///
  /// - **Side Effects**: Navigator push → PhotoUploadScreen
  /// - **호출**: _buildActionButtons() 사진 보내기 버튼 onTap, _buildRecentPhotos() 더보기
  Future<void> _openPhotos() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoUploadScreen(familyId: widget.familyId),
      ),
    );
  }

  /// 영상 알림 목록 화면으로 이동 (`Callback`)
  ///
  /// - **Side Effects**: Navigator push → ReminderListScreen
  /// - **호출**: _buildActionButtons() 영상 알림 버튼 onTap
  Future<void> _openVideoReminder() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReminderListScreen(familyId: widget.familyId),
      ),
    );
  }

  /// 페어링 해제 확인 다이얼로그 표시 (`Callback`)
  ///
  /// 확인 시 FamilyService.leaveFamily() 호출, 루트가 아니면 pop.
  ///
  /// - **Side Effects**: showDialog, leaveFamily 호출, Navigator pop
  /// - **호출**: PopupMenuButton 'unpair' 선택 시
  void _confirmUnpair() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('페어링 해제'),
        content: const Text(
          '시니어 기기와의 연결을 해제하시겠습니까?\n다시 연결하려면 페어링 코드를 입력해야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _familyService.leaveFamily(widget.familyId);
              if (!widget.isRoot) Navigator.of(context).pop();
            },
            child: Text('해제', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
  }

  /// 가족 추가 — PairingScreen으로 이동 (`Callback`)
  ///
  /// 페어링 완료 시 PairingHelper.onPairingComplete() 호출 후 부모에 알림.
  ///
  /// - **Side Effects**: Navigator push, onAddFamily 콜백
  /// - **호출**: PopupMenuButton 'add' 선택 시
  Future<void> _addFamily() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PairingScreen(
          onPairedWithId: (familyId) async {
            await PairingHelper.onPairingComplete(context, familyId);
            if (context.mounted) Navigator.of(context).pop();
            widget.onAddFamily?.call();
          },
        ),
      ),
    );
  }


  /// 모든 RTDB 구독 해제 (`Lifecycle`)
  ///
  /// - **Side Effects**: _subs, _deviceDetailSubs 모든 구독 cancel
  /// - **호출**: 위젯 제거 시 Flutter 프레임워크에 의해
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _callGuard.dispose();
    _monitorGuard.dispose();
    _photoGuard.dispose();
    _reminderGuard.dispose();
    _menuGuard.dispose();
    for (final sub in _subs) {
      sub.cancel();
    }
    for (final s in _deviceDetailSubs) {
      s.cancel();
    }
    _reminderCountSub?.cancel();
    _labelSub?.cancel();
    super.dispose();
  }

  // ─── UI ───

  /// 메인 빌드 — 전체 화면 구성 (`Widget Builder`)
  ///
  /// Scaffold + AppBar(메뉴) + SingleChildScrollView:
  ///   기기 상태 카드 → 액션 버튼 → 최근 사진 → 멤버 목록
  ///
  /// - **Returns**: `Widget` — 전체 화면 위젯
  /// - **호출**: Flutter 프레임워크 (setState 시 재호출)
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 타이틀은 Hero 카드가 hero 역할 — 중복 제거
        automaticallyImplyLeading: !widget.isRoot,
        actions: [
          const ThemeSwitcherButton(),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              HapticFeedback.selectionClick();
              if (value == 'add') _menuGuard.run(_addFamily);
              if (value == 'unpair') _menuGuard.run(() async => _confirmUnpair());
              if (value == 'logout') _menuGuard.run(() async => AuthService().signOut());
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'add',
                child: Text('가족 추가'),
              ),
              const PopupMenuItem(
                value: 'unpair',
                child: Text('페어링 해제'),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Text('로그아웃'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDeviceStatusCard(),
                  const SizedBox(height: 14),
                  _buildActionButtons(),
                  const SizedBox(height: 18),
                  if (_photoMap.isNotEmpty) ...[
                    _buildRecentPhotos(),
                    const SizedBox(height: 18),
                  ],
                  if (_members.isNotEmpty) _buildMembersSection(),
                ],
              ),
            ),
    );
  }

  /// 기기 상태 카드 — 온라인/오프라인/통화중 + 저장 용량 표시 (`Widget Builder`)
  ///
  /// _primaryDevice가 null이면 '등록된 기기가 없습니다' 표시.
  /// 상태 색상: 통화중(주황), 온라인(초록), 오프라인(회색).
  /// storageTotal이 있으면 _buildStorageBar()로 용량 바 표시.
  ///
  /// - **Returns**: `Widget` — 기기 상태 Card 위젯
  /// - **호출**: build()
  Widget _buildDeviceStatusCard() {
    final device = _primaryDevice;
    final cs = Theme.of(context).colorScheme;
    final ext = Theme.of(context).extension<AppColorExt>()!;

    if (device == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: Text('등록된 기기가 없습니다', style: TextStyle(fontSize: 16)),
          ),
        ),
      );
    }

    // 상태 결정
    final Color statusColor;
    final IconData statusIcon;
    final String statusText;

    if (_isInCall) {
      statusColor = ext.warning;
      statusIcon = Icons.videocam;
      final callerName = _callStatus?['callerName'] ?? '';
      statusText = callerName.isNotEmpty ? '통화 중 · $callerName' : '통화 중';
    } else if (_isOnline) {
      statusColor = ext.success;
      statusIcon = Icons.check_circle;
      statusText = '온라인';
    } else {
      statusColor = ext.textSecondary;
      statusIcon = Icons.circle_outlined;
      statusText = '오프라인';
    }

    // 표시 단일 소스: /families/{fid}/_label (페어링 때 저장, 가족 멤버 공용)
    final seniorName = _familyLabel ?? '가족';
    final photoCount = _photoMap.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 시니어 이름 (hero) — 상태와 같은 줄에 표시
            Row(
              children: [
                Expanded(
                  child: Text(
                    seniorName,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(statusIcon, color: statusColor, size: 14),
                const SizedBox(width: 4),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 정보 2개 (사진 수, 알림 수)
            Row(
              children: [
                _infoChip(
                  icon: Icons.photo_library_outlined,
                  label: '사진 $photoCount장',
                ),
                const SizedBox(width: 12),
                _infoChip(
                  icon: Icons.notifications_outlined,
                  label: _reminderCount > 0 ? '알림 $_reminderCount개' : '알림 없음',
                ),
              ],
            ),
            // 저장 용량
            if (device['storageTotal'] != null) ...[
              const SizedBox(height: 12),
              _buildStorageBar(device, cs, ext),
            ],
          ],
        ),
      ),
    );
  }

  /// Hero 카드 내부 정보 칩 (사진 수 / 알림 수) (`Widget Builder`)
  Widget _infoChip({required IconData icon, required String label}) {
    final ext = Theme.of(context).extension<AppColorExt>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: ext.textSecondary),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(color: ext.textSecondary, fontSize: 13),
        ),
      ],
    );
  }

  /// 저장 용량 프로그레스 바 — 사용량/전체 표시 (`Widget Builder`)
  ///
  /// 사용률에 따라 색상 변경: >90% error, >75% warning, 그 외 primary.
  ///
  /// - **Params**:
  ///   - [device] — 기기 정보 맵 (storageTotal, storageAvailable 포함)
  ///   - [cs] — 현재 테마 ColorScheme
  ///   - [ext] — 현재 테마 AppColorExt
  /// - **Returns**: `Widget` — LinearProgressIndicator + 텍스트
  /// - **호출**: _buildDeviceStatusCard()
  Widget _buildStorageBar(Map<String, dynamic> device, ColorScheme cs, AppColorExt ext) {
    final total = (device['storageTotal'] as num).toDouble();
    final available = (device['storageAvailable'] as num).toDouble();
    final used = total - available;
    final ratio = total > 0 ? used / total : 0.0;

    String formatSize(double bytes) {
      if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)}GB';
      if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(0)}MB';
      return '${bytes.toInt()}B';
    }

    final color = ratio > 0.9
        ? cs.error
        : ratio > 0.75
            ? ext.warning
            : cs.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('저장 공간', style: TextStyle(fontSize: 13, color: ext.textSecondary)),
            Text('${(ratio * 100).toInt()}%',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: ratio,
            color: color,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${formatSize(used)} / ${formatSize(total)}',
          style: TextStyle(color: ext.textSecondary, fontSize: 12),
        ),
      ],
    );
  }

  /// 액션 버튼 그리드 — 영상통화/모니터링/사진/알림 (`Widget Builder`)
  ///
  /// 기기 상태에 따라 버튼 활성/비활성:
  /// - 영상통화: 온라인 + 비통화중일 때만
  /// - 모니터링: 온라인이면 (통화 중에도 가능, 1:N)
  /// - 사진/알림: 항상 활성
  ///
  /// - **Returns**: `Widget` — Wrap 레이아웃의 액션 버튼들
  /// - **호출**: build()
  Widget _buildActionButtons() {
    final canCall = _isOnline && !_isInCall;
    final canMonitor = _isOnline; // 통화 중에도 모니터링 가능 (1:N)
    final callLabel = _isInCall ? '통화 중' : '영상통화';

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _actionButton(
              icon: Icons.videocam,
              label: callLabel,
              guard: _callGuard,
              onTap: canCall ? _callDevice : null,
            )),
            const SizedBox(width: 12),
            Expanded(child: _actionButton(
              icon: Icons.remove_red_eye,
              label: '모니터링',
              guard: _monitorGuard,
              onTap: canMonitor ? _monitorDevice : null,
            )),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _actionButton(
              icon: Icons.photo_library,
              label: '사진 보내기',
              guard: _photoGuard,
              onTap: _openPhotos,
            )),
            const SizedBox(width: 12),
            Expanded(child: _actionButton(
              icon: Icons.movie_creation_outlined,
              label: '영상 알림',
              guard: _reminderGuard,
              onTap: _openVideoReminder,
            )),
          ],
        ),
      ],
    );
  }

  /// 개별 액션 버튼 위젯 생성 (`Widget Builder`)
  ///
  /// onTap이 null이면 비활성 스타일 (회색 배경 + 회색 아이콘).
  ///
  /// - **Params**:
  ///   - [icon] — 버튼 아이콘
  ///   - [label] — 버튼 라벨 텍스트
  ///   - [onTap] — 탭 콜백 (null이면 비활성)
  /// - **Returns**: `Widget` — 2×2 그리드에서 Expanded 로 쓰이는 액션 카드
  /// - **호출**: _buildActionButtons()
  Widget _actionButton({
    required IconData icon,
    required String label,
    required TapGuard guard,
    Future<void> Function()? onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    final ext = Theme.of(context).extension<AppColorExt>()!;

    return ValueListenableBuilder<bool>(
      valueListenable: guard.isBusy,
      builder: (context, busy, _) {
        final isDisabled = onTap == null || busy;
        final fg = isDisabled ? ext.textSecondary : cs.primary;
        final bg = isDisabled ? cs.surface : cs.primary.withValues(alpha: 0.12);
        final border = isDisabled
            ? ext.textSecondary.withValues(alpha: 0.2)
            : cs.primary.withValues(alpha: 0.4);

        return PressScale(
          onTap: isDisabled
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  guard.run(onTap);
                },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: fg, size: 24),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: isDisabled ? ext.textSecondary : null,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 최근 보낸 사진 섹션 — 가로 스크롤 썸네일 목록 (`Widget Builder`)
  ///
  /// _photoMap에서 최신순 정렬, 최대 10장 표시.
  /// CachedNetworkImage로 썸네일 로드, 탭 시 PhotoUploadScreen 이동.
  ///
  /// - **Returns**: `Widget` — 제목 + 가로 스크롤 썸네일 ListView
  /// - **호출**: build() (_photoMap이 비어있지 않을 때)
  Widget _buildRecentPhotos() {
    // 최신순 정렬, 최대 10장
    final photos = _photoMap.values.toList()
      ..sort((a, b) =>
          ((b['createdAt'] as num?) ?? 0).compareTo((a['createdAt'] as num?) ?? 0));
    final recent = photos.length > 10 ? photos.sublist(0, 10) : photos;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '최근 보낸 사진',
              style: TextStyle(
                color: Theme.of(context).extension<AppColorExt>()!.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            GestureDetector(
              onTap: _openPhotos,
              child: Text(
                '더보기',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 80,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: recent.length,
            itemBuilder: (context, index) {
              final photo = recent[index];
              final thumbUrl = photo['thumbUrl'] as String? ?? '';
              if (thumbUrl.isEmpty) return const SizedBox.shrink();

              final surface = Theme.of(context).colorScheme.surface;
              final iconColor = Theme.of(context).extension<AppColorExt>()!.textSecondary;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: _openPhotos,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: thumbUrl,
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                      placeholder: (_, _) => Container(
                        width: 80,
                        height: 80,
                        color: surface,
                        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                      errorWidget: (_, _, _) => Container(
                        width: 80,
                        height: 80,
                        color: surface,
                        child: Icon(Icons.broken_image, color: iconColor),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 가족 멤버 섹션 — Chip 목록 (이름) (`Widget Builder`)
  ///
  /// 멤버는 Family 앱 사용자(자녀)만. 시니어는 /families/members에 포함 안 됨.
  ///
  /// - **Returns**: `Widget` — 제목 + Wrap 레이아웃의 Chip 목록
  /// - **호출**: build() (_members가 비어있지 않을 때)
  Widget _buildMembersSection() {
    final cs = Theme.of(context).colorScheme;
    final ext = Theme.of(context).extension<AppColorExt>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '가족 멤버',
          style: TextStyle(
            color: ext.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _members.map((m) {
            final name = (m['name'] ?? '알 수 없음') as String;
            return Chip(
              avatar: Icon(Icons.person_outline, size: 16, color: cs.primary),
              label: Text(name, style: const TextStyle(fontSize: 13)),
              side: BorderSide(color: cs.primary.withValues(alpha: 0.35)),
              backgroundColor: Colors.transparent,
            );
          }).toList(),
        ),
      ],
    );
  }
}
