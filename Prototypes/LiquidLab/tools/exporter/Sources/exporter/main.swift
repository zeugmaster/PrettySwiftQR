import Foundation
import PrettyQRCore

// Writes the three test symbols the lab offers (URL v2, invoice v5, animated UR v11) as bit strings.
func bits(_ m: QRMatrix) -> String { m.modules.map { $0 ? "1" : "0" }.joined() }

var out: [String: Any] = [:]
let url = try QRMatrixEncoder.encode(text: "https://example.com", errorCorrection: .medium)
out["static"] = ["n": url.size, "frames": [bits(url)]]
let invoice = try QRMatrixEncoder.encode(text: "lightning:lnbc1u1pjexample0xyz9qrsgq7q8kz0f3n5y2w6a8d4c3v6b7n8m9", errorCorrection: .medium)
out["medium"] = ["n": invoice.size, "frames": [bits(invoice)]]
let encoder = try QRFrameEncoder(payload: .auto(String(repeating: "cashuAeyJ0b2tlbiI6W3sicHJvb2ZzIjpb", count: 40)))
var frames: [String] = []
var size = 0
for _ in 0..<6 { let frame = try encoder.nextFrame(); size = frame.size; frames.append(bits(frame)) }
out["animated"] = ["n": size, "frames": frames]
let r = QROutlineRadii.round
out["radii"] = [r.module, r.inner, r.finderOuter, r.finderInner, r.finderCenter]
let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: data)
print("wrote", CommandLine.arguments[1], url.size, invoice.size, size)
