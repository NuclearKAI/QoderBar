import Foundation
import UserNotifications

/// 通知发送封装：在非 .app bundle 环境（如 swift run）下静默跳过，避免异常。
final class BudgetNotificationCenter {
    static let shared = BudgetNotificationCenter()
    private var authorized: Bool?

    private init() {}

    func requestAuthorizationIfNeeded(completion: ((Bool) -> Void)? = nil) {
        guard Bundle.main.bundleIdentifier != nil else {
            completion?(false)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                self.authorized = granted
                completion?(granted)
            }
        }
    }

    func send(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
        if authorized == true {
            deliver()
        } else {
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    self.authorized = granted
                    if granted { deliver() }
                }
            }
        }
    }
}
