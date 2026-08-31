import XCTest
@testable import DomainKit

final class TeamDTests: XCTestCase {
    func testDomainKitIsLinked() {
        XCTAssertNotNil(DomainKitModule.self)
    }
}
