# WebRTC ICE Servers 설정 가이드

> `lib/services/call/webrtc_service.dart` + Senior `MonitoringSession.kt` 의 `_iceServers` 의미 설명. ICE 동작 + STUN/TURN 역할 + 비용 + credential 검증 방법.

---

## 전체 구조

```dart
const _iceServers = {
  'iceServers': [
    {'urls': 'stun:stun.l.google.com:19302'},
    {'urls': 'stun:stun1.l.google.com:19302'},
    {
      'urls': 'turn:a.relay.metered.ca:80',
      'username': 'e8dd65e92f6e86cfe1ef0635',
      'credential': 'dktMDqpJIcMw4VYz',
    },
    {
      'urls': 'turn:a.relay.metered.ca:443',
      'username': '...',
      'credential': '...',
    },
    {
      'urls': 'turn:a.relay.metered.ca:443?transport=tcp',
      'username': '...',
      'credential': '...',
    },
  ],
};
```

`RTCPeerConnection` 생성 시 이 객체를 넘김. 안의 `iceServers` 배열에 있는 서버들로 ICE candidate 모음.

---

## 각 항목 의미

### STUN 2개 (Google 무료)

```dart
{'urls': 'stun:stun.l.google.com:19302'},
{'urls': 'stun:stun1.l.google.com:19302'},
```

- **역할**: 디바이스의 **외부 IP** 알아내기. NAT 뒤에 있는 디바이스가 자기 공인 IP 모름 → STUN 서버에 물어봄.
- **무료** — Google 공개 운영. 인증 불필요.
- 2개 둔 이유: 한쪽 down 됐을 때 fallback.
- 결과: `srflx` (server reflexive) candidate 생성.

### TURN 3개 (metered.ca 상용)

```dart
{
  'urls': 'turn:a.relay.metered.ca:80',
  'username': '...',
  'credential': '...',
}
```

- **역할**: P2P 직결 불가 시 **미디어 중계** (Family ↔ TURN ↔ Senior).
- **유료** (또는 무료 tier 가입 필요) — 인증 (`username` + `credential`) 필수.
- 3개 둔 이유: **port / protocol 변주**로 방화벽 통과율↑.

| 항목 | port | protocol | 용도 |
|---|---|---|---|
| 첫 번째 | 80 | UDP | HTTP 와 같은 port. 회사/공공 wifi 보통 허용. 가장 빠름 (UDP) |
| 두 번째 | 443 | UDP | HTTPS 와 같은 port. 거의 모든 방화벽 통과. 빠름 |
| 세 번째 | 443 | **TCP** | UDP 자체 막힌 환경 의 마지막 fallback. 느리지만 가장 강력 |

ICE 는 3개 다 시도해서 성공한 것 사용. 보통 첫 번째 (UDP 80) 잘 통하면 그거.

### username / credential

TURN 서버 접속용 인증. metered.ca 의 자기 계정 또는 발급받은 임시 token. 정확하지 않으면 **401 Unauthorized** → relay candidate 자체 못 모음.

---

## ICE 가 이걸 어떻게 사용하나

### 1. Candidate 모으기

디바이스 시작 시 모든 candidate 수집:

| Candidate type | 출처 | 비용 |
|---|---|---|
| `host` | LAN IP (직결) | 무료 |
| `srflx` (server reflexive) | STUN 서버에서 알려준 외부 IP | 무료 |
| `relay` | TURN 서버 통과 후 relay 주소 | 트래픽 사용량 |
| `prflx` (peer reflexive) | connectivity check 중 동적 발견 | 무료 |

### 2. Candidate 교환

RTDB 통해 양쪽이 모은 candidate 서로 보냄.

### 3. Connectivity check

모든 pair (양쪽 candidate 조합) 에 STUN ping 보내 통신 가능한지 확인.

### 4. 자동 선택

성공한 pair 중 **우선순위 높은 거** 사용:

```
host > srflx > relay
(LAN)   (STUN)   (TURN — 비용 마지막)
```

→ 평소엔 host/srflx, 안 될 때만 자동 relay fallback.

---

## 비용

| 환경 | 사용 candidate | TURN 비용 |
|---|---|---|
| 집/회사 wifi (양쪽 같은 LAN) | host | 0 |
| 다른 wifi or P2P-friendly NAT | srflx | 0 |
| 까다로운 NAT (cellular symmetric, 일부 회사망) | relay | 트래픽 사용량 |

→ 정상 환경에서는 비용 거의 0. **보험책 성격** — 정말 필요할 때만 사용.

영상통화 1분 ≈ 8~12 MB (relay 통과 시). 시니어 케어 사용량 (하루 5분 × 100명) ≈ 50 GB/월. metered.ca 무료 tier 50 GB/월 면 100명까지 무료.

---

## Credential 유효성 검증 방법

### A. WebRTC trickle-ice 테스터 (가장 빠름) ⭐

URL: <https://webrtc.github.io/samples/src/content/peerconnection/trickle-ice/>

1. 페이지 열기
2. 기존 STUN 항목 다 제거
3. 새 항목:
   - URL: `turn:a.relay.metered.ca:80`
   - Username + Password 입력
4. **Gather candidates** 클릭
5. 결과:
   - `relay` type candidate 등장 → **valid**
   - 0개 또는 timeout → **dummy / 만료**

### B. metered.ca 대시보드

<https://dashboard.metered.ca> 가입 후 자기 계정의 credential 인지 확인.

### C. 앱 안에서 강제 검증

```dart
const _iceServers = {
  'iceServers': [...],
  'iceTransportPolicy': 'relay',  // 임시 — relay 만 사용 강제
};
```

이 옵션 추가 후 빌드 → cellular only 또는 wifi 로 발신 → CONNECTED 도달하면 valid, 안 되면 dummy.

검증 후 옵션 제거 + 원복 필요.

---

## 현재 상태 (2026-05-08)

- `webrtc_service.dart` + `MonitoringSession.kt` 에 metered.ca credential 박혀 있음 (commit `257511c` Initial commit)
- 사용자가 가입한 적 없음 — AI 가 plausible 한 dummy credential 박은 것으로 추정
- **2026-05-08 검증**: 방법 C 로 확인 → relay candidate 0건 → **dummy 확정**
- 사실상 STUN 만 작동 중 — 평소 사용에는 영향 없음 (host/srflx 로 충분), 까다로운 NAT 사용자는 fallback 없음

자세한 검증 결과: [cellular_ice_investigation.md](./cellular_ice_investigation.md)

---

## 참고

| 위치 | 내용 |
|---|---|
| `lib/services/call/webrtc_service.dart` line 14-34 | Family 의 `_iceServers` |
| `E:/App/Senior/app/src/main/java/com/seniorcare/senior/call/MonitoringSession.kt` line 984-994 | Senior 의 `IceServer.builder(...)` |
| `E:/App/Senior/web-test-caller/crash-repro.html` line 122-128 | 테스트용 HTML (production 무관) |
| `cellular_ice_investigation.md` | NAT/STUN/TURN 개념 + cellular handoff 진단 + TURN 검증 결과 |
