//! The usbmuxd wire format: a 16-byte little-endian header (total length, version 1, message type 8 = plist,
//! tag) followed by an XML property list.
//!
//! Mirrors Swift's `USBMuxProtocol` (`LainUSBMux/USBMuxProtocol.swift`). libimobiledevice's usbmuxd 1.1.1
//! speaks the same framing (`usbmuxd-proto.h`: `struct usbmuxd_header`, `MESSAGE_PLIST = 8`) and answers a
//! version-1 client in plist, with the request's tag echoed.

use std::io::Cursor;

use plist::{Dictionary, Value};

use crate::UsbMuxError;

/// Bytes in the packet header (Swift: `USBMuxProtocol.headerSize`).
pub const HEADER_SIZE: usize = 16;
/// The protocol version lain speaks: 1, the plist protocol (Swift: `USBMuxProtocol.version`).
pub const VERSION: u32 = 1;
/// The message type of a plist packet (Swift: `USBMuxProtocol.plistMessageType`).
pub const PLIST_MESSAGE_TYPE: u32 = 8;
/// The largest plist body accepted (Swift: `USBMuxProtocol.maxBodySize`, 1 MiB).
pub const MAX_BODY_SIZE: usize = 1 << 20;

/// usbmuxd's `Result` numbers (Swift: the cases documented on `USBMuxError.result`; libimobiledevice:
/// `enum usbmuxd_result`, identical values).
pub mod result {
    /// Success; after a `Connect`, the socket is now a raw pipe.
    pub const OK: u64 = 0;
    /// An unknown or malformed command.
    pub const BAD_COMMAND: u64 = 1;
    /// No such device.
    pub const BAD_DEVICE: u64 = 2;
    /// The device refused the TCP connection (nothing listening on the port).
    pub const CONNECTION_REFUSED: u64 = 3;
    /// The header's protocol version isn't one the daemon speaks.
    pub const BAD_VERSION: u64 = 6;
}

/// One usbmuxd packet: its tag and its plist dictionary (Swift: `USBMuxProtocol.Packet`).
#[derive(Debug, Clone, PartialEq)]
pub struct Packet {
    pub tag: u32,
    pub plist: Dictionary,
}

impl Packet {
    pub fn new(tag: u32, plist: Dictionary) -> Self {
        Self { tag, plist }
    }

    /// The `MessageType` string, if there is one (Swift: `Packet.messageType`).
    pub fn message_type(&self) -> Option<&str> {
        self.plist.get("MessageType").and_then(Value::as_string)
    }

    /// An integer field as a non-negative number. usbmuxd writes its integers unsigned; a negative or
    /// non-integer value reads as absent.
    pub fn unsigned(&self, key: &str) -> Option<u64> {
        unsigned(self.plist.get(key)?)
    }

    /// The packet's bytes: header, then the XML plist (Swift: `USBMuxProtocol.encode`).
    pub fn encode(&self) -> Result<Vec<u8>, UsbMuxError> {
        let mut body = Vec::new();
        Value::Dictionary(self.plist.clone())
            .to_writer_xml(&mut body)
            .map_err(|e| UsbMuxError::Protocol(format!("encode: {e}")))?;
        let length = u32::try_from(HEADER_SIZE + body.len())
            .map_err(|_| UsbMuxError::Protocol(format!("body of {} bytes", body.len())))?;
        let mut out = Vec::with_capacity(HEADER_SIZE + body.len());
        for v in [length, VERSION, PLIST_MESSAGE_TYPE, self.tag] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.extend_from_slice(&body);
        Ok(out)
    }

    /// Parses a plist body (XML or binary). It must be a dictionary (Swift: `USBMuxProtocol.decodeBody`).
    pub fn decode_body(body: &[u8], tag: u32) -> Result<Self, UsbMuxError> {
        match Value::from_reader(Cursor::new(body)) {
            Ok(Value::Dictionary(plist)) => Ok(Self { tag, plist }),
            _ => Err(UsbMuxError::Protocol("bad plist".into())),
        }
    }
}

/// A plist value as a non-negative integer.
pub(crate) fn unsigned(value: &Value) -> Option<u64> {
    match value {
        Value::Integer(i) => i.as_unsigned(),
        _ => None,
    }
}

/// The parsed header: the body's length and the tag (Swift: `USBMuxProtocol.decodeHeader`'s tuple).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub body_length: usize,
    pub tag: u32,
}

/// Parses a header. Rejects anything but version 1 and type 8, a length below the header's, and a body over
/// [`MAX_BODY_SIZE`] (Swift: `USBMuxProtocol.decodeHeader`).
pub fn decode_header(bytes: &[u8; HEADER_SIZE]) -> Result<Header, UsbMuxError> {
    let u32_at = |i: usize| u32::from_le_bytes([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]);
    let length = u32_at(0) as usize;
    let (version, message) = (u32_at(4), u32_at(8));
    if version != VERSION || message != PLIST_MESSAGE_TYPE {
        return Err(UsbMuxError::Protocol(format!("version {version} type {message}")));
    }
    if length < HEADER_SIZE || length - HEADER_SIZE > MAX_BODY_SIZE {
        return Err(UsbMuxError::Protocol(format!("length {length}")));
    }
    Ok(Header { body_length: length - HEADER_SIZE, tag: u32_at(12) })
}

/// The fields every request carries (Swift: `USBMuxProtocol.base`).
fn base(message_type: &str) -> Dictionary {
    let mut d = Dictionary::new();
    d.insert("MessageType".into(), message_type.into());
    d.insert("ClientVersionString".into(), "lain".into());
    d.insert("ProgName".into(), "lain".into());
    d
}

/// A `Listen` request (Swift: `USBMuxProtocol.listen`).
pub fn listen(tag: u32) -> Packet {
    Packet::new(tag, base("Listen"))
}

/// A `ListDevices` request. Swift's client has none; the Linux smoke test and diagnostics use it.
pub fn list_devices(tag: u32) -> Packet {
    Packet::new(tag, base("ListDevices"))
}

/// The value of `PortNumber` for `port`: the port in network byte order, read as a host integer (PeerTalk's
/// `htons`; Swift: `Int(port.bigEndian)`). On this little-endian machine 47800 (0xBAB8) becomes 0xB8BA.
/// libimobiledevice reads it back the same way: `ntohs((uint16_t)PortNumber)`.
pub fn wire_port(port: u16) -> u16 {
    port.to_be()
}

/// A `Connect` request to `port` on the device (Swift: `USBMuxProtocol.connect`).
pub fn connect(tag: u32, device_id: u32, port: u16) -> Packet {
    let mut d = base("Connect");
    d.insert("DeviceID".into(), u64::from(device_id).into());
    d.insert("PortNumber".into(), u64::from(wire_port(port)).into());
    Packet::new(tag, d)
}

/// A daemon's `Result` reply (Swift: `USBMuxProtocol.result`).
pub fn result_packet(tag: u32, number: u64) -> Packet {
    let mut d = Dictionary::new();
    d.insert("MessageType".into(), "Result".into());
    d.insert("Number".into(), number.into());
    Packet::new(tag, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let p = connect(7, 5, 47800);
        let bytes = p.encode().unwrap();
        let header = decode_header(bytes[..16].try_into().unwrap()).unwrap();
        assert_eq!(header, Header { body_length: bytes.len() - 16, tag: 7 });
        assert_eq!(bytes[4..12], [1, 0, 0, 0, 8, 0, 0, 0]); // version 1, plist type 8, little-endian
        assert_eq!(Packet::decode_body(&bytes[16..], header.tag).unwrap(), p);
        assert_eq!(p.message_type(), Some("Connect"));
        assert_eq!(p.unsigned("DeviceID"), Some(5));
    }

    #[test]
    fn port_is_in_network_byte_order() {
        // PeerTalk's htons(47800): 0xBAB8 → 0xB8BA read as a host integer.
        assert_eq!(connect(1, 1, 47800).unsigned("PortNumber"), Some(u64::from(u16::from_ne_bytes([0xBA, 0xB8]))));
        #[cfg(target_endian = "little")]
        assert_eq!(connect(1, 1, 47800).unsigned("PortNumber"), Some(0xB8BA));
    }

    #[test]
    fn rejects_bad_headers() {
        assert!(decode_header(&[0; 16]).is_err()); // version 0, type 0
        let mut h = [0x10, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0];
        assert!(decode_header(&h).is_ok()); // an empty body is a valid header
        h[0] = 0x0F; // shorter than the header
        assert!(decode_header(&h).is_err());
        let too_long = u32::try_from(HEADER_SIZE + MAX_BODY_SIZE + 1).unwrap().to_le_bytes();
        h[..4].copy_from_slice(&too_long);
        assert!(decode_header(&h).is_err());
        h[..4].copy_from_slice(&u32::try_from(HEADER_SIZE + MAX_BODY_SIZE).unwrap().to_le_bytes());
        assert!(decode_header(&h).is_ok());
        h[8] = 1; // the binary protocol's MESSAGE_RESULT
        assert!(decode_header(&h).is_err());
    }

    #[test]
    fn rejects_bad_bodies() {
        assert!(Packet::decode_body(b"junk", 0).is_err());
        let array = br#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array/></plist>"#;
        assert!(Packet::decode_body(array, 0).is_err());
    }

    #[test]
    fn decodes_libimobiledevice_style_unsigned_integers() {
        // libplist writes plist_new_uint values as plain <integer>s, as Apple's does.
        let xml = br#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>MessageType</key><string>Result</string><key>Number</key><integer>3</integer></dict></plist>"#;
        let p = Packet::decode_body(xml, 1).unwrap();
        assert_eq!(p, result_packet(1, 3));
        assert_eq!(p.unsigned("Number"), Some(result::CONNECTION_REFUSED));
    }
}
