import Testing
@testable import MiniMixUI

@MainActor @Test func rootViewBuilds() {
    _ = RootView(app: AppViewModel(services: .mocks(demo: false))).body
}
