//
//  EditorIndexHtml.swift
//
//  Created by cyan on 7/27/26.
//

import Foundation
import os.log

/**
  index.html built by CoreEditor.
 */
public enum EditorIndexHtml {
  public static func fromAppBundle(config: EditorConfig, userSettings: String) -> String {
    toHtml(template: bundledContents, config: config, userSettings: userSettings)
  }
}

// MARK: - Private

private extension EditorIndexHtml {
  static let bundledContents: String = {
    bundledData?.toString() ?? ""
  }()

  static var bundledData: Data? {
    guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else {
      assertionFailure("Missing dist/index.html to set up the editor")
      return nil
    }

    return try? Data(contentsOf: url)
  }

  static func toHtml(
    template: String,
    config: EditorConfig,
    userSettings: String
  ) -> String {
    // Replace the later placeholder first to avoid searching arbitrarily large inserted JSON
    template
      .replacing("\"{{USER_SETTINGS}}\"", with: userSettings, maxReplacements: 1)
      .replacing("\"{{EDITOR_CONFIG}}\"", with: config.jsonEncoded, maxReplacements: 1)
  }
}

private let os_logger = os.Logger()
