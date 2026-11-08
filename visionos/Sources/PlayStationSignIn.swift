// SPDX-License-Identifier: AGPL-3.0-only
// Account-ID flow adapted from upstream gui/src/psnaccountid.cpp.
import Foundation
import SwiftUI
import WebKit

struct PlayStationSignIn: View {
    let onComplete: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var exchanging = false
    @State private var state = UUID().uuidString
    private var authorizationURL: URL {
        var components = URLComponents(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize")!
        components.queryItems = [URLQueryItem(name: "service_entity", value: "urn:service-entity:psn"),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: PSNEndpoints.clientID),
            URLQueryItem(name: "redirect_uri", value: PSNEndpoints.redirect),
            URLQueryItem(name: "scope", value: "psn:clientapp"), URLQueryItem(name: "request_locale", value: "en_US"),
            URLQueryItem(name: "ui", value: "pr"), URLQueryItem(name: "service_logo", value: "ps"),
            URLQueryItem(name: "layout_type", value: "popup"), URLQueryItem(name: "smcid", value: "remoteplay"),
            URLQueryItem(name: "prompt", value: "always"), URLQueryItem(name: "state", value: state)]
        return components.url!
    }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("PlayStation sign-in").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Sign in on Sony’s website to retrieve your account ID. This prototype saves the ID locally; your password stays with Sony.")
                .font(.callout).foregroundStyle(.secondary)
            if let error {
                ContentUnavailableView("Sign-in could not finish", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(error))
            } else if exchanging {
                ProgressView("Linking your account…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SonySignInWebView(url: authorizationURL) { url in
                    guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          parts.queryItems?.first(where: { $0.name == "state" })?.value == state,
                          let code = parts.queryItems?.first(where: { $0.name == "code" })?.value else {
                        error = "Sony did not return a valid sign-in response. Close this window and try again."
                        return
                    }
                    exchanging = true
                    Task {
                        do { let id = try await PSNAccountLookup.accountID(code: code); onComplete(id); dismiss() }
                        catch { self.error = "The account ID could not be retrieved. You can also enter an existing account ID under Advanced."; exchanging = false }
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }.padding(24).frame(width: 650, height: 740)
    }
}
private struct SonySignInWebView: UIViewRepresentable {
    let url: URL
    let onRedirect: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onRedirect: onRedirect) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onRedirect: (URL) -> Void
        private var completed = false
        init(onRedirect: @escaping (URL) -> Void) { self.onRedirect = onRedirect }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.scheme == "https",
               url.host == "remoteplay.dl.playstation.net", url.path == "/remoteplay/redirect" {
                decisionHandler(.cancel)
                if !completed { completed = true; onRedirect(url) }
            } else { decisionHandler(.allow) }
        }
    }
}
private enum PSNAccountLookup {
    static func accountID(code: String) async throws -> Data {
        let tokenURL = URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        let basic = Data("\(PSNEndpoints.clientID):\(PSNEndpoints.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code), URLQueryItem(name: "scope", value: "psn:clientapp"),
            URLQueryItem(name: "redirect_uri", value: PSNEndpoints.redirect)]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String else { throw LookupError.failed }
        var inspection = URLRequest(url: tokenURL.appendingPathComponent(token))
        inspection.timeoutInterval = 30
        inspection.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        let (accountData, accountResponse) = try await URLSession.shared.data(for: inspection)
        guard (accountResponse as? HTTPURLResponse)?.statusCode == 200,
              let details = try JSONSerialization.jsonObject(with: accountData) as? [String: Any],
              let text = details["user_id"] as? String, let numeric = UInt64(text) else { throw LookupError.failed }
        var little = numeric.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }
    enum LookupError: Error { case failed }
}
