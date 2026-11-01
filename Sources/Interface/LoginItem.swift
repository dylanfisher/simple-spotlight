import Search
import ServiceManagement

/// Where a login item stands, as `SMAppService.Status` says, which macOS 12 doesn't have.
public enum LoginItemStatus: Sendable {
    case notRegistered, enabled, requiresApproval, notFound
}

/// The app's login item as `SMAppService` keeps it. A protocol so tests can stand in for the
/// user's real login items.
@MainActor
public protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

/// The login item of the running app's own bundle. On macOS 12, which has no `SMAppService`,
/// there is none, and registering throws.
public struct MainAppLoginItem: LoginItemService {
    /// Why registering fails on macOS 12.
    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Opening at login needs macOS 13 or later." }
    }

    public init() {}

    public var status: LoginItemStatus {
        guard #available(macOS 13, *) else { return .notFound }
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws {
        guard #available(macOS 13, *) else { throw Unavailable() }
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        guard #available(macOS 13, *) else { return }
        try SMAppService.mainApp.unregister()
    }
}

/// Keeps the login item in step with the `launchAtLogin` setting, and says what stops it. With
/// the setting false, a login item for the app is removed, even one the user added by hand in
/// System Settings.
@MainActor
public struct LoginItem {
    /// Whether this macOS can open the app at login, so the settings window offers it.
    public static var isAvailable: Bool {
        if #available(macOS 13, *) { true } else { false }
    }

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
