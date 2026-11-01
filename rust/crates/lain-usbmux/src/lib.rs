//! A usbmuxd client (list, listen, connect), and a fake usbmuxd for tests.
//!
//! Swift reference: `Packages/LainKit/Sources/LainUSBMux/` (`USBMux.swift`, `USBMuxProtocol.swift`) and
//! `LainTestSupport/FakeUSBMuxd.swift`. Brief: `docs/LINUX-HOST-PLAN.md`, `lain-usbmux`.
//!
//! On Linux the daemon is libimobiledevice's usbmuxd, on the same socket (`/var/run/usbmuxd`) and protocol as
//! Apple's. It runs only while an iOS device is attached: udev starts it for the first device, and it exits
//! after the last one goes, leaving its socket file behind. So [`UsbMuxError::Unavailable`] is the normal
//! state with no iPad, and a [`UsbMuxEvents`] stream ending is normal after an unplug.
//!
//! ```no_run
//! # async fn demo() -> Result<(), lain_usbmux::UsbMuxError> {
//! let client = lain_usbmux::UsbMuxClient::default();
//! let mut events = client.listen().await?;
//! while let Some(event) = events.next().await? {
//!     if let lain_usbmux::UsbMuxEvent::Attached(device) = event {
//!         let _pipe = client.connect(device.device_id, 47800).await?;
//!     }
//! }
//! # Ok(())
//! # }
//! ```

mod client;
mod error;
mod event;
pub mod protocol;

#[cfg(feature = "fake")]
pub mod fake;

pub use client::{DEFAULT_SOCKET_PATH, UsbMuxClient, UsbMuxEvents};
pub use error::UsbMuxError;
pub use event::{UsbMuxDevice, UsbMuxEvent};
