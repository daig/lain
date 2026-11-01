//! `org.gnome.Mutter.DisplayConfig`: the desktop's monitors as `GetCurrentState` reports them, and the
//! arguments of `ApplyMonitorsConfig` (decision L8; no Swift counterpart: the Mac host never moves displays,
//! `DisplayLayoutProvider` only reads `CGDisplayBounds`).
//!
//! Only `ApplyMonitorsConfig`'s **method 1 (temporary)** is representable here: [`APPLY_METHOD`] is a
//! constant and [`apply_args`] takes no method. Method 2 (persistent) makes GNOME Shell ask "Keep these
//! display settings?" and revert after about 20 s, which nobody at the iPad can answer (spike B, §3).

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use zbus::zvariant::{OwnedValue, Value};

/// `ApplyMonitorsConfig`'s method: 1, temporary. The only one lain ever sends (see the module docs).
pub const APPLY_METHOD: u32 = 1;

/// A monitor's identity in Mutter: `(connector, vendor, product, serial)`. A physical monitor's spec is
/// stable; a virtual one's serial changes with every session (spike B, §1).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct MonitorSpec {
    pub connector: String,
    pub vendor: String,
    pub product: String,
    pub serial: String,
}

impl MonitorSpec {
    pub fn new(connector: &str, vendor: &str, product: &str, serial: &str) -> Self {
        Self {
            connector: connector.to_owned(),
            vendor: vendor.to_owned(),
            product: product.to_owned(),
            serial: serial.to_owned(),
        }
    }

    /// The same physical monitor, possibly on another connector.
    pub fn same_device(&self, other: &MonitorSpec) -> bool {
        self.vendor == other.vendor && self.product == other.product && self.serial == other.serial
    }
}

/// One mode of a monitor.
#[derive(Debug, Clone, PartialEq)]
pub struct Mode {
    /// Mutter's mode id, e.g. `2752x2064@120.000`: what `ApplyMonitorsConfig` takes.
    pub id: String,
    pub width: i32,
    pub height: i32,
    pub refresh: f64,
    pub current: bool,
}

/// One monitor (Mutter: a "physical" monitor, which may be virtual).
#[derive(Debug, Clone, PartialEq)]
pub struct MonitorInfo {
    pub spec: MonitorSpec,
    pub modes: Vec<Mode>,
    /// The `is-virtual` property, where Mutter reports it.
    pub is_virtual_prop: Option<bool>,
}

impl MonitorInfo {
    pub fn current_mode(&self) -> Option<&Mode> {
        self.modes.iter().find(|m| m.current)
    }

    /// A virtual monitor (lain's, or another remote-desktop client's) rather than a real one. Mutter names its
    /// virtual monitors `Meta-<n>`, vendor `MetaVendor` (spike B, §1).
    pub fn is_virtual(&self) -> bool {
        self.is_virtual_prop.unwrap_or(false)
            || self.spec.connector.starts_with("Meta-")
            || self.spec.vendor == "MetaVendor"
    }
}

/// One logical monitor: a region of the global space shown by one or more (mirrored) monitors.
#[derive(Debug, Clone, PartialEq)]
pub struct LogicalMonitor {
    pub x: i32,
    pub y: i32,
    pub scale: f64,
    pub transform: u32,
    pub primary: bool,
    pub monitors: Vec<MonitorSpec>,
}

/// `layout-mode`: logical (1, the default under `scale-monitor-framebuffer`) or physical (2).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutMode {
    /// Positions and sizes are logical pixels: a monitor's size is its mode divided by its scale.
    Logical,
    /// Positions and sizes are device pixels.
    Physical,
}

/// The desktop as one `GetCurrentState` reply.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayState {
    /// Passed back to `ApplyMonitorsConfig`, which refuses a stale one.
    pub serial: u32,
    pub monitors: Vec<MonitorInfo>,
    pub logical: Vec<LogicalMonitor>,
    pub layout_mode: LayoutMode,
}

/// An integer rectangle in the global space (logical pixels in logical layout mode).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct IRect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl IRect {
    pub const fn new(x: i32, y: i32, width: i32, height: i32) -> Self {
        Self { x, y, width, height }
    }

    pub fn max_x(&self) -> i32 {
        self.x + self.width
    }

    pub fn max_y(&self) -> i32 {
        self.y + self.height
    }

    /// The interiors intersect (touching edges don't count).
    pub fn overlaps(&self, other: &IRect) -> bool {
        self.x < other.max_x() && other.x < self.max_x() && self.y < other.max_y() && other.y < self.max_y()
    }
}

/// A transform that turns the monitor by 90° or 270° (Mutter's `MetaMonitorTransform`: 1, 3, 5, 7), so its
/// logical width is the mode's height.
pub fn transform_swaps_axes(transform: u32) -> bool {
    transform % 2 == 1
}

/// The size a monitor with `mode` occupies in the global space at `scale` and `transform`.
pub fn logical_size(width: i32, height: i32, scale: f64, transform: u32, layout_mode: LayoutMode) -> (i32, i32) {
    let (w, h) = if transform_swaps_axes(transform) { (height, width) } else { (width, height) };
    match layout_mode {
        LayoutMode::Physical => (w, h),
        LayoutMode::Logical => {
            let s = if scale > 0.0 { scale } else { 1.0 };
            ((f64::from(w) / s).round() as i32, (f64::from(h) / s).round() as i32)
        }
    }
}

impl DisplayState {
    pub fn monitor(&self, connector: &str) -> Option<&MonitorInfo> {
        self.monitors.iter().find(|m| m.spec.connector == connector)
    }

    /// The logical monitor showing `connector`.
    pub fn logical_of(&self, connector: &str) -> Option<&LogicalMonitor> {
        self.logical.iter().find(|l| l.monitors.iter().any(|s| s.connector == connector))
    }

    /// A logical monitor's rectangle: its position and its first monitor's current mode at its scale.
    pub fn rect_of(&self, logical: &LogicalMonitor) -> Option<IRect> {
        let mode = logical.monitors.first().and_then(|s| self.monitor(&s.connector)).and_then(|m| m.current_mode())?;
        let (w, h) = logical_size(mode.width, mode.height, logical.scale, logical.transform, self.layout_mode);
        Some(IRect::new(logical.x, logical.y, w, h))
    }

    /// Every monitor's spec, the set lain's arrangement depends on.
    pub fn monitor_set(&self) -> std::collections::BTreeSet<MonitorSpec> {
        self.monitors.iter().map(|m| m.spec.clone()).collect()
    }
}

/// `GetCurrentState`'s reply, as zvariant decodes `(ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv})`.
pub type RawMode = (String, i32, i32, f64, f64, Vec<f64>, HashMap<String, OwnedValue>);
pub type RawSpec = (String, String, String, String);
pub type RawMonitor = (RawSpec, Vec<RawMode>, HashMap<String, OwnedValue>);
pub type RawLogical = (i32, i32, f64, u32, bool, Vec<RawSpec>, HashMap<String, OwnedValue>);
pub type RawState = (u32, Vec<RawMonitor>, Vec<RawLogical>, HashMap<String, OwnedValue>);

fn prop_bool(props: &HashMap<String, OwnedValue>, key: &str) -> Option<bool> {
    props.get(key).and_then(|v| bool::try_from(&**v).ok())
}

fn prop_u32(props: &HashMap<String, OwnedValue>, key: &str) -> Option<u32> {
    props.get(key).and_then(|v| u32::try_from(&**v).ok())
}

fn spec(raw: RawSpec) -> MonitorSpec {
    MonitorSpec { connector: raw.0, vendor: raw.1, product: raw.2, serial: raw.3 }
}

/// Decodes a `GetCurrentState` reply. A missing `layout-mode` means logical, Mutter's default here.
pub fn parse_state(raw: RawState) -> DisplayState {
    let (serial, monitors, logical, props) = raw;
    let monitors = monitors
        .into_iter()
        .map(|(s, modes, mprops)| MonitorInfo {
            spec: spec(s),
            modes: modes
                .into_iter()
                .map(|(id, width, height, refresh, _preferred_scale, _scales, p)| Mode {
                    id,
                    width,
                    height,
                    refresh,
                    current: prop_bool(&p, "is-current").unwrap_or(false),
                })
                .collect(),
            is_virtual_prop: prop_bool(&mprops, "is-virtual"),
        })
        .collect();
    let logical = logical
        .into_iter()
        .map(|(x, y, scale, transform, primary, specs, _)| LogicalMonitor {
            x,
            y,
            scale,
            transform,
            primary,
            monitors: specs.into_iter().map(spec).collect(),
        })
        .collect();
    let layout_mode = match prop_u32(&props, "layout-mode") {
        Some(2) => LayoutMode::Physical,
        _ => LayoutMode::Logical,
    };
    DisplayState { serial, monitors, logical, layout_mode }
}

/// One logical monitor of a configuration to apply.
#[derive(Debug, Clone, PartialEq)]
pub struct LogicalConfig {
    pub x: i32,
    pub y: i32,
    pub scale: f64,
    pub transform: u32,
    pub primary: bool,
    /// `(connector, mode id)` of each monitor shown in it.
    pub monitors: Vec<(String, String)>,
}

/// `ApplyMonitorsConfig`'s arguments: `(u serial, u method, a(iiduba(ssa{sv})) logical_monitors, a{sv}
/// properties)`.
pub type ApplyArgs<'a> = (
    u32,
    u32,
    Vec<(i32, i32, f64, u32, bool, Vec<(String, String, HashMap<String, Value<'a>>)>)>,
    HashMap<String, Value<'a>>,
);

/// The arguments for applying `config` against the state with `serial`, always with [`APPLY_METHOD`]
/// (temporary). No properties: the layout mode stays as it is.
pub fn apply_args(serial: u32, config: &[LogicalConfig]) -> ApplyArgs<'static> {
    let logical = config
        .iter()
        .map(|l| {
            let monitors = l.monitors.iter().map(|(c, m)| (c.clone(), m.clone(), HashMap::new())).collect();
            (l.x, l.y, l.scale, l.transform, l.primary, monitors)
        })
        .collect();
    (serial, APPLY_METHOD, logical, HashMap::new())
}

/// The configuration that keeps every logical monitor as it is (moved by `shift`, which keeps the layout's
/// top-left at the origin), except `connector`'s, which goes to `at` with `scale`. Mode, transform and the
/// primary flag stay as they are. `None` if a monitor has no current mode (nothing to apply it with).
pub fn config_with(
    state: &DisplayState,
    connector: &str,
    at: (i32, i32),
    scale: f64,
    shift: (i32, i32),
) -> Option<Vec<LogicalConfig>> {
    state
        .logical
        .iter()
        .map(|l| {
            let monitors = l
                .monitors
                .iter()
                .map(|s| Some((s.connector.clone(), state.monitor(&s.connector)?.current_mode()?.id.clone())))
                .collect::<Option<Vec<_>>>()?;
            let is_lain = l.monitors.iter().any(|s| s.connector == connector);
            let (x, y, scale) = if is_lain { (at.0, at.1, scale) } else { (l.x + shift.0, l.y + shift.1, l.scale) };
            Some(LogicalConfig { x, y, scale, transform: l.transform, primary: l.primary, monitors })
        })
        .collect()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use zbus::zvariant::{DynamicType, serialized::Context, to_bytes};

    pub(crate) fn owned(v: Value<'_>) -> OwnedValue {
        v.try_to_owned().unwrap()
    }

    fn raw_mode(id: &str, w: i32, h: i32, hz: f64, current: bool) -> RawMode {
        let mut p = HashMap::new();
        if current {
            p.insert("is-current".to_owned(), owned(Value::from(true)));
        }
        (id.to_owned(), w, h, hz, 1.0, vec![1.0, 2.0], p)
    }

    fn raw_spec(c: &str, v: &str, p: &str, s: &str) -> RawSpec {
        (c.to_owned(), v.to_owned(), p.to_owned(), s.to_owned())
    }

    /// The reference machine with lain's display up, as spike B saw it (`HDMI-1` primary at the origin,
    /// `Meta-0` to its right at scale 1).
    pub(crate) fn reference_raw(lain_scale: f64) -> RawState {
        let hdmi = raw_spec("HDMI-1", "SAM", "Odyssey G95NC", "HNTY301882");
        let meta = raw_spec("Meta-0", "MetaVendor", "Virtual remote monitor", "0x000001");
        let mut layout = HashMap::new();
        layout.insert("layout-mode".to_owned(), owned(Value::from(1u32)));
        (
            7,
            vec![
                (
                    hdmi.clone(),
                    vec![
                        raw_mode("3840x2160@60.000", 3840, 2160, 60.0, true),
                        raw_mode("1920x1080@60.000", 1920, 1080, 60.0, false),
                    ],
                    HashMap::new(),
                ),
                (meta.clone(), vec![raw_mode("2752x2064@120.000", 2752, 2064, 120.0, true)], HashMap::new()),
            ],
            vec![
                (0, 0, 1.0, 0, true, vec![hdmi], HashMap::new()),
                (3840, 0, lain_scale, 0, false, vec![meta], HashMap::new()),
            ],
            layout,
        )
    }

    #[test]
    fn parses_the_reference_state() {
        let s = parse_state(reference_raw(1.0));
        assert_eq!(s.serial, 7);
        assert_eq!(s.layout_mode, LayoutMode::Logical);
        assert_eq!(s.monitors.len(), 2);
        assert_eq!(s.monitors[0].current_mode().unwrap().id, "3840x2160@60.000");
        assert!(!s.monitors[0].is_virtual());
        assert!(s.monitors[1].is_virtual());
        let lain = s.logical_of("Meta-0").unwrap();
        assert_eq!(s.rect_of(lain), Some(IRect::new(3840, 0, 2752, 2064)));
        let s2 = parse_state(reference_raw(2.0));
        assert_eq!(s2.rect_of(s2.logical_of("Meta-0").unwrap()), Some(IRect::new(3840, 0, 1376, 1032)));
    }

    #[test]
    fn parses_physical_layout_mode() {
        let mut raw = reference_raw(2.0);
        raw.3.insert("layout-mode".to_owned(), owned(Value::from(2u32)));
        let s = parse_state(raw);
        assert_eq!(s.layout_mode, LayoutMode::Physical);
        // In physical mode a monitor occupies its mode's size whatever its scale.
        assert_eq!(s.rect_of(s.logical_of("Meta-0").unwrap()), Some(IRect::new(3840, 0, 2752, 2064)));
    }

    #[test]
    fn rotated_monitors_swap_axes() {
        assert_eq!(logical_size(2752, 2064, 2.0, 1, LayoutMode::Logical), (1032, 1376));
        assert_eq!(logical_size(2752, 2064, 2.0, 2, LayoutMode::Logical), (1376, 1032));
        assert_eq!(logical_size(2752, 2064, 2.0, 7, LayoutMode::Physical), (2064, 2752));
        assert_eq!(logical_size(3840, 2160, 1.3333333730697632, 0, LayoutMode::Logical), (2880, 1620));
    }

    #[test]
    fn apply_args_have_mutters_signature_and_method_one() {
        let s = parse_state(reference_raw(1.0));
        let config = config_with(&s, "Meta-0", (3840, 0), 2.0, (0, 0)).unwrap();
        assert_eq!(
            config,
            vec![
                LogicalConfig {
                    x: 0,
                    y: 0,
                    scale: 1.0,
                    transform: 0,
                    primary: true,
                    monitors: vec![("HDMI-1".into(), "3840x2160@60.000".into())]
                },
                LogicalConfig {
                    x: 3840,
                    y: 0,
                    scale: 2.0,
                    transform: 0,
                    primary: false,
                    monitors: vec![("Meta-0".into(), "2752x2064@120.000".into())]
                },
            ]
        );
        let args = apply_args(s.serial, &config);
        assert_eq!(args.0, 7);
        assert_eq!(args.1, 1, "temporary, never persistent");
        assert_eq!(<ApplyArgs<'_> as DynamicType>::signature(&args).to_string(), "(uua(iiduba(ssa{sv}))a{sv})");
        // It serializes as a D-Bus body.
        let ctx = Context::new_dbus(zbus::zvariant::LE, 0);
        assert!(to_bytes(ctx, &args).unwrap().len() > 40);
    }

    #[test]
    fn config_shifts_the_other_monitors() {
        // The iPad to the left: HDMI-1 moves right by lain's width.
        let s = parse_state(reference_raw(1.0));
        let config = config_with(&s, "Meta-0", (0, 0), 2.0, (1376, 0)).unwrap();
        assert_eq!((config[0].x, config[0].y, config[0].scale), (1376, 0, 1.0));
        assert_eq!((config[1].x, config[1].y, config[1].scale), (0, 0, 2.0));
    }

    #[test]
    fn config_needs_a_current_mode_for_every_monitor() {
        let mut s = parse_state(reference_raw(1.0));
        s.monitors[0].modes.iter_mut().for_each(|m| m.current = false);
        assert_eq!(config_with(&s, "Meta-0", (3840, 0), 2.0, (0, 0)), None);
    }

    #[test]
    fn rect_overlap_ignores_touching_edges() {
        let a = IRect::new(0, 0, 10, 10);
        assert!(!a.overlaps(&IRect::new(10, 0, 5, 5)));
        assert!(!a.overlaps(&IRect::new(0, 10, 5, 5)));
        assert!(a.overlaps(&IRect::new(9, 9, 5, 5)));
    }
}
