import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import '../services/photo_transfer_service.dart';

/// 사진 업로드 + 관리 화면 (`StatefulWidget`)
///
/// 기능:
///   - 갤러리/카메라에서 사진 선택 → Storage 업로드 (리사이즈 + 압축)
///   - 업로드된 사진 그리드 표시 (썸네일, CachedNetworkImage)
///   - 사진 삭제 (RTDB remove → CF가 Storage 썸네일 자동 삭제)
///   - 상태 표시: pending(업로드 중), done(Senior 다운로드 완료)
///
/// RTDB /families/{fid}/photoSync/ onValue 구독으로 실시간 동기화
class PhotoUploadScreen extends StatefulWidget {
  /// 이 화면이 표시할 가족 그룹 ID
  final String familyId;

  const PhotoUploadScreen({super.key, required this.familyId});

  @override
  State<PhotoUploadScreen> createState() => _PhotoUploadScreenState();
}

/// [PhotoUploadScreen]의 `State`
///
/// _photoMap에 현재 모든 사진 정보를 보관하고, RTDB 이벤트마다 갱신.
///
/// - **섹션 구성**:
///   - 상태 필드 — 업로드 진행률, 사진 맵
///   - RTDB 구독 — _watchPhotos()
///   - 업로드 — _pickMultiAndUpload(), _pickCameraAndUpload(), _uploadFiles()
///   - 다이얼로그 — _showPickerDialog(), _showPhotoDetail(), _confirmDelete()
///   - UI 빌드 — build(), _buildGridTile()
///   - 유틸리티 — _statusIcon(), _statusText(), _formatDateFull(), _formatSize()
class _PhotoUploadScreenState extends State<PhotoUploadScreen> {

  // ─── 상태 필드 ───

  /// 사진 업로드/삭제/스트림 서비스
  final _service = PhotoTransferService();

  /// 갤러리/카메라 접근 플러그인
  final _picker = ImagePicker();

  /// RTDB 구독 목록 (dispose 시 해제용)
  final List<StreamSubscription> _subs = [];

  /// photoId → _PhotoItem 맵 (RTDB 전체 스냅샷에서 갱신)
  final Map<String, _PhotoItem> _photoMap = {};

  /// 현재 업로드 진행 중 여부 (FAB 비활성화 + 프로그레스 바 표시)
  bool _uploading = false;

  /// 현재 파일의 업로드 진행률 (0.0 ~ 1.0)
  double _uploadProgress = 0;

  /// 총 업로드 대상 파일 수 (다중 선택 시)
  int _uploadTotal = 0;

  /// 현재 업로드 중인 파일 순번 (1-based)
  int _uploadCurrent = 0;

  @override
  void initState() {
    super.initState();
    _watchPhotos();
  }

  // ─── RTDB 구독 ───

  /// RTDB photoSync 실시간 구독 시작 (`Method`)
  ///
  /// - **Params**: 없음 (widget.familyId 사용)
  /// - **Returns**: `void`
  /// - **Side Effects**: [_photoMap] 갱신, [_subs]에 구독 추가
  ///
  /// onValue 전체 스냅샷을 받아 _photoMap을 교체.
  /// expired 상태이거나 thumbUrl이 없는 항목은 제외.
  void _watchPhotos() {
    final sub = _service.watchPhotoSync(widget.familyId).listen((event) {
      final data = event.snapshot.value;
      final newMap = <String, _PhotoItem>{};
      if (data != null) {
        final raw = Map<String, dynamic>.from(data as Map);
        for (final entry in raw.entries) {
          final id = entry.key;
          final info = Map<String, dynamic>.from(entry.value as Map);
          final status = info['status'] as String? ?? 'pending';
          if (status == 'expired') continue;
          if (info['thumbUrl'] == null) continue;
          newMap[id] = _PhotoItem.fromMap(id, info);
        }
      }
      if (mounted) setState(() => _photoMap..clear()..addAll(newMap));
    });
    _subs.add(sub);
  }

  /// 사진 목록을 최신순으로 정렬하여 반환 (`Getter`)
  ///
  /// - **Returns**: `List<_PhotoItem>` — createdAt 내림차순 정렬
  List<_PhotoItem> get _sortedPhotos {
    final list = _photoMap.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  // ─── 업로드 ───

  /// 갤러리에서 다중 사진 선택 후 업로드 (`Method`, async)
  ///
  /// - **Params**: 없음 (image_picker 다이얼로그에서 선택)
  /// - **Returns**: `Future<void>`
  /// - **호출**: [_showPickerDialog]에서 "갤러리에서 선택" 탭 시
  Future<void> _pickMultiAndUpload() async {
    final picked = await _picker.pickMultiImage(imageQuality: 100);
    if (picked.isEmpty) return;
    await _uploadFiles(picked.map((x) => File(x.path)).toList());
  }

  /// 카메라로 단일 사진 촬영 후 업로드 (`Method`, async)
  ///
  /// - **Params**: 없음 (image_picker 카메라 UI에서 촬영)
  /// - **Returns**: `Future<void>`
  /// - **호출**: [_showPickerDialog]에서 "카메라로 촬영" 탭 시
  Future<void> _pickCameraAndUpload() async {
    final picked = await _picker.pickImage(source: ImageSource.camera, imageQuality: 100);
    if (picked == null) return;
    await _uploadFiles([File(picked.path)]);
  }

  /// 파일 목록을 순차 업로드 (`Method`, async)
  ///
  /// - **Params**:
  ///   - [files] — 업로드할 로컬 이미지 파일 목록
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: [_uploading], [_uploadProgress], [_uploadCurrent] 상태 변경
  ///   완료 시 SnackBar로 "N장 전송 완료" / "N장 성공, N장 실패" 표시
  ///
  /// 각 파일마다 [PhotoTransferService.uploadPhoto]를 호출하고,
  /// onProgress 콜백으로 [_uploadProgress]를 실시간 갱신.
  Future<void> _uploadFiles(List<File> files) async {
    setState(() {
      _uploading = true;
      _uploadProgress = 0;
      _uploadTotal = files.length;
      _uploadCurrent = 0;
    });

    int success = 0;
    int fail = 0;

    for (final file in files) {
      if (!mounted) break;
      setState(() => _uploadCurrent++);
      try {
        await _service.uploadPhoto(
          widget.familyId,
          file,
          onProgress: (p) {
            if (mounted) setState(() => _uploadProgress = p);
          },
        );
        success++;
      } catch (e) {
        fail++;
        print('업로드 실패: $e');
      }
    }

    if (mounted) {
      setState(() => _uploading = false);
      final msg = fail == 0
          ? '$success장 전송 완료'
          : '$success장 성공, $fail장 실패';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    }
  }

  // ─── 다이얼로그 ───

  /// 사진 소스 선택 바텀시트 (`Method`)
  ///
  /// - **Returns**: `void`
  /// - **UI**: 갤러리(다중) / 카메라(단일) 선택지 표시
  /// - **호출**: FAB "사진 보내기" 버튼 탭 시
  void _showPickerDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.white),
              title: const Text('갤러리에서 선택 (여러 장)', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickMultiAndUpload(); },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.white),
              title: const Text('카메라로 촬영', style: TextStyle(color: Colors.white)),
              onTap: () { Navigator.pop(context); _pickCameraAndUpload(); },
            ),
          ],
        ),
      ),
    );
  }

  /// 사진 상세 바텀시트 (`Method`)
  ///
  /// - **Params**:
  ///   - [photo] — 상세 표시할 사진 아이템
  /// - **Returns**: `void`
  /// - **UI**: 썸네일 확대 + 메타데이터(보낸 사람/날짜/용량/상태) + 삭제 버튼(done일 때만)
  /// - **호출**: 그리드 타일 탭 시
  void _showPhotoDetail(_PhotoItem photo) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 썸네일 확대 표시
              if (photo.thumbUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: photo.thumbUrl,
                    width: 200,
                    height: 200,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      width: 200,
                      height: 200,
                      color: Colors.grey[800],
                      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    errorWidget: (_, _, _) => Container(
                      width: 200,
                      height: 200,
                      color: Colors.grey[800],
                      child: const Icon(Icons.broken_image, color: Colors.grey, size: 48),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              // 메타데이터 행
              _detailRow('보낸 사람', photo.uploadedByName),
              _detailRow('날짜', _formatDateFull(photo.createdAt)),
              _detailRow('용량', _formatSize(photo.size)),
              _detailRow('상태', _statusText(photo.status)),
              const SizedBox(height: 16),
              // done 상태에서만 삭제 가능
              if (photo.status == 'done')
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      _confirmDelete(photo.id);
                    },
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('시니어 기기에서 삭제'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[700],
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 상세 바텀시트의 라벨-값 행 (`Widget Builder`)
  ///
  /// - **Params**:
  ///   - [label] — 좌측 라벨 (예: "보낸 사람")
  ///   - [value] — 우측 값 (예: "홍길동")
  /// - **Returns**: `Widget` — 한 행의 Row
  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 14)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 14)),
          ),
        ],
      ),
    );
  }

  /// 사진 삭제 확인 다이얼로그 (`Method`)
  ///
  /// - **Params**:
  ///   - [photoId] — 삭제할 사진의 RTDB key
  /// - **Returns**: `void`
  /// - **Side Effects**: 확인 시 [PhotoTransferService.deletePhoto] 호출 → RTDB remove()
  /// - **호출**: [_showPhotoDetail]의 삭제 버튼 탭 시
  void _confirmDelete(String photoId) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('사진 삭제', style: TextStyle(color: Colors.white)),
        content: const Text('이 사진을 시니어 기기에서 삭제하시겠습니까?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _service.deletePhoto(widget.familyId, photoId);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// RTDB 구독 해제 (`Lifecycle`)
  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

  // ─── UI 빌드 ───

  /// 메인 화면 빌드 (`Widget`, override)
  ///
  /// - **구성**:
  ///   - 업로드 프로그레스 바 (업로드 중에만)
  ///   - 안내 텍스트
  ///   - 4열 사진 그리드 (또는 빈 상태 메시지)
  ///   - FAB "사진 보내기" (업로드 중 비활성)
  @override
  Widget build(BuildContext context) {
    final photos = _sortedPhotos;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('사진 보내기${photos.isNotEmpty ? ' (${photos.length})' : ''}'),
      ),
      body: Column(
        children: [
          // 업로드 프로그레스 바 (업로드 중에만 표시)
          if (_uploading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  LinearProgressIndicator(value: _uploadProgress, color: Colors.blue),
                  const SizedBox(height: 4),
                  Text(
                    _uploadTotal > 1
                        ? '업로드 중... $_uploadCurrent/$_uploadTotal (${(_uploadProgress * 100).toInt()}%)'
                        : '업로드 중... ${(_uploadProgress * 100).toInt()}%',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),

          // 안내 텍스트
          if (photos.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '시니어 기기 슬라이드쇼에 표시 중인 사진',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),

          // 사진 그리드 (4열) 또는 빈 상태 메시지
          Expanded(
            child: photos.isEmpty
                ? const Center(
                    child: Text(
                      '보낸 사진이 없습니다\n아래 버튼으로 사진을 보내보세요',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, fontSize: 16),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(4),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      crossAxisSpacing: 2,
                      mainAxisSpacing: 2,
                    ),
                    itemCount: photos.length,
                    itemBuilder: (context, index) => _buildGridTile(photos[index]),
                  ),
          ),
        ],
      ),
      // 사진 추가 FAB (업로드 중이면 비활성)
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _showPickerDialog,
        icon: const Icon(Icons.add_photo_alternate),
        label: const Text('사진 보내기'),
        backgroundColor: _uploading ? Colors.grey : Colors.blue,
      ),
    );
  }

  /// 그리드의 각 사진 타일 (`Widget Builder`)
  ///
  /// - **Params**:
  ///   - [photo] — 표시할 사진 아이템
  /// - **Returns**: `Widget` — 썸네일 + 상태 아이콘 오버레이
  /// - **탭 동작**: [_showPhotoDetail] 바텀시트 열림
  Widget _buildGridTile(_PhotoItem photo) {
    return GestureDetector(
      onTap: () => _showPhotoDetail(photo),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 썸네일 이미지
          photo.thumbUrl.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: photo.thumbUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => Container(color: Colors.grey[800]),
                  errorWidget: (_, _, _) => Container(
                    color: Colors.grey[800],
                    child: const Icon(Icons.image, color: Colors.white38, size: 32),
                  ),
                )
              : Container(
                  color: Colors.grey[800],
                  child: const Icon(Icons.image, color: Colors.white38, size: 32),
                ),
          // 상태 아이콘 (done이 아닌 경우에만 표시)
          if (photo.status != 'done')
            Positioned(
              right: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: _statusIcon(photo.status),
              ),
            ),
        ],
      ),
    );
  }

  // ─── 유틸리티 ───

  /// 사진 상태에 따른 아이콘 위젯 반환 (`Widget Builder`)
  ///
  /// - **Params**:
  ///   - [status] — 사진 전송 상태 문자열
  /// - **Returns**: `Widget` — 상태별 아이콘
  ///   - pending: 주황 시계 (Senior 다운로드 대기)
  ///   - downloading: 파란 로딩 (Senior 수신 중)
  ///   - done: 초록 체크 (전송 완료)
  ///   - expired: 빨간 에러 (만료)
  Widget _statusIcon(String status) {
    switch (status) {
      case 'pending':
        return const Icon(Icons.schedule, color: Colors.orange, size: 18);
      case 'downloading':
        return const SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
        );
      case 'done':
        return const Icon(Icons.check_circle, color: Colors.green, size: 18);
      case 'expired':
        return const Icon(Icons.error_outline, color: Colors.red, size: 18);
      default:
        return const Icon(Icons.help_outline, color: Colors.grey, size: 18);
    }
  }

  /// 사진 상태 코드를 한글 텍스트로 변환 (`Utility`)
  ///
  /// - **Params**:
  ///   - [status] — RTDB status 값 ("pending", "downloading", "done", "expired")
  /// - **Returns**: `String` — 한글 상태명
  String _statusText(String status) {
    switch (status) {
      case 'pending': return '대기 중';
      case 'downloading': return '수신 중';
      case 'done': return '전송 완료';
      case 'expired': return '만료';
      default: return status;
    }
  }

  /// 타임스탬프를 날짜 문자열로 포맷 (`Utility`)
  ///
  /// - **Params**:
  ///   - [timestamp] — 밀리초 단위 Unix 타임스탬프
  /// - **Returns**: `String` — "2026.3.23 18:30" 형식 (0이면 빈 문자열)
  String _formatDateFull(int timestamp) {
    if (timestamp == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.year}.${dt.month}.${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// 바이트 수를 사람이 읽기 쉬운 형식으로 변환 (`Utility`)
  ///
  /// - **Params**:
  ///   - [bytes] — 파일 크기 (바이트)
  /// - **Returns**: `String` — "1.5MB", "320KB", "512B" 등
  String _formatSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)}MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${bytes}B';
  }
}

/// 사진 메타데이터 모델 (`Model`, private)
///
/// RTDB /families/{fid}/photoSync/{photoId} 의 데이터를
/// UI에서 사용하기 편한 형태로 매핑.
class _PhotoItem {
  /// RTDB push key (photoId)
  final String id;

  /// 썸네일 이미지 URL (Storage)
  final String thumbUrl;

  /// 업로드한 사람 이름
  final String uploadedByName;

  /// 업로드 시각 (밀리초 타임스탬프)
  final int createdAt;

  /// 전송 상태: pending → downloading → done / expired
  final String status;

  /// 원본 파일 크기 (바이트)
  final int size;

  _PhotoItem({
    required this.id,
    required this.thumbUrl,
    required this.uploadedByName,
    required this.createdAt,
    required this.status,
    required this.size,
  });

  /// RTDB 스냅샷 Map에서 _PhotoItem 생성 (`Factory`)
  ///
  /// - **Params**:
  ///   - [id] — photoId (RTDB key)
  ///   - [info] — RTDB 스냅샷의 value Map
  /// - **Returns**: `_PhotoItem` — null-safe 기본값 적용된 인스턴스
  factory _PhotoItem.fromMap(String id, Map<String, dynamic> info) {
    return _PhotoItem(
      id: id,
      thumbUrl: info['thumbUrl'] as String? ?? '',
      uploadedByName: info['uploadedByName'] as String? ?? '',
      createdAt: info['createdAt'] as int? ?? 0,
      status: info['status'] as String? ?? 'pending',
      size: info['size'] as int? ?? 0,
    );
  }
}
