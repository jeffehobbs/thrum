import PDFKit
// Prints the first line of each page — a quick way to spot spill pages, which
// begin mid-table instead of with a heading.
let a = CommandLine.arguments
guard a.count >= 2, let doc = PDFDocument(url: URL(fileURLWithPath: a[1])) else { exit(1) }
for i in 0..<doc.pageCount {
    let s = (doc.page(at: i)?.string ?? "")
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let head = s.prefix(3).joined(separator: " ⁄ ")
    print(String(format: "p%02d  %@", i + 1, String(head.prefix(96))))
}
