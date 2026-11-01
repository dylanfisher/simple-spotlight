import Foundation
import Search
import ServiceManagement
import Testing

@testable import Interface

/// A login item that records what was asked of it.
@MainActor
private final class FakeService: LoginItemService {
    var status: LoginItemStatus
    var statusAfterRegister: LoginItemStatus = .enabled
    var failure: (any Error)?
    private(set) var calls: [String] = []

    init(_ status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        calls.append("register")
        if let failure { throw failure }
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        if let failure { throw failure }
        status = .notRegistered
    }
}

@MainActor @Test func registersWhenTurnedOn() {
    let service = FakeService(.notRegistered)

    #expect(LoginItem(service: service, appName: "Simple Spotlight").follow(true) == nil)
    #expect(service.calls == ["register"])
}

@MainActor @Test func unregistersWhenTurnedOff() {
    let service = FakeService(.enabled)

    #expect(LoginItem(service: service, appName: "Simple Spotlight").follow(false) == nil)
    #expect(service.calls == ["unregister"])
}

@MainActor @Test func leavesALoginItemAlreadyAsAsked() {
    let on = FakeService(.enabled)
    let off = FakeService(.notRegistered)

    _ = LoginItem(service: on, appName: "Simple Spotlight").follow(true)
    _ = LoginItem(service: off, appName: "Simple Spotlight").follow(false)

    #expect(on.calls.isEmpty)
    #expect(off.calls.isEmpty)
}

@MainActor @Test func asksForApprovalInLoginItems() throws {
    let service = FakeService(.notRegistered)
    service.statusAfterRegister = .requiresApproval

    let row = try #require(LoginItem(service: service, appName: "Simple Spotlight").follow(true))

    #expect(row.title == "Allow Simple Spotlight in Login Items to open it at login")
    #expect(row.kind == .problem)
    #expect(row.id == ProblemItems.ID.loginItem.id)
    #expect(row.target == .openURL(LoginItem.settingsURL))
}

@MainActor @Test func saysWhyRegisteringFailed() throws {
    let service = FakeService(.notRegistered)
    service.failure = CocoaError(.fileReadNoPermission)

    let row = try #require(LoginItem(service: service, appName: "Simple Spotlight").follow(true))

    #expect(row.title == "Simple Spotlight couldn't open at login")
    #expect(row.subtitle == CocoaError(.fileReadNoPermission).localizedDescription)
}
