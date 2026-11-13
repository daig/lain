//! v7: the client chooses its display's scale (`Hello.desiredScale`) from the scales the host offers
//! (`HelloAck.displayScales`), and the host says which it applied (`HelloAck.displayScale`). Swift:
//! `DisplayScaleTests`.

mod common;

use std::time::Duration;

use common::*;
use lain_platform::DisplayBackend;
use lain_proto::*;

const T: Duration = Duration::from_secs(5);

fn duo(desired_scale: u16) -> Hello {
    Hello {
        device_model: "iPhone19,4".into(),
        pixel_width: 2853,
        pixel_height: 2007,
        scale: 3,
        desired_scale,
        ..hello()
    }
}

#[tokio::test]
async fn a_duo_asking_for_three_gets_its_display_at_three() {
    let mut rig = Rig::new(RigOptions { usb_hello: duo(300), ..RigOptions::default() }).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert_eq!(link.version, NEWEST_VERSION);
    let ack = link.hello_ack().await.expect("HelloAck");
    assert_eq!(ack.display_scale, 300);
    assert_eq!(ack.display_scales, [100, 125, 150, 175, 200, 225, 250, 275, 300]);
    // Made a few pixels smaller so that Mutter can apply 3× exactly: 950×668 points.
    let session = rig.platform.video().last_session().expect("video started");
    assert_eq!((session.config().width, session.config().height), (2850, 2004));
    assert_eq!((ack.display_point_width, ack.display_point_height), (950, 668));
    assert_eq!(rig.platform.display.applied_scale(), Some(3.0));
    rig.session.stop().await;
}

#[tokio::test]
async fn a_scale_between_the_offered_ones_gets_the_nearest() {
    let mut rig = Rig::new(RigOptions { usb_hello: duo(240), ..RigOptions::default() }).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert_eq!(link.hello_ack().await.expect("HelloAck").display_scale, 250);
    rig.session.stop().await;
}

#[tokio::test]
async fn a_client_choosing_none_gets_the_hosts_own() {
    let mut rig = Rig::new(RigOptions { usb_hello: duo(0), ..RigOptions::default() }).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    let ack = link.hello_ack().await.expect("HelloAck");
    assert_eq!(ack.display_scale, 200);
    let session = rig.platform.video().last_session().expect("video started");
    assert_eq!((session.config().width, session.config().height), (2852, 2006));
    rig.session.stop().await;
}
