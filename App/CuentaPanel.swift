import SwiftUI
import UIKit
import WebKit

struct Account: Codable, Identifiable {
    let id: UUID
    var name: String
    let tint: Int

    init(_ name: String, tint: Int) {
        self.id = UUID()
        self.name = name
        self.tint = tint
    }

    var color: Color {
        let colors: [Color] = [.teal, .blue, .indigo, .orange, .pink, .purple]
        return colors[tint % colors.count]
    }
}

@main
struct CuentaPanelApp: App {
    var body: some Scene {
        WindowGroup { Panel() }
    }
}

@MainActor
final class Profiles: ObservableObject {
    @Published private(set) var accounts: [Account]
    @Published var selection: UUID? {
        didSet { UserDefaults.standard.set(selection?.uuidString, forKey: "selectedAccount") }
    }
    private var sessions: [UUID: ChatController] = [:]

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "accounts")
            .flatMap { try? JSONDecoder().decode([Account].self, from: $0) }
        let initial = saved ?? [
            Account("Personal", tint: 0), Account("Escuela", tint: 1), Account("Berea", tint: 2)
        ]
        accounts = initial
        let previous = defaults.string(forKey: "selectedAccount").flatMap { UUID(uuidString: $0) }
        selection = initial.first(where: { $0.id == previous })?.id ?? initial.first?.id
        persist()
    }

    func save(_ name: String, editing id: UUID?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let id, let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].name = trimmed
        } else {
            let account = Account(trimmed, tint: accounts.count)
            accounts.append(account)
            selection = account.id
        }
        persist()
    }

    func controller(for id: UUID) -> ChatController {
        if let existing = sessions[id] { return existing }
        let controller = ChatController(profile: id)
        sessions[id] = controller
        return controller
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: "accounts")
        }
    }
}

struct AccountEditor: Identifiable {
    let id = UUID()
    var account: Account?
}

@MainActor
struct Panel: View {
    @StateObject private var profiles = Profiles()
    @State private var editor: AccountEditor?

    var body: some View {
        NavigationSplitView {
            List(selection: $profiles.selection) {
                Section("Cuentas") {
                    ForEach(profiles.accounts) { account in
                        NavigationLink(value: account.id) {
                            Label {
                                Text(account.name)
                            } icon: {
                                Image(systemName: "person.crop.circle.fill")
                                    .foregroundStyle(account.color)
                            }
                        }
                        .contextMenu {
                            Button("Cambiar nombre", systemImage: "pencil") {
                                editor = AccountEditor(account: account)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("WhatsApps")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .toolbar {
                Button("Añadir cuenta", systemImage: "plus") { editor = AccountEditor() }
            }
        } detail: {
            if let account = profiles.accounts.first(where: { $0.id == profiles.selection }) {
                let controller = profiles.controller(for: account.id)
                ChatSurface(controller: controller)
                    .id(account.id)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .navigationTitle(account.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        Button("Recargar WhatsApp", systemImage: "arrow.clockwise") {
                            controller.loadWhatsApp()
                        }
                        Button("Cambiar nombre", systemImage: "pencil") {
                            editor = AccountEditor(account: account)
                        }
                    }
            } else {
                ContentUnavailableView("Selecciona una cuenta", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $editor) { item in
            ProfileForm(name: item.account?.name ?? "", editing: item.account != nil) { name in
                profiles.save(name, editing: item.account?.id)
            }
        }
    }
}

struct ProfileForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var name: String
    let editing: Bool
    let save: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nombre de la cuenta", text: $name)
                if !editing {
                    Text("Usa Dispositivos vinculados en el teléfono de esta cuenta para escanear el código QR.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(editing ? "Cambiar nombre" : "Añadir cuenta")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save(name); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct ChatSurface: UIViewControllerRepresentable {
    let controller: ChatController
    func makeUIViewController(context: Context) -> ChatController { controller }
    func updateUIViewController(_ uiViewController: ChatController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: ChatController, coordinator: ()) {
        uiViewController.view.endEditing(true)
    }
}

final class ChatController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private static let address = URL(string: "https://web.whatsapp.com/")!
    private let webView: WKWebView
    private let activity = UIActivityIndicatorView(style: .medium)
    private var activeNavigation: WKNavigation?
    private let status = UILabel()
    private var externalLink: URL?
    private var linkPromptVisible = false
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var needsReload = false

    init(profile: UUID) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile)
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(profile:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        view.keyboardLayoutGuide.followsUndockedKeyboard = false

        status.numberOfLines = 0
        status.textAlignment = .center
        status.textColor = .secondaryLabel
        status.backgroundColor = .systemBackground
        activity.hidesWhenStopped = true

        for subview in [webView, status, activity] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            status.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            activity.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activity.topAnchor.constraint(equalTo: view.topAnchor, constant: 10)
        ])
        loadWhatsApp()
    }

    func loadWhatsApp() {
        guard isViewLoaded else { return }
        needsReload = false
        status.isHidden = true
        activity.startAnimating()
        activeNavigation = webView.load(URLRequest(url: Self.address))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation == activeNavigation else { return }
        activity.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(navigation, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(navigation, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        needsReload = true
        if view.window != nil { loadWhatsApp() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if needsReload || (webView.url == nil && !webView.isLoading && status.isHidden) {
            loadWhatsApp()
        }
    }

    private func showFailure(_ navigation: WKNavigation?, _ error: Error) {
        guard navigation == activeNavigation else { return }
        activity.stopAnimating()
        let failure = error as NSError
        guard failure.domain != NSURLErrorDomain || failure.code != NSURLErrorCancelled else { return }
        status.text = "No se pudo cargar WhatsApp Web. Revisa la conexión y toca Recargar WhatsApp."
        status.isHidden = false
    }

    private func isWhatsAppWeb(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == Self.address.host
    }

    private func confirmExternalLink(_ url: URL) {
        guard !linkPromptVisible, presentedViewController == nil,
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        externalLink = url
        linkPromptVisible = true
        let alert = UIAlertController(title: "Abrir enlace en el navegador",
                                      message: url.host,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { [weak self] _ in
            self?.externalLink = nil
            self?.linkPromptVisible = false
        })
        alert.addAction(UIAlertAction(title: "Abrir", style: .default) { [weak self] _ in
            if let url = self?.externalLink { UIApplication.shared.open(url) }
            self?.externalLink = nil
            self?.linkPromptVisible = false
        })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel, preferences); return }
        if action.shouldPerformDownload && (isWhatsAppWeb(url) || url.scheme == "blob") {
            decisionHandler(.download, preferences)
        } else if action.targetFrame?.isMainFrame == false || isWhatsAppWeb(url) {
            decisionHandler(.allow, preferences)
        } else {
            decisionHandler(.cancel, preferences)
            if action.navigationType == .linkActivated { confirmExternalLink(url) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        decisionHandler(!response.canShowMIMEType || disposition.hasPrefix("attachment") ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileName = (suggestedFilename as NSString).lastPathComponent
        guard !fileName.isEmpty, ![".", "..", "/"].contains(fileName) else {
            completionHandler(nil)
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(fileName)
            downloads[ObjectIdentifier(download)] = url
            completionHandler(url)
        } catch {
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        guard view.window != nil, presentedViewController == nil else {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let url = downloads.removeValue(forKey: ObjectIdentifier(download)) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        guard view.window != nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Falló la descarga",
                                      message: "Vuelve a descargar el archivo desde el chat.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Aceptar", style: .default))
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard action.targetFrame == nil, let url = action.request.url else { return nil }
        if isWhatsAppWeb(url) {
            activeNavigation = webView.load(action.request)
        } else if action.navigationType == .linkActivated {
            confirmExternalLink(url)
        }
        return nil
    }
}
