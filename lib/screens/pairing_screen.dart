import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/family_service.dart';
import '../services/auth_service.dart';
import '../widgets/press_scale.dart';

/// 페어링 코드 입력 화면 (`StatefulWidget`)
///
/// Senior 태블릿에 표시된 6자리 영숫자 코드를 입력하거나
/// QR 코드를 스캔하여 가족 그룹에 참가.
///
/// 코드 입력 → FamilyService.joinFamily() → RTDB /families/{fid}/members에 등록
/// 성공 시 onPairedWithId 콜백 → PairingHelper.onPairingComplete() → 이름 설정
///
/// ## 섹션 구성
/// - **입력 처리**: 코드 제출, QR 스캔 화면 이동
/// - **UI**: 코드 입력 필드 + 연결 버튼 + QR 스캔 버튼
class PairingScreen extends StatefulWidget {
  /// 페어링 완료 콜백 (familyId 불필요 시 사용, 레거시)
  final VoidCallback? onPaired;

  /// 페어링 완료 콜백 (familyId 전달, PairingHelper.onPairingComplete 호출용)
  final Future<void> Function(String familyId)? onPairedWithId;

  const PairingScreen({super.key, this.onPaired, this.onPairedWithId});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

/// [PairingScreen]의 State (`State`)
///
/// 6자리 코드 입력/QR 스캔 → FamilyService.joinFamily() 호출 → 콜백 전달.
///
/// ## 섹션 구성
/// - **입력 처리**: _submitCode (수동/QR), _openQrScanner
/// - **UI**: build — 코드 입력 + 에러 표시 + 버튼
class _PairingScreenState extends State<PairingScreen> {
  /// 페어링 코드 입력 컨트롤러
  final _codeController = TextEditingController();

  /// 가족 관련 CRUD 서비스
  final _familyService = FamilyService();

  /// 페어링 진행 중 로딩 상태
  bool _loading = false;

  /// 에러 메시지 (null이면 에러 없음)
  String? _error;

  // ─── 입력 처리 ───

  /// 페어링 코드 제출 — 가족 그룹 참가 시도 (`Method`, async)
  ///
  /// 코드가 비어있으면 에러 표시.
  /// FamilyService.joinFamily()로 가족 참가 후 콜백 호출.
  ///
  /// - **Params**:
  ///   - [code] — QR 스캔 결과 (null이면 TextField 값 사용)
  /// - **Returns**: `Future<void>`
  /// - **Side Effects**: _loading, _error 갱신, onPairedWithId/onPaired 콜백 호출
  /// - **호출**: 연결 버튼 onPressed, TextField onSubmitted, QR 스캔 콜백
  Future<void> _submitCode([String? code]) async {
    if (_loading) return; // double-tap 차단
    final pairingCode = code ?? _codeController.text.trim();
    if (pairingCode.isEmpty) {
      setState(() => _error = '페어링 코드를 입력하세요');
      return;
    }

    HapticFeedback.lightImpact();
    setState(() { _loading = true; _error = null; });

    try {
      final familyId = await _familyService.joinFamily(pairingCode);
      await widget.onPairedWithId?.call(familyId);
      widget.onPaired?.call();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  /// QR 코드 스캔 화면으로 이동 (`Callback`)
  ///
  /// _QrScanScreen에서 코드 인식 시 자동으로 _submitCode() 호출.
  ///
  /// - **Side Effects**: Navigator push → _QrScanScreen, 스캔 성공 시 _submitCode 호출
  /// - **호출**: QR 스캔 버튼 onPressed
  void _openQrScanner() {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _QrScanScreen(
          onCodeScanned: (code) {
            Navigator.of(context).pop();
            _codeController.text = code;
            _submitCode(code);
          },
        ),
      ),
    );
  }

  // ─── 라이프사이클 ───

  /// 텍스트 컨트롤러 해제 (`Lifecycle`)
  ///
  /// - **Side Effects**: _codeController dispose
  /// - **호출**: 위젯 제거 시 Flutter 프레임워크에 의해
  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  // ─── UI ───

  /// 메인 빌드 — 페어링 코드 입력 화면 구성 (`Widget Builder`)
  ///
  /// 구성 요소:
  /// - 링크 아이콘 + 안내 텍스트
  /// - 6자리 영숫자 입력 TextField (대문자 변환, 특수문자 차단)
  /// - 에러 메시지 (있을 때만)
  /// - 연결하기 버튼 (로딩 시 CircularProgressIndicator)
  /// - QR 코드 스캔 버튼
  ///
  /// - **Returns**: `Widget` — 전체 화면 위젯
  /// - **호출**: Flutter 프레임워크 (setState 시 재호출)
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('기기 연결'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => AuthService().signOut(),
            tooltip: '로그아웃',
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.link, color: cs.primary, size: 64),
                const SizedBox(height: 24),
                const Text(
                  '시니어 기기와 연결',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '시니어 태블릿에 표시된\n페어링 코드를 입력하거나 QR을 스캔하세요',
                  style: TextStyle(fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 36),

                // 코드 입력
                TextField(
                  controller: _codeController,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 8,
                  ),
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(6),
                  ],
                  decoration: const InputDecoration(
                    hintText: '코드 입력',
                    hintStyle: TextStyle(fontSize: 24, letterSpacing: 4),
                    contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  ),
                  onSubmitted: (_) => _submitCode(),
                ),
                const SizedBox(height: 20),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(color: cs.error, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),

                // 연결 버튼
                PressScale(
                  onTap: _loading ? null : () => _submitCode(),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _loading ? null : () => _submitCode(),
                      child: _loading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              '연결하기',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // QR 스캔 버튼
                PressScale(
                  onTap: _loading ? null : _openQrScanner,
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: _loading ? null : _openQrScanner,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text(
                        'QR 코드 스캔',
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ),
              ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// QR 코드 스캔 화면 (`StatefulWidget`, private)
///
/// mobile_scanner 플러그인으로 카메라 열어 QR 코드 인식.
/// 6자리 영숫자(A-Z0-9) 패턴만 허용, 인식 즉시 onCodeScanned 콜백.
///
/// ## 섹션 구성
/// - **스캔 처리**: _onDetect — 바코드 인식 + 패턴 검증
/// - **UI**: 카메라 뷰 + 가이드 프레임 + 안내 텍스트
class _QrScanScreen extends StatefulWidget {
  /// QR 코드 인식 시 호출되는 콜백 (6자리 영숫자 코드 전달)
  final void Function(String code) onCodeScanned;

  const _QrScanScreen({required this.onCodeScanned});

  @override
  State<_QrScanScreen> createState() => _QrScanScreenState();
}

/// [_QrScanScreen]의 State (`State`)
///
/// 카메라 제어 + 중복 스캔 방지 + 바코드 패턴 검증.
class _QrScanScreenState extends State<_QrScanScreen> {
  /// mobile_scanner 카메라 컨트롤러
  final _controller = MobileScannerController();

  /// 중복 스캔 방지 플래그 (한 번 인식되면 true)
  bool _scanned = false;

  // ─── 라이프사이클 ───

  /// 카메라 컨트롤러 해제 (`Lifecycle`)
  ///
  /// - **Side Effects**: _controller dispose
  /// - **호출**: 위젯 제거 시 Flutter 프레임워크에 의해
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // ─── 스캔 처리 ───

  /// 바코드 인식 콜백 — 6자리 영숫자 패턴 검증 후 콜백 호출 (`Callback`)
  ///
  /// 이미 스캔됐으면 무시 (중복 방지).
  /// rawValue를 대문자 변환 후 ^[A-Z0-9]{6}$ 패턴 검증.
  ///
  /// - **Params**:
  ///   - [capture] — mobile_scanner가 전달하는 바코드 캡처 결과
  /// - **Side Effects**: _scanned → true, onCodeScanned 콜백 호출
  /// - **호출**: MobileScanner onDetect
  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final barcode = capture.barcodes.firstOrNull;
    if (barcode == null || barcode.rawValue == null) return;

    final raw = barcode.rawValue!.trim().toUpperCase();
    // 6자리 영숫자만 허용
    if (RegExp(r'^[A-Z0-9]{6}$').hasMatch(raw)) {
      _scanned = true;
      widget.onCodeScanned(raw);
    }
  }

  // ─── UI ───

  /// 메인 빌드 — QR 스캔 화면 구성 (`Widget Builder`)
  ///
  /// Stack 구성:
  /// - 전체 화면 카메라 뷰 (MobileScanner)
  /// - 중앙 250x250 가이드 프레임 (흰색 테두리)
  /// - 하단 안내 텍스트
  ///
  /// - **Returns**: `Widget` — QR 스캔 전체 화면 위젯
  /// - **호출**: Flutter 프레임워크
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,  // 카메라 렌더링 배경 — 의도적 검정
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('QR 코드 스캔'),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // 중앙 가이드 프레임
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: cs.primary, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          // 하단 안내
          const Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Text(
              '시니어 태블릿의 QR 코드를\n카메라에 비춰주세요',
              style: TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
