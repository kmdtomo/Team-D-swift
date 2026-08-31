import Foundation
import Testing
@testable import CompositionKit
import DomainKit

@Test func liveCompositionUsesOnlyLiveProviderWhenItFails() async throws {
    let fixture = ProviderSpy(result: .success(()))
    let live = ProviderSpy(result: .failure(StubError.unavailable))
    let endpoints = try LiveServiceEndpoints(
        backendBaseURL: URL(string: "https://backend.example.invalid")!,
        liveKitURL: URL(string: "wss://livekit.example.invalid")!
    )
    let composition = RuntimeServiceComposition.live(endpoints: endpoints, provider: live)

    await #expect(throws: StubError.unavailable) { try await composition.start() }
    #expect(composition.mode == .live)
    #expect(await live.callCount == 1)
    #expect(await fixture.callCount == 0)
}

@Test func liveStartupFailureRetainsLiveModeAndJapaneseMessageWithoutFixtureFallback() async throws {
    let fixture = ProviderSpy(result: .success(()))
    let live = ProviderSpy(result: .failure(StubError.unavailable))
    let endpoints = try LiveServiceEndpoints(
        backendBaseURL: URL(string: "https://backend.example.invalid")!,
        liveKitURL: URL(string: "wss://livekit.example.invalid")!
    )

    let state = await RuntimeServiceComposition.live(endpoints: endpoints, provider: live).startupState()

    #expect(state == .liveFailure)
    #expect(state.mode == .live)
    #expect(state.message == "ライブ接続を利用できません。撮影はこのまま続けられます。")
    #expect(await live.callCount == 1)
    #expect(await fixture.callCount == 0)
}

@Test func fixtureCompositionDoesNotCreateANetworkSession() async throws {
    let fixture = ProviderSpy(result: .success(()))
    let composition = RuntimeServiceComposition.fixture(provider: fixture)

    try await composition.start()
    #expect(composition.mode == .fixture)
    #expect(composition.endpoints == nil)
    #expect(composition.session == nil)
    #expect(await fixture.callCount == 1)
}

@Test func fixtureStartupFailureRemainsAnExplicitFixtureFailure() async {
    let fixture = ProviderSpy(result: .failure(.unavailable))
    let state = await RuntimeServiceComposition.fixture(provider: fixture).startupState()

    #expect(state == .fixtureFailure)
    #expect(state.mode == .fixture)
    #expect(state.message == "テストデータの準備を開始できません。")
    #expect(await fixture.callCount == 1)
}

@Test func bundleModeOverrideFailsClosedWithoutRelabelingTheCompiledProvider() {
    let failure = BuildModeValidator.startupFailure(compiledMode: .live, bundleMode: "fixture")

    #expect(failure == .configurationFailure(.live))
    #expect(failure?.mode == .live)
    #expect(failure?.message == "アプリの実行モード設定を確認できません。撮影を開始できません。")
    #expect(BuildModeValidator.startupFailure(compiledMode: .fixture, bundleMode: "fixture") == nil)
}

@Test func liveEndpointsRequireHTTPSAndWSS() {
    #expect(throws: RuntimeCompositionError.invalidBackendBaseURL) {
        try LiveServiceEndpoints(backendBaseURL: URL(string: "http://backend.example.invalid")!, liveKitURL: URL(string: "wss://livekit.example.invalid")!)
    }
    #expect(throws: RuntimeCompositionError.invalidLiveKitURL) {
        try LiveServiceEndpoints(backendBaseURL: URL(string: "https://backend.example.invalid")!, liveKitURL: URL(string: "https://livekit.example.invalid")!)
    }
    #expect(throws: RuntimeCompositionError.invalidBackendBaseURL) {
        try LiveServiceEndpoints(backendBaseURL: URL(string: "https://user:password@backend.example.invalid?token=value")!, liveKitURL: URL(string: "wss://livekit.example.invalid")!)
    }
}

@Test func networkSessionDoesNotPersistResponsesCookiesOrCredentials() {
    let session = EphemeralSessionFactory.makeSession()
    let configuration = session.configuration

    #expect(configuration.urlCache == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
}

private enum StubError: Error, Equatable, Sendable { case unavailable }

private actor ProviderSpy: RuntimeProvider {
    private(set) var callCount = 0
    private let result: Result<Void, StubError>

    init(result: Result<Void, StubError>) { self.result = result }

    func start() throws {
        callCount += 1
        try result.get()
    }
}
