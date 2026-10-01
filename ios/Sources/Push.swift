import SwiftUI
import UserNotifications

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        FeedStore.registerProcessing()
        FeedStore.scheduleRefresh()
        FeedStore.scheduleProcessing()
        Task {
            guard (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let device = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(device, forKey: "pushDevice")
        Task { await Self.syncStockAlerts() }
    }

    static func syncStockAlerts() async {
        guard let device = UserDefaults.standard.string(forKey: "pushDevice") else { return }
        let server = UserDefaults.standard.string(forKey: "serverURL") ?? "https://bryce-newswire.bryce-e19.workers.dev"
        guard let url = NewswireAPI.validatedURL(server) else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let store = PortfolioStore.shared
        let realItems = Set(store.items.filter { $0.environment == .production }.map(\.id))
        let symbols = Set(store.snapshot.positions.filter { realItems.contains($0.itemID) && $0.option == nil && $0.quantity != 0 }.map { $0.symbol.uppercased() }).sorted()
        do {
            try await NewswireAPI(baseURL: url).register(device: device, environment: environment, symbols: symbols)
            UserDefaults.standard.set("Monitoring \(symbols.count) held stocks", forKey: "stockAlertStatus")
        }
        catch {
            UserDefaults.standard.set("Registration failed: \(error.localizedDescription)", forKey: "stockAlertStatus")
            store.error = "Stock alerts could not sync. \(error.localizedDescription)"
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
