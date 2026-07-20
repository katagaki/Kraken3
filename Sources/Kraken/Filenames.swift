import Foundation

enum Filenames {

    static func sanitize(_ raw: String) -> String {
        var name = raw

        if let slash = name.range(of: "/", options: .backwards) {
            name = String(name[slash.upperBound...])
        }
        if let backslash = name.range(of: "\\", options: .backwards) {
            name = String(name[backslash.upperBound...])
        }

        name = stripControl(name)
        name = name.replacingOccurrences(of: "..", with: "_")
        name = name.trimmingCharacters(in: .whitespaces)

        if name.isEmpty || name.allSatisfy({ $0 == "." }) {
            name = "download"
        }
        if name.count > 200 {
            name = String(name.suffix(200))
        }
        return name
    }

    static func stripControl(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F && !($0.value >= 0x80 && $0.value <= 0x9F)
        }))
    }
}
