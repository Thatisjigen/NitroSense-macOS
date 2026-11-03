// The texts of the app are written in English and translated by App/it.lproj/Localizable.strings. A Text with a literal looks its key
// up by itself; a String that comes in a variable goes through L. Without a translation the key itself is shown.

import Foundation

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

func L(_ format: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(format, comment: ""), arguments: args) }
