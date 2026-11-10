# Dazzle

Presentation app that opens, edits, plays and saves PowerPoint presentations, and opens and saves Keynote presentations.

- **Dazzle** is the iOS and iPadOS app, in `Dazzle`, with its watch remote in `DazzleWatch`.
- **Dazzle for Mac** is the native AppKit app, in `DazzleMac`.
- **DazzleEngine** is the framework they build on: the presentation model, reading and writing PowerPoint and Keynote, and drawing slides, in `Engine/DazzleEngine`. `Common/` holds the editing and slideshow code the apps share.
- **Dazzle for the web** is the offline web app, with the engine and the editing code compiled to WebAssembly, in `Web`. See [Web/README.md](Web/README.md) and [Web/PLAN.md](Web/PLAN.md).

The engine is a Swift package (`Engine/Package.swift`) that the Xcode project, `Dazzle.xcodeproj`, compiles in place, and the web build depends on.
