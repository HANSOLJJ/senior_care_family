import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:image_picker/image_picker.dart';
import '../services/photo_transfer_service.dart';

class PhotoUploadScreen extends StatefulWidget {
  final String familyId;

  const PhotoUploadScreen({super.key, required this.familyId});

  @override
  State<PhotoUploadScreen> createState() => _PhotoUploadScreenState();
}

class _PhotoUploadScreenState extends State<PhotoUploadScreen> {
  final _service = PhotoTransferService();
  final _picker = ImagePicker();
  StreamSubscription<DatabaseEvent>? _syncSub;
  List<_PhotoItem> _photos = [];
  bool _uploading = false;
  double _uploadProgress = 0;

  @override
  void initState() {
    super.initState();
    _watchPhotos();
  }

  void _watchPhotos() {
    _syncSub = _service.watchPhotoSync(widget.familyId).listen((event) {
      final data = event.snapshot.value as Map?;
      if (data == null) {
        if (mounted) setState(() => _photos = []);
        return;
      }

      final list = <_PhotoItem>[];
      for (final entry in data.entries) {
        final id = entry.key as String;
        final info = Map<String, dynamic>.from(entry.value as Map);
        final status = info['status'] as String? ?? 'pending';
        if (status == 'deleted' || status == 'expired') continue;

        // done 상태인데 storagePath가 남아있으면 Storage 임시 파일 정리
        final storagePath = info['storagePath'] as String?;
        if (status == 'done' && storagePath != null) {
          _service.cleanupStorageFile(widget.familyId, id, storagePath);
        }

        list.add(_PhotoItem(
          id: id,
          thumbnail: info['thumbnail'] as String? ?? '',
          uploadedByName: info['uploadedByName'] as String? ?? '',
          createdAt: info['createdAt'] as int? ?? 0,
          status: status,
          size: info['size'] as int? ?? 0,
        ));
      }

      // 최신순 정렬
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      if (mounted) setState(() => _photos = list);
    });
  }

  int _uploadTotal = 0;
  int _uploadCurrent = 0;

  /// 갤러리에서 다중 선택
  Future<void> _pickMultiAndUpload() async {
    final picked = await _picker.pickMultiImage(imageQuality: 100);
    if (picked.isEmpty) return;
    await _uploadFiles(picked.map((x) => File(x.path)).toList());
  }

  /// 카메라로 단일 촬영
  Future<void> _pickCameraAndUpload() async {
    final picked = await _picker.pickImage(source: ImageSource.camera, imageQuality: 100);
    if (picked == null) return;
    await _uploadFiles([File(picked.path)]);
  }

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
              // 썸네일 크게
              if (photo.thumbnail.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    base64Decode(photo.thumbnail),
                    width: 200, height: 200, fit: BoxFit.cover,
                  ),
                ),
              const SizedBox(height: 16),
              // 정보 행들
              _detailRow('보낸 사람', photo.uploadedByName),
              _detailRow('날짜', _formatDateFull(photo.createdAt)),
              _detailRow('용량', _formatSize(photo.size)),
              _detailRow('상태', _statusText(photo.status)),
              const SizedBox(height: 16),
              // 삭제 버튼
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

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('사진 보내기${_photos.isNotEmpty ? ' (${_photos.length})' : ''}'),
      ),
      body: Column(
        children: [
          // 업로드 진행률
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

          // 설명
          if (_photos.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '시니어 기기 슬라이드쇼에 표시 중인 사진',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),

          // 사진 그리드
          Expanded(
            child: _photos.isEmpty
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
                    itemCount: _photos.length,
                    itemBuilder: (context, index) => _buildGridTile(_photos[index]),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _showPickerDialog,
        icon: const Icon(Icons.add_photo_alternate),
        label: const Text('사진 보내기'),
        backgroundColor: _uploading ? Colors.grey : Colors.blue,
      ),
    );
  }

  Widget _buildGridTile(_PhotoItem photo) {
    return GestureDetector(
      onTap: () => _showPhotoDetail(photo),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 썸네일
          if (photo.thumbnail.isNotEmpty)
            Image.memory(
              base64Decode(photo.thumbnail),
              fit: BoxFit.cover,
            )
          else
            Container(
              color: Colors.grey[800],
              child: const Icon(Icons.image, color: Colors.white38, size: 32),
            ),
          // 상태 오버레이 (done 제외 — done은 깔끔하게)
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

  String _statusText(String status) {
    switch (status) {
      case 'pending': return '대기 중';
      case 'downloading': return '수신 중';
      case 'done': return '전송 완료';
      case 'expired': return '만료';
      default: return status;
    }
  }

  String _formatDateFull(int timestamp) {
    if (timestamp == 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.year}.${dt.month}.${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)}MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
    return '${bytes}B';
  }
}

class _PhotoItem {
  final String id;
  final String thumbnail;
  final String uploadedByName;
  final int createdAt;
  final String status;
  final int size;

  _PhotoItem({
    required this.id,
    required this.thumbnail,
    required this.uploadedByName,
    required this.createdAt,
    required this.status,
    required this.size,
  });
}
