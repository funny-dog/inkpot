//
//  StatisticsResult.swift
//
//  Created by cyan on 5/4/25.
//

import Foundation
import MarkEditKit
import NaturalLanguage

struct StatisticsResult: Sendable {
  let characters: Int
  let words: Int

  init(content: ReadableContent) {
    characters = content.sourceText.count
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = content.trimmedText
    words = tokenizer.tokens(for: content.trimmedText.startIndex..<content.trimmedText.endIndex).count
  }
}
