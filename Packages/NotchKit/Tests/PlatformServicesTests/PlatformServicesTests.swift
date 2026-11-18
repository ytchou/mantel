import Testing
@testable import PlatformServices

@Test func moduleIsLinked() {
    #expect(PlatformServicesModule.name == "PlatformServices")
}
