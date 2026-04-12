import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import '../config/app_config.dart';

/// 사진 전송 서비스 (`Service`) — Family → Storage(임시 버퍼) → Senior 다운로드
///
/// 업로드 흐름:
///   1. Family가 갤러리/카메라에서 사진 선택
///   2. [AppConfig.targetDevice] 기반 리사이즈 + JPEG 압축
///   3. Storage에 원본 업로드 (임시 버퍼: `families/{fid}/temp/`) + 썸네일 생성·업로드 (`families/{fid}/thumbs/`)
///   4. RTDB `/families/{fid}/photoSync/{photoId}` 에 메타데이터 기록 (status: pending)
///   5. Senior가 onValue로 감지 → OkHttp 다운로드 → `downloadedBy/{did}: true` 기록
///   6. Cloud Function(`onPhotoDownloaded`)이 모든 Senior 다운로드 완료 시 Storage 원본 삭제
///
/// 삭제 흐름:
///   1. Family가 RTDB `photoSync/{photoId}` 노드를 `remove()` 호출
///   2. Cloud Function(`onPhotoDeleted`)이 thumbPath의 Storage 파일 삭제
///   3. Senior는 onValue 전체 스냅샷 reconcile로 로컬 파일 삭제
///
/// RTDB 경로:
///   - `/families/{fid}/photoSync/{photoId}` — 사진 메타데이터 (fileName, size, status, ...)
///   - `/families/{fid}/photoSync/{photoId}/downloadedBy/{did}` — Senior 다운로드 완료 마커
///
/// Storage 경로:
///   - `families/{fid}/temp/{fileName}` — 원본 임시 버퍼 (Senior 다운로드 후 삭제)
///   - `families/{fid}/thumbs/{photoId}.jpg` — 썸네일 영구 저장 (photoSync 삭제 시 삭제)
class PhotoTransferService {
  /// Firebase RTDB 싱글턴 인스턴스
  final FirebaseDatabase _db = FirebaseDatabase.instance;

  /// Firebase Storage 싱글턴 인스턴스
  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Firebase Auth 싱글턴 인스턴스
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ─── 업로드 ───

  /// 사진 업로드: 리사이즈 + 압축 + 썸네일 + Storage + RTDB (`Method`, async)
  ///
  /// 전체 과정: 이미지 압축 → MD5 체크섬 → Storage 원본 업로드 → Storage 썸네일 업로드
  /// → RTDB 메타데이터 등록 (status: pending).
  ///
  /// 파일명 형식: `photo_{creatorName}_{yyyyMMdd_HHmmss}.jpg`
  /// 진행률: 원본 업로드 80% + 썸네일 업로드 20% 비율로 콜백.
  ///
  /// - **Params**:
  ///   - [familyId] — 대상 가족 그룹 ID
  ///   - [imageFile] — 업로드할 원본 이미지 파일
  ///   - [onProgress] — 진행률 콜백 (0.0 ~ 1.0)
  /// - **Returns**: `String` — 생성된 photoId (RTDB push key)
  /// - **Side Effects**:
  ///   - Storage `families/{fid}/temp/{fileName}` 에 압축 원본 업로드
  ///   - Storage `families/{fid}/thumbs/{photoId}.jpg` 에 썸네일 업로드
  ///   - RTDB `/families/{fid}/photoSync/{photoId}` 에 메타데이터 기록
  /// - **호출**: photo_upload_screen.dart의 업로드 버튼
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

    // 2. 썸네일 생성 (400×400, JPEG 80%, ~100KB) → Storage 영구 저장
    final thumbBytes = await FlutterImageCompress.compressWithFile(
      imageFile.absolute.path,
      minWidth: 400,
      minHeight: 400,
      quality: 80,
      format: CompressFormat.jpeg,
    );
    if (thumbBytes == null) throw Exception('썸네일 생성 실패');

    // 3. MD5 체크섬
    final checksum = md5.convert(compressed).toString();

    // 4. 원본 Storage 업로드 (임시 버퍼)
    final storagePath = 'families/$familyId/temp/$fileName';
    final ref = _storage.ref(storagePath);
    final uploadTask = ref.putData(
      Uint8List.fromList(compressed),
      SettableMetadata(contentType: 'image/jpeg'),
    );

    uploadTask.snapshotEvents.listen((snapshot) {
      if (snapshot.totalBytes > 0) {
        final progress = snapshot.bytesTransferred / snapshot.totalBytes;
        onProgress?.call(progress * 0.8); // 원본 업로드 80%까지
      }
    });

    await uploadTask;
    final downloadUrl = await ref.getDownloadURL();
    print('Storage 원본 업로드 완료: $storagePath');

    // 5. 썸네일 Storage 업로드 (영구 저장)
    final thumbPath = 'families/$familyId/thumbs/$photoId.jpg';
    final thumbRef = _storage.ref(thumbPath);
    await thumbRef.putData(
      Uint8List.fromList(thumbBytes),
      SettableMetadata(contentType: 'image/jpeg'),
    );
    final thumbUrl = await thumbRef.getDownloadURL();
    onProgress?.call(1.0);
    print('Storage 썸네일 업로드 완료: $thumbPath (${thumbBytes.length} bytes)');

    // 6. RTDB 메타데이터 등록
    final uploadedByName = user.displayName ?? '가족';
    final label = '$fileName (pending, $uploadedByName)';
    await _db.ref('families/$familyId/photoSync/$photoId').set({
      '_label': label,
      'fileName': fileName,
      'size': compressed.length,
      'checksum': checksum,
      'storageUrl': downloadUrl,
      'storagePath': storagePath,
      'thumbUrl': thumbUrl,
      'thumbPath': thumbPath,
      'uploadedBy': user.uid,
      'uploadedByName': uploadedByName,
      'createdAt': ServerValue.timestamp,
      'status': 'pending',
      'retryCount': 0,
    });
    print('RTDB 메타 등록: photoSync/$photoId status=pending, thumbUrl=$thumbUrl');

    return photoId;
  }

  // ─── 삭제 ───

  /// 사진 삭제: RTDB 노드 즉시 제거 (`Method`, async)
  ///
  /// RTDB `photoSync/{photoId}` 노드를 remove()하면:
  /// - Senior: onValue 전체 스냅샷 reconcile로 로컬 파일 삭제
  /// - Cloud Function(`onPhotoDeleted`): thumbPath의 Storage 썸네일 삭제
  /// - 원본 Storage 파일은 이미 `onPhotoDownloaded`에서 삭제된 상태 (또는 cleanupExpiredPhotos)
  ///
  /// - **Params**:
  ///   - [familyId] — 대상 가족 그룹 ID
  ///   - [photoId] — 삭제할 사진 ID (RTDB push key)
  /// - **Side Effects**: RTDB `/families/{fid}/photoSync/{photoId}` 노드 삭제
  /// - **호출**: photo_upload_screen.dart의 사진 삭제 버튼
  Future<void> deletePhoto(String familyId, String photoId) async {
    await _db.ref('families/$familyId/photoSync/$photoId').remove();
    print('사진 삭제: $photoId RTDB 노드 제거');
  }

  // ─── 실시간 감시 ───

  /// photoSync 전체 스트림 감시 (`Stream`)
  ///
  /// onValue로 `/families/{fid}/photoSync` 전체 스냅샷을 구독한다.
  /// `setPersistenceEnabled(true)` 상태에서 delta sync로 실제 네트워크 전송은 변경분만.
  ///
  /// - **Params**:
  ///   - [familyId] — 감시 대상 가족 그룹 ID
  /// - **Returns**: `Stream<DatabaseEvent>` — photoSync 전체 스냅샷 변경 이벤트
  /// - **호출**: photo_upload_screen.dart에서 사진 목록 실시간 갱신
  Stream<DatabaseEvent> watchPhotoSync(String familyId) =>
      _db.ref('families/$familyId/photoSync').onValue;
}
