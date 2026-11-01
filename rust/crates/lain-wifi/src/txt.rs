//! The host's Bonjour TXT record. Swift: `LainTXT` (`Discovery.swift`).

use lain_platform::ServiceAd;
use lain_proto::{BONJOUR_SERVICE_TYPE, VersionList};

/// The host's Bonjour TXT record (§7.7, D29): `v` = the newest protocol version, `vs` = every version it
/// supports, `id` = the host id. Only a pre-filter: the handshake decides (PROTOCOL-VERSIONING §3.2).
/// Swift: `LainTXT`.
///
/// Difference from Swift: the dictionary is an ordered list of pairs, `v`, `vs`, `id` (then `bench`), as
/// [`ServiceAd::txt`] carries it; DNS-SD readers, Swift's included, don't depend on the order.
#[derive(Debug, Clone, Copy)]
pub struct LainTxt;

impl LainTxt {
    /// The newest version. Legacy iPads read only this, and compare it with their own.
    pub const VERSION_KEY: &str = "v";
    /// Every supported version, comma-separated (`3,4`). The iPad dials only hosts that share one.
    pub const VERSIONS_KEY: &str = "vs";
    /// A canonical UUID; the iPad dials only ids it holds a Wi-Fi secret for (`mac:<id>`).
    pub const HOST_ID_KEY: &str = "id";
    /// `bench=1` marks Swift's `--bench wifi` (for logs).
    pub const BENCH_KEY: &str = "bench";

    /// `versions` `None`: [`VersionList::offered`]'s. Swift: `LainTXT.dictionary(hostId:versions:bench:)`.
    pub fn dictionary(host_id: &str, versions: Option<&[u8]>, bench: bool) -> Vec<(String, String)> {
        let offered;
        let versions = match versions {
            Some(v) => v,
            None => {
                offered = VersionList::offered().versions();
                &offered
            }
        };
        let newest = versions.iter().max().copied().unwrap_or(0);
        let all = versions.iter().map(u8::to_string).collect::<Vec<_>>().join(",");
        let mut txt = vec![
            (Self::VERSION_KEY.to_owned(), newest.to_string()),
            (Self::VERSIONS_KEY.to_owned(), all),
            (Self::HOST_ID_KEY.to_owned(), host_id.to_owned()),
        ];
        if bench {
            txt.push((Self::BENCH_KEY.to_owned(), "1".to_owned()));
        }
        txt
    }

    /// The versions a TXT record advertises, ascending: `vs`, or a legacy host's single `v`; empty if
    /// neither parses. Swift: `LainTXT.versions(in:)`.
    pub fn versions<'a>(txt: impl IntoIterator<Item = (&'a str, &'a str)>) -> Vec<u8> {
        let (mut v, mut vs) = (None, None);
        for (key, value) in txt {
            match key {
                Self::VERSION_KEY => v = Some(value),
                Self::VERSIONS_KEY => vs = Some(value),
                _ => {}
            }
        }
        if let Some(list) = vs {
            let mut parsed: Vec<u8> = list.split(',').filter_map(|s| s.parse().ok()).collect();
            if !parsed.is_empty() {
                parsed.sort_unstable();
                return parsed;
            }
        }
        v.and_then(|s| s.parse().ok()).map(|v| vec![v]).unwrap_or_default()
    }

    /// The host's advertisement: `_lain._tcp` named `name` on `port`, with [`dictionary`](Self::dictionary)
    /// as its TXT record. Swift: `HostWiFiListener`'s `NetworkStreamListener.Advertisement`.
    pub fn service_ad(name: &str, port: u16, host_id: &str, versions: Option<&[u8]>) -> ServiceAd {
        ServiceAd {
            service_type: BONJOUR_SERVICE_TYPE.to_owned(),
            name: name.to_owned(),
            port,
            txt: Self::dictionary(host_id, versions, false),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST_ID: &str = "6F9619FF-8B86-D011-B42D-00C04FC964FF";

    fn pairs(txt: &[(&'static str, &'static str)]) -> Vec<u8> {
        LainTxt::versions(txt.iter().copied())
    }

    /// Swift: `WiFiDiscovery.txtCarriesTheVersionsAndHostId` (the DNS-SD wire round trip is Avahi's here).
    #[test]
    fn txt_carries_the_versions_and_host_id() {
        let offered = VersionList::offered().versions();
        let expected = vec![
            ("v".to_owned(), offered.last().unwrap().to_string()),
            ("vs".to_owned(), offered.iter().map(u8::to_string).collect::<Vec<_>>().join(",")),
            ("id".to_owned(), HOST_ID.to_owned()),
        ];
        assert_eq!(LainTxt::dictionary(HOST_ID, None, false), expected);
        let s = |a: &str, b: &str| (a.to_owned(), b.to_owned());
        assert_eq!(
            LainTxt::dictionary(HOST_ID, Some(&[3, 4]), true),
            vec![s("v", "4"), s("vs", "3,4"), s("id", HOST_ID), s("bench", "1")]
        );
        let ad = LainTxt::service_ad("lain host", 50_123, HOST_ID, Some(&[3, 4]));
        assert_eq!(ad.service_type, "_lain._tcp");
        assert_eq!((ad.name.as_str(), ad.port), ("lain host", 50_123));
        assert_eq!(ad.txt, vec![s("v", "4"), s("vs", "3,4"), s("id", HOST_ID)]);
    }

    /// Swift: `WiFiDiscovery.theMappingToleratesOddRecords`, the version half (`DiscoveredHost` is the
    /// client's).
    #[test]
    fn versions_tolerate_odd_records() {
        assert_eq!(pairs(&[("id", HOST_ID)]), Vec::<u8>::new());
        assert_eq!(pairs(&[("id", HOST_ID), ("v", "two")]), Vec::<u8>::new());
        assert_eq!(pairs(&[("id", HOST_ID), ("v", "300")]), Vec::<u8>::new());
        // A legacy host advertises only `v`; `vs` wins when it parses.
        assert_eq!(pairs(&[("v", "2")]), vec![2]);
        assert_eq!(pairs(&[("v", "5"), ("vs", "4,x,5")]), vec![4, 5]);
        assert_eq!(pairs(&[("v", "2"), ("vs", "")]), vec![2]);
        assert_eq!(pairs(&[("vs", "4,3")]), vec![3, 4]);
        let ours = LainTxt::dictionary(HOST_ID, Some(&[3, 4]), false);
        assert_eq!(LainTxt::versions(ours.iter().map(|(k, v)| (k.as_str(), v.as_str()))), vec![3, 4]);
    }
}
