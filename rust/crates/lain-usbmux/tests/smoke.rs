//! Against the real usbmuxd (libimobiledevice's, on Linux). Run by hand, with an iPad attached:
//! `cargo test -p lain-usbmux --test smoke -- --ignored --nocapture`.

use lain_usbmux::{DEFAULT_SOCKET_PATH, UsbMuxClient, UsbMuxError};

#[tokio::test]
#[ignore = "needs the real usbmuxd, which runs only while an iOS device is attached"]
async fn lists_devices_on_the_real_daemon() {
    match UsbMuxClient::default().list_devices().await {
        Ok(devices) => {
            println!("usbmuxd at {DEFAULT_SOCKET_PATH}: {} USB device(s)", devices.len());
            for d in devices {
                println!("  {d:?}");
            }
        }
        Err(UsbMuxError::Unavailable { source, .. }) => {
            // libimobiledevice's usbmuxd is started by udev when an iOS device is plugged in and exits after
            // the last one is removed, leaving its socket file behind (hence ConnectionRefused).
            println!(
                "SKIPPED: no usbmuxd at {DEFAULT_SOCKET_PATH} ({source}). It is socket-activated and runs only while \
                 an iOS device is attached: plug in the iPad and run again."
            );
        }
        Err(e) => panic!("usbmuxd: {e}"),
    }
}
