import XCTest
@testable import MackyCore

final class MCPOAuthTests: XCTestCase {
    func testDiscoveryURLs() {
        let mcpURL = URL(string: "https://flowts.lovable.app/mcp")!
        XCTAssertEqual(MCPOAuth.protectedResourceMetadataURLs(mcpURL: mcpURL, wwwAuthenticateHeader: nil).map(\.absoluteString), [
            "https://flowts.lovable.app/.well-known/oauth-protected-resource/mcp",
            "https://flowts.lovable.app/.well-known/oauth-protected-resource"
        ])
        let header = #"Bearer error="invalid_token", resource_metadata="https://flowts.lovable.app/.well-known/oauth-protected-resource""#
        XCTAssertEqual(MCPOAuth.protectedResourceMetadataURLs(mcpURL: mcpURL, wwwAuthenticateHeader: header).first?.absoluteString,
                       "https://flowts.lovable.app/.well-known/oauth-protected-resource")
        XCTAssertEqual(MCPOAuth.authorizationServerMetadataURLs(issuer: "https://abc.supabase.co/auth/v1").map(\.absoluteString), [
            "https://abc.supabase.co/.well-known/oauth-authorization-server/auth/v1",
            "https://abc.supabase.co/auth/v1/.well-known/oauth-authorization-server",
            "https://abc.supabase.co/.well-known/openid-configuration/auth/v1",
            "https://abc.supabase.co/auth/v1/.well-known/openid-configuration"
        ])
        XCTAssertEqual(MCPOAuth.authorizationServerMetadataURLs(issuer: "https://auth.example.com/").first?.absoluteString,
                       "https://auth.example.com/.well-known/oauth-authorization-server")
    }

    func testMetadataRegistrationAndURLs() throws {
        XCTAssertEqual(MCPOAuth.authorizationServer(fromProtectedResourceMetadata: Data(#"{"resource":"x","authorization_servers":["https://a.b/auth/v1"]}"#.utf8)), "https://a.b/auth/v1")
        let metadata = try XCTUnwrap(MCPOAuth.parseAuthorizationServerMetadata(Data(#"{"issuer":"i","authorization_endpoint":"https://a.b/authorize?x=1","token_endpoint":"https://a.b/token","registration_endpoint":"https://a.b/register"}"#.utf8)))
        XCTAssertEqual(metadata.registrationEndpoint, "https://a.b/register")
        XCTAssertEqual(MCPOAuth.scope(for: metadata), "openid email profile")
        let url = try XCTUnwrap(MCPOAuth.authorizationURL(metadata: metadata, clientIdentifier: "c1", redirectURI: "http://localhost:5000/callback", codeChallenge: "ch", state: "st"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first?.name, "x")
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        let registration = try JSONSerialization.jsonObject(with: MCPOAuth.registrationRequestBody(redirectURI: "http://localhost:5000/callback")) as! [String: Any]
        XCTAssertEqual(registration["token_endpoint_auth_method"] as? String, "none")
        XCTAssertEqual(MCPOAuth.parseClientIdentifier(fromRegistrationResponse: Data(#"{"client_id":"abc"}"#.utf8)), "abc")
        let body = String(decoding: MCPOAuth.refreshRequestBody(clientIdentifier: "c1", refreshToken: "r/1"), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=refresh_token&client_id=c1&refresh_token=r%2F1")
        XCTAssertEqual(GoogleOAuth.parseCallback(requestText: "GET /callback?code=AB&state=st HTTP/1.1\r\n")?.code, "AB")
    }

    func testCredentialsRefresh() {
        let now = Date(timeIntervalSince1970: 1000)
        let credentials = MCPOAuth.StoredCredentials(clientIdentifier: "c", tokenEndpoint: "t", accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(30))
        XCTAssertTrue(credentials.isExpired(now: now))
        let refreshed = credentials.updated(with: GoogleOAuth.Tokens(accessToken: "a2", refreshToken: nil, expiresInSeconds: 3600), now: now)
        XCTAssertEqual(refreshed.refreshToken, "r")
        XCTAssertEqual(refreshed.accessToken, "a2")
        XCTAssertFalse(refreshed.isExpired(now: now))
    }
}
