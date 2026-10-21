# Composer fixed layout and retained menus; Split appearance and resize — 2026-10-21

Owner requests reference-matched orbit/model, enclosed plug, single photo and upright clip artwork; fixed thinking page fitting the keyboard region, enlarged labels and default capsule; clearer dark arcs and selected rail; retained open menu/detail across app background; remove dark divider stripe; investigate dragging performance; match Single sidebar shadow in Split for both appearances. Blueprint 17477d4. Build/package only; no tests per owner.

Diagnosis from source: thinking ScrollView exceeded keyboard height; Workspace explicitly drew a dark gray divider rectangle; both menu owners closed on willResignActive and keyboard session treated scene inactivity as detachment. Sidebar shadow already shares a one-pass two-contour decoration with Single parameters, but Split selected a different backing color. Divider submitted every pan sample through observed workspace layout and rebuilt accessibility actions each time; top edge material could capture the two live timelines while they resized. No measured FPS claim.

Implementation: fixed adaptive thinking geometry; reference vector artwork; dynamic dark contrast. Same-window suspension retains menu ownership/reservation/level and settles native transitions; pending uncommitted effort selection is invalidated. Actual window/size/navigation invalidations still close, and an already-requested close is not resurrected. Same process only, no process-death restoration. Remove stripe, use Single's system background for the shared shadow composition, preserve independent card contours. Coalesce changed pan samples to display refresh, synchronously deliver final displacement before finish, discard cancelled samples; cache unchanged accessibility actions. Pause decorative blur sampling during resize and refresh final geometry, preserving blur algorithm and native anchor/receipt flow. Synchronous layout remains necessary for existing native receipts; device profiling is still required to establish remaining bottlenecks and actual FPS.

Static review and macOS device build pending. No tests or on-device acceptance claimed. Unrelated deep-reading-native-trace.txt excluded. No main merge.

## Build and delivery receipt

Read-only review of ca20d4b found no remaining blocking issue. Both menu owners increment the suspension revision synchronously; the completion checks it even if the inactive/active cycle happens before SwiftUI observes the intermediate state. No tests run.

Application source ca20d4b7f9bc74d1a863c65317e751212e5c1e27; packaging e1862b877b709d328bf240a46e98e1518c7243c4. Run https://github.com/54zhien/Zen-Agent/actions/runs/39559523426 succeeded: frozen-source comparison, XcodeGen, Xcode 26.6 device build and unsigned IPA packaging. No tests run.

Downloaded 27.1 and verified Info.plist identity/version, application source in BUILD-INFO and local SHA-256 against SHA256SUMS: e188424411f5833e777b500d08ce1cd2ee5be3db53433ceb524db9f4c47e4e27. File size 41726257 bytes. Device appearance, background retention and actual frame rate remain pending on-device acceptance. No main merge.
