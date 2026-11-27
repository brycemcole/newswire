import BackgroundTasks
import UIKit
import UserNotifications

/// Keeps an Ask answer running after the reader leaves the app. The system shows its own progress card with a cancel button.
@MainActor final class AskBackgroundTask {
    private static let prefix = "com.brycecole.newswire.ask"
    private let title: String
    private let onExpire: @MainActor () -> Void
    private var task: BGContinuedProcessingTask?
    private var completed: Int64 = 0
    private var subtitle: String
    private var result: Bool?

    init(question: String, research: Bool, onExpire: @escaping @MainActor () -> Void) {
        title = research ? "Researching" : "Answering"
        subtitle = String(question.prefix(80))
        self.onExpire = onExpire
        let id = "\(Self.prefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in
                guard let self, let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                self.began(task)
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    private func began(_ task: BGContinuedProcessingTask) {
        if let result { task.setTaskCompleted(success: result); return }
        self.task = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = completed
        task.updateTitle(title, subtitle: subtitle)
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.onExpire() }
        }
    }

    func update(_ status: String) {
        completed = min(completed + 8, 90)
        subtitle = status
        task?.progress.completedUnitCount = completed
        task?.updateTitle(title, subtitle: status)
    }

    func finish(answer: String?) {
        guard result == nil else { return }
        result = answer != nil
        if let task {
            if answer != nil { task.progress.completedUnitCount = 100 }
            task.setTaskCompleted(success: answer != nil)
            self.task = nil
        }
        guard let answer, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your answer is ready"
        content.body = Self.preview(answer)
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ask-answer-\(UUID().uuidString)", content: content, trigger: nil))
    }

    private static func preview(_ answer: String) -> String {
        let line = answer.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(line.replacing(/\*\*|\[\d{1,2}\]/, with: "").trimmingCharacters(in: .whitespaces).prefix(160))
    }
}
