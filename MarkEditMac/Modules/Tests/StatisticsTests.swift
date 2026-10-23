//
//  StatisticsTests.swift
//
//  Created by Inkpot on 10/23/26.
//

import MarkEditKit
import XCTest
@testable import Statistics

final class StatisticsTests: XCTestCase {
  func testCountsEnglishChineseAndJapaneseWords() {
    for (text, characters) in [("Hello world", 11), ("苹果 香蕉", 5), ("東京 大阪", 5)] {
      let content = ReadableContent(sourceText: text, trimmedText: text, paragraphCount: 0, commentCount: 0)
      let result = StatisticsResult(content: content)
      XCTAssertEqual(result.characters, characters)
      XCTAssertEqual(result.words, 2)
    }
  }

  func testCountsComposedCharactersAndEmojiAsCharacters() {
    let text = "👨‍👩‍👧‍👦e\u{301}"
    let content = ReadableContent(sourceText: text, trimmedText: text, paragraphCount: 0, commentCount: 0)
    XCTAssertEqual(StatisticsResult(content: content).characters, 2)
  }

  func testCountsWordsFromReadableText() {
    let content = ReadableContent(sourceText: "[Hello](https://example.com)", trimmedText: "Hello", paragraphCount: 0, commentCount: 0)
    XCTAssertEqual(StatisticsResult(content: content).words, 1)
  }

  func testEmptyText() {
    let content = ReadableContent(sourceText: "", trimmedText: "", paragraphCount: 0, commentCount: 0)
    let result = StatisticsResult(content: content)
    XCTAssertEqual(result.characters, 0)
    XCTAssertEqual(result.words, 0)
  }
}
