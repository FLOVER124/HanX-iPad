# HanX for iPad

[HanX](https://github.com/FLOVER124/HanX)의 iPad 버전입니다. macOS GUI의 문서·도표·프레젠테이션·PDF 편집 기능과 화면 구성(리본 탭과 그룹, 명령 이름)을 그대로 옮기고, 터치·Apple Pencil·하드웨어 키보드·화상 키보드에 맞게 다시 만들었습니다.

- iPadOS 17 이상, Xcode 16 이상 (UIKit, PDFKit, PencilKit, Vision)
- 파일 형식 엔진(HWP·HWPX·DOCX·XLSX·PPTX 읽기/쓰기, 수식 엔진)은 macOS 앱과 같은 소스(`Engine/`)를 그대로 컴파일합니다.

## 빌드와 실행

1. Xcode에서 `HanXPad.xcodeproj`를 엽니다.
2. 프로젝트 › **HanXPad** 타깃 › **Signing & Capabilities**에서 **Team**을 본인 Apple Developer 팀으로 고릅니다. 필요하면 **Bundle Identifier**(`com.hanword.editor.ipad`)를 본인 소유 식별자로 바꿉니다.
3. 상단 실행 대상에서 연결한 iPad(또는 iPad 시뮬레이터)를 고르고 ⌘R로 실행합니다.
   - 실기기에 처음 설치할 때는 iPad의 **설정 › 개인정보 보호 및 보안 › 개발자 모드**를 켜야 합니다.
4. 배포는 **Product › Archive** 후 Organizer에서 TestFlight / App Store Connect로 올립니다.

명령줄 빌드(서명 없이 시뮬레이터용):

```sh
xcodebuild -project HanXPad.xcodeproj -scheme HanXPad -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

### 자동 검증 (CI)

`.github/workflows/build.yml`이 GitHub의 macOS 러너에서 iPad 시뮬레이터용으로 빌드한 뒤, 디버그 빌드 전용 실행 옵션 `-HanXDemo document|spreadsheet|presentation|pdf`로 네 편집기를 예제 문서로 열어 크래시 여부와 화면을 확인합니다. 열린 문서는 지원하는 모든 형식으로 내보낸 다음 다시 읽어 봅니다(HWPX·HWP·DOCX·XLSX·PPTX·PDF 등).

## 기능 (macOS 앱 대응)

| macOS | iPad |
|---|---|
| 시작 창 (새로 만들기, 최근 문서, 열기) | 시스템 문서 브라우저(최근 항목·파일 앱 위치) + **새로 만들기** 시트: 새 문서(HWPX/HWP/DOCX/HanX), 새 프레젠테이션(PPTX/HanX), 새 도표(XLSX/CSV/HanX), 양식(편지지, 라벨 2열×7행) |
| 문서 편집기 리본: 홈 · 글자 모양 · 양식 · 삽입 · 쪽 문단 · 보기 | 같은 탭과 명령. 쪽 단위 편집(쪽 윤곽), 머리말/꼬리말, 쪽 번호, 표(두 번 탭해 표 편집: 줄·칸 추가/삭제, 셀 합치기/나누기, 배경, 세로 정렬, 칸 너비), 그림(사진 보관함·파일·붙여넣기, 크기 조정), 쪽 나누기(Control-Return), 구분선, 편집 용지, 자간·장평, 스타일, 찾기·바꾸기, 눈금자, 핀치 확대 |
| 도표 편집기 리본: 홈 · 셀 서식 · 삽입 크기 · 데이터 · 보기 | 같은 탭과 명령. 수식 입력줄·이름 상자, 시트 탭(추가·이름·삭제), 병합, 표시 형식, 행/열 삽입·삭제, 열 너비 자동, 행 높이, 차트 5종(이동·크기 조절·설정), 자동 합계, 정렬, 채우기, 연속 데이터, 틀 고정, 찾기, 머리글 경계 끌어 크기 조절 |
| 프레젠테이션 편집기 리본: 홈 · 삽입 · 디자인 · 배치 · 그림 · 전환 · 보기 | 같은 탭과 명령. 슬라이드 목록(끌어서 순서 변경, 복제/삭제/복사/붙여넣기), 텍스트 상자·도형 21종·그림·동영상·표·선, 배경색/디자인/그라데이션/배경 그림, 회전·뒤집기·비율·맞춤·간격·순서, 그림 자르기·보정·배경 제거(피사체 인식/단색)·원본 복원, 화면 전환 21종·애니메이션 창, 슬라이드 쇼, 발표자 노트 |
| PDF 편집기 (읽기 / 개체 편집) | **읽기**(PDFKit, 시스템 찾기), **개체 편집**(텍스트 줄·이미지·도형 선택, 이동·크기·회전, 채우기 색, 텍스트 수정, 이미지 교체, 삭제, 텍스트/이미지/도형 추가, 문자 인식, 검색 가능한 텍스트 추가, 문서로 편집), **펜**(Apple Pencil 필기를 페이지에 넣기), 페이지 회전·복제·빈 페이지·PDF 삽입·삭제·끌어서 순서 변경 |
| 저장 / 다른 이름으로 저장 / 내보내기 / 인쇄 | 저장, 다른 형식으로 내보내기(문서: HanX·HWPX·HWP·DOCX·PDF·HTML·RTF·MD·TXT / 도표: HanX·XLSX·CSV·TSV·HTML·PDF / 프레젠테이션: HanX·PPTX·PDF / PDF: PDF·DOCX·HWPX), 공유, AirPrint 인쇄 |

### iPad에 맞춘 부분

- **터치**: 44pt 리본 버튼, 메뉴는 풀다운. 도표는 길게 눌러 끌기·선택 핸들로 범위 선택, 이미 선택한 셀을 탭하면 편집 메뉴. 슬라이드는 끌어서 이동, 8방향 핸들, 회전 핸들(15° 맞춤), 두 손가락으로 크기·회전, 가운데·가장자리 맞춤선.
- **Apple Pencil / 트랙패드**: 펜·포인터로 끌면 영역 선택, PDF·슬라이드에 펜으로 그리기(PencilKit).
- **하드웨어 키보드**: ⌘S 저장, ⌘⇧S 내보내기, ⌘P 인쇄, ⌘F 찾기, ⌘G 다음 찾기, ⌘B/I/U, ⌘Z/⇧⌘Z. 도표는 화살표·Tab·Return·Delete·F2·⌘화살표, 셀을 고르고 바로 타이핑하면(한글 조합 포함) 입력이 시작됩니다. 슬라이드는 화살표(⇧ 10pt)로 미세 이동, ⌘D 복제, ⌘⇧M 새 슬라이드, 슬라이드 쇼는 화살표·Space·Esc(프레젠터 리모컨 호환). ⌘ 키를 길게 누르면 단축키 목록이 보입니다.
- **화상 키보드**: 문서 편집 중 키보드 위 단축 막대에 굵게/기울임/밑줄, 표·그림 넣기. 도표에서 셀만 선택할 때는 키보드가 올라오지 않고, 두 번 탭하거나 수식 입력줄을 누르면 올라옵니다. 키보드가 화면을 가리지 않도록 편집 영역이 자동으로 줄어듭니다.
- **파일**: 파일 앱과 같은 위치에서 바로 열고 저장(Open in place). HanX가 만든 파일(양식, PDF→문서)은 **나의 iPad › HanX**에 저장됩니다. **글꼴 추가…**(문서 브라우저 ⓘ 메뉴)로 TTF/OTF 글꼴을 가져올 수 있습니다.

### 원본 파일 보호

macOS 앱과 같이, HWP·HWPX·DOCX·XLSX·PPTX·PDF 같은 원본 파일은 처음 **저장**할 때 "원본에 저장 / HanX 파일로 사본 저장 / 다른 형식으로 내보내기"를 묻습니다. 원본 저장을 확인하기 전에는 자동 저장하지 않고, 닫을 때 변경 내용이 있으면 저장 여부를 묻습니다. HanX가 새로 만든 파일과 `.hanx` 파일은 자동 저장합니다.

## 구조

```
HanXPad.xcodeproj   Xcode 16 프로젝트 (폴더 동기화: HanXPad/, Engine/ 안의 파일을 자동으로 포함)
Config/Info.plist   문서 형식(UTI)·장면 설정
Engine/             macOS HanX와 공유하는 엔진 (Scripts/sync-engine.sh로 갱신)
Engine/iOS/         iPadOS에 없는 XMLDocument를 대신하는 XML 파서 (DOCTYPE/엔터티 확장 없음)
HanXPad/App         앱·장면, 문서 브라우저, 새로 만들기, 편집기 생성
HanXPad/Common      리본, 편집기 공통 화면(저장·내보내기·인쇄·닫기), 글꼴, 테마, 사진/파일 선택
HanXPad/Document    문서 편집기 (TextKit 다중 페이지, UDocument ↔ NSAttributedString, 표, 머리말/꼬리말, PDF 출력)
HanXPad/Sheet       도표 편집기 (가상 캔버스 그리드, 셀 편집기, 차트, PDF 출력)
HanXPad/Slides      프레젠테이션 편집기 (캔버스, 슬라이드 목록, 그림 편집, 전환·애니메이션, 슬라이드 쇼)
HanXPad/PDF         PDF 편집기 (개체 탐지, 페이지 다시 그리기 편집, OCR, PDF → 문서 변환)
```

엔진 갱신:

```sh
Scripts/sync-engine.sh ../HanX
```

## macOS 판과 다른 점

- **PDF 편집**: macOS 앱은 Python(pdfium) 워커로 PDF 개체를 직접 고칩니다. iPadOS에서는 외부 프로세스를 실행할 수 없으므로 PDFKit/Core Graphics로 다시 구현했습니다. 편집한 페이지는 원본 내용을 벡터 그대로 다시 그린 뒤 변경 사항을 그려 넣습니다(다른 페이지는 그대로 유지, 링크·양식 필드 유지). 그래서 기존 개체 삭제·이동은 배경색으로 덮고 같은 영역을 옮겨 그리는 방식이며, 문자 인식은 기기 내 Vision을 씁니다.
- **문서의 표**: iPadOS TextKit에는 표 레이아웃(NSTextTable)이 없어, 표는 본문 안의 한 덩어리로 표시하고 **두 번 탭**해 표 편집 화면에서 고칩니다. 병합·테두리·여백·고정 높이 등 원본 표 정보는 그대로 보존합니다.
- **PDF → 문서 변환**은 PDFKit의 텍스트 줄 정보로 위치·크기·색을 복원합니다. 글자가 없는 페이지는 페이지 이미지로 가져옵니다.
- CLI·MCP·설치 프로그램은 iPad 판에 포함하지 않습니다.

## 라이선스

MIT License ([LICENSE](LICENSE), [NOTICE](NOTICE)). 한글과컴퓨터, Microsoft와 제휴 또는 승인 관계가 없습니다.
