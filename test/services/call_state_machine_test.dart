import 'package:flutter_test/flutter_test.dart';
import 'package:senior_care_family/services/call/call_state_machine.dart';

void main() {
  group('CallStateMachine', () {
    late CallStateMachine fsm;

    setUp(() {
      fsm = CallStateMachine();
    });

    tearDown(() {
      fsm.dispose();
    });

    test('초기 phase 는 idle', () {
      expect(fsm.phase.value, CallPhase.idle);
      expect(fsm.reason, isNull);
      expect(fsm.isEnding, isFalse);
      expect(fsm.isTerminated, isFalse);
    });

    group('허용 전이', () {
      test('idle → connecting', () {
        expect(fsm.to(CallPhase.connecting, reason: 'startCall'), isTrue);
        expect(fsm.phase.value, CallPhase.connecting);
      });

      test('connecting → connected', () {
        fsm.to(CallPhase.connecting, reason: 'startCall');
        expect(fsm.to(CallPhase.connected, reason: 'answer_received'), isTrue);
        expect(fsm.phase.value, CallPhase.connected);
      });

      test('connected → upgrading → connected', () {
        fsm.to(CallPhase.connecting, reason: 'startCall');
        fsm.to(CallPhase.connected, reason: 'answer_received');
        expect(fsm.to(CallPhase.upgrading, reason: 'upgrade'), isTrue);
        expect(fsm.to(CallPhase.connected, reason: 'renegotiate_done'), isTrue);
        expect(fsm.phase.value, CallPhase.connected);
      });

      test('connected → reconnecting → connected', () {
        fsm.to(CallPhase.connecting, reason: 'startCall');
        fsm.to(CallPhase.connected, reason: 'answer_received');
        expect(fsm.to(CallPhase.reconnecting, reason: 'peer_disconnected'), isTrue);
        expect(fsm.to(CallPhase.connected, reason: 'ice_restored'), isTrue);
      });

      test('upgrading → reconnecting 허용 (DISCONNECTED race)', () {
        fsm.to(CallPhase.connecting, reason: 'startCall');
        fsm.to(CallPhase.connected, reason: 'answer_received');
        fsm.to(CallPhase.upgrading, reason: 'upgrade');
        expect(fsm.to(CallPhase.reconnecting, reason: 'peer_disconnected'), isTrue);
      });

      test('어떤 상태에서든 terminating 전이 허용', () {
        // idle → terminating
        expect(fsm.to(CallPhase.terminating, reason: 'hangup'), isTrue);
        expect(fsm.phase.value, CallPhase.terminating);

        // connecting → terminating
        final fsm2 = CallStateMachine();
        fsm2.to(CallPhase.connecting, reason: 'startCall');
        expect(fsm2.to(CallPhase.terminating, reason: 'hangup'), isTrue);
        fsm2.dispose();

        // connected → terminating
        final fsm3 = CallStateMachine();
        fsm3.to(CallPhase.connecting, reason: 'startCall');
        fsm3.to(CallPhase.connected, reason: 'answer_received');
        expect(fsm3.to(CallPhase.terminating, reason: 'hangup'), isTrue);
        fsm3.dispose();
      });

      test('terminating → terminated', () {
        fsm.to(CallPhase.terminating, reason: 'hangup');
        expect(fsm.to(CallPhase.terminated, reason: 'cleanup_done'), isTrue);
        expect(fsm.phase.value, CallPhase.terminated);
      });
    });

    group('금지 전이 — false 반환 + 상태 불변', () {
      test('idle → connected 금지 (connecting 경유 필요)', () {
        expect(fsm.to(CallPhase.connected, reason: 'bad'), isFalse);
        expect(fsm.phase.value, CallPhase.idle);
      });

      test('idle → upgrading 금지', () {
        expect(fsm.to(CallPhase.upgrading, reason: 'bad'), isFalse);
        expect(fsm.phase.value, CallPhase.idle);
      });

      test('idle → reconnecting 금지', () {
        expect(fsm.to(CallPhase.reconnecting, reason: 'bad'), isFalse);
      });

      test('connecting → reconnecting 금지 (한번이라도 connected 필요)', () {
        fsm.to(CallPhase.connecting, reason: 'startCall');
        expect(fsm.to(CallPhase.reconnecting, reason: 'bad'), isFalse);
      });

      test('reconnecting → upgrading 금지', () {
        fsm.to(CallPhase.connecting, reason: 'startCall');
        fsm.to(CallPhase.connected, reason: 'answer_received');
        fsm.to(CallPhase.reconnecting, reason: 'peer_disconnected');
        expect(fsm.to(CallPhase.upgrading, reason: 'bad'), isFalse);
      });

      test('terminating → 다른 상태 복귀 금지', () {
        fsm.to(CallPhase.connecting, reason: 'startCall');
        fsm.to(CallPhase.terminating, reason: 'hangup');
        expect(fsm.to(CallPhase.connecting, reason: 'bad'), isFalse);
        expect(fsm.to(CallPhase.connected, reason: 'bad'), isFalse);
        expect(fsm.to(CallPhase.reconnecting, reason: 'bad'), isFalse);
      });

      test('terminated 는 terminal — 어떤 전이도 금지', () {
        fsm.terminate(TerminateReason.userHangup);
        expect(fsm.phase.value, CallPhase.terminated);
        expect(fsm.to(CallPhase.idle, reason: 'bad'), isFalse);
        expect(fsm.to(CallPhase.connecting, reason: 'bad'), isFalse);
        expect(fsm.to(CallPhase.terminating, reason: 'bad'), isFalse);
      });
    });

    group('terminate — idempotent + reason 세팅', () {
      test('idle 에서 terminate → terminating → terminated 연속 전이', () {
        fsm.terminate(TerminateReason.userHangup);
        expect(fsm.phase.value, CallPhase.terminated);
        expect(fsm.reason, TerminateReason.userHangup);
        expect(fsm.isTerminated, isTrue);
        expect(fsm.isEnding, isTrue);
      });

      test('connected 에서 terminate', () {
        fsm.to(CallPhase.connecting, reason: 'startCall');
        fsm.to(CallPhase.connected, reason: 'answer_received');
        fsm.terminate(TerminateReason.remoteEnded);
        expect(fsm.phase.value, CallPhase.terminated);
        expect(fsm.reason, TerminateReason.remoteEnded);
      });

      test('terminate 중복 호출은 no-op — 첫 reason 덮어쓰지 않음', () {
        fsm.terminate(TerminateReason.iceFailed);
        final firstReason = fsm.reason;
        fsm.terminate(TerminateReason.userHangup);
        expect(fsm.reason, firstReason);
        expect(fsm.phase.value, CallPhase.terminated);
      });

      test('terminating 상태에서 terminate 호출 → terminated 로 진행', () {
        fsm.to(CallPhase.terminating, reason: 'hangup');
        fsm.terminate(TerminateReason.userHangup);
        expect(fsm.phase.value, CallPhase.terminated);
        expect(fsm.reason, TerminateReason.userHangup);
      });

      test('모든 TerminateReason 이 terminate 로 세팅 가능', () {
        for (final reason in TerminateReason.values) {
          final f = CallStateMachine();
          f.terminate(reason);
          expect(f.reason, reason);
          expect(f.isTerminated, isTrue);
          f.dispose();
        }
      });
    });

    group('isEnding 가드', () {
      test('idle/connecting/connected/upgrading/reconnecting 에선 false', () {
        expect(fsm.isEnding, isFalse);
        fsm.to(CallPhase.connecting, reason: 'startCall');
        expect(fsm.isEnding, isFalse);
        fsm.to(CallPhase.connected, reason: 'answer_received');
        expect(fsm.isEnding, isFalse);
      });

      test('terminating/terminated 에선 true', () {
        fsm.to(CallPhase.terminating, reason: 'hangup');
        expect(fsm.isEnding, isTrue);
        fsm.to(CallPhase.terminated, reason: 'cleanup_done');
        expect(fsm.isEnding, isTrue);
      });
    });

    group('phase ValueNotifier 구독', () {
      test('전이 시 리스너 호출', () {
        final history = <CallPhase>[];
        fsm.phase.addListener(() => history.add(fsm.phase.value));
        fsm.to(CallPhase.connecting, reason: 'startCall');
        fsm.to(CallPhase.connected, reason: 'answer_received');
        fsm.terminate(TerminateReason.userHangup);
        expect(history, [
          CallPhase.connecting,
          CallPhase.connected,
          CallPhase.terminating,
          CallPhase.terminated,
        ]);
      });

      test('금지 전이는 리스너 호출 안 함', () {
        final history = <CallPhase>[];
        fsm.phase.addListener(() => history.add(fsm.phase.value));
        fsm.to(CallPhase.connected, reason: 'bad'); // idle→connected 금지
        expect(history, isEmpty);
      });
    });
  });
}
