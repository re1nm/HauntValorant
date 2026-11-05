import Foundation
import Protoquest
import HandyOperators

struct AuthClient {
	let baseURL = BaseURLs.authAPI
	let urlSession: URLSession
	var accessToken: AccessToken?
	
	init(urlSessionOverride: URLSession? = nil) async {
		self.urlSession = urlSessionOverride ?? .init(configuration: .ephemeral)
	}
	
	func cookies() -> [HTTPCookie] {
		urlSession.configuration.httpCookieStorage!.cookies ?? []
	}
	
	func setCookies(_ cookies: [HTTPCookie]) {
		cookies.forEach(urlSession.configuration.httpCookieStorage!.setCookie(_:))
	}
	
	func clearCookies() {
		urlSession.configuration.httpCookieStorage!.removeCookies(since: .distantPast)
	}
	
	func addHeaders(to rawRequest: inout URLRequest) async {
		rawRequest.headers.authorization = accessToken?.encoded
	}
	
	func send<R: AuthRequest>(_ request: R) async throws -> R.Response {
		let urlRequest = try URLRequest(url: request.url(relativeTo: BaseURLs.authAPI)) <- request.configure
		
		let response = try await Protolayer.urlSession(urlSession)
			.transformRequest {
				$0.headers.authorization = accessToken?.encoded
			}
			.readResponse {
				if $0.httpMetadata?.statusCode == 403 {
					throw AuthDecodingError.accessDenied
				}
			}
			.send(urlRequest)
		
		return try request.decodeResponse(from: response)
	}

	/// Requests the given URL without following the redirect it responds with, returning where that redirect points instead.
	func redirectTarget(of url: URL) async throws -> URL? {
		let (_, response) = try await urlSession.data(from: url, delegate: RedirectStopper())
		guard let response = response as? HTTPURLResponse else { return nil }
		if response.statusCode == 403 {
			throw AuthDecodingError.accessDenied
		}
		return response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:))
	}
}

private final class RedirectStopper: NSObject, URLSessionTaskDelegate {
	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest
	) async -> URLRequest? {
		nil // hand back the redirect response itself
	}
}

protocol AuthRequest: Request {}

extension JSONEncodingRequest where Self: AuthRequest {
	var encoderOverride: JSONEncoder? { requestEncoder }
}

extension JSONDecodingRequest where Self: AuthRequest {
	var decoderOverride: JSONDecoder? { responseDecoder }
}

private let requestEncoder = JSONEncoder() <- {
	$0.keyEncodingStrategy = .convertToSnakeCase
}
private let responseDecoder = JSONDecoder() <- {
	$0.keyDecodingStrategy = .convertFromSnakeCase
}

private enum AuthDecodingError: Error, LocalizedError {
	case accessDenied
	
	var errorDescription: String? {
		"The authentication servers could not be reached! Are you using a VPN or cellular data?"
	}
}
