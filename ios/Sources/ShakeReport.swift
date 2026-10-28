import PhotosUI
import SwiftUI
import UIKit

extension UIWindow {
    override open func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake else { return }
        ShakeReport.present(from: self)
    }
}

@MainActor enum ShakeReport {
    private static var presenting = false

    static func present(from window: UIWindow) {
        guard !presenting, var top = window.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        if top is UIHostingController<ShakeReportSheet> { return }
        let screen = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        presenting = true
        let host = UIHostingController(rootView: ShakeReportSheet(screen: screen) { presenting = false })
        host.sheetPresentationController?.detents = [.large()]
        top.present(host, animated: true)
    }
}

enum ReportKind: String, CaseIterable, Identifiable {
    case bug, feature
    var id: String { rawValue }
    var title: String { self == .bug ? "Bug" : "Feature" }
    var prompt: String { self == .bug ? "What went wrong? What did you expect?" : "What should it do?" }
}

struct ShakeReportSheet: View {
    let screen: UIImage
    let onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ReportKind.bug
    @State private var note = ""
    @State private var includeScreen = true
    @State private var picked: [PhotosPickerItem] = []
    @State private var extra: [UIImage] = []
    @State private var sending = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var images: [UIImage] { (includeScreen ? [screen] : []) + extra }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(ReportKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    TextField(kind.prompt, text: $note, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                }

                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            if includeScreen { thumbnail(screen) { includeScreen = false } }
                            ForEach(extra.indices, id: \.self) { index in
                                thumbnail(extra[index]) { extra.remove(at: index) }
                            }
                            if images.count < 4 {
                                PhotosPicker(selection: $picked, maxSelectionCount: 4 - images.count, matching: .screenshots) {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.quaternary)
                                        .frame(width: 72, height: 150)
                                        .overlay { Image(systemName: "plus").font(.title3).foregroundStyle(.secondary) }
                                }
                                .accessibilityLabel("Add screenshots")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                } header: {
                    Text("Screenshots")
                } footer: {
                    Text("Sent with the app version, iOS version and device model. A coding agent turns it into a draft pull request.")
                }

                if let failure {
                    Section { Text(failure).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else {
                        Button("Send") { Task { await send() } }
                            .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                picked = []
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), images.count < 4 {
                            extra.append(image)
                        }
                    }
                }
            }
            .onAppear { focused = true }
            .onDisappear(perform: onFinish)
            .interactiveDismissDisabled(sending)
        }
    }

    private func thumbnail(_ image: UIImage, remove: @escaping () -> Void) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 72, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.title3)
                }
                .padding(4)
                .accessibilityLabel("Remove screenshot")
            }
    }

    private func send() async {
        guard let url = NewswireAPI.validatedURL(FeedStore.shared.serverURL) else {
            failure = "Configure a valid HTTPS server URL in Settings."
            return
        }
        sending = true
        failure = nil
        let shots = images
        var body: [String: Any] = ["images": await Task.detached(priority: .userInitiated) { shots.compactMap(ShakeReportSheet.encode) }.value]
        body["kind"] = kind.rawValue
        body["note"] = note.trimmingCharacters(in: .whitespacesAndNewlines)
        body["context"] = Self.context
        if let device = UserDefaults.standard.string(forKey: "pushDevice") { body["device"] = device }
        do {
            try await NewswireAPI(baseURL: url).report(body)
            sending = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            sending = false
            failure = "Couldn't send: \(error.localizedDescription)"
        }
    }

    private static var context: [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return [
            "app": info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Newswire",
            "bundle": Bundle.main.bundleIdentifier ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "os": "iOS \(UIDevice.current.systemVersion)",
            "model": model,
            "reported_at": ISO8601DateFormatter().string(from: .now),
        ]
    }

    nonisolated private static func encode(_ image: UIImage) -> String? {
        let longest: CGFloat = 1600
        let size = image.size
        let scale = min(1, longest / max(size.width * image.scale, size.height * image.scale))
        let target = CGSize(width: size.width * image.scale * scale, height: size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        var quality: CGFloat = 0.7
        while quality > 0.2 {
            if let data = resized.jpegData(compressionQuality: quality), data.count < 1_000_000 { return data.base64EncodedString() }
            quality -= 0.15
        }
        return nil
    }
}

extension NewswireAPI {
    func report(_ body: [String: Any]) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/feedback"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw WireError.status(response.statusCode) }
    }
}
