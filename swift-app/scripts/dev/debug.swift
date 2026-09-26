import Foundation
import CNSCore

let oldTerms: [JSONValue] = []
let newTerms: [JSONValue] = [.object(JSONObject([("term", .string("SwiftUI"))]))]
print(oldTerms != newTerms)
