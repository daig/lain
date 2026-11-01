//! Video back after the owner stopped lain's display on the desktop (GNOME's sharing indicator): by hand
//! (`HostSession::resume_video`) or by itself (`HostConfig::resume_after_stop`). Asked for at the bring-up, where
//! Stop was pressed by accident twice.

mod common;

use std::time::Duration;

use common::*;

fn rig(resume: bool) -> (WifiRig, Vec<u8>) {
    let secret = secret();
    let config = lain_host::HostConfig { resume_after_stop: resume, ..wifi_config() };
    (WifiRig::new(vec![(SERIAL.to_owned(), secret.clone())], config), secret)
}

#[tokio::test(start_paused = true)]
async fn resume_by_hand_closes_the_link_for_a_fresh_session() {
    let (rig, secret) = rig(false);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    assert!(!rig.session.resume_video(), "nothing to resume while video runs");
    rig.platform.video().last_session().unwrap().stop_by_user();
    assert!(eventually(T, || rig.session.video_error().is_some()).await);
    assert!(!ipad.link.closed(Duration::from_secs(3)).await, "input only, not resumed by itself");
    assert!(rig.session.resume_video());
    assert!(ipad.link.closed(T).await, "the iPad reconnects");
    let back = rig.connect(&secret, wifi_hello()).await;
    assert!(back.hello_ack().is_some());
    assert_eq!((rig.platform.display.created(), rig.platform.display.live()), (2, 1), "a new display");
    assert!(rig.session.video_error().is_none());
}

#[tokio::test(start_paused = true)]
async fn resume_after_stop_does_it_once_then_waits() {
    let (rig, secret) = rig(true);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    rig.platform.video().last_session().unwrap().stop_by_user();
    assert!(ipad.link.closed(T).await, "closed by itself after the stop");
    let again = rig.connect(&secret, wifi_hello()).await;
    assert!(again.hello_ack().is_some());
    // A second stop within the gap stays stopped: no loop if the desktop keeps stopping it.
    rig.platform.video().last_session().unwrap().stop_by_user();
    assert!(!again.link.closed(Duration::from_secs(3)).await);
    assert!(rig.session.video_error().is_some());
}
