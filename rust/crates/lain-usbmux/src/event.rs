use plist::{Dictionary, Value};

use crate::protocol::{Packet, unsigned};

/// A device usbmuxd reports as attached over USB (Swift: `USBMuxDevice`).
///
/// `device_id` is a `u32` where Swift has `Int`: both daemons keep device ids as `uint32_t` (the binary
/// protocol's field, and libimobiledevice reads a `Connect`'s `DeviceID` as `(uint32_t)`), so a larger id is
/// treated as malformed and the event is skipped.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct UsbMuxDevice {
    pub device_id: u32,
    /// `Properties.SerialNumber`, or empty when absent. lain uses it as the pairing peer id.
    pub serial_number: String,
    pub product_id: Option<u64>,
    /// Bits per second (480 000 000 = USB 2). A `u64` where Swift has `Int` (the same width there):
    /// libimobiledevice reports SuperSpeed as 5 000 000 000, which doesn't fit 32 bits.
    pub connection_speed: Option<u64>,
}

impl UsbMuxDevice {
    pub fn new(device_id: u32, serial_number: impl Into<String>) -> Self {
        Self { device_id, serial_number: serial_number.into(), product_id: None, connection_speed: None }
    }

    /// Parses one `Attached`-shaped dictionary (an event, or a `ListDevices` entry). Returns the device and
    /// whether `Properties.ConnectionType` is `"USB"`. Needs `DeviceID` at the top level and a `Properties`
    /// dictionary, like Swift.
    pub(crate) fn from_attached(plist: &Dictionary) -> Option<(Self, bool)> {
        let props = plist.get("Properties").and_then(Value::as_dictionary)?;
        let device_id = u32::try_from(plist.get("DeviceID").and_then(unsigned)?).ok()?;
        let device = Self {
            device_id,
            serial_number: props.get("SerialNumber").and_then(Value::as_string).unwrap_or_default().to_owned(),
            product_id: props.get("ProductID").and_then(unsigned),
            connection_speed: props.get("ConnectionSpeed").and_then(unsigned),
        };
        let is_usb = props.get("ConnectionType").and_then(Value::as_string) == Some("USB");
        Some((device, is_usb))
    }
}

/// A USB attach or detach (Swift: `USBMuxEvent`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UsbMuxEvent {
    Attached(UsbMuxDevice),
    Detached { device_id: u32 },
}

impl UsbMuxEvent {
    /// Interprets an event packet; returns the event and whether it concerns a USB attachment (Swift:
    /// `USBMuxEvent.from`). Anything else, including libimobiledevice's `Paired` notification, is `None`.
    pub(crate) fn from_packet(p: &Packet) -> Option<(Self, bool)> {
        match p.message_type()? {
            "Attached" => UsbMuxDevice::from_attached(&p.plist).map(|(d, usb)| (Self::Attached(d), usb)),
            "Detached" => Some((Self::Detached { device_id: u32::try_from(p.unsigned("DeviceID")?).ok()? }, true)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dict(pairs: &[(&str, Value)]) -> Dictionary {
        pairs.iter().map(|(k, v)| ((*k).to_owned(), v.clone())).collect()
    }

    #[test]
    fn parses_events_like_the_real_daemons() {
        // Apple's shape, captured from /var/run/usbmuxd on macOS 27 (Swift's `parsesEventsLikeTheRealDaemon`).
        let props = dict(&[
            ("ConnectionSpeed", 480_000_000u64.into()),
            ("ConnectionType", "USB".into()),
            ("DeviceID", 5u64.into()),
            ("LocationID", 2_097_152u64.into()),
            ("ProductID", 4779u64.into()),
            ("SerialNumber", "0000".into()),
            ("USBSerialNumber", "0000".into()),
        ]);
        let attached = Packet::new(
            0,
            dict(&[("DeviceID", 5u64.into()), ("MessageType", "Attached".into()), ("Properties", props.into())]),
        );
        let expected = UsbMuxDevice {
            device_id: 5,
            serial_number: "0000".into(),
            product_id: Some(4779),
            connection_speed: Some(480_000_000),
        };
        assert_eq!(UsbMuxEvent::from_packet(&attached), Some((UsbMuxEvent::Attached(expected), true)));

        // libimobiledevice 1.1.1's shape (create_device_attached_plist): no USBSerialNumber, the serial with a
        // hyphen after 8 digits for new-style UDIDs, SuperSpeed as 5 Gbit/s.
        let props = dict(&[
            ("ConnectionSpeed", 5_000_000_000u64.into()),
            ("ConnectionType", "USB".into()),
            ("DeviceID", 3u64.into()),
            ("LocationID", 0x0003_0004u64.into()),
            ("ProductID", 0x12abu64.into()),
            ("SerialNumber", "00008103-0011223344556677".into()),
        ]);
        let attached = Packet::new(
            0,
            dict(&[("MessageType", "Attached".into()), ("DeviceID", 3u64.into()), ("Properties", props.into())]),
        );
        let Some((UsbMuxEvent::Attached(d), true)) = UsbMuxEvent::from_packet(&attached) else { panic!() };
        assert_eq!(d.serial_number, "00008103-0011223344556677");
        assert_eq!(d.connection_speed, Some(5_000_000_000));

        let network = Packet::new(
            0,
            dict(&[
                ("DeviceID", 9u64.into()),
                ("MessageType", "Attached".into()),
                ("Properties", dict(&[("ConnectionType", "Network".into())]).into()),
            ]),
        );
        let Some((UsbMuxEvent::Attached(d), false)) = UsbMuxEvent::from_packet(&network) else { panic!() };
        assert_eq!(d, UsbMuxDevice::new(9, ""));
    }

    #[test]
    fn skips_what_it_cannot_read() {
        let parse = |pairs: &[(&str, Value)]| UsbMuxEvent::from_packet(&Packet::new(0, dict(pairs)));
        let attached: Value = "Attached".into();
        let detached: Value = "Detached".into();
        let props: Value = dict(&[("ConnectionType", "USB".into())]).into();
        // No Properties, no DeviceID, an id beyond u32, a negative id, an unknown or missing MessageType.
        assert_eq!(parse(&[("MessageType", attached.clone()), ("DeviceID", 1u64.into())]), None);
        assert_eq!(parse(&[("MessageType", attached.clone()), ("Properties", props.clone())]), None);
        assert_eq!(parse(&[("MessageType", attached), ("DeviceID", (1u64 << 32).into()), ("Properties", props)]), None);
        assert_eq!(parse(&[("MessageType", detached.clone()), ("DeviceID", (-1i64).into())]), None);
        assert_eq!(parse(&[("MessageType", "Paired".into()), ("DeviceID", 1u64.into())]), None);
        assert_eq!(parse(&[("DeviceID", 1u64.into())]), None);
        assert_eq!(
            parse(&[("MessageType", detached), ("DeviceID", 4u64.into())]),
            Some((UsbMuxEvent::Detached { device_id: 4 }, true))
        );
    }
}
