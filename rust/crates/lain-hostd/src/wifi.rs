//! The Wi-Fi side of the daemon: the `lain-wifi` listener, refreshed on every `secrets_changed`, switched on and
//! off at run time, with the Bonjour ad following its status. Swift: `HostSession`'s ownership of its
//! `HostWiFiListener` (`wifiListener.refresh()`, `stop()`), whose `NetworkStreamListener` advertises while it
//! listens.

use std::time::Duration;

use lain_link::ByteStream;
use lain_platform::{Advertiser, HostIdentity, SecretStore, ServiceAd};
use lain_wifi::{LainTxt, WiFiListener, WiFiListenerOptions, WiFiStatus};
use tokio::sync::{mpsc, oneshot, watch};
use tracing::{debug, info, warn};

/// Why Wi-Fi is off before or without a listener. Runtime "off" is the listener's own `Off("stopped")`.
pub const OFF_IN_CONFIG: &str = "turned off in config.toml";
/// Swift: `HostController`'s "this Mac's lain id couldn't be loaded".
pub const OFF_NO_IDENTITY: &str = "this computer's lain id couldn't be loaded";
/// The listener's own status once cancelled (`lain_wifi::WiFiListener::cancel`).
pub const OFF_STOPPED: &str = "stopped";
/// Wi-Fi switched off, but the cancelled listener never said it stopped and was dropped.
pub const OFF_STOP_UNANSWERED: &str = "stopped (the listener didn't answer)";

/// Why a runtime Wi-Fi switch was refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum WifiControlError {
    /// Without a host id there's nothing to advertise and no `Pair` id: the daemon is USB-only (Swift's
    /// `HostController` without an identity).
    #[error("{OFF_NO_IDENTITY}; the host runs USB-only")]
    NoIdentity,
    /// The daemon is shutting down.
    #[error("the host is stopping")]
    Stopped,
}

pub(crate) enum Command {
    Set(bool, oneshot::Sender<Result<(), WifiControlError>>),
    Shutdown(oneshot::Sender<()>),
}

/// The actor that owns the listener and the advertiser.
pub(crate) struct WifiActor<S, A> {
    pub secrets: S,
    pub options: WiFiListenerOptions,
    /// The session's intake: every listener made sends on a clone of it.
    pub intake: mpsc::Sender<Box<dyn ByteStream>>,
    pub identity: Option<HostIdentity>,
    pub versions: Vec<u8>,
    pub advertiser: Option<A>,
    pub status: watch::Sender<WiFiStatus>,
    pub enabled: watch::Sender<bool>,
    pub secrets_changed: watch::Receiver<u64>,
    /// How long a cancelled listener may take to report `Off("stopped")` before it is dropped.
    pub stop_timeout: Duration,
    pub listener: Option<(WiFiListener, watch::Receiver<WiFiStatus>)>,
    pub advertised: Option<ServiceAd>,
}

impl<S: SecretStore + Clone, A: Advertiser> WifiActor<S, A> {
    pub(crate) async fn run(mut self, mut commands: mpsc::UnboundedReceiver<Command>) {
        // The counter's value now is no news: the first refresh is the listener's own.
        self.secrets_changed.borrow_and_update();
        let mut secrets_open = true;
        loop {
            tokio::select! {
                command = commands.recv() => match command {
                    Some(Command::Set(on, reply)) => {
                        let result = self.set(on).await;
                        let _ = reply.send(result);
                    }
                    Some(Command::Shutdown(reply)) => {
                        self.stop_listener().await;
                        self.withdraw().await;
                        let _ = reply.send(());
                        break;
                    }
                    None => {
                        self.stop_listener().await;
                        self.withdraw().await;
                        break;
                    }
                },
                changed = listener_changed(&mut self.listener) => match changed {
                    Some(status) => self.follow(status).await,
                    // The listener's task ended on its own (it panicked): nothing listens any more.
                    None => {
                        warn!("Wi-Fi: the listener ended unexpectedly");
                        self.listener = None;
                        self.follow(WiFiStatus::Failed("the listener ended".into())).await;
                    }
                },
                changed = self.secrets_changed.changed(), if secrets_open => match changed {
                    Ok(()) => {
                        if let Some((listener, _)) = &self.listener {
                            debug!("Wi-Fi: the pairings may have changed; re-reading them");
                            listener.refresh();
                        }
                    }
                    Err(_) => secrets_open = false,
                },
            }
        }
    }

    /// Starts the listener if there's none (Swift: `HostWiFiListener.start`; nothing listens before its first
    /// refresh).
    pub(crate) fn start_listener(&mut self) -> Result<(), WifiControlError> {
        if self.identity.is_none() {
            return Err(WifiControlError::NoIdentity);
        }
        self.enabled.send_replace(true);
        if self.listener.is_some() {
            return Ok(());
        }
        let listener = WiFiListener::new(self.secrets.clone(), self.options.clone(), self.intake.clone());
        listener.refresh();
        let mut status = listener.status();
        let now = status.borrow_and_update().clone();
        self.listener = Some((listener, status));
        self.status.send_replace(now);
        Ok(())
    }

    async fn set(&mut self, on: bool) -> Result<(), WifiControlError> {
        if on {
            info!("Wi-Fi: turned on");
            self.start_listener()?;
            // The status follows from the listener's watch.
            Ok(())
        } else {
            info!("Wi-Fi: turned off");
            self.enabled.send_replace(false);
            self.stop_listener().await;
            self.withdraw().await;
            Ok(())
        }
    }

    /// Cancels the listener (not a drop: a drop aborts its task, and the status would never say
    /// `Off("stopped")`), waits for it to say `Off("stopped")` itself, then drops it. An `Off` it showed before
    /// the cancel (no pairing yet, say) is not the answer: Wi-Fi is now off because it was switched off. A
    /// listener that doesn't answer within `stop_timeout` is dropped anyway, and the status says so
    /// ([`OFF_STOP_UNANSWERED`]) rather than pretending it stopped by itself.
    async fn stop_listener(&mut self) {
        let Some((listener, mut status)) = self.listener.take() else { return };
        listener.cancel();
        let answered = tokio::time::timeout(self.stop_timeout, async {
            loop {
                if *status.borrow_and_update() == WiFiStatus::Off(OFF_STOPPED.into()) {
                    return;
                }
                // Closed: the listener's actor ended, and its exit publishes `Off("stopped")` first.
                if status.changed().await.is_err() {
                    return;
                }
            }
        })
        .await
        .is_ok();
        drop(listener);
        if answered {
            self.publish(WiFiStatus::Off(OFF_STOPPED.into()));
        } else {
            warn!("Wi-Fi: the listener didn't stop within {:?}; dropped it", self.stop_timeout);
            self.publish(WiFiStatus::Off(OFF_STOP_UNANSWERED.into()));
        }
    }

    fn publish(&self, status: WiFiStatus) {
        self.status.send_if_modified(|current| {
            let changed = *current != status;
            *current = status;
            changed
        });
    }

    /// Publishes `status` and makes the ad follow it: advertised while listening, withdrawn otherwise.
    async fn follow(&mut self, status: WiFiStatus) {
        self.publish(status.clone());
        match (status.port(), &self.identity) {
            (Some(port), Some(identity)) => {
                let ad = LainTxt::service_ad(&identity.name, port, &identity.id, Some(&self.versions));
                self.advertise(ad).await;
            }
            _ => self.withdraw().await,
        }
    }

    async fn advertise(&mut self, ad: ServiceAd) {
        if self.advertised.as_ref() == Some(&ad) {
            return;
        }
        let Some(advertiser) = &self.advertiser else {
            debug!("Wi-Fi: listening on port {} with nothing to advertise it", ad.port);
            return;
        };
        match advertiser.advertise(ad.clone()).await {
            Ok(()) => info!("Wi-Fi: advertising {:?} ({}) on port {}", ad.name, ad.service_type, ad.port),
            // Avahi keeps an ad it couldn't publish yet and publishes it when it can.
            Err(e) => warn!("Wi-Fi: couldn't advertise {:?} on port {}: {e}", ad.name, ad.port),
        }
        self.advertised = Some(ad);
    }

    async fn withdraw(&mut self) {
        if self.advertised.take().is_none() {
            return;
        }
        if let Some(advertiser) = &self.advertiser {
            advertiser.withdraw().await;
            info!("Wi-Fi: no longer advertised");
        }
    }
}

/// The listener's next status change; `None` if its task ended; never, without a listener.
async fn listener_changed(listener: &mut Option<(WiFiListener, watch::Receiver<WiFiStatus>)>) -> Option<WiFiStatus> {
    match listener {
        Some((_, status)) => match status.changed().await {
            Ok(()) => Some(status.borrow_and_update().clone()),
            Err(_) => None,
        },
        None => std::future::pending().await,
    }
}
