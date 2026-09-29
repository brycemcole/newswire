import SwiftUI
import UserNotifications

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        FeedStore.scheduleRefresh()
        Task {
            guard (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let device = deviceToken.map { String(format: "%02x", $0) }.joined()
        let server = UserDefaults.standard.string(forKey: "serverURL") ?? "https://bryce-newswire.bryce-e19.workers.dev"
        let token = ReaderKeychain.read()
        guard let url = NewswireAPI.validatedURL(server), !token.isEmpty else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        Task { try? await NewswireAPI(baseURL: url, token: token).register(device: device, environment: environment) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
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
