//
//  StatisticsLocalizable.swift
//
//  Created by cyan on 8/25/23.
//

import Foundation

public struct StatisticsLocalizable {
  let mainTitle: String
  let selection: String
  let document: String
  let characters: String
  let words: String

  public init(
    mainTitle: String,
    selection: String,
    document: String,
    characters: String,
    words: String
  ) {
    self.mainTitle = mainTitle
    self.selection = selection
    self.document = document
    self.characters = characters
    self.words = words
  }
}
