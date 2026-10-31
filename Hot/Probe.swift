import Foundation

// A tiny library for testing whether this app can load code it downloads. Not used for anything else.
@_cdecl("hot_probe")
public func hotProbe() -> UnsafePointer<CChar>? {
    UnsafePointer(strdup("loaded and ran downloaded code"))
}
