import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
  final List<StreamSubscription> _subs = [];
  final Map<String, _PhotoItem> _photoMap = {};
  bool _uploading = false;
  double _uploadProgress = 0;
  int _uploadTotal = 0;
  int _uploadCurrent = 0;

  @override
  void initState() {
    super.initState();
    _watchPhotos();
  }

  void _watchPhotos() {
    final addedSub = _service.onPhotoAdded(widget.familyId).listen((event) {
      final id = event.snapshot.key;
      final value = event.snapshot.value;
      if (id == null || value == null) return;
      final info = Map<String, dynamic>.from(value as Map);
      final status = info['status'] as String? ?? 'pending';
      if (status == 'deleted' || status == 'expired') return;
      if (info['thumbUrl'] == null) return;
      if (mounted) setState(() => _photoMap[id] = _PhotoItem.fromMap(id, info));
    });

    final changedSub = _service.onPhotoChanged(widget.familyId).listen((event) {
      final id = event.snapshot.key;
      final value = event.snapshot.value;
      if (id == null || value == null) return;
      final info = Map<String, dynamic>.from(value as Map);
      final status = info['status'] as String? ?? 'pending';
      if (status == 'deleted' || status == 'expired') {
        if (mounted) setState(() => _photoMap.remove(id));
      } else if (info['thumbUrl'] != null) {
        if (mounted) setState(() => _photoMap[id] = _PhotoItem.fromMap(id, info));
      }
    });

    final removedSub = _service.onPhotoRemoved(widget.familyId).listen((event) {
      final id = event.snapshot.key;
      if (id == null) return;
      if (mounted) setState(() => _photoMap.remove(id));
    });

    _subs.addAll([addedSub, changedSub, removedSub]);
  }

  List<_PhotoItem> get _sortedPhotos {
    final list = _photoMap.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

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
              _detailRow('보낸 사람', photo.uploadedByName),
              _detailRow('날짜', _formatDateFull(photo.createdAt)),
              _detailRow('용량', _formatSize(photo.size)),
              _detailRow('상태', _statusText(photo.status)),
              const SizedBox(height: 16),
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
    for (final sub in _subs) {
      sub.cancel();
    }
    super.dispose();
  }

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

          if (photos.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '시니어 기기 슬라이드쇼에 표시 중인 사진',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),

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
  final String thumbUrl;
  final String uploadedByName;
  final int createdAt;
  final String status;
  final int size;

  _PhotoItem({
    required this.id,
    required this.thumbUrl,
    required this.uploadedByName,
    required this.createdAt,
    required this.status,
    required this.size,
  });

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
