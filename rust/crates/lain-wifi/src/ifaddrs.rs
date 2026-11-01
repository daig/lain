//! Which network interface owns a local address: `getifaddrs(3)`, the one C API this module wraps. No
//! Swift counterpart: Network.framework reports a connection's path (`NWPath.availableInterfaces`), which
//! `NetworkPath` reads.
#![allow(unsafe_code)]

use std::ffi::CStr;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

/// The interface whose address is `local`'s (an accepted or dialed socket's local address), `None` if no
/// interface has it. An IPv4-mapped IPv6 address (a dual-stack socket's IPv4 peer) is looked up as IPv4. A
/// link-local IPv6 address with a scope id matches only on that interface.
pub(crate) fn interface_owning(local: SocketAddr) -> Option<String> {
    let (ip, scope) = match local {
        SocketAddr::V4(a) => (IpAddr::V4(*a.ip()), 0),
        SocketAddr::V6(a) => match a.ip().to_ipv4_mapped() {
            Some(v4) => (IpAddr::V4(v4), 0),
            None => (IpAddr::V6(*a.ip()), a.scope_id()),
        },
    };
    interfaces().into_iter().find(|i| i.ip == ip && (scope == 0 || i.scope == 0 || i.scope == scope)).map(|i| i.name)
}

struct Address {
    name: String,
    ip: IpAddr,
    /// The IPv6 scope id (0 for IPv4 and global addresses).
    scope: u32,
}

/// Every interface address, IPv4 and IPv6; empty if `getifaddrs` fails.
fn interfaces() -> Vec<Address> {
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: `getifaddrs` writes a list head into `head`, which we free with `freeifaddrs` below.
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut cursor = head;
    while !cursor.is_null() {
        // SAFETY: `cursor` is a node of the list `getifaddrs` returned, valid until `freeifaddrs`.
        let entry = unsafe { &*cursor };
        cursor = entry.ifa_next;
        if entry.ifa_addr.is_null() || entry.ifa_name.is_null() {
            continue;
        }
        // SAFETY: `ifa_name` is a NUL-terminated string owned by the list.
        let name = unsafe { CStr::from_ptr(entry.ifa_name) }.to_string_lossy().into_owned();
        // SAFETY: `ifa_addr` is non-null; its family says which sockaddr it is, and the kernel sizes it to
        // match.
        let family = i32::from(unsafe { (*entry.ifa_addr).sa_family });
        let address = match family {
            libc::AF_INET => {
                // SAFETY: an `AF_INET` address is a `sockaddr_in`.
                let sin = unsafe { &*(entry.ifa_addr as *const libc::sockaddr_in) };
                Address { name, ip: IpAddr::V4(Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr))), scope: 0 }
            }
            libc::AF_INET6 => {
                // SAFETY: an `AF_INET6` address is a `sockaddr_in6`.
                let sin6 = unsafe { &*(entry.ifa_addr as *const libc::sockaddr_in6) };
                Address { name, ip: IpAddr::V6(Ipv6Addr::from(sin6.sin6_addr.s6_addr)), scope: sin6.sin6_scope_id }
            }
            _ => continue,
        };
        out.push(address);
    }
    // SAFETY: `head` came from a successful `getifaddrs` and is freed once; no reference into it survives.
    unsafe { libc::freeifaddrs(head) };
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loopback_belongs_to_lo() {
        assert_eq!(interface_owning("127.0.0.1:1".parse().unwrap()).as_deref(), Some("lo"));
        // A dual-stack socket's IPv4 peer.
        assert_eq!(interface_owning("[::ffff:127.0.0.1]:1".parse().unwrap()).as_deref(), Some("lo"));
        // TEST-NET-1 belongs to no interface.
        assert_eq!(interface_owning("192.0.2.1:1".parse().unwrap()), None);
    }

    #[test]
    fn ipv6_loopback_belongs_to_lo_when_configured() {
        let found = interface_owning("[::1]:1".parse().unwrap());
        // Some machines run without IPv6 on lo; then nothing owns ::1.
        assert!(found.is_none() || found.as_deref() == Some("lo"));
    }
}
