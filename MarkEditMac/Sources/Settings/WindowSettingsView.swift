//
//  WindowSettingsView.swift
//  MarkEditMac
//
//  Created by cyan on 1/26/23.
//

import SwiftUI
import SettingsUI

@MainActor
struct WindowSettingsView: View {
  @State private var toolbarMode = AppPreferences.Window.toolbarMode

  var body: some View {
    SettingsForm {
      Section {
        Picker(Localized.Settings.toolbarMode, selection: $toolbarMode) {
          Text(Localized.Settings.normalMode).tag(ToolbarMode.normal)
          Text(Localized.Settings.compactMode).tag(ToolbarMode.compact)
          Text(Localized.Settings.hiddenMode).tag(ToolbarMode.hidden)
        }
        .onChange(of: toolbarMode) {
          AppPreferences.Window.toolbarMode = toolbarMode
        }
        .formMenuPicker()
      }
    }
  }
}
