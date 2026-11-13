//! v6 sound (Swift: `HostConnection.startAudio`): the desktop's sound to the iPad on the audio channel, the
//! `sound` setting, pongs on the audio channel, and nothing to an older iPad.

mod common;

use std::time::Duration;

use common::*;
use lain_host::HostConfig;
use lain_platform::{AudioChunk, AudioFormat, PlatformError};
use lain_proto::*;

const T: Duration = Duration::from_secs(5);

fn chunk(at: u64) -> AudioChunk {
    AudioChunk { capture_time_ns: at, samples: vec![1, 2, 3, 4] }
}

async fn next_audio(link: &mut ClientLink) -> Option<Message> {
    within(T, link.audio_received.recv()).await.flatten()
}

#[tokio::test]
async fn the_desktops_sound_reaches_a_v6_ipad_and_follows_the_setting() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert_eq!(link.version, NEWEST_VERSION);
    assert!(link.hello_ack().await.is_some());
    let audio = rig.platform.fake.audio.clone();
    assert!(eventually(T, || audio.running().is_some()).await, "the capture starts");
    assert_eq!(audio.running(), Some((AudioFormat::SESSION, 20)), "24 kHz mono in 20 ms packets, as the Mac");
    assert_eq!(
        next_audio(&mut link).await,
        Some(Message::AudioConfig(AudioConfig { sample_rate: 24_000, channels: 1, encoding: AudioEncoding::Pcm16Le }))
    );
    assert!(audio.push(chunk(7)));
    assert_eq!(
        next_audio(&mut link).await,
        Some(Message::AudioPacket(AudioPacket { capture_time_ns: 7, samples: vec![1, 2, 3, 4] }))
    );

    // Off: the capture goes on, nothing is sent; on again: the next packet goes out.
    rig.session.set_sound(false);
    assert!(!rig.session.sound());
    assert!(audio.push(chunk(8)));
    // The setting is read as each packet goes out: let the one captured while off be handled first.
    tokio::time::sleep(Duration::from_millis(200)).await;
    rig.session.set_sound(true);
    assert!(audio.push(chunk(9)));
    let Some(Message::AudioPacket(p)) = next_audio(&mut link).await else { panic!("no packet") };
    assert_eq!(p.capture_time_ns, 9, "the packet captured while off was dropped");

    // The iPad's clock pings on the audio channel are answered there.
    let _ = link.audio.send(&Message::Ping(Ping { id: 3, sent_at_ns: 11 }));
    let Some(Message::Pong(pong)) = next_audio(&mut link).await else { panic!("no pong") };
    assert_eq!((pong.id, pong.ping_sent_at_ns), (3, 11));

    // The capture stops with the session (the iPad, still plugged in, may then start another).
    link.close();
    assert!(eventually(T, || audio.stops() == 1).await, "the capture stops");
}

#[tokio::test]
async fn sound_off_from_the_start_sends_only_the_config() {
    let options =
        RigOptions { config: HostConfig { sound: false, ..RigOptions::default().config }, ..RigOptions::default() };
    let mut rig = Rig::new(options).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    let audio = rig.platform.fake.audio.clone();
    assert!(matches!(next_audio(&mut link).await, Some(Message::AudioConfig(_))));
    assert!(audio.push(chunk(1)));
    assert_eq!(within(Duration::from_millis(300), link.audio_received.recv()).await, None);
}

#[tokio::test]
async fn a_v5_ipad_gets_no_sound() {
    let v5 = VersionList::supported().capped(Some(5));
    let options = RigOptions { client_versions: v5, ..RigOptions::default() };
    let mut rig = Rig::new(options).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert_eq!(link.version, 5);
    assert!(link.hello_ack().await.is_some());
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rig.platform.fake.audio.starts(), 0, "no capture for a peer without sound");
    assert_eq!(within(Duration::from_millis(100), link.audio_received.recv()).await, None);
}

#[tokio::test]
async fn a_failed_capture_is_tried_again() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let audio = rig.platform.fake.audio.clone();
    audio.fail_next_start(PlatformError::Unavailable("no sound server".into()));
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    assert!(matches!(next_audio(&mut link).await, Some(Message::AudioConfig(_))), "the retry sends its config");
    assert_eq!(audio.starts(), 1, "the failed start isn't counted; the retry is");
}
