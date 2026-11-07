import SwiftUI
import WebKit
import HandyOperators
import ValorantAPI

struct LoginForm: View {
	@ObservedObject var accountManager: AccountManager
	/// owned by whatever shows this, so it outlives SwiftUI rebuilding the sheet (see ``RiotSignInPage``)
	@ObservedObject var page: RiotSignInPage
	@State var isSigningIn = false

	@Environment(\.loadWithErrorAlerts) private var load
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		ZStack {
			SignInPageView(page: page, onSignIn: signIn(redirect:cookies:))
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
				page.startOver() // the sign-in page is spent at this point
				throw error
			}
		}
	}
}

/// Shows the sign-in sheet, keeping Riot's page around for as long as it's up.
///
/// The sheet hangs off the whole settings form rather than the account rows that start it: SwiftUI rebuilds form rows on a whim,
/// which would lose track of the sheet (it sometimes didn't even show up) or rebuild what's in it.
final class SignInPresenter: ObservableObject {
	/// what the sheet is for, if it's up
	@Published var target: AccountSettingsView.LoginTarget?
	private(set) var page: RiotSignInPage?

	func start(for target: AccountSettingsView.LoginTarget) {
		page?.close()
		page = .init() // a fresh page for every sign-in
		self.target = target
	}

	/// Lets go of the page once the sheet is gone.
	func close() {
		page?.close()
		page = nil
	}
}

extension View {
	func signInSheet(_ presenter: SignInPresenter, accountManager: AccountManager) -> some View {
		modifier(SignInSheetModifier(presenter: presenter, accountManager: accountManager))
	}
}

private struct SignInSheetModifier: ViewModifier {
	@ObservedObject var presenter: SignInPresenter
	var accountManager: AccountManager

	func body(content: Content) -> some View {
		content.sheet(item: $presenter.target, onDismiss: presenter.close) { _ in
			if let page = presenter.page {
				LoginForm(accountManager: accountManager, page: page)
					.withLoadErrorAlerts()
			}
		}
	}
}

/// Riot's sign-in page in a web view, which hands over the redirect it ends on (carrying the access token) instead of following it.
///
/// This lives apart from the views showing it, because SwiftUI rebuilds the sign-in sheet's contents now and then—
/// e.g. when the app goes to the background and back, like when confirming the sign-in on Riot Mobile.
/// A new web view would start the sign-in over from scratch, so whatever presents the sheet keeps this around for as long as it's up.
final class RiotSignInPage: NSObject, ObservableObject {
	@Published private(set) var webView: WKWebView
	/// gets the redirect the sign-in ends on, along with the cookies that keep the session going once the access token expires
	var onSignIn: ((URL, [HTTPCookie]) async -> Void)?

	override init() {
		webView = Self.makeWebView()
		super.init()
		load()
	}

	/// Replaces the page with a fresh one, e.g. once a sign-in attempt has used it up.
	func startOver() {
		webView = Self.makeWebView()
		load()
	}

	/// Lets go of everything once the sign-in sheet is gone.
	func close() {
		onSignIn = nil
		webView.stopLoading()
	}

	private func load() {
		webView.navigationDelegate = self
		webView.load(URLRequest(url: APISession.signInPageURL))
	}

	private static func makeWebView() -> WKWebView {
		let configuration = WKWebViewConfiguration() <- {
			// start from scratch every time, so adding another account doesn't just sign into the last one again
			$0.websiteDataStore = .nonPersistent()
		}
		return WKWebView(frame: .zero, configuration: configuration)
	}
}

extension RiotSignInPage: WKNavigationDelegate {
	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
		guard let url = navigationAction.request.url, APISession.isSignInRedirect(url) else { return .allow }

		// these keep the session going once the access token expires
		let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
			.filter { $0.domain.hasSuffix("riotgames.com") }
		Task { [onSignIn] in await onSignIn?(url, cookies) }
		return .cancel
	}
}

/// Shows the sign-in page's web view—the same one every time, taking it over from wherever it was shown before.
private struct SignInPageView: UIViewRepresentable {
	@ObservedObject var page: RiotSignInPage
	var onSignIn: (URL, [HTTPCookie]) async -> Void

	func makeUIView(context: Context) -> UIView {
		page.onSignIn = onSignIn
		return UIView() <- { show(page.webView, in: $0) }
	}

	func updateUIView(_ container: UIView, context: Context) {
		page.onSignIn = onSignIn
		// after starting over, there's a new web view to show
		if page.webView.superview == nil {
			show(page.webView, in: container)
		}
	}

	private func show(_ webView: WKWebView, in container: UIView) {
		container.subviews.forEach { $0.removeFromSuperview() }
		webView.frame = container.bounds
		webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		container.addSubview(webView) // this also takes it out of wherever it was before
	}
}

#if DEBUG
struct LoginSheet_Previews: PreviewProvider {
	static var previews: some View {
		Group {
			LoginForm(accountManager: .mocked, page: .init())
			LoginForm(accountManager: .mocked, page: .init(), isSigningIn: true)
		}
		.withLoadErrorAlerts()
		.previewLayout(.sizeThatFits)
	}
}
#endif
