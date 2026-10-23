//
//  StatisticsView.swift
//
//  Created by cyan on 8/26/23.
//

import AppKit
import AppKitExtensions
import SwiftUI

@MainActor
struct StatisticsView: View {
  private let fullResult: StatisticsResult
  private let selectionResult: StatisticsResult?
  private let localizable: StatisticsLocalizable

  @State private var viewingMode: ViewingMode = .selection
  @State private var localMonitor: Any?

  init(
    fullResult: StatisticsResult,
    selectionResult: StatisticsResult?,
    localizable: StatisticsLocalizable
  ) {
    self.fullResult = fullResult
    self.selectionResult = selectionResult
    self.localizable = localizable
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack {
        if selectionResult != nil {
          Picker(localizable.mainTitle, selection: $viewingMode) {
            Text(localizable.selection).tag(ViewingMode.selection)
            Text(localizable.document).tag(ViewingMode.document)
          }
          .labelsHidden() // Hide the label while keeping the accessibility
          .pickerStyle(.segmented)
          .padding()
          .onAppear {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
              switch event.keyCode {
              case .kVK_LeftArrow:
                viewingMode = .selection
                return nil
              case .kVK_RightArrow:
                viewingMode = .document
                return nil
              default:
                return event
              }
            }
          }
          .onDisappear {
            if let localMonitor {
              NSEvent.removeMonitor(localMonitor)
              self.localMonitor = nil
            }
          }
        } else {
          Text(localizable.mainTitle)
            .font(.system(size: 14, weight: .semibold))
        }
      }
      .frame(height: 40)

      Divider()

      ScrollView {
        VStack(spacing: 0) {
          StatisticsCell(
            iconName: Icons.characters,
            titleText: localizable.characters,
            valueText: "\(currentResult.characters)"
          )

          StatisticsCell(
            iconName: Icons.words,
            titleText: localizable.words,
            valueText: "\(currentResult.words)"
          )
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
      }
      .safeAreaPadding(.bottom, 8)
    }
  }
}

// MARK: - Private

private extension StatisticsView {
  enum ViewingMode: Int {
    case selection = 0
    case document = 1
  }

  enum Icons {
    static let characters = "textformat"
    static let words = "text.bubble"
  }

  var isViewingDocument: Bool {
    // We are viewing full document if there's no selection, or we explicitly selected the document section
    selectionResult == nil || viewingMode == .document
  }

  var currentResult: StatisticsResult {
    if !isViewingDocument, let selectionResult {
      return selectionResult
    }

    return fullResult
  }
}
