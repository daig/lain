//! The desktop as the contract sees it: [`Monitor`]s with stable ids, built from a [`DisplayState`] (Swift:
//! `DisplayLayoutProvider.layout`, which reads `CGDisplayBounds`; here `GetCurrentState`).

use std::collections::HashMap;

use lain_platform::{Monitor, RectF};

use crate::display_config::{DisplayState, IRect, MonitorSpec};

/// Host-run-stable monitor ids, keyed by monitor spec: a monitor keeps its id while it exists and gets it back
/// if it returns; an id never goes to another spec. lain's virtual monitor has a new serial every session, so
/// each session's display gets a new id (Swift: a `CGDirectDisplayID`, which macOS keeps per display).
#[derive(Debug, Default)]
pub struct IdMap {
    ids: HashMap<MonitorSpec, u32>,
    next: u32,
}

impl IdMap {
    pub fn id(&mut self, spec: &MonitorSpec) -> u32 {
        if let Some(id) = self.ids.get(spec) {
            return *id;
        }
        self.next += 1;
        self.ids.insert(spec.clone(), self.next);
        self.next
    }
}

/// One logical monitor with what the bridge needs beyond the contract's [`Monitor`].
#[derive(Debug, Clone, PartialEq)]
pub struct DesktopMonitor {
    pub monitor: Monitor,
    /// The monitor shown in it (the first, if mirrored): what `RecordMonitor` takes.
    pub spec: MonitorSpec,
    pub rect: IRect,
    pub scale: f64,
    pub is_virtual: bool,
    /// Its current mode: `(width, height, refresh)` in device pixels.
    pub mode: Option<(i32, i32, f64)>,
}

/// The desktop at one `GetCurrentState`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Desktop {
    pub serial: u32,
    pub monitors: Vec<DesktopMonitor>,
}

impl Desktop {
    /// The contract's view.
    pub fn contract_monitors(&self) -> Vec<Monitor> {
        self.monitors.iter().map(|m| m.monitor.clone()).collect()
    }

    pub fn by_connector(&self, connector: &str) -> Option<&DesktopMonitor> {
        self.monitors.iter().find(|m| m.spec.connector == connector)
    }

    pub fn lain(&self) -> Option<&DesktopMonitor> {
        self.monitors.iter().find(|m| m.monitor.lain)
    }

    /// The connectors present, in order.
    pub fn connectors(&self) -> Vec<String> {
        self.monitors.iter().map(|m| m.spec.connector.clone()).collect()
    }

    /// A real monitor besides lain's (Swift: `HostSetupProbe.hasOtherDisplay`, which leaves out lain's virtual
    /// display by vendor). Other virtual monitors (another remote-desktop client's) don't count either.
    pub fn has_other_display(&self) -> bool {
        self.monitors.iter().any(|m| !m.monitor.lain && !m.is_virtual)
    }
}

/// Builds the desktop from `state`, marking `lain_connector` as lain's display. One entry per logical
/// monitor, in Mutter's order. Bounds are the position plus the mode divided by the scale (transform-aware); a
/// logical monitor whose monitor has no current mode is left out.
pub fn build(state: &DisplayState, lain_connector: Option<&str>, ids: &mut IdMap) -> Desktop {
    let monitors = state
        .logical
        .iter()
        .filter_map(|l| {
            let spec = l.monitors.first()?.clone();
            let info = state.monitor(&spec.connector)?;
            let rect = state.rect_of(l)?;
            let lain = lain_connector.is_some_and(|c| l.monitors.iter().any(|s| s.connector == c));
            let mode = info.current_mode().map(|m| (m.width, m.height, m.refresh));
            Some(DesktopMonitor {
                monitor: Monitor {
                    id: ids.id(&spec),
                    bounds: RectF::new(
                        f64::from(rect.x),
                        f64::from(rect.y),
                        f64::from(rect.width),
                        f64::from(rect.height),
                    ),
                    primary: l.primary,
                    lain,
                },
                is_virtual: info.is_virtual(),
                spec,
                rect,
                scale: l.scale,
                mode,
            })
        })
        .collect();
    Desktop { serial: state.serial, monitors }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::display_config::{parse_state, tests::reference_raw};

    #[test]
    fn monitors_with_lain_marked() {
        let state = parse_state(reference_raw(2.0));
        let mut ids = IdMap::default();
        let d = build(&state, Some("Meta-0"), &mut ids);
        let m = d.contract_monitors();
        assert_eq!(m.len(), 2);
        assert_eq!(m[0], Monitor { id: 1, bounds: RectF::new(0.0, 0.0, 3840.0, 2160.0), primary: true, lain: false });
        assert_eq!(m[1], Monitor { id: 2, bounds: RectF::new(3840.0, 0.0, 1376.0, 1032.0), primary: false, lain: true });
        assert!(d.has_other_display());
        assert_eq!(d.lain().unwrap().mode, Some((2752, 2064, 120.0)));
        // Unmarked when lain's display isn't recorded (another client's virtual monitor).
        assert!(!build(&state, None, &mut ids).monitors.iter().any(|m| m.monitor.lain));
    }

    #[test]
    fn ids_are_stable_per_spec_and_never_reused() {
        let mut ids = IdMap::default();
        let a = MonitorSpec::new("HDMI-1", "SAM", "X", "1");
        let v1 = MonitorSpec::new("Meta-0", "MetaVendor", "Virtual remote monitor", "0x000001");
        let v2 = MonitorSpec::new("Meta-0", "MetaVendor", "Virtual remote monitor", "0x000002");
        assert_eq!(ids.id(&a), 1);
        assert_eq!(ids.id(&v1), 2);
        assert_eq!(ids.id(&a), 1);
        // The next session's virtual monitor has a new serial, so a new id.
        assert_eq!(ids.id(&v2), 3);
        assert_eq!(ids.id(&v1), 2);
    }

    #[test]
    fn no_other_display_when_only_virtual_monitors() {
        let mut state = parse_state(reference_raw(2.0));
        state.logical.remove(0);
        let d = build(&state, Some("Meta-0"), &mut IdMap::default());
        assert!(!d.has_other_display());
    }
}
