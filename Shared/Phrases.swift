import Foundation

// The same thing, said the same way in every app (the audit of 2026-11-10 found "Can’t reach the Mac" said seven ways
// across the apps, once with a typewriter apostrophe). A view that needs one of these says it from here.
enum Phrase {
    // The Mac isn't answering, on its own line or its own alert: what's wrong and the first thing to check.
    static let macAway = "Can’t reach the Mac. Is Tailscale on?"
    // The same, as a label that something else follows (a page's "Last read 2 min ago", a banner with its own second line).
    static let macAwayShort = "Can’t reach the Mac"
    // The Chumby isn't answering.
    static let chumbyAway = "The Chumby isn’t answering"
}
