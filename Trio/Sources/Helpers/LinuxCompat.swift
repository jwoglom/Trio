// Compatibility shims so the AlgorithmPackage target can compile with
// swift-corelibs-foundation (Linux CI). Not compiled into the app target.
import Foundation

#if !canImport(Darwin)
    extension String {
        /// swift-corelibs-foundation has no `String(localized:)`. The algorithm
        /// package only needs the literal text, so pass it through untranslated.
        init(localized value: String) { self = value }
    }
#endif
