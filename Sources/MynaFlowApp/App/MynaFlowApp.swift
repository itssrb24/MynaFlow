import SwiftUI

@main
struct MynaFlowApp: App {
  var body: some Scene {
    // Menu bar agent lands in slice 1.10; this keeps the target buildable.
    Settings { EmptyView() }
  }
}
