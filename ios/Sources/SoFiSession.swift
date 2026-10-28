import Observation
import WebKit
import UIKit

nonisolated struct SoFiWebHolding: Identifiable, Equatable {
    let id: String
    let symbol: String
    let quantity: Double
    let price: Double?
    let value: Double?
}

nonisolated struct SoFiPage: Decodable {
    struct Table: Decodable {
        let headers: [String]
        let rows: [[String]]
    }
    let login: Bool
    let tables: [Table]

    var holdings: [SoFiWebHolding] {
        var result: [SoFiWebHolding] = []
        for (tableIndex, table) in tables.prefix(15).enumerated() {
            let headers = table.headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard let symbolIndex = headers.firstIndex(of: "symbol"),
                  let quantityIndex = headers.firstIndex(where: { ["quantity", "shares", "contracts"].contains($0) }) else { continue }
            let priceIndex = headers.firstIndex(where: { ["price", "current price", "market price"].contains($0) })
            let valueIndex = headers.firstIndex(where: { ["market value", "current value"].contains($0) })
            for (rowIndex, row) in table.rows.prefix(250).enumerated() {
                guard row.count == headers.count,
                      let quantity = Self.number(row[quantityIndex]), quantity != 0 else { continue }
                let symbol = row[symbolIndex].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                guard SoFiTrail.validSymbol(symbol) else { continue }
                // An option row must identify the entire contract, never just its underlying.
                let optionRow = headers[quantityIndex] == "contracts" || row.contains {
                    $0.range(of: #"\b(option|call|put)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                }
                if optionRow && OptionSymbol(symbol) == nil { continue }
                result.append(SoFiWebHolding(id: "\(tableIndex):\(rowIndex):\(symbol)", symbol: symbol, quantity: quantity,
                    price: priceIndex.flatMap { Self.number(row[$0]) }, value: valueIndex.flatMap { Self.number(row[$0]) }))
            }
        }
        return result
    }

    private static func number(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^-?\$?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let number = Double(value.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")),
              number.isFinite else { return nil }
        return number
    }
}

@Observable final class SoFiSession: NSObject, WKNavigationDelegate {
    static let shared = SoFiSession()
    static let profileID = UUID(uuidString: "086F2D29-472F-4FB7-84A6-5C790E653F92")!
    static let dashboard = URL(string: "https://www.sofi.com/dashboard/")!

    enum Status: String {
        case disconnected = "Not connected"
        case checking = "Checking saved session…"
        case signIn = "Sign-in required"
        case unrecognized = "Portfolio page not recognized"
        case available = "Holdings read from SoFi"
        case failed = "Connection needs attention"
        case paused = "Session checks paused"
    }

    private(set) var enabled: Bool
    private(set) var status: Status = .disconnected
    private(set) var holdings: [SoFiWebHolding] = []
    private(set) var readAt: Date?
    private(set) var message: String?
    private(set) var clearing = false
    var browserPresented = false
    @ObservationIgnored private var browser: WKWebView?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var activeRun = UUID()
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "sofiWebEnabled")
        super.init()
        if enabled { status = .paused }
    }

    var webView: WKWebView {
        if let browser { return browser }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.profileID)
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        browser = view
        return view
    }

    nonisolated static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "sofi.com" || host.hasSuffix(".sofi.com")
    }

    nonisolated static func isPortfolio(_ url: URL) -> Bool {
        allows(url) && ["www.sofi.com", "sofi.com"].contains(url.host?.lowercased() ?? "")
            && (url.path.hasPrefix("/wealth/") || url.path.hasPrefix("/invest/"))
    }

    var resumeURL: URL {
        guard let raw = defaults.string(forKey: "sofiPortfolioPath"), let url = URL(string: raw),
              Self.isPortfolio(url), url.query == nil, url.fragment == nil else { return Self.dashboard }
        return url
    }

    func connect() {
        guard !clearing else { return }
        enabled = true
        defaults.set(true, forKey: "sofiWebEnabled")
        if browser?.url == nil || status == .failed || status == .paused { refresh() }
        browserPresented = true
    }

    func refresh() {
        guard enabled, !clearing, browser?.isLoading != true else { return }
        generation = UUID()
        readTask?.cancel()
        status = .checking
        message = nil
        lastAttempt = .now
        webView.load(URLRequest(url: resumeURL))
    }

    func rememberPortfolioPage() {
        guard let url = browser?.url, Self.isPortfolio(url), status == .available,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        components.query = nil
        components.fragment = nil
        defaults.set(components.url?.absoluteString, forKey: "sofiPortfolioPath")
        message = "This portfolio path will reopen with your saved session. You may need to select the account again."
    }

    func suspend() {
        generation = UUID()
        readTask?.cancel()
        browser?.stopLoading()
        if enabled { status = .paused }
    }

    func runWhileActive() async {
        #if DEBUG
        if CommandLine.arguments.contains("-sofiPreview") { return }
        #endif
        let run = UUID()
        activeRun = run
        defer { if activeRun == run { suspend() } }
        while !Task.isCancelled && UIApplication.shared.applicationState == .active {
            if enabled && !browserPresented && !clearing {
                if status == .paused || lastAttempt == nil || Date.now.timeIntervalSince(lastAttempt!) >= 300 { refresh() }
            }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    func disconnect() async {
        guard !clearing else { return }
        clearing = true
        enabled = false
        defaults.removeObject(forKey: "sofiWebEnabled")
        defaults.removeObject(forKey: "sofiPortfolioPath")
        suspend()
        browserPresented = false
        let store = browser?.configuration.websiteDataStore ?? WKWebsiteDataStore(forIdentifier: Self.profileID)
        browser?.navigationDelegate = nil
        browser = nil
        holdings = []
        readAt = nil
        message = nil
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        status = .disconnected
        clearing = false
    }

    func readPage() async {
        guard enabled, !clearing, UIApplication.shared.applicationState == .active,
              let browser, let url = browser.url, Self.allows(url) else { return }
        let token = generation
        do {
            let raw = try await browser.evaluateJavaScript(Self.captureScript, in: nil, contentWorld: .defaultClient)
            guard token == generation, enabled, browser.url == url, !Task.isCancelled,
                  let json = raw as? String, let data = json.data(using: .utf8) else { return }
            let page = try JSONDecoder().decode(SoFiPage.self, from: data)
            if page.login || url.host == "login.sofi.com" || url.path.hasPrefix("/login") {
                status = .signIn
                holdings = []
                readAt = nil
                message = "Open SoFi to sign in or complete verification."
            } else if Self.isPortfolio(url), !page.holdings.isEmpty {
                holdings = page.holdings
                readAt = .now
                status = .available
                message = nil
            } else {
                status = .unrecognized
                message = "Open your Invest holdings in SoFi. Native import supports labeled holdings tables; other layouts need verification."
            }
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            status = .failed
            message = "Could not read this page. Open SoFi and try again."
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        generation = UUID()
        readTask?.cancel()
        status = .checking
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard enabled, !clearing, UIApplication.shared.applicationState == .active else { return }
        readTask?.cancel()
        readTask = Task { [weak self] in
            for _ in 0..<4 {
                guard !Task.isCancelled else { return }
                await self?.readPage()
                if self?.status == .available || self?.status == .signIn { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        generation = UUID()
        readTask?.cancel()
        status = .failed
        message = "SoFi stopped loading. Reopen it to restore the saved session."
    }

    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        generation = UUID()
        readTask?.cancel()
        status = .failed
        message = "SoFi could not load. Check your connection and retry."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.targetFrame?.isMainFrame == false,
           navigationAction.request.url?.scheme == "https", enabled, !clearing { return .allow }
        guard let url = navigationAction.request.url, Self.allows(url), enabled, !clearing else {
            message = "This link could not open inside the SoFi connection."
            return .cancel
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            return .cancel
        }
        return .allow
    }

    static let captureScript = #"""
    (() => {
      const visible = e => e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
      const text = e => (e.innerText || '').trim().slice(0, 160);
      const login = [...document.querySelectorAll('input[type="password"]')].some(visible);
      const tables = [...document.querySelectorAll('table, [role="table"], [role="grid"]')].filter(visible).slice(0, 15).map(table => {
        const headers = [...table.querySelectorAll('thead th, [role="columnheader"]')].slice(0, 20).map(text);
        const rows = [...table.querySelectorAll('tbody tr, [role="row"]')].filter(visible).slice(0, 250).map(row =>
          [...row.querySelectorAll('td, [role="cell"], [role="gridcell"]')].slice(0, 20).map(text)
        ).filter(row => row.length === headers.length);
        return {headers, rows};
      });
      return JSON.stringify({login, tables});
    })()
    """#
}
