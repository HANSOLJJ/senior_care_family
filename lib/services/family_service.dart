import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

/// 가족 그룹 관리 서비스
class FamilyService {
  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// 페어링 코드로 가족 그룹 참가
  /// [pairingCode] 시니어 기기에 표시된 6자리 코드
  Future<String> joinFamily(String pairingCode) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('로그인 필요');

    final code = pairingCode.trim().toUpperCase();

    // 1. 코드로 familyId 조회
    final codeSnap = await _db.ref('pairingCodes/$code').get();
    if (!codeSnap.exists) {
      throw Exception('유효하지 않은 페어링 코드입니다');
    }
    final familyId = codeSnap.value as String;

    // 2. 가족 그룹 존재 확인
    final familySnap = await _db.ref('families/$familyId').get();
    if (!familySnap.exists) {
      throw Exception('가족 그룹을 찾을 수 없습니다');
    }

    // 3. 멤버로 등록
    await _db.ref('families/$familyId/members/${user.uid}').set({
      'name': user.displayName ?? '가족',
      'role': 'family',
      'joinedAt': ServerValue.timestamp,
    });

    // 4. 사용자 프로필에 familyId 추가
    await _db.ref('users/${user.uid}/familyIds/$familyId').set(true);

    print('가족 그룹 참가 완료: $familyId');
    return familyId;
  }

  /// 현재 사용자의 가족 그룹 ID 목록
  Future<List<String>> getMyFamilyIds() async {
    final user = _auth.currentUser;
    if (user == null) return [];

    final snap = await _db.ref('users/${user.uid}/familyIds').get();
    if (!snap.exists) return [];

    final data = snap.value as Map;
    return data.keys.cast<String>().toList();
  }

  /// 가족 그룹의 기기 목록 (실시간 스트림)
  Stream<DatabaseEvent> watchFamilyDevices(String familyId) {
    return _db.ref('families/$familyId/devices').onValue;
  }

  /// 가족 그룹의 멤버 목록
  Future<List<Map<String, dynamic>>> getFamilyMembers(String familyId) async {
    final snap = await _db.ref('families/$familyId/members').get();
    if (!snap.exists) return [];

    final data = Map<String, dynamic>.from(snap.value as Map);
    return data.entries.map((e) {
      final info = Map<String, dynamic>.from(e.value as Map);
      info['uid'] = e.key;
      return info;
    }).toList();
  }

  /// 현재 사용자의 멤버십 실시간 감시 (제거 감지용)
  Stream<DatabaseEvent> watchMyMembership(String familyId) {
    final uid = _auth.currentUser!.uid;
    return _db.ref('families/$familyId/members/$uid').onValue;
  }

  /// 가족 그룹 탈퇴
  Future<void> leaveFamily(String familyId) async {
    final user = _auth.currentUser;
    if (user == null) return;

    await _db.ref('families/$familyId/members/${user.uid}').remove();
    await _db.ref('users/${user.uid}/familyIds/$familyId').remove();
    print('가족 그룹 탈퇴: $familyId');
  }
}
