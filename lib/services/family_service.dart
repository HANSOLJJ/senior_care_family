import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'firebase_instances_mixin.dart';
import 'network_guard.dart';

/// 가족 그룹 관리 서비스 (`Service`) — 페어링·멤버·그룹 이름 CRUD
///
/// RTDB 경로:
///   - `/pairingCodes/{code}` → familyId (Senior가 생성하는 6자리 영숫자 코드)
///   - `/families/{familyId}/members/{uid}` → {name, role, provider, ...}
///   - `/families/{familyId}/_label` → Console 가독성용 라벨
///   - `/users/{uid}/familyIds/{familyId}` → true (사용자별 가족 목록)
///   - `/users/{uid}/familyNames/{familyId}` → "부모님" 등 사용자 지정 라벨
///
/// 주요 흐름:
///   1. [joinFamily] — 6자리 페어링 코드로 가족 그룹 참가
///   2. [leaveFamily] — 가족 그룹 탈퇴 (멤버 + familyIds + familyNames 삭제)
///   3. [watchMyMembership] — Senior에서 멤버 삭제 시 실시간 감지 (강퇴 대응)
///   4. [setFamilyName] / [getFamilyNames] — 가족 그룹 사용자 지정 라벨 관리
class FamilyService with FirebaseInstancesMixin {

  // ─── 페어링 ───

  /// 페어링 코드로 가족 그룹에 참가 (`Method`, async)
  ///
  /// Senior 태블릿에 표시된 6자리 코드를 입력받아 가족 그룹에 멤버로 등록한다.
  /// 코드 → familyId 조회 → 그룹 존재 확인 → 멤버 등록 → 사용자 프로필 갱신 → _label 갱신.
  ///
  /// - **Params**:
  ///   - [pairingCode] — 시니어 기기에 표시된 6자리 영숫자 코드
  /// - **Returns**: `String` — 참가한 familyId
  /// - **Side Effects**:
  ///   - RTDB `/families/{fid}/members/{uid}` 에 멤버 정보 기록
  ///   - RTDB `/users/{uid}/familyIds/{fid}` 에 true 기록
  ///   - RTDB `/families/{fid}/_label` 업데이트
  /// - **호출**: pairing_screen.dart의 코드 입력 확인 버튼, device_list_screen.dart의 _addFamily()
  Future<String> joinFamily(String pairingCode) async {
    final user = auth.currentUser;
    if (user == null) throw Exception('로그인 필요');

    final code = pairingCode.trim().toUpperCase();

    // 1. 코드로 familyId 조회
    final codeSnap = await db.ref('pairingCodes/$code').get();
    if (!codeSnap.exists) {
      throw Exception('유효하지 않은 페어링 코드입니다');
    }
    final familyId = codeSnap.value as String;

    // 2. 가족 그룹 존재 확인
    final familySnap = await db.ref('families/$familyId').get();
    if (!familySnap.exists) {
      throw Exception('가족 그룹을 찾을 수 없습니다');
    }

    // 3. 멤버로 등록
    final name = (user.displayName?.isNotEmpty == true) ? user.displayName! : '가족';
    final provider = _getProvider(user);
    final memberRef = db.ref('families/$familyId/members/${user.uid}');
    await writeOrTimeout(
      () => memberRef.set({
        'name': name,
        'role': 'family',
        'provider': provider,
        'photoUrl': user.photoURL ?? '',
        'joinedAt': ServerValue.timestamp,
      }),
      label: '가족 참가',
      onTimeoutCleanup: () => memberRef.remove(),
    );

    // 4. 사용자 프로필에 familyId 추가
    await db.ref('users/${user.uid}/familyIds/$familyId').set(true);

    // 5. 가족 _label 업데이트 (멤버 이름 포함)
    final devicesSnap = await db.ref('families/$familyId/devices').get();
    final deviceIds = (devicesSnap.value as Map?)?.keys;
    String seniorName = '';
    if (deviceIds != null && deviceIds.isNotEmpty) {
      final did = deviceIds.first;
      final deviceSnap = await db.ref('devices/$did/name').get();
      seniorName = (deviceSnap.value as String?) ?? '';
    }
    final familyLabel = seniorName.isNotEmpty
        ? '$name의 가족 ($seniorName)'
        : '$name의 가족';
    await db.ref('families/$familyId/_label').set(familyLabel);

    print('가족 그룹 참가 완료: $familyId');
    return familyId;
  }

  // ─── 조회 ───

  /// 현재 사용자의 가족 그룹 ID 목록 조회 (`Method`, async)
  ///
  /// `/users/{uid}/familyIds` 노드에서 키 목록을 가져온다.
  ///
  /// - **Returns**: `List<String>` — familyId 리스트 (비로그인이면 빈 리스트)
  /// - **호출**: app.dart의 PairingGate, device_list_screen.dart 초기화
  Future<List<String>> getMyFamilyIds() async {
    final user = auth.currentUser;
    if (user == null) return [];

    final snap = await db.ref('users/${user.uid}/familyIds').get();
    if (!snap.exists) return [];

    final data = snap.value as Map;
    return data.keys.cast<String>().toList();
  }

  /// 가족 그룹의 멤버 목록 조회 (`Method`, async)
  ///
  /// `/families/{familyId}/members` 노드를 읽어 각 멤버 정보에 uid를 추가하여 반환.
  ///
  /// - **Params**:
  ///   - [familyId] — 조회 대상 가족 그룹 ID
  /// - **Returns**: `List<Map<String, dynamic>>` — 멤버 정보 리스트 (uid 포함)
  /// - **호출**: family_detail_screen.dart 멤버 목록 표시
  Future<List<Map<String, dynamic>>> getFamilyMembers(String familyId) async {
    final snap = await db.ref('families/$familyId/members').get();
    if (!snap.exists) return [];

    final data = Map<String, dynamic>.from(snap.value as Map);
    return data.entries.map((e) {
      final info = Map<String, dynamic>.from(e.value as Map);
      info['uid'] = e.key;
      return info;
    }).toList();
  }

  // ─── 실시간 감시 ───

  /// 현재 사용자의 멤버십 실시간 감시 (`Stream`)
  ///
  /// Senior 앱에서 멤버를 제거(강퇴)하면 이 스트림으로 감지하여
  /// Family 앱이 자동으로 가족 목록에서 해당 그룹을 제거할 수 있다.
  ///
  /// - **Params**:
  ///   - [familyId] — 감시 대상 가족 그룹 ID
  /// - **Returns**: `Stream<DatabaseEvent>` — 멤버 노드 변경 이벤트
  /// - **호출**: device_list_screen.dart에서 구독하여 강퇴 감지
  Stream<DatabaseEvent> watchMyMembership(String familyId) {
    final uid = auth.currentUser!.uid;
    return db.ref('families/$familyId/members/$uid').onValue;
  }

  // ─── 가족 이름 관리 ───

  /// 가족 그룹 사용자 지정 이름 설정 (`Method`, async)
  ///
  /// 사용자가 가족 그룹에 "부모님", "장인어른" 등 자신만의 라벨을 지정한다.
  /// 다른 가족 멤버에게는 보이지 않는 개인 설정.
  ///
  /// - **Params**:
  ///   - [familyId] — 대상 가족 그룹 ID
  ///   - [name] — 사용자 지정 이름 (예: "부모님")
  /// - **Side Effects**: RTDB `/users/{uid}/familyNames/{fid}` 에 이름 기록
  /// - **호출**: pairing_helper.dart의 _promptFamilyName()
  Future<void> setFamilyName(String familyId, String name) async {
    final user = auth.currentUser;
    if (user == null) return;
    await db.ref('users/${user.uid}/familyNames/$familyId').set(name);
  }

  /// 가족 그룹 이름 목록 조회 (`Method`, async)
  ///
  /// `/users/{uid}/familyNames` 전체를 읽어 familyId → 이름 맵 반환.
  ///
  /// - **Returns**: `Map<String, String>` — {familyId: 사용자 지정 이름}
  /// - **호출**: device_list_screen.dart에서 가족 목록 표시 시
  Future<Map<String, String>> getFamilyNames() async {
    final user = auth.currentUser;
    if (user == null) return {};
    final snap = await db.ref('users/${user.uid}/familyNames').get();
    if (!snap.exists) return {};
    final data = Map<String, dynamic>.from(snap.value as Map);
    return data.map((k, v) => MapEntry(k, v.toString()));
  }

  // ─── 헬퍼 ───

  /// Firebase Auth 사용자의 로그인 provider 문자열 추출 (`Utility`)
  ///
  /// 카카오/네이버는 uid 접두사로 판별, Google/Apple은 providerData로 판별.
  ///
  /// - **Params**:
  ///   - [user] — Firebase Auth User 객체
  /// - **Returns**: `String` — 'kakao' | 'naver' | 'apple' | 'google' | 'unknown'
  String _getProvider(User user) {
    if (user.uid.startsWith('kakao:')) return 'kakao';
    if (user.uid.startsWith('naver:')) return 'naver';
    for (final info in user.providerData) {
      if (info.providerId == 'apple.com') return 'apple';
      if (info.providerId == 'google.com') return 'google';
    }
    return 'unknown';
  }

  // ─── 탈퇴 ───

  /// 가족 그룹 탈퇴 (`Method`, async)
  ///
  /// 멤버 노드, familyIds, familyNames 세 군데를 모두 삭제한다.
  /// 가족 그룹 자체는 삭제하지 않음 (다른 멤버 + Senior 기기가 남아있을 수 있음).
  ///
  /// - **Params**:
  ///   - [familyId] — 탈퇴할 가족 그룹 ID
  /// - **Side Effects**:
  ///   - RTDB `/families/{fid}/members/{uid}` 삭제
  ///   - RTDB `/users/{uid}/familyIds/{fid}` 삭제
  ///   - RTDB `/users/{uid}/familyNames/{fid}` 삭제
  /// - **호출**: device_list_screen.dart 가족 그룹 탈퇴 메뉴
  Future<void> leaveFamily(String familyId) async {
    final user = auth.currentUser;
    if (user == null) return;

    await db.ref('families/$familyId/members/${user.uid}').remove();
    await db.ref('users/${user.uid}/familyIds/$familyId').remove();
    await db.ref('users/${user.uid}/familyNames/$familyId').remove();
    print('가족 그룹 탈퇴: $familyId');
  }
}
