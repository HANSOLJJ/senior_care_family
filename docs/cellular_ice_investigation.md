# Cellular handoff + ICE 제약 진단

> 발견 일자: 2026-05-07
> 디바이스: Galaxy A17 (RFKYA00Y49L) cellular 환경
> 결론: cellular **fresh start 는 정상 작동**. wifi → cellular **handoff 중에만** 영상 검은 화면 발생 — Senior 측 stale ICE state + libwebrtc handoff 동작 의심. **TURN relay 서버로 우회 가능** (handoff 시 relay path 강제).

---

## 1. 배경 개념 — NAT / STUN / TURN / ICE

### 1.1 NAT (Network Address Translation) 가 뭔가?

집/회사 wifi 라우터, 통신사 cellular 망 모두 **공인 IP 부족** + **보안** 이유로 NAT 사용.

```text
[디바이스 192.168.1.10]  →  [라우터 NAT]  →  [공인 IP 1.2.3.4]  →  인터넷
```

문제: 인터넷 쪽에서 디바이스로 직접 연결 불가 (router 가 막음). 디바이스가 먼저 outbound 시작해야 router 가 응답 받을 길 (NAT mapping) 을 열어줌.

### 1.2 NAT 종류 (가장 중요)

| 종류 | 설명 | P2P 가능? |
|---|---|---|
| **Full-cone** | 한 번 outbound 보내면 어떤 외부 IP/port 에서 와도 받음 | ✅ 쉬움 |
| **Address-restricted** | outbound 보냈던 IP 쪽에서만 받음 (port 무관) | ✅ 가능 |
| **Port-restricted** | outbound 보냈던 IP+port 쪽에서만 받음 | ⚠ 까다로움 |
| **Symmetric** | 같은 디바이스가 다른 destination 에 보낼 때마다 다른 외부 port 사용 | ❌ **P2P 불가** |

**Cellular 통신사 NAT 는 대부분 symmetric** — 보안 + 자원 절약. 이게 본 검증의 핵심 문제.

### 1.3 STUN (Session Traversal Utilities for NAT)

**역할**: 디바이스가 자기 외부 IP 알아내기.

```text
[디바이스]  →  STUN 서버 (예: stun.l.google.com:19302)
              "내 외부 IP 뭐임?"
            ←  "1.2.3.4:5678 이야"
```

WebRTC 가 ICE candidate 모을 때 STUN 사용:
- `host` candidate: 디바이스 LAN IP (예: 192.168.1.10)
- `srflx` (server reflexive) candidate: STUN 으로 알아낸 외부 IP (예: 1.2.3.4:5678)

**STUN 한계**: symmetric NAT 에선 srflx candidate 가 의미 없음. 외부에서 그 IP+port 로 보내도 NAT 가 다른 매핑 만들어 들어옴 → 매칭 안 됨.

### 1.4 TURN (Traversal Using Relays around NAT)

**역할**: P2P 안 될 때 **relay 서버** 통해 미디어 전달.

```text
[Family]  →  [TURN 서버]  →  [Senior]
       ↑       ↑                ↑
       relay candidate
```

TURN 사용 시:
- `relay` candidate 추가 (TURN 서버 주소)
- ICE 가 P2P (host/srflx) 시도 실패 시 relay 사용
- 보장: 인터넷 닿기만 하면 영상통화 됨

**비용**: TURN 서버는 모든 미디어 (영상/음성) 가 통과 → 대역폭 + CPU 부담. 사용자당 수백 KB/s ~ 수 Mbps. 자체 운영 시 서버 비용, 외부 서비스 (Twilio/Xirsys) 시 사용량 과금.

### 1.5 ICE (Interactive Connectivity Establishment)

**역할**: 위의 모든 candidate (host/srflx/relay) 모아서 **best path 선택**.

ICE 흐름:
1. 양쪽이 candidate 모음 (host + srflx + relay)
2. RTDB 시그널링 통해 서로 candidate 교환
3. **Connectivity check**: 모든 candidate pair 에 STUN ping 보내 통신 가능한 pair 찾음
4. 성공한 pair 중 우선순위 높은 거 선택 (host > srflx > relay — relay 는 비용 때문에 마지막)
5. 선택한 pair 로 미디어 흐름

ICE 가 어떤 pair 도 성공 못하면 → connection 실패 → 검은 화면.

---

## 2. 본 검증 케이스 — A17 Cellular Handoff

### 2.1 환경

- **Family A17**: Galaxy A17 (RFKYA00Y49L), Android, MediaTek 칩셋, **국내 통신사 cellular 활성**
- **Senior KEP**: M10VSA2 태블릿, wifi only
- **WebRTC config**: STUN 만 사용, **TURN 미설정** (현재 production 도 동일)

### 2.2 시나리오

1. A17 wifi on → 모니터링 시작 → **정상 (영상 보임)**
2. A17 wifi off → cellular fallback → ICE restart → PC=CONNECTED 보고됨 → **but 영상 검은 화면**
3. A17 앱 재부팅 → 새 모니터링 → **여전히 검은 화면**
4. A17 wifi on 복귀 → fresh 모니터링 → 정상

### 2.3 진단 로그

#### A17 측 — ICE candidate 수 점진적 감소

| 세션 시작 | ICE candidate 개수 | gathering complete | BufferPool (frame decode) |
|---|---|---|---|
| 17:11 monitoring (wifi) | 28 | ✅ | 활발 (분당 8~12) |
| 17:17:35 call (handoff 후) | 24 | ✅ (~2s) | 5 (잠깐) |
| **17:17:45 call** | 20 | ❌ COMPLETE 없음 | **0** |
| **17:18:04 call** | 16 | ❌ | **0** |
| **17:18:24 call** | 16 | ❌ | **0** |
| **17:19:00 call** | 16 | ❌ | **0** |
| **17:19:58 monitor** | 20 | ❌ | **0** |

→ `onIceGatheringChangeCOMPLETE` 미발화 = ICE gathering 무한 대기. carrier NAT 가 STUN 응답 차단 또는 host candidate 만 생기고 srflx 못 모음.

#### Senior 측 — PC CONNECTING 상태에서 빠져나오지 못함

callId `Os0VuUMEs8glmYq0m3R` (A17 17:17:45 영상통화):

```text
17:17:45.544  onChildAdded: callId=-Os0VuUMEs8glmYq0m3R, status=ringing
17:17:45.595  Senior 오디오 sender 비활성화 (incoming 표시)
17:17:45.613  remote description 설정 완료
17:17:45.739  answer 전송 완료
17:17:45.773  Senior ICE candidate: udp 172.30.1.24 (host, LAN)
17:17:45.846  Senior ICE candidate: udp 183.109.20.1 (srflx, public IP)
17:17:46.015  Senior PC 연결 상태: CONNECTING
... (14초 대기, CONNECTED 도달 안 함) ...
17:18:00.639  상대방 종료 감지 (status=ended) — A17 측 hangup
```

대조 — 첫 wifi 세션 (17:11:30, callId `Os0UTkrfCTFirVm9UY0`) 은:

```text
17:11:30.444  monitoring 발신 완료
17:11:31.319  원격 트랙 수신 kind=video
17:11:31.323  CallPhase.connecting → connected (answer_received)
17:11:31.323  RTCPeerConnectionState=Connecting
17:11:31.325  RTCPeerConnectionState=Connected  ← 즉시 CONNECTED
```

차이: wifi 세션은 ICE 가 즉시 connectivity check 통과. cellular 세션은 영원히 통과 못함.

#### 결정적 단서 — `BufferPool` (= video frame 디코딩 활동)

```text
17:11~17:13 (wifi 세션)        : 분당 8~12 (활발)
17:17 (handoff 후 짧은 회복)   : 5 (잠깐)
17:18~17:20 (모든 후속 세션)   : 0  ← video frame 0개 = 검은 화면
```

`BufferPool` 카운트 0 = 디코더가 받을 frame 자체가 안 옴 = ICE connectivity check 실패 → media RTP path 미형성.

### 2.4 메커니즘 정리

```text
[A17 cellular]              [Senior wifi]
       |                          |
   carrier NAT                  router NAT
   (symmetric)                  (full-cone or restricted)
       |                          |
   public IP A:port-X         public IP B:port-Y
   (port 매번 바뀜)
       
ICE check:
   A17 → Senior:  Senior 가 src port 안다 (RTDB 통해)
                  하지만 carrier 가 매번 다른 port 사용
                  Senior 가 보낸 STUN ping 이 A17 까지 못 옴
                  
   Senior → A17:  A17 가 src 알지만 carrier NAT 가 outbound 안 맞춤
                  (symmetric 특성)

→ 어떤 candidate pair 도 connectivity check 실패
→ ICE 영원히 CHECKING 상태
→ media RTP path 미형성
→ 검은 화면
```

### 2.5 왜 iOS Sol cellular 는 됐을까?

가설:
- **다른 통신사** — iOS Sol 의 carrier 가 less restrictive NAT (full-cone 또는 address-restricted)
- **iOS WebRTC 구현 차이** — IPv6 우선 사용하면 NAT 우회 가능 (IPv6 는 NAT 안 거침)
- **APN 설정** — 일부 통신사 IoT/특수 APN 은 public IP 직접 할당

확정하려면 iOS Sol 의 통신사 + APN 확인 필요.

### 2.6 cellular fresh start 는 잘 됨 — handoff 만 문제

사용자 검증 (다회):

- A17 cellular only fresh 모니터링/영상통화 → **정상 작동**
- iOS Sol cellular only fresh → **정상 작동**

→ A17 의 carrier NAT 가 진짜 fully symmetric 이라면 fresh 도 안 됐어야. 따라서 carrier NAT 가 P2P 막는 건 아니고, 다른 메커니즘 의심:

**가능 원인 (handoff 한정)**:

1. **Senior 측 stale state** — Family 의 wifi candidate 와 mapping 됐던 ICE state 가 ICE restart 후에도 cellular candidate 로 깨끗이 전환 안 됨. libwebrtc bug 또는 Senior 측 PC 가 "old candidate 와 통신 가능" 상태로 잘못 유지.
2. **A17 OS network state 일시 stuck** — wifi off 직후 Android network stack 이 cellular 라우팅 안정화 전 ICE restart 시도. 이 사이 STUN/RTP 패킷 손실.
3. **NAT mapping 시간차** — 새 cellular srflx candidate 가 STUN 으로 알아낸 IP/port 이지만 carrier NAT 의 mapping 이 ICE check 시점에 이미 다른 mapping 으로 교체. 이 경우 짧은 시간 안에 모든 게 바뀜.

**왜 앱 재부팅도 안 통하나?** — Senior 측 stale state 가능성 가장 큼. Family 재시작해도 Senior 의 이전 peer slot 잔존 또는 캐시된 ICE state 가 새 Family 와의 negotiation 방해.

### 2.7 production 영향 범위

| 시나리오 | 발생 빈도 | 영향 |
|---|---|---|
| 집/회사 wifi 만 사용 | 가장 많음 (시니어 일반적) | 0 |
| 외출 중 cellular 만 사용 | 중간 (이동 가족 사용자) | 0 (fresh 잘 됨) |
| 통화 중 wifi → cellular 전환 (집 → 외출) | 적음 (특수 case) | **검은 화면 가능성** |
| 통화 중 cellular → wifi 전환 (귀가) | 적음 | 일반적으로 OK (PC 자체 reconnect) |

→ 핵심 production 시나리오는 wifi/cellular fresh 가 다수. handoff edge case 는 적지만 발생 시 사용자 혼란.

---

## 3. Production 대응 — TURN 서버 도입

### 3.1 옵션 비교

| 옵션 | 설명 | 비용 | 운영 부담 |
|---|---|---|---|
| **A. coturn self-host** | 오픈소스 TURN. AWS/GCP 작은 인스턴스 | 서버비 ~$10~30/월 + 대역폭 (사용량 따라) | 직접 운영, 보안 패치, 모니터링 |
| **B. Twilio Network Traversal** | 매니지드 TURN | $0.40/GB (트래픽 기준) — 사용자 1명 영상통화 1분 ~10MB | 0 |
| **C. Xirsys / Metered** | 매니지드 TURN, 무료 tier 있음 | 무료 tier 후 사용량 과금 | 0 |
| **D. Cloudflare Calls (TURN 포함)** | 베타 단계 | 무료 (베타 한정) | 0 |

**현재 (시니어 케어 초기)**: 사용자 적으니 **B 또는 C** 가 합리적. 사용자 늘면 A 자체 운영으로 비용 절감 검토.

### 3.2 적용 코드 변경

`WebRtcService` 의 `_iceServers` 에 TURN 서버 추가:

```dart
final iceServers = [
  {
    'urls': ['stun:stun.l.google.com:19302'],
  },
  // TURN 추가 (Twilio 예시)
  {
    'urls': ['turn:global.turn.twilio.com:3478?transport=udp'],
    'username': '<dynamic_username_from_twilio_api>',
    'credential': '<dynamic_credential>',
  },
];
```

Twilio 등 매니지드 TURN 은 보통 **단기 credential** (TTL 24h) 발급. Cloud Function 으로 발급 endpoint 만들고 Family/Senior 가 통화 시작 전 호출.

### 3.3 TURN 효과 검증 시나리오

**S20 — Wi-Fi ↔ Cellular handoff (TURN 적용 후 재검증)**

1. A17 wifi on → 모니터링 시작 → connected
2. wifi off → cellular fallback → ICE restart
3. **기대 (TURN 적용 후)**: ICE 가 relay candidate 통해 connectivity check 성공 → CONNECTED → media RTP relay 통해 흐름 → 검은 화면 안 됨
4. wifi on 복귀 → 다시 더 빠른 path (host/srflx) 로 전환 → relay 사용 안 함

**측정 항목**:
- BufferPool count (frame decode 활동) — handoff 후에도 분당 5+ 면 OK
- ICE selected candidate type (relay 인지 host 인지)
- Senior 측 PC CONNECTED 도달 시간

### 3.4 TURN 외 대안 (Plan B 단계)

1. **wifi → cellular handoff 시 자동 통화 종료** — 사용자에게 "이동 중이라 통화 종료, 재발신 부탁" 안내. UX 나쁨.
2. **Cellular 전용 사용자 안내** — "안정 통화 위해 wifi 권장". 권장 사항이지 강제 아님.
3. **WebRTC ipv6 우선 설정** — 일부 통신사 ipv6 가 NAT 안 거치면 도움. 통신사별 검증 필요.

→ 모두 부분 해결. **장기적으로 TURN 가 정답.**

---

## 4. 즉각 권장 action

| 우선순위 | action |
|---|---|
| ⭐⭐⭐ | TURN 서비스 (Twilio/Xirsys) 가입 + 짧은 PoC 으로 handoff 시나리오 검증 |
| ⭐⭐ | 통신사별 NAT 종류 분류 (KT/SKT/LGU+ × prepaid/postpaid 등) |
| ⭐⭐ | Cloud Function 으로 TURN credential 동적 발급 endpoint |
| ⭐ | A17 cellular 외 다른 device 에서 동일 검증 (Galaxy S 시리즈 등) |
| ⭐ | iOS WebRTC 가 ipv6 우선이면 Android 도 ipv6 우선 설정 검토 |

---

## 5. 알려진 한계 (현재 NAT 환경)

이 doc 작성 시점 기준 (TURN 미적용):

- **wifi-only 사용자**: 영향 없음 (대다수 시니어)
- **cellular fresh start (Android/iOS 모두)**: 정상 작동 — 사용자 검증 완료
- **wifi → cellular handoff** (active session 중 wifi 끊고 cellular 로 전환): **검은 화면 가능** (A17 검증). 앱 재부팅도 즉시 회복 안 됨 — Senior 측 stale ICE state 의심.
- **cellular → wifi handoff**: 일반적으로 OK (PC 자체 reconnect 빠름)

이 제약은 [webrtc_integration_test.md](./webrtc_integration_test.md) 의 §6 "알려진 한계" 에 cross-link.
