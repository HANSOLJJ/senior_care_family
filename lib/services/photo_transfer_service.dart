import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import '../config/app_config.dart';

/// 사진 전송 서비스 — Family → Storage(임시) → Senior 다운로드
class PhotoTransferService {
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// 사진 업로드 (리사이즈 + 압축 + 썸네일 + Storage + RTDB)
  Future<String> uploadPhoto(String familyId, File imageFile, {
    void Function(double progress)? onProgress,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('로그인 필요');

    final profile = AppConfig.targetDevice;
    final photoId = _db.ref().push().key!;
    final creatorName = (user.displayName ?? '가족').replaceAll(RegExp(r'[/\\?%*:|"<>]'), '_');
    final now = DateTime.now();
    final dateTimeStr = '${now.toString().substring(0, 10).replaceAll('-', '')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final fileName = 'photo_${creatorName}_$dateTimeStr.jpg';

    // 1. 리사이즈 + JPEG 압축
    print('사진 압축 시작: maxRes=${profile.maxResolution}, quality=${profile.jpegQuality}');
    final compressed = await FlutterImageCompress.compressWithFile(
      imageFile.absolute.path,
      minWidth: profile.maxResolution,
      minHeight: profile.maxResolution,
      quality: profile.jpegQuality,
      format: CompressFormat.jpeg,
    );
    if (compressed == null) throw Exception('이미지 압축 실패');
    print('압축 완료: ${imageFile.lengthSync()} → ${compressed.length} bytes');

    // 2. 썸네일 생성 (200×200, JPEG 75%, base64 ~4-5KB)
    final thumbBytes = await FlutterImageCompress.compressWithFile(
      imageFile.absolute.path,
      minWidth: 200,
      minHeight: 200,
      quality: 75,
      format: CompressFormat.jpeg,
    );
    final thumbnail = thumbBytes != null ? base64Encode(thumbBytes) : '';

    // 3. MD5 체크섬
    final checksum = md5.convert(compressed).toString();

    // 4. Storage 업로드
    final storagePath = 'families/$familyId/temp/$fileName';
    final ref = _storage.ref(storagePath);
    final uploadTask = ref.putData(
      Uint8List.fromList(compressed),
      SettableMetadata(contentType: 'image/jpeg'),
    );

    // 진행률 콜백
    uploadTask.snapshotEvents.listen((snapshot) {
      if (snapshot.totalBytes > 0) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress?.call(progress);
      }
    });

    await uploadTask;
    final downloadUrl = await ref.getDownloadURL();
    print('Storage 업로드 완료: $storagePath');

    // 5. RTDB 메타데이터 등록
    final uploadedByName = user.displayName ?? '가족';
    final label = '$fileName (pending, $uploadedByName)';
    await _db.ref('families/$familyId/photoSync/$photoId').set({
      '_label': label,
      'fileName': fileName,
      'size': compressed.length,
      'checksum': checksum,
      'storageUrl': downloadUrl,
      'storagePath': storagePath,
      'uploadedBy': user.uid,
      'uploadedByName': uploadedByName,
      'createdAt': ServerValue.timestamp,
      'status': 'pending',
      'retryCount': 0,
      'thumbnail': thumbnail,
    });
    print('RTDB 메타 등록: photoSync/$photoId status=pending');

    return photoId;
  }

  /// 사진 삭제 요청 (Senior에서 로컬 삭제 유도)
  Future<void> deletePhoto(String familyId, String photoId) async {
    await _db.ref('families/$familyId/photoSync/$photoId/status').set('deleted');
    print('사진 삭제 요청: $photoId → deleted');
  }

  // Storage 삭제는 Cloud Function(onPhotoDownloaded)이 담당.
  // Family 앱에서 직접 삭제하지 않음.

  /// 보낸 사진 목록 실시간 스트림
  Stream<DatabaseEvent> watchPhotoSync(String familyId) {
    return _db.ref('families/$familyId/photoSync').onValue;
  }
}
