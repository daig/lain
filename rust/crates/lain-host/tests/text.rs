//! v6 `TextInput` (Swift: `InputInjector.text`): text typed as the keys of the desktop's layout.

mod common;

use std::time::Duration;

use common::*;
use lain_platform::InputAction;
use lain_proto::*;

const T: Duration = Duration::from_secs(5);

fn keys(actions: &[InputAction]) -> Vec<(u16, bool)> {
    actions
        .iter()
        .filter_map(|a| match *a {
            InputAction::Key { code, down } => Some((code, down)),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn dictated_text_is_typed_on_the_desktops_layout() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    // "Hi’" (a typographic apostrophe, as dictation writes it), then Control-c from the on-screen keyboard.
    link.send(Message::TextInput(TextInput { text: "Hi\u{2019}\n".into(), modifiers: ModifierFlags::EMPTY }));
    link.send(Message::TextInput(TextInput { text: "c".into(), modifiers: ModifierFlags::CONTROL }));
    let want = vec![
        (42, true),
        (35, true),
        (35, false),
        (42, false), // H
        (23, true),
        (23, false), // i
        (40, true),
        (40, false), // ’ as '
        (28, true),
        (28, false), // Return
        (29, true),
        (46, true),
        (46, false),
        (29, false), // Control-c
    ];
    assert!(eventually(T, || keys(&rig.actions()) == want).await, "{:?}", keys(&rig.actions()));
    rig.session.stop().await;
}
