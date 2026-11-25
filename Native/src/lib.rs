// SPDX-License-Identifier: AGPL-3.0-only
use oxp_clink::{model::*, protocol::AuthIdentity, session::SessionOptions, *};
use std::{ffi::{c_char, CStr}, net::Ipv4Addr, sync::{Arc, Condvar, Mutex, atomic::{AtomicI32, Ordering}}, time::Duration};

#[derive(Default)]
struct Client {
    pin: Mutex<(Option<String>, bool)>,
    wake: Condvar,
    state: AtomicI32,
    identity: Mutex<Option<AuthIdentity>>,
    peer_key: Mutex<Option<Vec<u8>>>,
}
impl PinProvider for Client {
    fn request_pin(&self, _: &str) -> Option<String> {
        self.state.store(6, Ordering::Release);
        let guard = self.pin.lock().ok()?;
        let (mut slot, _) = self.wake.wait_timeout_while(guard, Duration::from_secs(75),
            |p| p.0.is_none() && !p.1).ok()?;
        if slot.1 { return None }
        self.state.store(2, Ordering::Release);
        slot.0.take()
    }
    fn cancel(&self) { self.pin.lock().unwrap().1 = true; self.wake.notify_all(); }
}
impl TrustStore for Client {
    fn load_identity(&self) -> Result<Option<AuthIdentity>> { Ok(self.identity.lock().unwrap().clone()) }
    fn save_identity(&self, value: &AuthIdentity) -> Result<()> { *self.identity.lock().unwrap() = Some(value.clone()); Ok(()) }
    fn load_peer_key(&self, _: &str) -> Result<Option<Vec<u8>>> { Ok(self.peer_key.lock().unwrap().clone()) }
    fn save_peer_key(&self, _: &str, key: &[u8]) -> Result<()> { *self.peer_key.lock().unwrap() = Some(key.to_vec()); Ok(()) }
    fn forget_peer(&self, _: &str) -> Result<()> { self.peer_key.lock().unwrap().take(); Ok(()) }
}
impl ClinkListener for Client {
    fn state(&self, s: ClinkState) {
        let code = match s { ClinkState::Connecting=>1, ClinkState::Authenticating=>2,
            ClinkState::Negotiating=>3, ClinkState::Playing=>4, ClinkState::Ended=>5 };
        if self.state.load(Ordering::Acquire) >= 0 { self.state.store(code, Ordering::Release); }
    }
    fn error(&self, error: &str) {
        let code = if error.contains("pin") { -2 } else if error.contains("certificate") { -3 } else { -1 };
        self.state.store(code, Ordering::Release);
    }
}
impl OutputSink for Client {
    fn capabilities(&self, _: OutputCapabilities) {}
    fn control(&self, _: ControlEvent) {}
    fn stats(&self, _: OutputStats) {}
}
struct Active { output: Arc<ClinkOutput>, client: Arc<Client> }
static ACTIVE: Mutex<Option<Active>> = Mutex::new(None);

// All pointer arguments are borrowed only for the duration of the Swift call.
unsafe fn string(p: *const c_char) -> Option<String> {
    if p.is_null() { None } else { CStr::from_ptr(p).to_str().ok().map(str::to_owned) }
}
#[no_mangle]
pub unsafe extern "C" fn cl_start(local: *const c_char, peer: *const c_char, port: u16, pin: *const c_char) -> i32 {
    let Some((local, peer)) = string(local).and_then(|s| s.parse::<Ipv4Addr>().ok())
        .zip(string(peer).and_then(|s| s.parse::<Ipv4Addr>().ok())) else { return -1 };
    let Some(pin) = string(pin) else { return -1 };
    if (!pin.is_empty() && (pin.len()!=6 || !pin.bytes().all(|b|b.is_ascii_digit()))) || local==peer || peer.is_loopback() || peer.is_multicast() || peer.is_unspecified() || peer.is_broadcast() { return -1 }
    let mut active = ACTIVE.lock().unwrap();
    if active.is_some() { return -4 }
    let client = Arc::new(Client::default());
    if !pin.is_empty() { client.pin.lock().unwrap().0 = Some(pin); }
    client.state.store(1, Ordering::Release);
    let mut addresses = ClinkAddresses::new(peer, local);
    if port > 0 { addresses.auth_port = port; }
    let mut options = SessionOptions::default();
    options.ports.auth = addresses.auth_port;
    options.hevc = ClinkHevcMode::Off;
    options.device_name = "iPhone".into();
    options.device_id = format!("changan-{local}");
    let Ok(output) = ClinkOutput::new(Arc::new(StaticClinkLink(addresses)), client.clone(), client.clone())
        .and_then(|s| s.with_options(options)) else { return -1 };
    let output = Arc::new(output.with_listener(client.clone()));
    if output.open(client.clone()).is_err() { return -1 }
    output.on_session(&SessionState { id:1, phase:SessionPhase::Active, reason:None });
    *active = Some(Active {output, client});
    0
}
#[no_mangle]
pub unsafe extern "C" fn cl_pin(value: *const c_char) -> i32 {
    let Some(pin) = string(value) else { return -1 };
    if pin.len()!=6 || !pin.bytes().all(|b|b.is_ascii_digit()) { return -1 }
    let slot = ACTIVE.lock().unwrap();
    let Some(active) = slot.as_ref() else { return -1 };
    if active.client.state.load(Ordering::Acquire)!=6 { return -1 }
    active.client.pin.lock().unwrap().0 = Some(pin);
    active.client.wake.notify_one();
    0
}
#[no_mangle]
pub extern "C" fn cl_state() -> i32 {
    ACTIVE.lock().unwrap().as_ref().map_or(0, |s| s.client.state.load(Ordering::Acquire))
}
#[no_mangle]
pub extern "C" fn cl_stop() {
    let old = ACTIVE.lock().unwrap().take();
    if let Some(s) = old { s.output.close(); s.output.await_closed(Duration::from_secs(2)); }
}
#[no_mangle]
pub unsafe extern "C" fn cl_format(data:*const u8, len:usize) -> i32 {
    if data.is_null() || !(1..=65536).contains(&len) { return -1 }
    let Ok(fmt) = VideoFormat::create(0, VideoCodec::H264, std::slice::from_raw_parts(data,len).into(),Some(12.0)) else {return -1};
    let active = ACTIVE.lock().unwrap();
    if let Some(s) = active.as_ref() { s.output.on_video_format(0,Some(Arc::new(fmt))); return 0 }
    -1
}
#[no_mangle]
pub unsafe extern "C" fn cl_frame(data:*const u8, len:usize, pts:i64, key:bool) {
    if data.is_null() || len==0 || len>4*1024*1024 { return }
    if let Some(s) = ACTIVE.lock().unwrap().as_ref() {
        s.output.on_video_frame(VideoFrame {screen:0,session:1,data:std::slice::from_raw_parts(data,len).into(),
            pts_us:pts,key_frame:key,received_at_nanos:0});
    }
}
