//! Where lain's display sits relative to the owner's monitors (decision L8, spike B §3 and the lead's
//! decisions 2–4). No Swift counterpart: macOS remembers a virtual display's arrangement by its UUID, so the
//! Mac host never sets an origin (`VirtualStreamedDisplayProvider`). Mutter keeps a method-1 layout neither
//! across sessions nor across a change in the set of monitors, so lain stores the owner's arrangement itself
//! and re-applies it.
//!
//! - [`Arrangement`]: lain's display on one edge of a physical monitor, at an offset along it.
//! - [`derive`] reads it from a layout; [`place`] computes lain's position from it.
//! - [`Tracker`] decides when to re-apply and when to record (stable longer than GNOME's revert timeout).
//! - [`Store`] keeps it in `$XDG_CONFIG_HOME/lain/arrangement.toml`.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::time::Instant;

use crate::display_config::{DisplayState, IRect, MonitorSpec};

/// GNOME Shell reverts a persistent configuration nobody confirms after 20 s (spike B, §3). A layout is the
/// owner's only once it has outlived that, with a margin.
pub const STABLE_FOR: Duration = Duration::from_secs(25);

/// Which side of the anchor monitor lain's display is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

/// lain's display on `edge` of `anchor`, `offset` logical pixels along that edge (down for left and right,
/// across for top and bottom) from the anchor's top-left corner.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Arrangement {
    pub anchor: MonitorSpec,
    pub edge: Edge,
    pub offset: i32,
}

/// One monitor of a layout, as the arrangement rules see it.
#[derive(Debug, Clone, PartialEq)]
pub struct Placed {
    pub spec: MonitorSpec,
    pub rect: IRect,
    pub primary: bool,
    /// A real monitor: only these anchor an arrangement.
    pub physical: bool,
}

/// The layout's monitors, lain's left out, and lain's rectangle.
pub fn split(state: &DisplayState, lain_connector: &str) -> Option<(Vec<Placed>, IRect)> {
    let mut lain = None;
    let mut others = Vec::new();
    for l in &state.logical {
        let rect = state.rect_of(l)?;
        let spec = l.monitors.first()?.clone();
        if l.monitors.iter().any(|s| s.connector == lain_connector) {
            lain = Some(rect);
        } else {
            let physical = state.monitor(&spec.connector).is_some_and(|m| !m.is_virtual());
            others.push(Placed { spec, rect, primary: l.primary, physical });
        }
    }
    Some((others, lain?))
}

fn edge_between(lain: &IRect, a: &IRect) -> Option<(Edge, i32)> {
    let v_overlap = lain.y < a.max_y() && lain.max_y() > a.y;
    let h_overlap = lain.x < a.max_x() && lain.max_x() > a.x;
    if lain.x == a.max_x() && v_overlap {
        Some((Edge::Right, lain.y - a.y))
    } else if lain.max_x() == a.x && v_overlap {
        Some((Edge::Left, lain.y - a.y))
    } else if lain.y == a.max_y() && h_overlap {
        Some((Edge::Bottom, lain.x - a.x))
    } else if lain.max_y() == a.y && h_overlap {
        Some((Edge::Top, lain.x - a.x))
    } else {
        None
    }
}

/// lain's arrangement in a layout: the physical monitor it shares an edge with (the primary one first, then in
/// Mutter's order). `None` if it touches no physical monitor.
pub fn derive(others: &[Placed], lain: &IRect) -> Option<Arrangement> {
    let mut candidates: Vec<&Placed> = others.iter().filter(|p| p.physical).collect();
    candidates.sort_by_key(|p| !p.primary);
    candidates.into_iter().find_map(|p| {
        edge_between(lain, &p.rect).map(|(edge, offset)| Arrangement { anchor: p.spec.clone(), edge, offset })
    })
}

/// Where lain's display of `size` goes for `arrangement` among `others`, in the current global space (before
/// [`normalize`]). The offset is clamped so the two still share at least one pixel of edge. `None` if the anchor
/// isn't there (matched by spec, or the same device on another connector) or the result would overlap another
/// monitor.
pub fn place(arrangement: &Arrangement, others: &[Placed], size: (i32, i32)) -> Option<IRect> {
    let rect = position(arrangement, others, size)?;
    if others.iter().any(|p| p.rect.overlaps(&rect)) {
        return None;
    }
    Some(rect)
}

/// [`place`] without the overlap check.
fn position(arrangement: &Arrangement, others: &[Placed], size: (i32, i32)) -> Option<IRect> {
    let anchor = others
        .iter()
        .find(|p| p.spec == arrangement.anchor)
        .or_else(|| others.iter().find(|p| p.physical && p.spec.same_device(&arrangement.anchor)))?;
    let a = anchor.rect;
    let (w, h) = size;
    let along = |len_a: i32, len_l: i32| arrangement.offset.clamp(-(len_l - 1), len_a - 1);
    let rect = match arrangement.edge {
        Edge::Right => IRect::new(a.max_x(), a.y + along(a.height, h), w, h),
        Edge::Left => IRect::new(a.x - w, a.y + along(a.height, h), w, h),
        Edge::Bottom => IRect::new(a.x + along(a.width, w), a.max_y(), w, h),
        Edge::Top => IRect::new(a.x + along(a.width, w), a.y - h, w, h),
    };
    Some(rect)
}

/// The shift that puts the layout's top-left corner at (0, 0): Mutter rejects negative positions (spike B, §3:
/// "Invalid logical monitor position").
pub fn normalize(others: &[Placed], lain: &IRect) -> (i32, i32) {
    let min_x = others.iter().map(|p| p.rect.x).chain([lain.x]).min().unwrap_or(0);
    let min_y = others.iter().map(|p| p.rect.y).chain([lain.y]).min().unwrap_or(0);
    (-min_x, -min_y)
}

/// Two rectangles share a stretch of edge (Mutter's `mtk_rectangle_is_adjacent_to`): touching at a corner
/// doesn't count.
pub fn adjacent(a: &IRect, b: &IRect) -> bool {
    let v_overlap = a.y < b.max_y() && b.y < a.max_y();
    let h_overlap = a.x < b.max_x() && b.x < a.max_x();
    ((a.x == b.max_x() || b.x == a.max_x()) && v_overlap) || ((a.y == b.max_y() || b.y == a.max_y()) && h_overlap)
}

/// Every rectangle reachable from every other through shared edges: Mutter refuses any other layout ("Logical
/// monitors not adjacent", Mutter 50.1 `meta_verify_logical_monitor_config_list`, `is_connected_to_all`).
pub fn connected(rects: &[IRect]) -> bool {
    let Some(first) = rects.first() else { return true };
    let mut reached = vec![false; rects.len()];
    reached[0] = true;
    let mut todo = vec![*first];
    while let Some(r) = todo.pop() {
        for (i, other) in rects.iter().enumerate() {
            if !reached[i] && adjacent(&r, other) {
                reached[i] = true;
                todo.push(*other);
            }
        }
    }
    reached.into_iter().all(|r| r)
}

/// The arrangement to fall back on when there's none stored, or its anchor is gone: where lain's display is
/// now (Mutter's own placement, to the right of the layout, on `create`), else to the right of the rightmost
/// physical monitor, top-aligned.
pub fn fallback(others: &[Placed], lain: &IRect) -> Option<Arrangement> {
    derive(others, lain).or_else(|| rightmost(others))
}

/// lain's display to the right of the rightmost physical monitor, top-aligned.
fn rightmost(others: &[Placed]) -> Option<Arrangement> {
    others.iter().filter(|p| p.physical).max_by_key(|p| p.rect.max_x()).map(|p| Arrangement {
        anchor: p.spec.clone(),
        edge: Edge::Right,
        offset: 0,
    })
}

/// A full plan for lain's display: its new position and every other monitor's, normalized.
#[derive(Debug, Clone, PartialEq)]
pub struct Plan {
    /// What was applied: the stored arrangement, or the fallback. `None` on a desktop with no physical monitor
    /// (headless, its monitor unplugged): nothing anchors lain's display, so it stays where it is, and nothing is
    /// recorded as the owner's arrangement.
    pub arrangement: Option<Arrangement>,
    pub lain_at: (i32, i32),
    /// Every other logical monitor's new position, by its first monitor's spec.
    pub others_at: Vec<(MonitorSpec, (i32, i32))>,
}

/// The other monitors for lain's display going from `old` to `new`: as they are if that leaves the layout
/// connected; else, where lain's display changes size in place, with the monitors beyond its old right (bottom)
/// edge moved by the change in its width (height), so a display between two monitors still touches both. `None`
/// if neither gives a connected layout without overlaps.
fn close_gaps(others: &[Placed], old: &IRect, new: &IRect) -> Option<Vec<Placed>> {
    let fits = |moved: &[Placed]| {
        let rects: Vec<IRect> = moved.iter().map(|p| p.rect).chain([*new]).collect();
        let overlap = rects.iter().enumerate().any(|(i, a)| rects[i + 1..].iter().any(|b| a.overlaps(b)));
        !overlap && connected(&rects)
    };
    if fits(others) {
        return Some(others.to_vec());
    }
    if (new.x, new.y) != (old.x, old.y) {
        return None;
    }
    let (dx, dy) = (new.max_x() - old.max_x(), new.max_y() - old.max_y());
    let moved: Vec<Placed> = others
        .iter()
        .map(|p| {
            let mut p = p.clone();
            if p.rect.x >= old.max_x() {
                p.rect.x += dx;
            }
            if p.rect.y >= old.max_y() {
                p.rect.y += dy;
            }
            p
        })
        .collect();
    fits(&moved).then_some(moved)
}

/// Plans lain's display at `size` (its logical size at the spec's scale): `stored` if it can be placed, else
/// the fallback (where lain's display is now, else right of the rightmost physical monitor). Each one must
/// give a layout Mutter takes (no overlaps, connected: [`close_gaps`]); `None` if none does.
///
/// With no physical monitor at all (a headless desktop: the developer's requirement that lain keep working
/// once the monitor is unplugged after login), nothing can anchor lain's display: it is re-scaled where it is,
/// at its top-left corner, with no arrangement.
pub fn plan(stored: Option<&Arrangement>, others: &[Placed], lain_now: &IRect, size: (i32, i32)) -> Option<Plan> {
    let candidates = [stored.cloned(), derive(others, lain_now), rightmost(others)];
    let anchored = candidates.into_iter().flatten().find_map(|a| {
        // Overlaps are checked after the gaps are closed: a display growing in place pushes its neighbours.
        let rect = position(&a, others, size)?;
        let moved = close_gaps(others, lain_now, &rect)?;
        Some((Some(a), rect, moved))
    });
    let (wanted, rect, moved) = match anchored {
        Some(found) => found,
        None if !others.iter().any(|p| p.physical) => {
            let rect = IRect::new(lain_now.x, lain_now.y, size.0, size.1);
            (None, rect, close_gaps(others, lain_now, &rect)?)
        }
        None => return None,
    };
    // What the layout will show (the offset may have been clamped), so it isn't mistaken for the owner's.
    let arrangement = derive(&moved, &rect).or(wanted);
    let (sx, sy) = normalize(&moved, &rect);
    let others_at = moved.iter().map(|p| (p.spec.clone(), (p.rect.x + sx, p.rect.y + sy))).collect();
    Some(Plan { arrangement, lain_at: (rect.x + sx, rect.y + sy), others_at })
}

/// Why the tracker wants a layout applied.
#[derive(Debug, Clone, PartialEq)]
pub enum Apply {
    /// The stored arrangement (or the fallback): after `create`, or after a change in the set of monitors.
    Stored,
    /// The spec's scale, keeping lain's display where it is relative to its neighbour: Mutter or the owner put
    /// it at another scale (lead's decision 4).
    Scale,
}

/// What the tracker decides on a layout.
#[derive(Debug, Clone, PartialEq)]
pub enum Decision {
    Nothing,
    Apply(Apply),
    /// Record this arrangement as the owner's.
    Store(Arrangement),
    /// Look again at this time (a candidate is waiting out [`STABLE_FOR`]).
    WakeAt(Instant),
}

/// One layout as the tracker sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct View {
    pub set: BTreeSet<MonitorSpec>,
    /// lain's display's scale now, and the spec's.
    pub scale: f64,
    /// The scale to keep (the closest Mutter supports to the one asked for); 0 or less counts as 1.
    pub spec_scale: f64,
    /// lain's arrangement now.
    pub current: Option<Arrangement>,
}

/// The arrangement rules (lead's decisions 3 and 4), apart from D-Bus so they can be tested:
/// - re-apply the stored arrangement after `create` and whenever the set of monitors differs from the one it
///   was last applied for;
/// - re-apply the spec's scale whenever lain's display is at another one (once per drift: not again for the
///   same layout until the spec's scale has been seen, so a refusal can't loop);
/// - record an arrangement only once it has been stable for [`STABLE_FOR`], at the spec's scale, in the set
///   last applied for, different from both the stored one and the one lain itself last applied, and only after
///   lain's last apply in that set took effect: after a refusal the layout is Mutter's placement, not the
///   owner's.
///
/// A spec scale of 0 counts as 1, as in `DisplaySpec::logical_size`.
#[derive(Debug, Default)]
pub struct Tracker {
    stored: Option<Arrangement>,
    applied_set: Option<BTreeSet<MonitorSpec>>,
    applied: Option<Arrangement>,
    /// lain's last apply in `applied_set` was refused (or couldn't be planned).
    refused: bool,
    candidate: Option<(Arrangement, Instant)>,
    scale_tried: Option<(BTreeSet<MonitorSpec>, Option<Arrangement>)>,
    last: Option<View>,
}

impl Tracker {
    pub fn new(stored: Option<Arrangement>) -> Self {
        Self { stored, ..Self::default() }
    }

    pub fn stored(&self) -> Option<&Arrangement> {
        self.stored.as_ref()
    }

    /// A new display: the next layout re-applies.
    pub fn reset(&mut self) {
        self.applied_set = None;
        self.applied = None;
        self.refused = false;
        self.candidate = None;
        self.scale_tried = None;
        self.last = None;
    }

    /// lain applied (`accepted`) or tried to apply a layout for `set`, placing its display at `arrangement`. A
    /// refused apply counts too, so a layout Mutter won't take isn't retried until the monitors change; but
    /// nothing is recorded in `set` until an apply there is accepted (review A1).
    pub fn applied(&mut self, set: BTreeSet<MonitorSpec>, arrangement: Option<Arrangement>, accepted: bool) {
        self.applied_set = Some(set);
        self.applied = arrangement;
        self.refused = !accepted;
        self.candidate = None;
    }

    /// lain's last apply for the current set was refused: a re-scale should still aim for the stored
    /// arrangement, which the layout doesn't show.
    pub fn refused(&self) -> bool {
        self.refused
    }

    /// The decision for a new layout.
    pub fn on_layout(&mut self, now: Instant, view: View) -> Decision {
        self.last = Some(view.clone());
        if self.applied_set.as_ref() != Some(&view.set) {
            self.candidate = None;
            return Decision::Apply(Apply::Stored);
        }
        let target = if view.spec_scale > 0.0 { view.spec_scale } else { 1.0 };
        if (view.scale - target).abs() > 1e-3 {
            self.candidate = None;
            let key = (view.set.clone(), view.current.clone());
            if self.scale_tried.as_ref() == Some(&key) {
                return Decision::Nothing;
            }
            self.scale_tried = Some(key);
            return Decision::Apply(Apply::Scale);
        }
        // At the spec's scale: a later drift is a new one (review A2).
        self.scale_tried = None;
        if self.refused {
            self.candidate = None;
            return Decision::Nothing;
        }
        let Some(current) = view.current else {
            self.candidate = None;
            return Decision::Nothing;
        };
        if self.stored.as_ref() == Some(&current) || self.applied.as_ref() == Some(&current) {
            self.candidate = None;
            return Decision::Nothing;
        }
        match &self.candidate {
            Some((c, since)) if *c == current => {
                if now.duration_since(*since) >= STABLE_FOR {
                    self.candidate = None;
                    self.stored = Some(current.clone());
                    self.applied = Some(current.clone());
                    Decision::Store(current)
                } else {
                    Decision::WakeAt(*since + STABLE_FOR)
                }
            }
            _ => {
                self.candidate = Some((current, now));
                Decision::WakeAt(now + STABLE_FOR)
            }
        }
    }

    /// The wake-up a [`Decision::WakeAt`] asked for: the last layout, seen again.
    pub fn on_tick(&mut self, now: Instant) -> Decision {
        match self.last.clone() {
            Some(view) => self.on_layout(now, view),
            None => Decision::Nothing,
        }
    }
}

/// The stored arrangement, in `$XDG_CONFIG_HOME/lain/arrangement.toml`.
#[derive(Debug, Clone)]
pub struct Store {
    path: PathBuf,
}

#[derive(Serialize, Deserialize)]
struct StoredFile {
    arrangement: Arrangement,
}

impl Store {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    /// `$XDG_CONFIG_HOME/lain/arrangement.toml`, or `~/.config/lain/arrangement.toml`.
    pub fn default_path() -> Option<PathBuf> {
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| Path::new(&h).join(".config")))?;
        Some(base.join("lain").join("arrangement.toml"))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The stored arrangement; `None` if there is none or it can't be read (logged).
    pub fn load(&self) -> Option<Arrangement> {
        let text = match std::fs::read_to_string(&self.path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
            Err(e) => {
                tracing::warn!(path = %self.path.display(), "can't read the stored arrangement: {e}");
                return None;
            }
        };
        match toml::from_str::<StoredFile>(&text) {
            Ok(f) => Some(f.arrangement),
            Err(e) => {
                tracing::warn!(path = %self.path.display(), "ignoring an unreadable stored arrangement: {e}");
                None
            }
        }
    }

    /// Writes it atomically (a temporary file renamed over the old one).
    pub fn save(&self, arrangement: &Arrangement) -> std::io::Result<()> {
        let text = toml::to_string(&StoredFile { arrangement: arrangement.clone() }).map_err(std::io::Error::other)?;
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = self.path.with_extension("toml.tmp");
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &self.path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::display_config::{parse_state, tests::reference_raw};

    fn hdmi() -> MonitorSpec {
        MonitorSpec::new("HDMI-1", "SAM", "Odyssey G95NC", "HNTY301882")
    }

    fn phys(spec: MonitorSpec, rect: IRect, primary: bool) -> Placed {
        Placed { spec, rect, primary, physical: true }
    }

    fn set(names: &[&str]) -> BTreeSet<MonitorSpec> {
        names.iter().map(|n| MonitorSpec::new(n, "v", "p", "s")).collect()
    }

    #[test]
    fn derives_every_edge() {
        let others = vec![phys(hdmi(), IRect::new(0, 0, 3840, 2160), true)];
        let cases = [
            (IRect::new(3840, 100, 1376, 1032), Edge::Right, 100),
            (IRect::new(-1376, -50, 1376, 1032), Edge::Left, -50),
            (IRect::new(1232, 2160, 1376, 1032), Edge::Bottom, 1232),
            (IRect::new(10, -1032, 1376, 1032), Edge::Top, 10),
        ];
        for (rect, edge, offset) in cases {
            assert_eq!(derive(&others, &rect), Some(Arrangement { anchor: hdmi(), edge, offset }), "{rect:?}");
        }
        // Not touching, or touching only at a corner.
        assert_eq!(derive(&others, &IRect::new(3841, 0, 10, 10)), None);
        assert_eq!(derive(&others, &IRect::new(3840, 2160, 10, 10)), None);
    }

    #[test]
    fn only_physical_monitors_anchor_and_the_primary_wins() {
        let other = MonitorSpec::new("DP-1", "DEL", "U2720Q", "9");
        let virt = MonitorSpec::new("Meta-1", "MetaVendor", "Virtual remote monitor", "0x2");
        let lain = IRect::new(3840, 0, 1376, 1032);
        let mut others = vec![
            Placed { spec: virt, rect: IRect::new(5216, 0, 100, 100), primary: false, physical: false },
            phys(other.clone(), IRect::new(3840, 1032, 1000, 1000), false),
        ];
        assert_eq!(derive(&others, &lain).unwrap().anchor, other);
        others.push(phys(hdmi(), IRect::new(0, 0, 3840, 2160), true));
        assert_eq!(derive(&others, &lain).unwrap().anchor, hdmi());
    }

    #[test]
    fn placement_round_trips_and_clamps() {
        let others = vec![phys(hdmi(), IRect::new(0, 0, 3840, 2160), true)];
        for (edge, offset) in [(Edge::Right, 300), (Edge::Left, 0), (Edge::Bottom, 1232), (Edge::Top, -100)] {
            let a = Arrangement { anchor: hdmi(), edge, offset };
            let rect = place(&a, &others, (1376, 1032)).unwrap();
            assert_eq!(derive(&others, &rect), Some(a));
        }
        // An offset past the edge is clamped so the two still touch.
        let far = Arrangement { anchor: hdmi(), edge: Edge::Right, offset: 5000 };
        assert_eq!(place(&far, &others, (1376, 1032)), Some(IRect::new(3840, 2159, 1376, 1032)));
        let before = Arrangement { anchor: hdmi(), edge: Edge::Bottom, offset: -5000 };
        assert_eq!(place(&before, &others, (1376, 1032)), Some(IRect::new(-1375, 2160, 1376, 1032)));
    }

    #[test]
    fn placement_finds_the_anchor_on_another_connector_and_refuses_overlaps() {
        let moved = MonitorSpec { connector: "DP-2".into(), ..hdmi() };
        let others = vec![phys(moved, IRect::new(0, 0, 3840, 2160), true)];
        let a = Arrangement { anchor: hdmi(), edge: Edge::Right, offset: 0 };
        assert_eq!(place(&a, &others, (1376, 1032)), Some(IRect::new(3840, 0, 1376, 1032)));
        let blocked = vec![
            phys(hdmi(), IRect::new(0, 0, 3840, 2160), true),
            phys(MonitorSpec::new("DP-1", "D", "P", "1"), IRect::new(3840, 0, 1000, 1000), false),
        ];
        assert_eq!(place(&a, &blocked, (1376, 1032)), None);
        let gone = Arrangement { anchor: MonitorSpec::new("DP-9", "X", "Y", "Z"), edge: Edge::Right, offset: 0 };
        assert_eq!(place(&gone, &blocked, (1376, 1032)), None);
    }

    #[test]
    fn plan_normalizes_a_left_placement() {
        // The iPad to the left: the physical monitor moves to x = 1376, the global origin stays top-left.
        let others = vec![phys(hdmi(), IRect::new(0, 0, 3840, 2160), true)];
        let stored = Arrangement { anchor: hdmi(), edge: Edge::Left, offset: 0 };
        let now = IRect::new(3840, 0, 2752, 2064);
        let p = plan(Some(&stored), &others, &now, (1376, 1032)).unwrap();
        assert_eq!(p, Plan { arrangement: Some(stored), lain_at: (0, 0), others_at: vec![(hdmi(), (1376, 0))] });
    }

    fn rects_after(p: &Plan, size: (i32, i32), others: &[Placed]) -> Vec<IRect> {
        let mut rects: Vec<IRect> = p
            .others_at
            .iter()
            .map(|(s, (x, y))| {
                let r = others.iter().find(|o| o.spec == *s).unwrap().rect;
                IRect::new(*x, *y, r.width, r.height)
            })
            .collect();
        rects.push(IRect::new(p.lain_at.0, p.lain_at.1, size.0, size.1));
        rects
    }

    /// Review A3: A | lain | B with lain at scale 1; re-scaling it in place left B 1376 px away, which Mutter
    /// refuses ("Logical monitors not adjacent").
    #[test]
    fn rescaling_a_display_between_two_monitors_leaves_no_gap() {
        let a = MonitorSpec::new("DP-1", "DEL", "U2720Q", "1");
        let b = MonitorSpec::new("DP-2", "DEL", "U2720Q", "2");
        let others = vec![
            phys(a.clone(), IRect::new(0, 0, 1920, 1080), true),
            phys(b.clone(), IRect::new(1920 + 2752, 0, 1920, 1080), false),
        ];
        let lain_now = IRect::new(1920, 0, 2752, 2064);
        let p = plan(None, &others, &lain_now, (1376, 1032)).unwrap();
        assert_eq!(p.lain_at, (1920, 0));
        assert_eq!(p.others_at, vec![(a, (0, 0)), (b, (1920 + 1376, 0))]);
        assert!(connected(&rects_after(&p, (1376, 1032), &others)));
        // Growing in place pushes the neighbour instead of overlapping it.
        let lain_now = IRect::new(1920, 0, 1376, 1032);
        let others = vec![others[0].clone(), phys(others[1].spec.clone(), IRect::new(3296, 0, 1920, 1080), false)];
        let p = plan(None, &others, &lain_now, (2752, 2064)).unwrap();
        assert_eq!(p.others_at[1].1, (1920 + 2752, 0));
        assert!(connected(&rects_after(&p, (2752, 2064), &others)));
    }

    /// The stored arrangement would cut the layout in two (lain was the only link): the fallback is used.
    #[test]
    fn a_stored_arrangement_that_disconnects_the_layout_falls_back() {
        let a = MonitorSpec::new("DP-1", "DEL", "U2720Q", "1");
        let b = MonitorSpec::new("DP-2", "DEL", "U2720Q", "2");
        let others = vec![
            phys(a.clone(), IRect::new(0, 0, 1920, 1080), true),
            phys(b, IRect::new(1920 + 1376, 0, 1920, 1080), false),
        ];
        let below_a = Arrangement { anchor: a.clone(), edge: Edge::Bottom, offset: 0 };
        let lain_now = IRect::new(1920, 0, 1376, 1032);
        let p = plan(Some(&below_a), &others, &lain_now, (1376, 1032)).unwrap();
        assert_eq!(p.arrangement, Some(Arrangement { anchor: a, edge: Edge::Right, offset: 0 }));
        assert!(connected(&rects_after(&p, (1376, 1032), &others)));
    }

    #[test]
    fn connectivity_and_adjacency() {
        let a = IRect::new(0, 0, 10, 10);
        assert!(adjacent(&a, &IRect::new(10, 5, 5, 5)));
        assert!(adjacent(&a, &IRect::new(2, -3, 5, 3)));
        assert!(!adjacent(&a, &IRect::new(10, 10, 5, 5)), "a corner isn't an edge");
        assert!(!adjacent(&a, &IRect::new(11, 0, 5, 5)));
        assert!(connected(&[a, IRect::new(10, 0, 5, 5), IRect::new(15, 0, 5, 5)]));
        // Two pairs, each adjacent within itself, aren't connected.
        assert!(!connected(&[a, IRect::new(10, 0, 5, 5), IRect::new(30, 0, 5, 5), IRect::new(35, 0, 5, 5)]));
        assert!(connected(&[a]));
    }

    #[test]
    fn plan_falls_back_to_where_mutter_put_it_at_the_new_scale() {
        // On create, Mutter puts the monitor right of the layout at scale 1; at scale 2 it keeps that edge.
        let state = parse_state(reference_raw(1.0));
        let (others, lain) = split(&state, "Meta-0").unwrap();
        assert_eq!(lain, IRect::new(3840, 0, 2752, 2064));
        let p = plan(None, &others, &lain, (1376, 1032)).unwrap();
        assert_eq!(p.lain_at, (3840, 0));
        assert_eq!(p.others_at, vec![(hdmi(), (0, 0))]);
        assert_eq!(p.arrangement, Some(Arrangement { anchor: hdmi(), edge: Edge::Right, offset: 0 }));
        // A stored arrangement whose anchor is gone falls back too.
        let gone = Arrangement { anchor: MonitorSpec::new("DP-9", "X", "Y", "Z"), edge: Edge::Bottom, offset: 0 };
        assert_eq!(plan(Some(&gone), &others, &lain, (1376, 1032)).unwrap().lain_at, (3840, 0));
        // lain's display touching nothing (left alone at a gap) goes right of the rightmost physical monitor.
        let p = plan(None, &others, &IRect::new(9000, 9000, 2752, 2064), (1376, 1032)).unwrap();
        assert_eq!(p.lain_at, (3840, 0));
    }

    /// Headless (the bring-up, 2026-11-01): with the monitor unplugged, an iPad connecting made a display that
    /// stayed at Mutter's scale 1, because no physical monitor could anchor its plan. It is re-scaled in place now,
    /// with no arrangement recorded; a stored one waits for its monitor to come back.
    #[test]
    fn plan_with_no_physical_monitor_rescales_lain_in_place() {
        let stored = Arrangement { anchor: hdmi(), edge: Edge::Right, offset: 0 };
        for s in [None, Some(&stored)] {
            let p = plan(s, &[], &IRect::new(0, 0, 2752, 2064), (1376, 1032)).unwrap();
            assert_eq!(p, Plan { arrangement: None, lain_at: (0, 0), others_at: vec![] });
        }
        // Another remote-desktop client's virtual monitor right of lain's display: it follows the right edge in.
        let virt = MonitorSpec::new("Meta-1", "X", "Y", "Z");
        let others =
            vec![Placed { spec: virt.clone(), rect: IRect::new(2752, 0, 1920, 1080), primary: false, physical: false }];
        let p = plan(None, &others, &IRect::new(0, 0, 2752, 2064), (1376, 1032)).unwrap();
        assert_eq!(p, Plan { arrangement: None, lain_at: (0, 0), others_at: vec![(virt, (1376, 0))] });
    }

    /// The tracker after a headless apply: nothing anchors lain's display, so a layout at the spec's scale is
    /// left alone (no arrangement recorded), and the monitor coming back applies the stored one again.
    #[test]
    fn a_headless_apply_records_nothing_and_the_monitor_coming_back_reapplies() {
        let headless = set(&["Meta-0"]);
        let mut t = Tracker::new(Some(arr(0)));
        let now = Instant::now();
        assert_eq!(t.on_layout(now, view(&headless, 1.0, None)), Decision::Apply(Apply::Stored));
        t.applied(headless.clone(), None, true);
        assert_eq!(t.on_layout(now, view(&headless, 2.0, None)), Decision::Nothing);
        assert_eq!(t.stored(), Some(&arr(0)));
        let back = set(&["HDMI-1", "Meta-0"]);
        assert_eq!(t.on_layout(now, view(&back, 2.0, None)), Decision::Apply(Apply::Stored));
    }

    fn view(set: &BTreeSet<MonitorSpec>, scale: f64, current: Option<Arrangement>) -> View {
        View { set: set.clone(), scale, spec_scale: 2.0, current }
    }

    fn arr(offset: i32) -> Arrangement {
        Arrangement { anchor: hdmi(), edge: Edge::Right, offset }
    }

    #[test]
    fn reapplies_after_create_and_on_a_change_in_the_set_of_monitors() {
        let t0 = Instant::now();
        let one = set(&["HDMI-1", "Meta-0"]);
        let two = set(&["HDMI-1", "Meta-0", "DP-1"]);
        let mut t = Tracker::new(Some(arr(0)));
        assert_eq!(t.on_layout(t0, view(&one, 1.0, Some(arr(0)))), Decision::Apply(Apply::Stored));
        t.applied(one.clone(), Some(arr(0)), true);
        assert_eq!(t.on_layout(t0, view(&one, 2.0, Some(arr(0)))), Decision::Nothing);
        // A monitor appears: Mutter re-derives the layout, lain re-applies.
        assert_eq!(t.on_layout(t0, view(&two, 2.0, Some(arr(500)))), Decision::Apply(Apply::Stored));
        t.applied(two.clone(), Some(arr(0)), true);
        // And when it goes away again.
        assert_eq!(t.on_layout(t0, view(&one, 2.0, Some(arr(0)))), Decision::Apply(Apply::Stored));
        // A new display starts over.
        t.applied(one.clone(), Some(arr(0)), true);
        t.reset();
        assert_eq!(t.on_layout(t0, view(&one, 2.0, Some(arr(0)))), Decision::Apply(Apply::Stored));
    }

    #[test]
    fn reapplies_the_scale_once_per_layout() {
        let t0 = Instant::now();
        let one = set(&["HDMI-1", "Meta-0"]);
        let mut t = Tracker::new(None);
        t.applied(one.clone(), Some(arr(0)), true);
        assert_eq!(t.on_layout(t0, view(&one, 1.0, Some(arr(0)))), Decision::Apply(Apply::Scale));
        // Mutter refused, or reverted: not retried for the same layout...
        assert_eq!(t.on_layout(t0, view(&one, 1.0, Some(arr(0)))), Decision::Nothing);
        // ...but tried again when the layout changes. A fractional scale is never the owner's to store.
        assert_eq!(t.on_layout(t0, view(&one, 1.5, Some(arr(40)))), Decision::Apply(Apply::Scale));
        assert_eq!(t.on_tick(t0 + STABLE_FOR * 2), Decision::Nothing);
    }

    /// Review A2: the guard covered the whole display's life, so a second drift to the same layout stayed.
    #[test]
    fn the_scale_is_reapplied_every_time_it_drifts_not_only_once() {
        let t0 = Instant::now();
        let one = set(&["HDMI-1", "Meta-0"]);
        let mut t = Tracker::new(None);
        t.applied(one.clone(), Some(arr(0)), true);
        assert_eq!(t.on_layout(t0, view(&one, 1.0, Some(arr(0)))), Decision::Apply(Apply::Scale));
        t.applied(one.clone(), Some(arr(0)), true);
        assert_eq!(t.on_layout(t0, view(&one, 2.0, Some(arr(0)))), Decision::Nothing);
        let later = t0 + Duration::from_secs(60);
        assert_eq!(t.on_layout(later, view(&one, 1.0, Some(arr(0)))), Decision::Apply(Apply::Scale));
    }

    /// Review A4: `DisplaySpec` treats scale 0 as 1.
    #[test]
    fn spec_scale_zero_is_treated_as_one() {
        let one = set(&["HDMI-1", "Meta-0"]);
        let mut t = Tracker::new(None);
        t.applied(one.clone(), Some(arr(0)), true);
        let v = View { set: one, scale: 1.0, spec_scale: 0.0, current: Some(arr(0)) };
        assert_eq!(t.on_layout(Instant::now(), v), Decision::Nothing);
    }

    /// Review A1: after a refused apply the layout shows Mutter's placement, which must not become the owner's.
    #[test]
    fn a_refused_apply_does_not_record_mutters_placement_as_the_owners() {
        let t0 = Instant::now();
        let one = set(&["HDMI-1", "Meta-0"]);
        let stored = Arrangement { anchor: hdmi(), edge: Edge::Left, offset: 0 };
        let mut t = Tracker::new(Some(stored.clone()));
        assert_eq!(t.on_layout(t0, view(&one, 2.0, Some(arr(0)))), Decision::Apply(Apply::Stored));
        t.applied(one.clone(), Some(stored.clone()), false);
        assert!(t.refused());
        let soon = t0 + Duration::from_millis(5);
        assert_eq!(t.on_layout(soon, view(&one, 2.0, Some(arr(0)))), Decision::Nothing);
        assert_eq!(t.on_tick(soon + STABLE_FOR), Decision::Nothing);
        assert_eq!(t.stored(), Some(&stored));
        // Still not retried in this set; a re-scale still asks (and aims for the stored arrangement).
        assert_eq!(t.on_layout(soon, view(&one, 1.0, Some(arr(0)))), Decision::Apply(Apply::Scale));
        // An accepted apply in the set lets recording resume.
        t.applied(one.clone(), Some(stored.clone()), true);
        assert!(!t.refused());
        assert_eq!(t.on_layout(soon, view(&one, 2.0, Some(arr(300)))), Decision::WakeAt(soon + STABLE_FOR));
    }

    #[test]
    fn records_only_after_the_revert_timeout() {
        let t0 = Instant::now();
        let one = set(&["HDMI-1", "Meta-0"]);
        let mut t = Tracker::new(None);
        t.applied(one.clone(), Some(arr(0)), true);
        // lain's own layout is never recorded.
        assert_eq!(t.on_layout(t0, view(&one, 2.0, Some(arr(0)))), Decision::Nothing);
        // The owner moves it (GNOME Settings, method 2): a candidate, not yet the owner's.
        assert_eq!(t.on_layout(t0, view(&one, 2.0, Some(arr(300)))), Decision::WakeAt(t0 + STABLE_FOR));
        let early = t0 + STABLE_FOR - Duration::from_millis(1);
        assert_eq!(t.on_tick(early), Decision::WakeAt(t0 + STABLE_FOR));
        assert_eq!(t.on_tick(t0 + STABLE_FOR), Decision::Store(arr(300)));
        assert_eq!(t.stored(), Some(&arr(300)));
        // Seen again, it equals the stored one: nothing to rewrite.
        assert_eq!(t.on_layout(t0 + STABLE_FOR * 2, view(&one, 2.0, Some(arr(300)))), Decision::Nothing);
    }

    #[test]
    fn a_reverted_change_is_never_recorded() {
        let t0 = Instant::now();
        let one = set(&["HDMI-1", "Meta-0"]);
        let mut t = Tracker::new(Some(arr(0)));
        t.applied(one.clone(), Some(arr(0)), true);
        assert_eq!(t.on_layout(t0, view(&one, 2.0, Some(arr(300)))), Decision::WakeAt(t0 + STABLE_FOR));
        // GNOME reverts after its 20 s.
        let back = t0 + Duration::from_secs(20);
        assert_eq!(t.on_layout(back, view(&one, 2.0, Some(arr(0)))), Decision::Nothing);
        assert_eq!(t.on_tick(t0 + STABLE_FOR), Decision::Nothing);
        assert_eq!(t.stored(), Some(&arr(0)));
        // A second move restarts the clock.
        let again = t0 + Duration::from_secs(30);
        assert_eq!(t.on_layout(again, view(&one, 2.0, Some(arr(10)))), Decision::WakeAt(again + STABLE_FOR));
        let other = again + Duration::from_secs(5);
        assert_eq!(t.on_layout(other, view(&one, 2.0, Some(arr(20)))), Decision::WakeAt(other + STABLE_FOR));
        assert_eq!(t.on_tick(again + STABLE_FOR), Decision::WakeAt(other + STABLE_FOR));
    }

    #[test]
    fn not_recorded_at_the_wrong_scale_in_another_set_or_without_a_neighbour() {
        let t0 = Instant::now();
        let one = set(&["HDMI-1", "Meta-0"]);
        let mut t = Tracker::new(None);
        t.applied(one.clone(), Some(arr(0)), true);
        assert_eq!(t.on_layout(t0, view(&one, 2.0, None)), Decision::Nothing);
        assert_eq!(t.on_tick(t0 + STABLE_FOR), Decision::Nothing);
        assert_eq!(t.on_layout(t0, view(&one, 1.0, Some(arr(300)))), Decision::Apply(Apply::Scale));
        assert_eq!(t.on_tick(t0 + STABLE_FOR), Decision::Nothing);
        assert_eq!(t.stored(), None);
    }

    #[test]
    fn store_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::new(dir.path().join("lain").join("arrangement.toml"));
        assert_eq!(store.load(), None);
        let a = Arrangement { anchor: hdmi(), edge: Edge::Bottom, offset: -12 };
        store.save(&a).unwrap();
        assert_eq!(store.load(), Some(a));
        std::fs::write(store.path(), "not toml [").unwrap();
        assert_eq!(store.load(), None);
    }
}
