import Search
import ServiceManagement

/// The app's login item as `SMAppService` keeps it. A protocol so tests can stand in for the
/// user's real login items.
@MainActor
public protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// The login item of the running app's own bundle.
public struct MainAppLoginItem: LoginItemService {
    public init() {}

    public var status: SMAppService.Status { SMAppService.mainApp.status }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// Keeps the login item in step with the `launchAtLogin` setting, and says what stops it. With
/// the setting false, a login item for the app is removed, even one the user added by hand in
/// System Settings.
@MainActor
public struct LoginItem {
    /// System Settings' Login Items pane, where the user approves a login item.
    public static let settingsURL: URL = {
        guard let url = SettingsPaneProvider.paneURL("com.apple.LoginItems-Settings.extension")
        else { preconditionFailure("the Login Items pane has no URL") }
        return url
    }()

    private let service: any LoginItemService
    private let appName: String

    public init(service: any LoginItemService, appName: String) {
        self.service = service
        self.appName = appName
    }

    /// Registers the login item when `enabled` and unregisters it otherwise, doing nothing when
    /// it already is so. Returns a row that opens Login Items when that failed, or when macOS
    /// wants the user to approve it there; nil when it worked.
    public func follow(_ enabled: Bool) -> SearchItem? {
        let status = service.status
        do {
            if enabled {
                guard status != .enabled else { return nil }
                try service.register()
                guard service.status != .requiresApproval else { return approvalProblem }
            } else {
                guard status == .enabled || status == .requiresApproval else { return nil }
                try service.unregister()
            }
        } catch {
            let action = enabled ? "open at login" : "stop opening at login"
            return problem(
                "\(appName) couldn't \(action)", subtitle: error.localizedDescription)
        }
        return nil
    }

    /// The row `shown` becomes as the login item stands now, read without registering anything:
    /// gone once it is as `enabled` asks, as after the user approves it in System Settings.
    /// Cheap enough to call each time the panel shows.
    public func recheck(_ enabled: Bool, shown: SearchItem?) -> SearchItem? {
        guard let shown else { return nil }
        switch (enabled, service.status) {
        case (true, .enabled), (false, .notRegistered), (false, .notFound): return nil
        case (true, .requiresApproval): return approvalProblem
        default: return shown
        }
    }

    private var approvalProblem: SearchItem {
        problem(
            "Allow \(appName) in Login Items to open it at login",
            subtitle: "Return opens Login Items")
    }

    private func problem(_ title: String, subtitle: String) -> SearchItem {
        ProblemItems.row(
            .loginItem, title: title, subtitle: subtitle, target: .openURL(Self.settingsURL))
    }
}
