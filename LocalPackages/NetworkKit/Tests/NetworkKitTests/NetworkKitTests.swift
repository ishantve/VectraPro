//
//  NetworkKitTests.swift
//  NetworkKit
//
//  Exercises the client end-to-end against a stubbed URLProtocol.
//

import XCTest
@testable import NetworkKit

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class NetworkKitTests: XCTestCase {

    private struct Item: Codable, Equatable { let id: Int; let name: String }
    private struct Route: APIEndpoint { let path: String; let method: HTTPMethod }

    private func makeClient() -> APIManager {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = APIManager(session: URLSession(configuration: config))
        client.baseURL = URL(string: "https://example.com/api")
        return client
    }

    func testGetResolvesURLAndDecodes() async throws {
        let client = makeClient()
        let item = Item(id: 1, name: "Alpha")
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/api/items/1"))
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(item))
        }
        let got: Item = try await client.get("/items/1")
        XCTAssertEqual(got, item)
    }

    func testNon2xxThrowsUnacceptableStatusWithCode() async {
        let client = makeClient()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data("not found".utf8))
        }
        do {
            let _: Item = try await client.get("/missing")
            XCTFail("expected a thrown error")
        } catch let APIError.unacceptableStatus(code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testEndpointRequestUsesPathAndMethod() async throws {
        let client = makeClient()
        let item = Item(id: 7, name: "Route")
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.contains("/things"))
            XCTAssertEqual(req.httpMethod, "GET")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONEncoder().encode(item))
        }
        let got: Item = try await client.request(Route(path: "/things", method: .get))
        XCTAssertEqual(got, item)
    }

    func testDefaultHeaderSetAndRemove() {
        let client = makeClient()
        client.setDefaultHeader("value", forKey: "X-Test")
        XCTAssertEqual(client.defaultHeaders["X-Test"], "value")
        client.removeDefaultHeader(forKey: "X-Test")
        XCTAssertNil(client.defaultHeaders["X-Test"])
    }
}
