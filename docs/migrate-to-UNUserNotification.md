# NSUserNotification → UNUserNotificationCenter 마이그레이션 가이드

## 현재 상태

- `NSUserNotification` + `NSUserNotificationCenter.default.deliver()` 사용 중
- deprecated API지만 bare binary(`swift build` → `.build/debug/SuperVoiceAssistant`)에서 정상 동작
- `UNUserNotificationCenter`는 `Bundle.main.bundleIdentifier`가 nil이면 크래시 발생
  - `bundleProxyForCurrentProcess is nil` 에러

## 왜 크래시하는가

`swift build`로 생성된 바이너리는 `.app` 번들이 아닌 단독 실행 파일이라서:
- `Bundle.main.bundleIdentifier` → `nil`
- `UNUserNotificationCenter.current()` 호출 시 번들 프록시를 찾지 못해 `NSInternalInconsistencyException`

`codesign --identifier`로 번들 ID를 설정해도 이건 code signing identity일 뿐, 실제 `Info.plist` 기반 번들이 아님.

## 마이그레이션 방법

### 1. `.app` 번들 구조 생성

```
SuperVoiceAssistant.app/
  Contents/
    Info.plist
    MacOS/
      SuperVoiceAssistant    ← swift build 바이너리 복사
    Resources/
      AppIcon.icns           ← (선택) 앱 아이콘
```

### 2. Info.plist 작성

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.likeshock.SuperVoiceAssistant</string>
    <key>CFBundleName</key>
    <string>SuperVoiceAssistant</string>
    <key>CFBundleExecutable</key>
    <string>SuperVoiceAssistant</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Voice transcription requires microphone access.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Screen recording requires screen capture access.</string>
</dict>
</plist>
```

### 3. build-and-run.sh 수정 예시

```bash
#!/bin/bash
set -e
cd "$(dirname "$0")"
source .codesign.env

echo "🔨 Building..."
swift build

APP_DIR="SuperVoiceAssistant.app/Contents"
mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"

# 바이너리 복사
cp .build/debug/SuperVoiceAssistant "$APP_DIR/MacOS/"

# Info.plist 복사
cp Info.plist "$APP_DIR/"

# (선택) 리소스 복사
# cp AppIcon.icns "$APP_DIR/Resources/"

# codesign
echo "🔏 Signing app bundle..."
codesign --force --sign "$CERT_NAME" --identifier "$BUNDLE_ID" SuperVoiceAssistant.app

echo "🚀 Running..."
open SuperVoiceAssistant.app
# 또는: exec SuperVoiceAssistant.app/Contents/MacOS/SuperVoiceAssistant
```

### 4. 코드 변경

`sendNotification()` 헬퍼를 `UNUserNotificationCenter` 기반으로 교체:

```swift
import UserNotifications

func requestNotificationPermission() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error = error {
            print("⚠️ Notification permission error: \(error)")
        }
    }
}

func sendNotification(title: String, subtitle: String? = nil, body: String, sound: Bool = false) {
    let content = UNMutableNotificationContent()
    content.title = title
    if let subtitle = subtitle { content.subtitle = subtitle }
    content.body = body
    if sound { content.sound = .default }

    let request = UNNotificationRequest(
        identifier: UUID().uuidString,
        content: content,
        trigger: nil
    )
    UNUserNotificationCenter.current().add(request)
}
```

`applicationDidFinishLaunching`에서 `requestNotificationPermission()` 호출 추가.

## 주의사항

- `.app` 번들로 전환하면 `exec "$BINARY"` 방식의 직접 실행이 `open` 명령으로 바뀜
- `open`은 비동기라 터미널에서 stdout/stderr가 안 보일 수 있음 → `exec .app/Contents/MacOS/SuperVoiceAssistant`로 직접 실행하면 해결
- CoreML ANE 캐시는 codesign identity + bundle ID에 의존 → `.app` 전환 시 캐시 미스 1회 발생 가능
- Accessibility 권한이 `.app` 기준으로 재설정될 수 있음 (시스템 설정에서 다시 허용 필요)

## 참고

- 원본 레포(ykdojo/super-voice-assistant)도 `NSUserNotification` 사용 중 (2025년 기준)
- `NSUserNotification`은 macOS 14+에서 deprecated이지만 아직 동작함
- 향후 macOS 버전에서 제거될 수 있으므로 `.app` 번들 전환 권장
