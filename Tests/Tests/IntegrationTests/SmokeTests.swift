import Testing
@testable import TestSupport

@Test func testMediaRootIsInsideRepo() {
    #expect(TestMediaLocator.root.lastPathComponent == "TestMedia")
}
