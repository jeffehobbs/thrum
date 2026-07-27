import PDFKit
import AppKit

// Rasterizes each page of a PDF to PNG so the layout can be eyeballed.
//   pdfpng <in.pdf> <outdir> [scale]
let a = CommandLine.arguments
guard a.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: a[1])) else {
    print("usage: pdfpng <in.pdf> <outdir> [scale]"); exit(1)
}
let scale = a.count > 3 ? (Double(a[3]) ?? 1.5) : 1.5
print("pages: \(doc.pageCount)")
for i in 0..<doc.pageCount {
    guard let page = doc.page(at: i) else { continue }
    let box = page.bounds(for: .mediaBox)
    let w = Int(box.width * scale), h = Int(box.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    page.draw(with: .mediaBox, to: ctx)
    guard let img = ctx.makeImage() else { continue }
    let rep = NSBitmapImageRep(cgImage: img)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(a[2])/page\(String(format: "%02d", i + 1)).png"))
    }
}
