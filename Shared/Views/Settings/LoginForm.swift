import SwiftUI
import WebKit
import HandyOperators
import ValorantAPI

struct LoginForm: View {
	@ObservedObject var accountManager: AccountManager
	@State var isSigningIn = false
	/// changing this starts over with a fresh sign-in page
	@State var attempt = 0

	@Environment(\.loadWithErrorAlerts) private var load
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		ZStack {
			RiotSignInPage(onSignIn: signIn(redirect:cookies:))
				.id(attempt)
				.opacity(isSigningIn ? 0.25 : 1)
				.disabled(isSigningIn)

			if isSigningIn {
				ProgressView {
					Text("signing in…", comment: "Login Form")
				}
			}
		}
		.safeAreaInset(edge: .bottom) {
			Text("You're signing in on Riot's own page, so Recon Bolt never sees your password—just the session once you're done.", comment: "Login Form: shown below Riot's sign-in page")
				.font(.footnote)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding()
				.background(.bar)
		}
		.navigationTitle(Text("Sign In with your Riot account", comment: "Login Form"))
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItemGroup(placement: .cancellationAction) {
				Button { dismiss() } label: {
					Text("Cancel")
				}
			}
		}
		.withToolbar(allowLargeTitles: false)
	}

	@MainActor
	func signIn(redirect: URL, cookies: [HTTPCookie]) async {
		isSigningIn = true
		defer { isSigningIn = false }

		await load(errorTitle: Text("Could not sign in!", comment: "Login Form: error title")) {
			do {
				try await accountManager.addAccount(signInRedirect: redirect, cookies: cookies)
				dismiss()
			} catch {
				attempt += 1 // the sign-in page is spent at this point
				throw error
			}
		}
	}
}

/// Riot's sign-in page in a web view, which hands over the redirect it ends on (carrying the access token) instead of following it.
private struct RiotSignInPage: UIViewRepresentable {
	var onSignIn: (URL, [HTTPCookie]) async -> Void

	func makeCoordinator() -> Coordinator {
		.init(onSignIn: onSignIn)
	}

	func makeUIView(context: Context) -> WKWebView {
		let configuration = WKWebViewConfiguration() <- {
			// start from scratch every time, so adding another account doesn't just sign into the last one again
			$0.websiteDataStore = .nonPersistent()
		}
		return WKWebView(frame: .zero, configuration: configuration) <- {
			$0.navigationDelegate = context.coordinator
			$0.load(URLRequest(url: APISession.signInPageURL))
		}
	}

	func updateUIView(_ webView: WKWebView, context: Context) {
		context.coordinator.onSignIn = onSignIn
	}

	final class Coordinator: NSObject, WKNavigationDelegate {
		var onSignIn: (URL, [HTTPCookie]) async -> Void

		init(onSignIn: @escaping (URL, [HTTPCookie]) async -> Void) {
			self.onSignIn = onSignIn
		}

		func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
			guard let url = navigationAction.request.url, APISession.isSignInRedirect(url) else { return .allow }

			// these keep the session going once the access token expires
			let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
				.filter { $0.domain.hasSuffix("riotgames.com") }
			Task { [onSignIn] in await onSignIn(url, cookies) }
			return .cancel
		}
	}
}

#if DEBUG
struct LoginSheet_Previews: PreviewProvider {
	static var previews: some View {
		Group {
			LoginForm(accountManager: .mocked)
			LoginForm(accountManager: .mocked, isSigningIn: true)
		}
		.withLoadErrorAlerts()
		.previewLayout(.sizeThatFits)
	}
}
#endif
