import Foundation
import HandyOperators

public struct APISession: Codable {
	/// Only present for sessions signed into with a username & password, not for ones from Riot's sign-in page.
	public let credentials: Credentials?
	var accessToken: AccessToken
	var entitlementsToken: String
	var cookies: [Cookie]
	public let location: Location
	public let userID: User.ID
	/// Set to true when the session realizes it has expired unrecoverably (requiring the user to sign in again).
	public internal(set) var hasExpired = false
	
#if DEBUG
	/// A mocked session with bogus data, for testing.
	public static let mocked = Self(
		credentials: .init(),
		accessToken: .init(type: "", token: "", idToken: "", expiration: .distantFuture),
		entitlementsToken: "",
		cookies: [],
		location: .europe,
		userID: .init()
	)
#endif
}

struct Cookie: Hashable {
	var httpCookie: HTTPCookie
	var name: String { httpCookie.name }
}

extension Cookie: Codable {
	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		
		// backwards compatibility with existing cookies, for now
		do {
			let old = try container.decode(OldCookie.self)
			self.httpCookie = old.httpCookie
			return
		} catch {}
		
		let raw = try container.decode(Data.self)
		
		guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [HTTPCookie.self], from: raw) else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid cookie data")
		}
		self.httpCookie = decoded as! HTTPCookie
	}
	
	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		let raw = try NSKeyedArchiver.archivedData(
			withRootObject: httpCookie,
			requiringSecureCoding: false
		)
		try container.encode(raw)
	}
	
	private struct OldCookie: Codable, Hashable {
		var name: String
		var value: String
		var domain: String
		var path: String
		
		init(_ httpCookie: HTTPCookie) {
			name = httpCookie.name
			value = httpCookie.value
			domain = httpCookie.domain
			path = httpCookie.path
		}
		
		var httpCookie: HTTPCookie {
			.init(properties: [
				.name: name,
				.value: value,
				.domain: domain,
				.path: path,
			])!
		}
	}
}

struct AccessToken: Codable, Hashable {
	var type: String
	var token: String
	var idToken: String
	var expiration: Date
	
	var encoded: String {
		"\(type) \(token)"
	}
	
	var hasExpired: Bool {
		expiration < .now
	}
}

extension APISession {
	public init(
		credentials: Credentials,
		withCookiesFrom other: APISession? = nil,
		urlSessionOverride: URLSession? = nil,
		multifactorHandler: @escaping MultifactorHandler
	) async throws {
		let client = await AuthClient(urlSessionOverride: urlSessionOverride)
		if let other {
			client.setCookies(other.cookies.map(\.httpCookie))
		}

		try await self.init(
			credentials: credentials,
			accessToken: client.getAccessToken(loginBehavior: .allow(credentials, multifactorHandler)),
			client: client
		)
	}

	/// Sets up a session for someone who signed in on Riot's own sign-in page (``signInPageURL``), e.g. in a web view.
	///
	/// - Parameters:
	///   - signInRedirect: The URL the sign-in page redirected to once done, i.e. the first one ``isSignInRedirect(_:)`` recognizes.
	///   - cookies: The cookies set during sign-in, which keep the session going after the access token expires.
	public init(
		signInRedirect: URL,
		cookies: [HTTPCookie],
		urlSessionOverride: URLSession? = nil
	) async throws {
		let client = await AuthClient(urlSessionOverride: urlSessionOverride)
		client.setCookies(cookies)

		try await self.init(
			credentials: nil,
			accessToken: signInRedirect.extractAccessToken(),
			client: client
		)
	}

	private init(credentials: Credentials?, accessToken: AccessToken, client: AuthClient) async throws {
		self.credentials = credentials
		self.accessToken = accessToken

		let client = client <- { $0.accessToken = accessToken }

		// parallelization!
		async let entitlement = client.getEntitlementsToken()
		async let userID = client.getUserID()
		async let location = client.getLocation(using: accessToken)
		self.entitlementsToken = try await entitlement
		self.userID = try await userID
		self.location = try await location

		self.cookies = client.cookies().map(Cookie.init)
	}

	mutating func refreshAccessToken(multifactorHandler: MultifactorHandler?) async throws {
		let client = await AuthClient()
		client.setCookies(cookies.map(\.httpCookie))
		let loginBehavior: AuthClient.LoginBehavior
		if let credentials, let multifactorHandler {
			loginBehavior = .allow(credentials, multifactorHandler)
		} else {
			loginBehavior = .disallow
		}
		accessToken = try await client.getAccessToken(loginBehavior: loginBehavior)

		cookies = client.cookies().map(Cookie.init)
	}
}
