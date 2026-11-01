//! The status in the log (the lead's notes, "Status in the log"): every `HostStatus` change as its title, every
//! Wi-Fi status change as its title, the video line while connected, and never a secret or a PSK. Its own test
//! binary: the log is captured by a process-wide subscriber, which the runtime's worker threads log through.

mod common;

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use lain_hostd::DEFAULT_LOG_FILTER;
use lain_link::LinkTransport;
use lain_platform::fake::MemorySecretStore;
use lain_proto::*;
use lain_usbmux::fake::FakeDevice;
use lain_wifi::WiFiPsk;

/// Everything logged, as text.
#[derive(Clone, Default)]
struct Captured(Arc<Mutex<Vec<u8>>>);

impl Captured {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

impl Write for Captured {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Captured {
    type Writer = Captured;
    fn make_writer(&'a self) -> Captured {
        self.clone()
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn base64(bytes: &[u8]) -> String {
    const ABC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..=chunk.len() {
            out.push(ABC[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

/// The ways a key could reach the log: hex either case, base64 (unpadded prefix), `{:?}` of the bytes.
fn leaks(log: &str, what: &str, bytes: &[u8]) {
    let hex = hex(bytes);
    for form in [hex.clone(), hex.to_uppercase(), base64(bytes), format!("{bytes:?}")] {
        assert!(!log.contains(&form), "the log shows the {what} as {form}");
    }
    // Half of it is enough to give it away.
    assert!(!log.contains(&hex[..hex.len() / 2]), "the log shows part of the {what}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_status_is_logged_and_no_secret_is() {
    let captured = Captured::default();
    let subscriber = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new(DEFAULT_LOG_FILTER.replace("=info", "=debug")))
        .with_ansi(false)
        .with_writer(captured.clone())
        .finish();
    tracing::subscriber::set_global_default(subscriber).expect("the only subscriber in this binary");

    // Unpaired: the first USB session pairs, the listener listens, the iPad streams video.
    let mut rig = Rig::new(MemorySecretStore::default(), RigOptions { devices: vec![], ..RigOptions::default() }).await;
    rig.mux.attach(FakeDevice::usb(7, SERIAL));
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    assert!(rig.connected(LinkTransport::Usb).await);
    let port = rig.listening().await;
    let session = rig.platform.video().last_session().expect("video started");
    session.capture();
    assert!(link.first_video(T, |m| matches!(m, Message::VideoFrame(_))).await.is_some());
    // Logged every 200 ms in the rig (10 s in the daemon).
    assert!(eventually(T, || captured.text().contains("Video 2752×2064 4:2:0; ")).await, "{}", captured.text());

    // Back over Wi-Fi with the paired secret, so the PSK has been in use too.
    let secret = rig.usb.wifi_secret().expect("paired");
    link.close();
    rig.mux.detach(7);
    let (_wifi, reply) = wifi_connect(port, &secret, hello()).await.expect("a Wi-Fi link");
    assert!(matches!(reply, Message::HelloAck(_)), "{reply:?}");
    assert!(rig.connected(lo()).await);
    rig.shutdown().await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    let log = captured.text();
    for line in [
        "Waiting for iPad",
        "Connected to iPad16,6 over USB",
        "Wi-Fi: off: no paired iPad yet",
        &format!("Wi-Fi: listening on port {port} with 1 paired iPad"),
        "Wi-Fi: off: stopped",
        "Mb/s, ",
        "Encode p50 ",
        "shutdown complete",
    ] {
        assert!(log.contains(line), "no {line:?} in the log:\n{log}");
    }
    leaks(&log, "pairing secret", &secret);
    let psk = WiFiPsk::new(&secret);
    leaks(&log, "PSK", psk.key());
}
