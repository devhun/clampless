<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Clampless">
</p>

<h1 align="center">Clampless</h1>

<p align="center">
  외부 모니터 없이도 맥북 덮개를 닫은 채 깨어 있게 해 주는 메뉴바 앱<br>
  <sub>Clamshell, minus the display — Intel / Apple Silicon Universal · macOS 11+</sub>
</p>

---

macOS의 클램셸 모드는 전원·외부 모니터·외장 입력장치가 모두 연결돼 있어야 동작합니다.
Clampless는 모니터 없이 덮개를 닫아 두고 **SSH·화면 공유로 맥미니처럼 원격 사용**하다가,
필요할 때 덮개를 열어 평소처럼 쓰는 사용 방식을 위해 만들었습니다.

내부적으로는 `pmset -a disablesleep 1|0` 을 메뉴바 아이콘 클릭 한 번으로 토글합니다.

## 기능

| 동작 | 결과 |
|---|---|
| 아이콘 좌클릭 | 켜기/끄기 토글 (☀︎ 켜짐 / ☾zz 꺼짐) |
| 우클릭 또는 control+클릭 | 메뉴 |

메뉴 항목

- **배터리로 전환되면 자동으로 끄기** (기본 켜짐) — 어댑터가 빠지면 해제해 가방 속 과열 방지
- **종료 시 끄기** (기본 켜짐) — 앱 종료 시 원래 잠자기 동작으로 복구
- **로그인 시 실행** (macOS 13+)
- **권한 설정 제거…**

터미널에서 직접 `pmset` 을 바꿔도 10초 이내에 아이콘에 반영됩니다.

## 설치

Xcode 없이 Command Line Tools(`swiftc`, `lipo`, `codesign`)만 있으면 빌드됩니다.

```bash
./build.sh                                  # → build/Clampless.app (x86_64 + arm64)
cp -R build/Clampless.app /Applications/
open /Applications/Clampless.app
```

ad-hoc 서명이므로 다른 Mac에서 처음 열 때 Gatekeeper 경고가 뜨면 우클릭 → 열기로 실행하세요.

## 권한

`disablesleep` 은 root 권한이 필요합니다. 처음 토글할 때 관리자 비밀번호를 **한 번** 묻고,
아래 sudoers 규칙을 설치해 이후에는 비밀번호 없이 동작합니다.

```
# /etc/sudoers.d/clampless
<사용자> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

허용 범위는 위 두 명령뿐이며, 메뉴의 "권한 설정 제거…" 로 삭제할 수 있습니다.

## 원격 사용 팁

- 시스템 설정 → 일반 → 공유 → **원격 로그인**(SSH), **화면 공유** 켜기
- 전원 어댑터를 연결하고 통풍되는 곳에 두기 (덮개를 닫으면 발열이 빠지기 어려움)

## 수동 확인 / 복구

```bash
pmset -g | grep SleepDisabled     # 켜져 있으면 "SleepDisabled 1"
sudo pmset -a disablesleep 0       # 수동 해제
```

## 구조

```
Sources/main.swift          메뉴바 앱 전체 (AppKit, 단일 파일)
Resources/Info.plist        LSUIElement 앱 번들 설정 (Dock 아이콘 없음)
Resources/AppIcon.icns      앱 아이콘
Scripts/make_icon.swift     아이콘을 코드로 그리는 스크립트
Scripts/make_icon.sh        PNG → .icns 변환
build.sh                    Universal 빌드 + 번들 + ad-hoc 서명
```
