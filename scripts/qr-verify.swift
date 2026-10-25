// Independent check of src/core/qr.ts with Apple's QR detector (CoreImage), macOS only.
// Input file: QR symbols as lines of '0'/'1' (1 = dark), symbols separated by a blank line.
// Output: first "CONTROL ok" or "CONTROL failed" (Apple's own generator decoded by Apple's
// detector: proves this environment can decode at all), then one line per symbol, the decoded
// text or "<none>". Used by test/qr.test.ts; offline, no network.
import CoreImage
import Foundation

let raw = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let symbols = raw.components(separatedBy: "\n\n").map { $0.split(separator: "\n").map(Array.init) }.filter { !$0.isEmpty }
let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!

// Positive control: a symbol made by CIQRCodeGenerator, rasterized like ours.
let controlText = "homebot control 12345"
var control = "failed"
if let gen = CIFilter(name: "CIQRCodeGenerator") {
  gen.setValue(controlText.data(using: .utf8), forKey: "inputMessage")
  gen.setValue("M", forKey: "inputCorrectionLevel")
  if let out = gen.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
     let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(out, from: out.extent) {
    let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    if found.first == controlText { control = "ok" }
  }
}
print("CONTROL \(control)")

for rows in symbols {
  let n = rows.count, scale = 8, quiet = 4
  let side = (n + 2 * quiet) * scale
  var pixels = [UInt8](repeating: 255, count: side * side)
  for (y, row) in rows.enumerated() {
    for (x, c) in row.enumerated() where c == "1" {
      for dy in 0..<scale {
        for dx in 0..<scale { pixels[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0 }
      }
    }
  }
  let provider = CGDataProvider(data: Data(pixels) as CFData)!
  let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
  print(found.first ?? "<none>")
}
