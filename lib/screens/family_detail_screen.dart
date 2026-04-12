import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/auth_service.dart';
import '../services/family_service.dart';
import '../services/pairing_helper.dart';
import '../services/photo_transfer_service.dart';
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
class _FamilyDetailScreenState extends State<FamilyDetailScreen> {
  /// 가족 관련 CRUD 서비스
  final _familyService = FamilyService();

  /// 사진 전송 서비스 (photoSync 감시용)
  final _photoService = PhotoTransferService();

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

  // ─── Getter ───

  /// 대표 기기 (첫 번째 Senior 기기) (`Getter`)
  ///
  /// - **Returns**: `Map<String, dynamic>?` — 기기 정보 또는 null
  /// - **호출**: _isOnline, _isInCall, _callDevice, _monitorDevice, _buildDeviceStatusCard
  Map<String, dynamic>? get _primaryDevice =>
      _devices.isNotEmpty ? _devices.first : null;

  /// 대표 기기 온라인 여부 (`Getter`)
  ///
  /// - **Returns**: `bool` — online 필드가 true인지
  /// - **호출**: _buildDeviceStatusCard, _buildActionButtons
  bool get _isOnline => _primaryDevice?['online'] == true;

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
    _loadData();
  }

  /// 데이터 감시 일괄 시작 (`Method`)
  ///
  /// - **Side Effects**: 기기/통화/사진 구독 + 멤버 조회
  /// - **호출**: initState()
  void _loadData() {
    _watchDevices();
    _watchCallStatus();
    _watchPhotos();
    _loadMembers();
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
        if (mounted) setState(() { _devices = []; _loading = false; });
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
      final aOn = a['online'] == true ? 0 : 1;
      final bOn = b['online'] == true ? 0 : 1;
      return aOn.compareTo(bOn);
    });

    if (mounted) setState(() { _devices = list; _loading = false; });
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
      if (mounted) setState(() => _photoMap..clear()..addAll(newMap));
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
    if (mounted) setState(() => _members = members);
  }

  // ─── 액션 ───

  /// 대표 기기에 영상통화 발신 (`Callback`)
  ///
  /// MonitoringScreen(callType:'call')으로 네비게이션.
  ///
  /// - **Side Effects**: Navigator push → MonitoringScreen
  /// - **호출**: _buildActionButtons() 영상통화 버튼 onTap
  void _callDevice() {
    final device = _primaryDevice;
    if (device == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MonitoringScreen(
          targetDeviceId: device['id'] as String,
          targetDeviceName: (device['name'] ?? device['model'] ?? device['id']) as String,
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
  void _monitorDevice() {
    final device = _primaryDevice;
    if (device == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MonitoringScreen(
          targetDeviceId: device['id'] as String,
          targetDeviceName: (device['name'] ?? device['model'] ?? device['id']) as String,
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
  void _openPhotos() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PhotoUploadScreen(familyId: widget.familyId),
      ),
    );
  }

  /// 영상 알림 목록 화면으로 이동 (`Callback`)
  ///
  /// - **Side Effects**: Navigator push → ReminderListScreen
  /// - **호출**: _buildActionButtons() 영상 알림 버튼 onTap
  void _openVideoReminder() {
    Navigator.of(context).push(
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
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('페어링 해제', style: TextStyle(color: Colors.white)),
        content: const Text(
          '시니어 기기와의 연결을 해제하시겠습니까?\n다시 연결하려면 페어링 코드를 입력해야 합니다.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _familyService.leaveFamily(widget.familyId);
              if (!widget.isRoot) Navigator.of(context).pop();
            },
            child: const Text('해제', style: TextStyle(color: Colors.red)),
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
  void _addFamily() {
    Navigator.of(context).push(
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
    for (final sub in _subs) {
      sub.cancel();
    }
    for (final s in _deviceDetailSubs) {
      s.cancel();
    }
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
    final title = widget.familyName ?? '가족';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(title),
        automaticallyImplyLeading: !widget.isRoot,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            color: Colors.grey[900],
            onSelected: (value) {
              if (value == 'add') _addFamily();
              if (value == 'unpair') _confirmUnpair();
              if (value == 'logout') AuthService().signOut();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'add',
                child: Text('가족 추가', style: TextStyle(color: Colors.white)),
              ),
              const PopupMenuItem(
                value: 'unpair',
                child: Text('페어링 해제', style: TextStyle(color: Colors.white)),
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
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildDeviceStatusCard(),
                  const SizedBox(height: 20),
                  _buildActionButtons(),
                  const SizedBox(height: 24),
                  if (_photoMap.isNotEmpty) ...[
                    _buildRecentPhotos(),
                    const SizedBox(height: 24),
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
    if (device == null) {
      return Card(
        color: Colors.grey[900],
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: Text(
              '등록된 기기가 없습니다',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),
        ),
      );
    }

    // 상태 결정
    final Color statusColor;
    final IconData statusIcon;
    final String statusText;

    if (_isInCall) {
      statusColor = Colors.orange;
      statusIcon = Icons.videocam;
      final callerName = _callStatus?['callerName'] ?? '';
      statusText = callerName.isNotEmpty ? '통화 중 — $callerName' : '통화 중';
    } else if (_isOnline) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
      statusText = '온라인';
    } else {
      statusColor = Colors.grey;
      statusIcon = Icons.circle_outlined;
      statusText = '오프라인';
    }

    return Card(
      color: Colors.grey[900],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  (device['name'] ?? device['model'] ?? '') as String,
                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ],
            ),
            if (device['storageTotal'] != null) ...[
              const SizedBox(height: 12),
              _buildStorageBar(device),
            ],
          ],
        ),
      ),
    );
  }

  /// 저장 용량 프로그레스 바 — 사용량/전체 + 사진 수 표시 (`Widget Builder`)
  ///
  /// 사용률에 따라 색상 변경: >90% 빨강, >75% 주황, 그 외 파랑.
  ///
  /// - **Params**:
  ///   - [device] — 기기 정보 맵 (storageTotal, storageAvailable, photoCount 포함)
  /// - **Returns**: `Widget` — LinearProgressIndicator + 텍스트
  /// - **호출**: _buildDeviceStatusCard()
  Widget _buildStorageBar(Map<String, dynamic> device) {
    final total = (device['storageTotal'] as num).toDouble();
    final available = (device['storageAvailable'] as num).toDouble();
    final photoCount = (device['photoCount'] as num?)?.toInt() ?? 0;
    final used = total - available;
    final ratio = total > 0 ? used / total : 0.0;

    String formatSize(double bytes) {
      if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)}GB';
      if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(0)}MB';
      return '${bytes.toInt()}B';
    }

    final color = ratio > 0.9 ? Colors.red : ratio > 0.75 ? Colors.orange : Colors.blue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: ratio,
            backgroundColor: Colors.grey[700],
            color: color,
            minHeight: 4,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${formatSize(used)} / ${formatSize(total)} 사용 · 사진 $photoCount장',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
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

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _actionButton(
          icon: Icons.videocam,
          label: callLabel,
          color: canCall ? Colors.green : Colors.grey[700]!,
          onTap: canCall ? _callDevice : null,
        ),
        _actionButton(
          icon: Icons.camera_outdoor,
          label: '모니터링',
          color: canMonitor ? Colors.orange : Colors.grey[700]!,
          onTap: canMonitor ? _monitorDevice : null,
        ),
        _actionButton(
          icon: Icons.photo_library,
          label: '사진 보내기',
          color: Colors.blue,
          onTap: _openPhotos,
        ),
        _actionButton(
          icon: Icons.movie,
          label: '영상 알림',
          color: Colors.purple,
          onTap: _openVideoReminder,
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
  ///   - [color] — 활성 상태 색상
  ///   - [onTap] — 탭 콜백 (null이면 비활성)
  /// - **Returns**: `Widget` — 100px 너비의 액션 버튼 Container
  /// - **호출**: _buildActionButtons()
  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    final isDisabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: isDisabled ? Colors.grey[900] : color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isDisabled ? Colors.grey[800]! : color.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: isDisabled ? Colors.grey[600] : color, size: 28),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: isDisabled ? Colors.grey[600] : Colors.white,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
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
            const Text(
              '최근 보낸 사진',
              style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
            ),
            GestureDetector(
              onTap: _openPhotos,
              child: const Text(
                '더보기',
                style: TextStyle(color: Colors.blue, fontSize: 13),
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
                        color: Colors.grey[800],
                        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                      errorWidget: (_, _, _) => Container(
                        width: 80,
                        height: 80,
                        color: Colors.grey[800],
                        child: const Icon(Icons.broken_image, color: Colors.grey),
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

  /// 가족 멤버 섹션 — Chip 목록 (이름 + 역할) (`Widget Builder`)
  ///
  /// 시니어 역할이면 '(시니어)' 접미어 표시.
  ///
  /// - **Returns**: `Widget` — 제목 + Wrap 레이아웃의 Chip 목록
  /// - **호출**: build() (_members가 비어있지 않을 때)
  Widget _buildMembersSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '가족 멤버',
          style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: _members.map((m) {
            final name = (m['name'] ?? '알 수 없음') as String;
            final role = (m['role'] ?? '') as String;
            return Chip(
              avatar: const Icon(Icons.person, size: 18, color: Colors.white70),
              label: Text(
                role == 'senior' ? '$name (시니어)' : name,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
              backgroundColor: Colors.grey[800],
              side: BorderSide.none,
            );
          }).toList(),
        ),
      ],
    );
  }
}
