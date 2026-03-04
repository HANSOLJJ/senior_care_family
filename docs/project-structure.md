# Flutter 프로젝트 구조 가이드

이 문서는 `senior_win` Flutter 프로젝트의 구조를 설명합니다.

## 프로젝트 핵심 구조

```
Senior/
├── lib/                    # Dart 소스 코드 (가장 중요!)
│   └── main.dart           # 앱 시작점
├── pubspec.yaml            # 프로젝트 설정 & 의존성 관리
├── test/                   # 테스트 코드
│   └── widget_test.dart
├── android/                # Android 네이티브 코드
├── ios/                    # iOS 네이티브 코드
├── web/                    # 웹 빌드용
├── windows/                # Windows 데스크톱용
├── linux/                  # Linux 데스크톱용
└── macos/                  # macOS 데스크톱용
```

---

## 핵심 파일 설명

### 1. `lib/` 폴더 - 실제 앱 코드

앱 개발할 때 **90% 이상의 시간을 여기서** 보냅니다.

- `main.dart` - 앱의 진입점. `main()` 함수에서 앱이 시작됨
- 앱이 커지면 이 폴더 안에 하위 폴더를 만들어 코드를 구조화함

### 2. `pubspec.yaml` - 프로젝트 설정 파일

npm의 `package.json`과 비슷한 역할입니다.

```yaml
name: senior_win # 프로젝1트 이름
version: 1.0.0+1 # 앱 버전
environment:
  sdk: ^3.10.8 # Dart SDK 버전

dependencies: # 사용하는 패키지들
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8 # iOS 스타일 아이콘

dev_dependencies: # 개발용 패키지 (테스트 등)
  flutter_test:
    sdk: flutter
```

### 3. 플랫폼별 폴더 (android/, ios/, web/ 등)

- Flutter가 자동 생성/관리
- 플랫폼별 설정이 필요할 때만 수정 (앱 아이콘, 권한 설정 등)
- **일반적으로 건드릴 필요 없음**

---

## main.dart 코드 구조

```dart
void main() {
  runApp(const MyApp());     // 앱 시작
}

class MyApp extends StatelessWidget { ... }     // 루트 위젯
class MyHomePage extends StatefulWidget { ... } // 메인 화면
class _MyHomePageState extends State { ... }    // 상태 관리
```

### 핵심 개념

| 개념                | 설명                                                    |
| ------------------- | ------------------------------------------------------- |
| **StatelessWidget** | 상태가 변하지 않는 위젯                                 |
| **StatefulWidget**  | 상태가 변할 수 있는 위젯 (버튼 클릭으로 카운터 증가 등) |
| **setState()**      | 화면을 다시 그리라고 Flutter에게 알려주는 함수          |

---

## 자주 사용하는 명령어

| 명령어                       | 설명              |
| ---------------------------- | ----------------- |
| `flutter run`                | 앱 실행           |
| `flutter pub get`            | 패키지 설치       |
| `flutter pub add [패키지명]` | 새 패키지 추가    |
| `flutter build apk`          | Android APK 빌드  |
| `flutter build ios`          | iOS 빌드          |
| `flutter clean`              | 빌드 캐시 삭제    |
| `flutter doctor`             | Flutter 환경 점검 |

---

## 권장 lib/ 폴더 구조 (프로젝트가 커질 때)

```
lib/
├── main.dart
├── screens/          # 화면 위젯들
├── widgets/          # 재사용 가능한 위젯들
├── models/           # 데이터 모델 클래스
├── services/         # API 호출, 데이터베이스 등
├── providers/        # 상태 관리 (Provider 사용 시)
└── utils/            # 유틸리티 함수들
```

---

## 정리

개발할 때 주로 작업하는 곳:

1. **`lib/`** - Dart 코드 작성
2. **`pubspec.yaml`** - 패키지 추가할 때
3. **`assets/`** (나중에 생성) - 이미지, 폰트 등 리소스

나머지 폴더들은 Flutter가 알아서 관리하니 신경 쓰지 않아도 됩니다.
