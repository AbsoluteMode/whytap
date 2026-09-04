import Foundation

/// URLProtocol stub that records requests and serves canned responses.
/// One stub instance per test (shared via a stack of handlers).
final class StubURLProtocol: URLProtocol {
    /// Closure invoked for every intercepted request. Returns
    /// (statusCode, headers, body).
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    /// Captures every request seen during a test.
    static var capturedRequests: [URLRequest] = []
    /// Captures the request body (URLProtocol drops `httpBodyStream` after
    /// upload tasks consume it, so we read it here).
    static var capturedBodies: [Data] = []

    static func reset() {
        handler = nil
        capturedRequests = []
        capturedBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capturedRequests.append(request)
        if let stream = request.httpBodyStream {
            Self.capturedBodies.append(Self.drain(stream))
        } else if let body = request.httpBody {
            Self.capturedBodies.append(body)
        } else {
            Self.capturedBodies.append(Data())
        }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: bufferSize)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
