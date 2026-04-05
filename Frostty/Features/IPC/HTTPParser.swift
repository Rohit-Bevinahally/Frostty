import Foundation

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let statusMessage: String
    let headers: [String: String]
    let body: Data?

    func serialize() -> Data {
        var result = "HTTP/1.1 \(statusCode) \(statusMessage)\r\n"

        for (key, value) in headers {
            result += "\(key): \(value)\r\n"
        }

        let hasContentLength = headers.contains { $0.key.lowercased() == "content-length" }
        if !hasContentLength {
            result += "Content-Length: \(body?.count ?? 0)\r\n"
        }

        result += "\r\n"

        var data = Data(result.utf8)
        if let body {
            data.append(body)
        }
        return data
    }
}

enum HTTPParseError: Error, Equatable {
    case headerTooLarge
    case bodyTooLarge
    case invalidContentLength
    case malformedRequest
    case timeout
}

struct HTTPParser {
    static let maxHeaderSize = 8 * 1024
    static let maxBodySize = 1 * 1024 * 1024

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func parse(_ data: Data) throws -> HTTPRequest {
        guard let separatorRange = data.range(of: headerTerminator) else {
            if data.count > maxHeaderSize {
                throw HTTPParseError.headerTooLarge
            }
            throw HTTPParseError.malformedRequest
        }

        let headerEndIndex = separatorRange.lowerBound
        if headerEndIndex > maxHeaderSize {
            throw HTTPParseError.headerTooLarge
        }

        let headerData = data[data.startIndex..<headerEndIndex]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.malformedRequest
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw HTTPParseError.malformedRequest
        }

        let requestLineParts = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLineParts.count >= 2 else {
            throw HTTPParseError.malformedRequest
        }

        let method = String(requestLineParts[0])
        let path = String(requestLineParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colonIndex])
            let valueStart = line.index(after: colonIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLengthValue = headers.first { $0.key.lowercased() == "content-length" }?.value
        var body: Data?

        if let lengthString = contentLengthValue {
            guard let length = Int(lengthString), length >= 0 else {
                throw HTTPParseError.invalidContentLength
            }
            if length > maxBodySize {
                throw HTTPParseError.bodyTooLarge
            }

            if length > 0 {
                let bodyStart = separatorRange.upperBound
                if bodyStart < data.endIndex {
                    let available = data[bodyStart..<data.endIndex]
                    body = Data(available.prefix(length))
                }
            }
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    static func response(
        statusCode: Int,
        body: Data?,
        contentType: String = "application/json"
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            statusMessage: statusMessage(for: statusCode),
            headers: [
                "Content-Type": contentType,
                "Connection": "close",
                "Content-Length": "\(body?.count ?? 0)",
            ],
            body: body
        )
    }

    static func response(statusCode: Int, json: Any) -> HTTPResponse {
        let body = try? JSONSerialization.data(withJSONObject: json)
        return response(statusCode: statusCode, body: body, contentType: "application/json")
    }

    private static func statusMessage(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }
}
