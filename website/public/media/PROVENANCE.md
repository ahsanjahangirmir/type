# Product captures
Captured November 12, 2026 from a Debug build of the actual Type SwiftUI/AppKit source, including the user's preexisting app improvements. The app was copied and built outside the repository, with a separate bundle identifier `com.ajm.type.websitecapture` and display name `Type Website Capture`. All published screenshots contain only an original sample manuscript and sample notebooks in `/tmp/type-website-capture/library`.

Paper and Sepia use Light appearance. Slate uses Dark appearance. The focus image is actual paragraph focus mode with the cursor at the start of “A sentence becomes a thought.” The OS screen-sharing indicator is omitted by cropping the top 100 pixels. The detached hero toolbar and sidebar are crops of actual UI. No HTML screenshot imitations, AI-generated app screens, or user writing are used.

Capture issue: the app's cacheDisplay hook omitted SwiftUI content. Native window screenshots were used instead. During capture setup, app-name resolution selected an earlier temporary build without launch overrides; its automatic restored view was observed but not interacted with, captured for publication, or edited. The temporary source was then hardened to force the sample library for every launch before all published media was captured.

Reprocess the original screenshots, if retained:
`node scripts/prepare-media.mjs /tmp/type-website-capture/media`

Only scaling, WebP encoding and the documented crops were applied to the source pixels.
