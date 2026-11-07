import XCTest

/// Drives the real app with taps and typing, the way a person (or App Review)
/// would: start screen → each editor → main ribbon commands → close.
final class HanXPadUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String] = []) {
        app.launchArguments = arguments
        app.launch()
    }

    private func tap(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(what) 없음", file: file, line: line)
        element.tap()
    }

    private func button(_ label: String) -> XCUIElement { app.buttons[label].firstMatch }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// Closes the editor; answers the save prompt if one appears.
    private func closeEditor() {
        tap(button("닫기"), "닫기 버튼")
        let discard = app.alerts.buttons["저장하지 않음"]
        if discard.waitForExistence(timeout: 2) { discard.tap() }
        XCTAssertTrue(app.staticTexts["새로 만들기"].waitForExistence(timeout: 10), "시작 화면으로 돌아오지 않음")
    }

    func testStartScreenOpensFileBrowser() {
        launch()
        XCTAssertTrue(app.staticTexts["새로 만들기"].waitForExistence(timeout: 10))
        tap(button("파일 열기"), "파일 열기 상자")
        // The system document browser can take a while to come up on a cold simulator.
        tap(app.buttons["닫기"].firstMatch, "파일 브라우저 닫기", timeout: 40)
        XCTAssertTrue(app.staticTexts["새로 만들기"].waitForExistence(timeout: 10))
    }

    func testDocumentEditing() {
        launch()
        tap(button("새 문서"), "새 문서 타일")
        let page = app.textViews.firstMatch
        tap(page, "문서 페이지")
        page.typeText("Hello HanX")
        tap(button("굵게"), "리본 굵게")
        tap(button("글자 모양"), "글자 모양 탭")
        tap(button("취소선"), "리본 취소선")
        tap(button("삽입"), "삽입 탭")
        tap(button("쪽 나누기"), "쪽 나누기")
        tap(button("보기"), "보기 탭")
        tap(button("확대"), "확대")
        shot("document")
        closeEditor()
    }

    func testSpreadsheetEditing() {
        launch()
        tap(button("새 도표"), "새 도표 타일")
        let formula = app.textFields["수식 입력줄"]
        tap(formula, "수식 입력줄")
        formula.typeText("120\n")
        tap(formula, "수식 입력줄")
        formula.typeText("=A1*2\n")
        tap(button("굵게"), "리본 굵게")
        tap(button("데이터"), "데이터 탭")
        tap(button("오름차순"), "오름차순")
        tap(button("보기"), "보기 탭")
        tap(button("확대"), "확대")
        shot("spreadsheet")
        closeEditor()
    }

    func testPresentationEditingAndShow() {
        launch()
        tap(button("새 프레젠테이션"), "새 프레젠테이션 타일")
        tap(button("삽입"), "삽입 탭")
        tap(button("텍스트 상자"), "텍스트 상자")
        app.typeText("Slide title")
        tap(button("새 슬라이드"), "새 슬라이드")
        tap(button("보기"), "보기 탭")
        tap(button("처음부터"), "처음부터")
        // Tap through the show until it closes itself after the last slide.
        for _ in 0..<6 {
            if button("닫기").exists && button("닫기").isHittable { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            sleep(1)
        }
        XCTAssertTrue(button("닫기").waitForExistence(timeout: 10), "슬라이드 쇼가 끝나지 않음")
        shot("presentation")
        closeEditor()
    }

    func testPDFModes() {
        launch(["-HanXDemo", "pdf", "-HanXSlowAutoHide"])
        XCTAssertTrue(button("닫기").waitForExistence(timeout: 15), "PDF가 열리지 않음")
        // 읽기: the bars hide by themselves (10 s in this test build); a tap brings them back.
        sleep(13)
        XCTAssertFalse(button("닫기").exists && button("닫기").isHittable, "읽기 모드에서 상단바가 숨지 않음")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(button("닫기").waitForExistence(timeout: 3) && button("닫기").isHittable, "탭해도 상단바가 나타나지 않음")
        // iPad shows a segmented control; iPhone a 모드 menu. The bars may hide
        // again while the test runner is slow, so tap the page to bring them back.
        var switched = false
        for _ in 0..<4 where !switched {
            let menu = app.buttons["모드"].firstMatch
            if menu.exists && menu.isHittable { menu.tap() }
            let ink = app.buttons["필기"].firstMatch
            if ink.waitForExistence(timeout: 1) && ink.isHittable { ink.tap(); switched = true }
            else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); sleep(1) }
        }
        XCTAssertTrue(switched, "필기 모드로 바꾸지 못함")
        sleep(1)
        shot("pdf-ink")
        if !app.buttons["개체 편집"].firstMatch.exists { tap(app.buttons["모드"].firstMatch, "모드 메뉴") }
        tap(app.buttons["개체 편집"].firstMatch, "개체 편집 모드")
        tap(button("텍스트 추가"), "텍스트 추가")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Added")
        tap(app.alerts.buttons["확인"], "확인")
        if button("페이지 패널").exists { button("페이지 패널").tap() }   // iPhone: inside "…"
        shot("pdf-edit")
        closeEditor()
    }
}
