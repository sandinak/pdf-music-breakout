// Verification harness: mirrors the Python CLI so the two implementations
// can be diffed against real files.  verify FILE.pdf [OUTDIR]
import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count > 1, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: verify FILE.pdf [OUTDIR]\n".data(using: .utf8)!)
    exit(1)
}

let (labels, title) = Detection.pageLabels(doc)
let (parts, front) = Detection.group(labels: labels,
                                     aliases: Naming.defaultAliases,
                                     pageCount: doc.pageCount)

var options = ExportOptions()
options.title = title

let name = (args[1] as NSString).lastPathComponent
print("\(name): \(doc.pageCount) pages, \(parts.count) parts")
print("title: \(title)")
if !front.isEmpty {
    print("front matter: page(s) \(front.map { String($0 + 1) }.joined(separator: ", "))")
}
for p in parts {
    print(String(format: "  %-34@ %2d pp   pages %@   [%@]",
                 options.filename(for: p) as NSString, p.pages.count, p.ranges, p.label))
}

if args.count > 2 {
    let folder = URL(fileURLWithPath: args[2])
    do {
        let written = try Splitter.export(parts: parts, front: front, from: doc,
                                          options: options, into: folder)
        for w in written {
            let note = w.refitted > 0 ? ", \(w.refitted) refitted" : ""
            print("  wrote \(w.url.lastPathComponent) (\(w.pages) pp\(note))")
        }
    } catch {
        print("export failed: \(error)")
        exit(1)
    }
}
