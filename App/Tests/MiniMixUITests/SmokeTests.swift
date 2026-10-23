import Testing
@testable import MiniMixUI

@MainActor @Test func rootViewBuilds() {
    _ = RootView().body
}
