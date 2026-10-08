import SwiftUI
import UserNotifications

enum PushRegistrationDecision: Equatable {
    case disabled, requestPermission, register, denied

    static func resolve(authorized: Bool, undetermined: Bool, enabled: Bool) -> Self {
        guard enabled else { return .disabled }
        if authorized { return .register }
        return undetermined ? .requestPermission : .denied
    }
}

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        FeedStore.registerProcessing()
        FeedStore.scheduleRefresh()
        FeedStore.scheduleProcessing()
        Task {
            #if DEBUG
            if CommandLine.arguments.contains("-macroSample") || CommandLine.arguments.contains("-notificationSetupPreview") { return }
            #endif
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            let allowed = status == .authorized || status == .provisional || status == .ephemeral
            let decision = PushRegistrationDecision.resolve(authorized: allowed, undetermined: status == .notDetermined, enabled: UserDefaults.standard.bool(forKey: "pushEnabled") || allowed)
            guard decision == .register else { return }
            UserDefaults.standard.set(true, forKey: "pushEnabled")
            application.registerForRemoteNotifications()
        }
        return true
    }

    static func enable() async {
        #if DEBUG
        if CommandLine.arguments.contains("-macroSample") { return }
        #endif
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral
        let decision = PushRegistrationDecision.resolve(authorized: allowed, undetermined: settings.authorizationStatus == .notDetermined, enabled: true)
        let granted: Bool
        switch decision {
        case .requestPermission:
            granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true
        case .register:
            granted = true
        case .denied, .disabled:
            granted = false
        }
        UserDefaults.standard.set(granted, forKey: "pushEnabled")
        if granted {
            UserDefaults.standard.set("Waiting for Apple device registration", forKey: "pushRegistrationStatus")
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            UserDefaults.standard.set("Notifications are off. Allow them in iOS Settings to enable alerts.", forKey: "pushRegistrationStatus")
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let device = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(device, forKey: "pushDevice")
        UserDefaults.standard.set("Registered with Apple", forKey: "pushRegistrationStatus")
        Task { await Self.syncStockAlerts() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set("Apple registration failed: \(error.localizedDescription)", forKey: "pushRegistrationStatus")
    }

    static func syncStockAlerts() async {
        guard UserDefaults.standard.bool(forKey: "pushEnabled") else { return }
        guard let device = UserDefaults.standard.string(forKey: "pushDevice") else {
            UserDefaults.standard.set("Waiting for Apple device registration", forKey: "pushRegistrationStatus")
            return
        }
        let server = UserDefaults.standard.string(forKey: "serverURL") ?? "https://bryce-newswire.bryce-e19.workers.dev"
        guard let url = NewswireAPI.validatedURL(server) else {
            UserDefaults.standard.set("Sync failed: Configure a valid HTTPS server URL in Settings.", forKey: "pushServerStatus")
            return
        }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let store = PortfolioStore.shared
        let realItems = Set(store.items.filter { $0.environment == .production }.map(\.id))
        let symbols = Set(store.snapshot.positions.filter { realItems.contains($0.itemID) && $0.option == nil && $0.quantity != 0 }.map { $0.symbol.uppercased() }).sorted()
        do {
            try await NewswireAPI(baseURL: url).register(device: device, environment: environment, symbols: symbols, muted: AlertTopic.muted.sorted())
            UserDefaults.standard.set("Synced: \(symbols.count) held stocks", forKey: "pushServerStatus")
        }
        catch {
            UserDefaults.standard.set("Sync failed: \(error.localizedDescription)", forKey: "pushServerStatus")
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let symbol = info["symbol"] as? String,
           let link = URL(string: "newswire://quote/" + symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) {
            completionHandler()
            Task { await UIApplication.shared.open(link) }
            return
        }
        let id = info["id"] as? String
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let feed = FeedMode(rawValue: info["feed"] as? String ?? "") ?? .wire
        completionHandler()
        Task { await FeedStore.shared.open(storyID: id, feed: feed, fallback: url) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        let before = FeedStore.shared.stories.first?.id
        await FeedStore.shared.backgroundRefresh()
        return FeedStore.shared.stories.first?.id == before ? .noData : .newData
    }
}
