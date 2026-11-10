//! Original Magpie Routing in a macOS child WKWebView.
//!
//! Magpie serves its own versioned assets and APIs. Herdr only owns the
//! container and the private loopback `magpie web` process; no route,
//! context-card, layout, or animation code is reimplemented here.

use gpui::{prelude::FluentBuilder as _, *};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::{
    cell::RefCell,
    ffi::{CString, c_void},
    io::{BufRead, BufReader},
    os::unix::fs::OpenOptionsExt,
    path::PathBuf,
    process::{Child, Command, Stdio},
    rc::Rc,
};

unsafe extern "C" {
    fn herdr_routing_create(parent: *mut c_void, url: *const std::ffi::c_char) -> *mut c_void;
    fn herdr_routing_bounds(view: *mut c_void, x: f64, y: f64, w: f64, h: f64);
    fn herdr_routing_visible(view: *mut c_void, visible: bool);
    fn herdr_routing_release(view: *mut c_void);
    fn herdr_routing_inspect(view: *mut c_void, path: *const std::ffi::c_char);
}

/// Main-thread-only owner: the bridge retains WebKit and releases its view.
#[derive(Default)]
struct NativePage {
    view: Option<std::ptr::NonNull<c_void>>,
    visible: bool,
}

impl NativePage {
    /// GPUI and AppKit use points, not Retina backing pixels. The bridge
    /// converts the top-left canvas origin to the parent's native coordinates.
    fn place(&mut self, url: &str, bounds: Bounds<Pixels>, window: &Window) {
        if self.view.is_none() {
            let Ok(handle) = HasWindowHandle::window_handle(window) else { return };
            let RawWindowHandle::AppKit(handle) = handle.as_raw() else { return };
            let url = CString::new(url).expect("Magpie URL contains no NUL");
            // SAFETY: all GPUI render callbacks run on the AppKit main thread;
            // the parent NSView remains owned by this window.
            self.view = std::ptr::NonNull::new(unsafe { herdr_routing_create(handle.ns_view.as_ptr(), url.as_ptr()) });
        }
        if let Some(view) = self.view {
            unsafe {
                herdr_routing_bounds(
                    view.as_ptr(),
                    f32::from(bounds.origin.x) as f64,
                    f32::from(bounds.origin.y) as f64,
                    f32::from(bounds.size.width) as f64,
                    f32::from(bounds.size.height) as f64,
                );
                herdr_routing_visible(view.as_ptr(), self.visible);
            }
        }
    }

    fn set_visible(&mut self, visible: bool) {
        self.visible = visible;
        if let Some(view) = self.view {
            unsafe { herdr_routing_visible(view.as_ptr(), visible) };
        }
    }
}

impl Drop for NativePage {
    fn drop(&mut self) {
        if let Some(view) = self.view {
            unsafe { herdr_routing_release(view.as_ptr()) };
        }
    }
}

/// One page per window. The child process reads the current gateway's own
/// trace (including when the Magpie desktop app owns that gateway).
pub(super) struct RoutingView {
    native: Rc<RefCell<NativePage>>,
    server: Option<Child>,
    url: Option<String>,
    error: Option<String>,
    _ready: Option<Task<()>>,
}

impl RoutingView {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let mut view = Self {
            native: Default::default(),
            server: None,
            url: None,
            error: None,
            _ready: None,
        };
        match start_page() {
            Ok((server, ready)) => {
                view.server = Some(server);
                view._ready = Some(cx.spawn(async move |this, cx| {
                    if let Ok(result) = ready.recv().await {
                        let _ = this.update(cx, |this, cx| {
                            match result {
                                Ok(url) => this.url = Some(url),
                                Err(error) => this.error = Some(error),
                            }
                            cx.notify();
                        });
                    }
                }));
            }
            Err(error) => view.error = Some(error.to_string()),
        }
        view
    }

    pub fn set_visible(&mut self, visible: bool) {
        self.native.borrow_mut().set_visible(visible);
    }

    /// Diagnostic snapshots use the live DOM and WebKit's own flight positions;
    /// they never change routing or send a model request. Query keys are omitted.
    pub fn inspect(&self) -> serde_json::Value {
        let path = crate::mods::app_dir().join("data/routing-inspection.json");
        if let Some(view) = self.native.borrow().view {
            let destination = CString::new(path.to_string_lossy().as_bytes()).unwrap();
            unsafe { herdr_routing_inspect(view.as_ptr(), destination.as_ptr()) };
        }
        let mut result = serde_json::json!({ "ready": self.url.is_some(), "snapshot": path });
        if let Some(error) = &self.error {
            result["error"] = serde_json::json!(error);
        }
        result
    }
}

impl Render for RoutingView {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let native = self.native.clone();
        let url = self.url.clone();
        div()
            .size_full()
            .bg(crate::settings::color_or_literal("surface"))
            .when(url.is_some(), |el| {
                el.child(
                    canvas(
                        move |bounds, window, _| {
                            native.borrow_mut().place(url.as_deref().unwrap(), bounds, window);
                        },
                        |_, _, _, _| {},
                    )
                    .size_full(),
                )
            })
            .when(self.url.is_none(), |el| {
                el.flex()
                    .items_center()
                    .justify_center()
                    .p_4()
                    .child(self.error.clone().unwrap_or_else(|| "正在打开 Magpie 原版 Routing…".into()))
            })
    }
}

impl Drop for RoutingView {
    fn drop(&mut self) {
        // Only the private process started here is ours to stop. The gateway
        // and the user's Magpie/Herdr processes are never signalled.
        if let Some(server) = &mut self.server {
            let _ = server.kill();
            let _ = server.wait();
        }
    }
}

type PageReady = async_channel::Receiver<Result<String, String>>;

/// Keep the sign-in link in memory, never in a layout, diagnostic or log.
/// Port 0 lets the OS allocate an available loopback port for this window.
fn start_page() -> anyhow::Result<(Child, PageReady)> {
    let candidates = [
        PathBuf::from("/Applications/Magpie.app/Contents/MacOS/magpie"),
        crate::mods::home().join("Applications/Magpie.app/Contents/MacOS/magpie"),
    ];
    let binary = candidates.iter().find(|path| path.is_file()).ok_or_else(|| anyhow::anyhow!("未找到 Magpie.app，请先安装 Magpie"))?;
    let folder = crate::mods::app_dir().join("data");
    std::fs::create_dir_all(&folder)?;
    let log = std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(folder.join("magpie-web.log"))?;
    let mut child = Command::new(binary)
        .args(["web", "--addr", "127.0.0.1:0", "--no-open"])
        .env_remove("MAGPIE_WEB_KEY")
        .env_remove("MAGPIE_WEB_RUNKEY")
        .env_remove("MAGPIE_WEB_URL")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(log)
        .spawn()?;
    let output = child.stdout.take().expect("piped stdout");
    let (send, receive) = async_channel::bounded(1);
    std::thread::spawn(move || {
        let mut sent = false;
        for line in BufReader::new(output).lines().map_while(Result::ok) {
            if !sent && let Some(url) = page_link(&line) {
                sent = true;
                let _ = send.send_blocking(Ok(url));
            }
            // Continue draining stdout so the owned process cannot block on logs.
        }
        if !sent {
            let _ = send.send_blocking(Err("Magpie 页面服务未启动，详情见 data/magpie-web.log".into()));
        }
    });
    Ok((child, receive))
}

fn page_link(line: &str) -> Option<String> {
    let start = line.find("http://127.0.0.1:")?;
    let url = line[start..].split_whitespace().next()?;
    url.contains("/?k=").then(|| format!("{url}&view=routing"))
}

#[cfg(test)]
mod tests {
    use super::page_link;
    #[test]
    fn takes_only_the_private_loopback_sign_in_link() {
        assert_eq!(page_link("● magpie web on http://127.0.0.1:1234/?k=test"), Some("http://127.0.0.1:1234/?k=test&view=routing".into()));
        assert_eq!(page_link("gateway http://127.0.0.1:3425"), None);
        assert_eq!(page_link("http://example.com/?k=test"), None);
    }
}
