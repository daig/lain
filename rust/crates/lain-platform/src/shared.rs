//! Every bridge trait is implemented for `Arc<T>`, delegating to `T`, so one implementation can serve both
//! the [`Platform`](crate::Platform) bundle and the tasks that need an owned handle of their own: an
//! acceptor's secret store, a cursor monitor's source and clock. Only this crate can write these impls
//! (the orphan rule keeps them out of the consumers).

use std::collections::BTreeMap;
use std::future::Future;
use std::sync::Arc;

use tokio::sync::{mpsc, watch};

use crate::{
    Advertiser, Clock, CursorImage, CursorSource, DisplayBackend, DisplaySpec, EncodeConfig, EncodeRequest,
    InputAction, InputBackend, InputSettings, Monitor, PointF, PowerBackend, Result, SecretStore, ServiceAd,
    SettingsSource, SetupReport, SetupSource, StreamInfo, StreamedDisplay, VideoBackend, VideoEvent, VideoSession,
};

impl<T: Advertiser> Advertiser for Arc<T> {
    fn advertise(&self, ad: ServiceAd) -> impl Future<Output = Result<()>> + Send {
        (**self).advertise(ad)
    }

    fn withdraw(&self) -> impl Future<Output = ()> + Send {
        (**self).withdraw()
    }
}

impl<T: Clock + ?Sized> Clock for Arc<T> {
    fn now_ns(&self) -> u64 {
        (**self).now_ns()
    }
}

impl<T: CursorSource + ?Sized> CursorSource for Arc<T> {
    fn current(&self) -> Option<Arc<CursorImage>> {
        (**self).current()
    }
}

impl<T: DisplayBackend> DisplayBackend for Arc<T> {
    type Source = T::Source;

    fn create(&self, spec: DisplaySpec) -> impl Future<Output = Result<(StreamedDisplay, Self::Source)>> + Send {
        (**self).create(spec)
    }

    fn destroy(&self) -> impl Future<Output = ()> + Send {
        (**self).destroy()
    }

    fn monitors(&self) -> watch::Receiver<Vec<Monitor>> {
        (**self).monitors()
    }

    fn cursor_location(&self) -> Option<PointF> {
        (**self).cursor_location()
    }

    fn applied_scale(&self) -> Option<f64> {
        (**self).applied_scale()
    }
}

impl<T: InputBackend + ?Sized> InputBackend for Arc<T> {
    fn apply(&self, actions: &[InputAction]) {
        (**self).apply(actions)
    }
}

impl<T: PowerBackend + ?Sized> PowerBackend for Arc<T> {
    fn set_awake(&self, awake: bool) {
        (**self).set_awake(awake)
    }

    fn user_activity(&self) {
        (**self).user_activity()
    }
}

impl<T: SecretStore> SecretStore for Arc<T> {
    fn secret(&self, account: &str) -> impl Future<Output = Result<Option<Vec<u8>>>> + Send {
        (**self).secret(account)
    }

    fn set_secret(&self, account: &str, secret: &[u8]) -> impl Future<Output = Result<()>> + Send {
        (**self).set_secret(account, secret)
    }

    fn remove_secret(&self, account: &str) -> impl Future<Output = Result<()>> + Send {
        (**self).remove_secret(account)
    }

    fn all_secrets(&self) -> impl Future<Output = Result<BTreeMap<String, Vec<u8>>>> + Send {
        (**self).all_secrets()
    }
}

impl<T: SettingsSource + ?Sized> SettingsSource for Arc<T> {
    fn input_settings(&self) -> InputSettings {
        (**self).input_settings()
    }
}

impl<T: SetupSource + ?Sized> SetupSource for Arc<T> {
    fn setup(&self) -> SetupReport {
        (**self).setup()
    }
}

impl<T: VideoBackend> VideoBackend for Arc<T> {
    type Source = T::Source;
    type Session = T::Session;

    fn start(
        &self,
        source: &Self::Source,
        config: EncodeConfig,
    ) -> impl Future<Output = Result<(Self::Session, mpsc::UnboundedReceiver<VideoEvent>)>> + Send {
        (**self).start(source, config)
    }
}

impl<T: VideoSession + ?Sized> VideoSession for Arc<T> {
    fn info(&self) -> StreamInfo {
        (**self).info()
    }

    fn encode(&self, request: EncodeRequest) {
        (**self).encode(request)
    }

    fn stop(&self) -> impl Future<Output = ()> + Send {
        (**self).stop()
    }
}

#[cfg(all(test, feature = "fake"))]
mod tests {
    use super::*;
    use crate::fake::{FakeClock, FakeCursor, FakeDisplay, FakeVideo, MemorySecretStore};

    // A generic consumer that owns its handles, as lain-link's acceptor and lain-media's cursor monitor do.
    fn owned<S: SecretStore, C: CursorSource, K: Clock>(store: S, cursor: C, clock: K) -> (S, C, K) {
        (store, cursor, clock)
    }

    fn display<D: DisplayBackend>(_: &D) {}
    fn video<V: VideoBackend>(_: &V) {}

    #[tokio::test]
    async fn shared_handles_delegate() {
        let store = Arc::new(MemorySecretStore::with([("host".to_string(), vec![1, 2, 3])]));
        let clock = Arc::new(FakeClock::new(5));
        let cursor: Arc<dyn CursorSource> = Arc::new(FakeCursor::default());
        let (store2, cursor2, clock2) = owned(store.clone(), cursor.clone(), clock.clone());

        store2.set_secret("mac:1", &[9]).await.unwrap();
        assert_eq!(store.snapshot().get("mac:1"), Some(&vec![9]));
        assert_eq!(store2.secret("host").await.unwrap(), Some(vec![1, 2, 3]));
        assert_eq!(store2.all_secrets().await.unwrap().len(), 2);
        store2.remove_secret("mac:1").await.unwrap();
        assert!(!store.snapshot().contains_key("mac:1"));

        clock.advance(10);
        assert_eq!(clock2.now_ns(), 15);
        assert!(cursor2.current().is_none());

        display(&Arc::new(FakeDisplay::new()));
        video(&Arc::new(FakeVideo::new(FakeClock::new(0))));
    }
}

impl<T: crate::AudioBackend> crate::AudioBackend for Arc<T> {
    type Capture = T::Capture;

    fn start(
        &self,
        format: crate::AudioFormat,
        chunk_ms: u32,
    ) -> impl Future<Output = Result<(Self::Capture, mpsc::Receiver<crate::AudioChunk>)>> + Send {
        (**self).start(format, chunk_ms)
    }
}
