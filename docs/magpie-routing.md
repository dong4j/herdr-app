# Original Magpie Routing on macOS

This custom Herdr build embeds Magpie's original Routing page in a child
WKWebView. Magpie owns its HTML, CSS, JavaScript, flight animation, context
map, request history and replay. Herdr supplies the container and the
Files → Changes → Routing switcher. The only page adaptation hides Magpie's
outer navigation; the Routing interface is unchanged.

Install Magpie.app in `/Applications` or `~/Applications`. Opening Routing
starts a private `magpie web --addr 127.0.0.1:0 --no-open` process, which reads
the running gateway's own trace. Herdr keeps its sign-in URL in memory and
stops only its own web process. It never restarts the gateway or terminals.

The main layout contains a block with id `routing` and content
`{"magpie_routing":true}` inside `panel-body`. Personal layouts using the
earlier `{"mod":"magpie-routing"}` slot automatically show this same page
on macOS, without rewriting those layouts or starting the old JavaScript mod.
The panel width is remembered independently of Files and Changes. WebKit
hides while Herdr overlays are open, then resumes the original page.

## Build and verify

The base is Herdr v0.1.14, upstream commit
`2405bf388c568c3ed479f05b8e405ccfa44b3f2c`. Its Ghostty submodule is
`291fd050b9e9c293c8adb6a140742649b7e42d3a`. Use the repository's normal Rust,
Bun, Xcode and Zig 0.16 prerequisites. Initialize the Ghostty submodule on a
fresh clone. Set `ZIG` to an absolute executable path when using the custom
run script outside the original build workspace, then run:

```sh
./script/build_and_run.sh --verify
cargo test --locked
bun test scripts/routing-tabs.test.ts
```

The run script uses an isolated app home and core session. It only restarts
that custom test window; it leaves the person's installed app and terminals
running. `routing.inspect` schedules WebKit's own DOM diagnostic and native
snapshot under the selected app home's `data/`. The diagnostic omits request
bodies and sign-in keys. `herdr-app shot` captures only GPUI: use a native
window screenshot to see the composited WebKit view.

Validation on macOS included original replay, account masking, history
selection, scrollbar dragging, Files/Changes/Routing switching, independent
panel width, overlay dismissal, and an existing personal layout. Live WebKit
capture recorded 36 distinct stage frames and 15 flight transforms in 8.32
seconds. The served Routing and context assets matched local Magpie
v0.1.3536 source byte for byte.

The installed custom binary takes effect when the person next quits and
reopens Herdr. Keep a complete copy of the previous application for rollback.
An official Herdr update replaces this custom build; retain its source patch
when upgrading. Ordinary mods and non-macOS platforms do not gain WebViews.

## Tracking official releases

The maintained fork is `dong4j/herdr-app`. Its dedicated feature branch is
`feat/magpie-routing-webview`, based on the official v0.1.14 commit above.
`origin` points to the personal fork and `upstream` to
`https://github.com/herdrdev/herdr-app.git`. The feature branch tracks its
counterpart on `origin`; the fork's default branch stays separate.

This source build does not enable official automatic updates. Installing an
official app package replaces the native Routing support, so follow a new
official release by merging its tag into the feature branch, resolving any
compatibility changes, and rebuilding the custom application:

```sh
git fetch upstream --tags
git switch feat/magpie-routing-webview
git merge vX.Y.Z
git submodule update --init --recursive
```

Replace `vX.Y.Z` with the desired official release tag. Run the build and
checks above, exercise the original page in the isolated app, then publish
the verified change with `git push origin feat/magpie-routing-webview`.
Merging releases retains the published feature history without a force push.
