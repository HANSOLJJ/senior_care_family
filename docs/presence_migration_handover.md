# Presence 판정 마이그레이션 — Connection List 패턴

> 작성: Senior 팀 → Family 팀 인수인계
> 관련 PR: Senior `DeviceRegistration` Connection List 도입
> 스키마 v4 (참조: [RTDB_schema.md](RTDB_schema.md))
>
> **상태: 마이그레이션 완료 (2026-04-15)**
> - Family 앱: `connections.hasChildren()` 기반 판정으로 전환 완료
> - Senior 앱: `online` 필드 쓰기 제거 완료
> - Cloud Function `cleanupOrphanedData`: orphan 조건을 `!hasConnections` 단독으로 단순화 완료
> - `online` 필드는 RTDB 스키마에서 제거됨
>
> 이 문서는 향후 참고용으로 보존. 배경/race 원리는 유효.

## TL;DR

Senior 기기 **온라인 판정 로직**을 `/devices/{did}/online: boolean` 읽기에서
`/devices/{did}/connections`의 `hasChildren()` 읽기로 바꿔야 합니다.

기존 방식은 Firebase `onDisconnect` race로 **살아있는 기기가 `online=false`로 고정**되는 버그가 실제로 관측되어 해결된 건입니다.

---

## 배경 — 왜 바꿔야 하나

### 실제 관측된 버그

Senior 기기 power reset 후 RTDB 직접 조회 결과:

```json
{
  "online": false,
  "lastSeen": 1776223778701,
  ...
}
```

기기는 **살아있고 WiFi 연결 정상**인데 Family UI에서 offline으로 표시.

### 원인 — onDisconnect race

단일 `online: boolean` + `onDisconnect().setValue(false)` 구조에서:

| 시각 | 이벤트 |
|---|---|
| T0 | 세션 A register → `online=true`, 서버에 onDisconnect(A) 예약 |
| T0+N | power reset. TCP 소켓 FIN 못 보냄 → 서버는 세션 A 아직 살아있다고 인지 |
| T0+N+M | 재부팅 완료, 세션 B register → `online=true` 새로 씀 + onDisconnect(B) 예약 |
| T0+N+M+K | **서버가 드디어 세션 A TCP dead 감지 (keepalive ~30–90초)** → **onDisconnect(A) 발화 → `online=false`** |
| 이후 | `.info/connected` 이벤트 없음 → false 고정 |

실제 로그에서 세션 B register 49초 뒤에 정확히 onDisconnect(A)가 발화한 타임스탬프 확인됨.

### 해결책 — Connection List 패턴

단일 boolean 대신 세션별 child 노드:

```
/devices/{did}/connections/{sessionId}: true
```

- `onDisconnect().removeValue()` → **자기 child만 제거** → 타 세션 간섭 불가
- 상태 판정: `hasChildren()` → 자식 1개라도 있으면 online

이제 세션 A ghost onDisconnect가 발화해도 `connections/{sessionIdA}`만 지움. `connections/{sessionIdB}`는 그대로. `hasChildren() == true` 유지 → **정확한 online 판정**.

---

## 스키마 변경점

```
/devices/{deviceId}/
  ├── online: boolean         ← DEPRECATED (backward compat로 Senior가 계속 씀, 신뢰 불가)
  ├── lastSeen: timestamp     ← 기존 그대로
  ├── connections/            ← 신규
  │   └── {sessionId}: true   ← Senior가 register 시 UUID 생성. onDisconnect().removeValue()
  ├── ...
```

- Senior는 **과도기 동안 둘 다 씀** (`connections/{sessionId}` + 기존 `online`)
- Family가 connections 기반으로 완전 전환되면, 별도 PR에서 Senior `online` 필드 쓰기 제거 + DEPRECATED 표기 삭제

---

## Dart 구현 가이드

### 1. 기존 `online` 읽는 코드 찾기

```bash
cd E:/App/Family/lib
grep -rn "'online'" . | grep -v test
# 또는
grep -rn "\.child('online')" .
```

후보 예시 (실제 경로는 Family 코드에 따라 다름):
- `lib/services/device_service.dart`
- `lib/screens/home/device_card.dart`
- `lib/state/family_provider.dart`

### 2. 기존 코드 패턴

```dart
// BEFORE
final online = (snapshot.child('online').value as bool?) ?? false;
```

### 3. 신규 판정 코드

```dart
// AFTER
final connSnap = snapshot.child('connections');
final isOnline = connSnap.exists && connSnap.children.isNotEmpty;
```

- `connections` 노드 자체가 없으면 → offline (최초 register 전)
- 자식 수 0 → offline (onDisconnect로 전부 제거된 상태)
- 자식 수 ≥ 1 → online

### 4. listener 부착 (ValueEventListener)

`/devices/{did}` 전체를 이미 구독 중이면 추가 작업 없음 — snapshot에 `connections` 포함됨. `children.isNotEmpty` 호출만 추가.

`/devices/{did}/online` 를 개별 구독 중이었다면 → `/devices/{did}/connections` 로 경로 변경.

```dart
// 개별 구독 예시
FirebaseDatabase.instance
    .ref('devices/$deviceId/connections')
    .onValue
    .listen((event) {
  final isOnline =
      event.snapshot.exists && event.snapshot.children.isNotEmpty;
  // UI 업데이트
});
```

### 5. `lastSeen` 기반 보조 라벨 (선택)

"5분 전 접속" 같은 UX 라벨이 필요하면:

```dart
final lastSeen = snapshot.child('lastSeen').value as int?;
final ageMin = lastSeen != null
    ? (DateTime.now().millisecondsSinceEpoch - lastSeen) ~/ 60000
    : null;
final lastSeenText = switch (ageMin) {
  null => '접속 기록 없음',
  < 1 => '방금 전',
  < 60 => '$ageMin분 전',
  _ => '${ageMin ~/ 60}시간 전',
};
```

### 6. UI 반영

기존 online 인디케이터(아이콘 색상, 상태 텍스트) 로직을 그대로 쓰되 `isOnline` 값만 교체:

```dart
Icon(
  Icons.circle,
  color: isOnline ? Colors.green : Colors.grey,
  size: 12,
)
```

---

## (선택) 점진적 롤아웃 — Feature Flag

한 번에 전체 교체가 부담스러우면:

```dart
class FeatureFlags {
  static const useConnectionList = true; // 기본 on, 긴급 롤백 대비
}

final isOnline = FeatureFlags.useConnectionList
    ? (connSnap.exists && connSnap.children.isNotEmpty)
    : ((snapshot.child('online').value as bool?) ?? false);
```

롤아웃 절차:
1. flag false로 배포 → 기존 동작 유지
2. 사내 기기에서 flag true 켜서 검증
3. 전체 사용자 flag true 롤아웃
4. 안정 확인 후 flag 및 `online` 필드 의존 코드 완전 제거

---

## 테스트 시나리오

### 시나리오 1 — 정상 부팅

1. Senior 앱 실행
2. Family 앱에서 해당 Senior 기기 카드 확인 → **온라인 표시**
3. RTDB 콘솔: `/devices/{did}/connections/<uuid>: true` 존재

### 시나리오 2 — 재부팅 race 재현 (핵심)

1. Senior power reset (전원 차단 → 재부팅)
2. 부팅 완료 후 1분 대기
3. Family 앱에서 해당 기기 **온라인 유지** ✅
4. (이전 구현이라면 이 시점에 `online=false`로 고정되어 offline 표시됐을 케이스)
5. RTDB 콘솔 관찰:
   - 부팅 직후: `connections`에 새 sessionId entry
   - ~1분 뒤: 이전 세션 ghost sessionId는 서버가 제거, 신규 sessionId만 남음
   - Family UI는 줄곧 online

### 시나리오 3 — 정상 종료

1. Senior 앱 unregister 호출 (앱 명시적 종료 플로우)
2. 수 초 내 Family UI **오프라인 전환**
3. RTDB: `/devices/{did}/connections` 비어있음 (또는 경로 자체 삭제)

### 시나리오 4 — 앱 크래시

1. Senior 앱 강제 종료 (process kill)
2. Firebase TCP keepalive timeout (30–90초)
3. Family UI 오프라인 전환
4. RTDB: `connections/{sessionId}` 자동 제거됨 (onDisconnect)

---

## 이후 정리 (완료)

Family가 connections 기반으로 완전 전환된 후 동일 배포에서 진행:

1. ✅ Senior `DeviceRegistration`에서 `online` 필드 쓰기/onDisconnect 제거
2. ✅ Cloud Function `cleanupOrphanedData` 조건 단순화:
   - 이전: `!online && lastSeen 7일`
   - 현재: `!hasConnections && lastSeen 7일`
3. ✅ `RTDB_schema.md`에서 `online` 필드 완전 삭제

---

## 참고

- [RTDB_schema.md](RTDB_schema.md) — 현재 스키마 (v4)
- [Firebase 공식 — Enabling Offline Capabilities > onDisconnect](https://firebase.google.com/docs/database/android/offline-capabilities#section-on-disconnect)
- Senior 측 구현: `E:/App/Senior/app/src/main/java/com/seniorcare/senior/firebase/DeviceRegistration.kt`
- Cloud Function 수정: `E:/App/Family/functions/index.js` `doOrphanCleanup()`
