// The one-time download link as a QR code, drawn by Core Image (DESIGN §20.1: the TypeScript QR
// encoder is dropped). Modules stay sharp: the image is made at one pixel per module and scaled
// without interpolation by the view.
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum QRCode {
  /// One pixel per module, with Core Image's quiet zone; nil if the text can't be encoded.
  public static func image(_ text: String, correction: String = "M") -> CGImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(text.utf8)
    f.correctionLevel = correction
    guard let out = f.outputImage else { return nil }
    return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(out, from: out.extent)
  }
}
