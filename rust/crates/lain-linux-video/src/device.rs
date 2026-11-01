//! The one GPU device video uses: the AMD iGPU's render node, chosen from sysfs by PCI vendor (decisions L3
//! and L7; lead's decision, wave 3 prep). No Swift counterpart: a Mac has one GPU.
//!
//! The node is picked from `/sys/class/drm/renderD*/device/vendor` = `0x1002`, preferring the one whose
//! `boot_vga` is 1, with an override (`LAIN_RENDER_NODE`, or [`LinuxVideoConfig`](crate::LinuxVideoConfig))
//! that must still be AMD. It is opened once, checked to be that very device (`fstat`'s `st_rdev` against the
//! node's sysfs `dev`), and that one fd serves GBM, EGL and VA. No other node is ever opened: never an NVIDIA
//! device.

use std::os::fd::OwnedFd;
use std::path::{Path, PathBuf};

use lain_platform::PlatformError;
use rustix::fs::{FileType, Mode, OFlags};

/// The PCI vendor id of AMD.
pub const AMD_VENDOR: &str = "0x1002";
/// Names a render node to use instead of the automatic choice (`renderD130` or `/dev/dri/renderD130`).
pub const RENDER_NODE_VAR: &str = "LAIN_RENDER_NODE";

/// A render node chosen from sysfs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderNode {
    /// `renderD130`.
    pub name: String,
    /// `/dev/dri/renderD130`.
    pub path: PathBuf,
    /// Its device number, from sysfs `dev` (`226:130`).
    pub major: u32,
    pub minor: u32,
    /// The PCI address (`0000:79:00.0`), for logs.
    pub pci: Option<String>,
    pub boot_vga: bool,
}

fn read_trimmed(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|s| s.trim().to_string())
}

fn parse_dev(text: &str) -> Option<(u32, u32)> {
    let (major, minor) = text.trim().split_once(':')?;
    Some((major.parse().ok()?, minor.parse().ok()?))
}

/// Reads one `renderD*` entry of `<sysfs>/class/drm`; `None` unless it is an AMD node with a device number.
fn read_node(drm: &Path, name: &str, dev_dir: &Path) -> Option<RenderNode> {
    let entry = drm.join(name);
    if read_trimmed(&entry.join("device/vendor")).as_deref() != Some(AMD_VENDOR) {
        return None;
    }
    let (major, minor) = parse_dev(&read_trimmed(&entry.join("dev"))?)?;
    let pci = std::fs::read_link(entry.join("device")).ok().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()));
    Some(RenderNode {
        name: name.to_string(),
        path: dev_dir.join(name),
        major,
        minor,
        pci,
        boot_vga: read_trimmed(&entry.join("device/boot_vga")).as_deref() == Some("1"),
    })
}

fn node_number(name: &str) -> u32 {
    name.strip_prefix("renderD").and_then(|n| n.parse().ok()).unwrap_or(u32::MAX)
}

/// Chooses the render node under `sysfs` (normally `/sys`), naming it under `dev_dir` (normally `/dev/dri`).
///
/// With `override_node` (a node name or a path whose file name is one), that node, if it is AMD; otherwise the
/// AMD node whose `boot_vga` is 1, else the lowest-numbered AMD node. Fails, naming what it saw, when there is
/// none. Reads sysfs only: nothing is opened.
pub fn select_render_node(sysfs: &Path, dev_dir: &Path, override_node: Option<&str>) -> Result<RenderNode, PlatformError> {
    let drm = sysfs.join("class/drm");
    if let Some(wanted) = override_node.map(str::trim).filter(|s| !s.is_empty()) {
        let name = Path::new(wanted).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if !name.starts_with("renderD") {
            return Err(PlatformError::Unavailable(format!("{RENDER_NODE_VAR}={wanted} isn't a render node")));
        }
        return read_node(&drm, &name, dev_dir).ok_or_else(|| {
            PlatformError::Unavailable(format!(
                "{RENDER_NODE_VAR}={wanted}: {name} isn't an AMD render node (PCI vendor {AMD_VENDOR}); video uses only the AMD iGPU"
            ))
        });
    }
    let entries = std::fs::read_dir(&drm)
        .map_err(|e| PlatformError::Unavailable(format!("can't list {}: {e}", drm.display())))?;
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("renderD"))
        .collect();
    names.sort_by_key(|n| node_number(n));
    let nodes: Vec<RenderNode> = names.iter().filter_map(|n| read_node(&drm, n, dev_dir)).collect();
    let chosen = nodes.iter().find(|n| n.boot_vga).or(nodes.first()).cloned();
    chosen.ok_or_else(|| {
        PlatformError::Unavailable(format!(
            "no AMD render node (PCI vendor {AMD_VENDOR}) among {:?}; video encodes only on the AMD iGPU",
            names
        ))
    })
}

/// [`select_render_node`] on the real sysfs and `/dev/dri`, with `override_node`, or else `LAIN_RENDER_NODE`.
pub fn select_system_render_node(override_node: Option<&str>) -> Result<RenderNode, PlatformError> {
    let env = std::env::var(RENDER_NODE_VAR).ok();
    select_render_node(Path::new("/sys"), Path::new("/dev/dri"), override_node.or(env.as_deref()))
}

/// Opens `node` read-write (close-on-exec) and checks that the fd is that character device: `st_rdev` equals
/// the device number sysfs gave. The fd is the only one video opens on the GPU.
pub fn open_render_node(node: &RenderNode) -> Result<OwnedFd, PlatformError> {
    let fd = rustix::fs::open(&node.path, OFlags::RDWR | OFlags::CLOEXEC | OFlags::NOCTTY, Mode::empty())
        .map_err(|e| PlatformError::Unavailable(format!("can't open {}: {e}", node.path.display())))?;
    check_is_node(&fd, node)?;
    Ok(fd)
}

/// The `fstat` check of [`open_render_node`].
pub fn check_is_node(fd: &OwnedFd, node: &RenderNode) -> Result<(), PlatformError> {
    let st = rustix::fs::fstat(fd).map_err(|e| PlatformError::Failed(format!("fstat {}: {e}", node.path.display())))?;
    let is_char = FileType::from_raw_mode(st.st_mode) == FileType::CharacterDevice;
    let (major, minor) = (rustix::fs::major(st.st_rdev), rustix::fs::minor(st.st_rdev));
    if !is_char || (major, minor) != (node.major, node.minor) {
        return Err(PlatformError::Failed(format!(
            "{} is device {major}:{minor} (character device: {is_char}), but sysfs says {}:{}; refusing it",
            node.path.display(),
            node.major,
            node.minor
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fake `/sys/class/drm` with the reference machine's three render nodes: two NVIDIA cards (128, 129)
    /// and the AMD iGPU (130).
    fn fake_sysfs(amd_boot_vga: bool) -> tempfile::TempDir {
        let root = tempfile::tempdir().unwrap();
        let add = |name: &str, minor: u32, vendor: &str, pci: &str, boot_vga: Option<&str>| {
            let devices = root.path().join("devices").join(pci);
            std::fs::create_dir_all(&devices).unwrap();
            std::fs::write(devices.join("vendor"), format!("{vendor}\n")).unwrap();
            if let Some(b) = boot_vga {
                std::fs::write(devices.join("boot_vga"), format!("{b}\n")).unwrap();
            }
            let entry = root.path().join("class/drm").join(name);
            std::fs::create_dir_all(&entry).unwrap();
            std::fs::write(entry.join("dev"), format!("226:{minor}\n")).unwrap();
            std::os::unix::fs::symlink(&devices, entry.join("device")).unwrap();
        };
        add("renderD128", 128, "0x10de", "0000:01:00.0", Some("0"));
        add("renderD129", 129, "0x10de", "0000:02:00.0", Some("0"));
        add("renderD130", 130, "0x1002", "0000:79:00.0", Some(if amd_boot_vga { "1" } else { "0" }));
        // A card node and a connector are ignored.
        std::fs::create_dir_all(root.path().join("class/drm/card3-HDMI-A-1")).unwrap();
        root
    }

    #[test]
    fn picks_the_amd_node() {
        for boot_vga in [true, false] {
            let sys = fake_sysfs(boot_vga);
            let node = select_render_node(sys.path(), Path::new("/dev/dri"), None).unwrap();
            assert_eq!(node.name, "renderD130");
            assert_eq!(node.path, Path::new("/dev/dri/renderD130"));
            assert_eq!((node.major, node.minor), (226, 130));
            assert_eq!(node.pci.as_deref(), Some("0000:79:00.0"));
            assert_eq!(node.boot_vga, boot_vga);
        }
    }

    #[test]
    fn prefers_boot_vga_then_the_lowest() {
        let sys = fake_sysfs(false);
        // A second AMD node, lower-numbered, not the boot GPU.
        let devices = sys.path().join("devices/0000:03:00.0");
        std::fs::create_dir_all(&devices).unwrap();
        std::fs::write(devices.join("vendor"), "0x1002\n").unwrap();
        let entry = sys.path().join("class/drm/renderD127");
        std::fs::create_dir_all(&entry).unwrap();
        std::fs::write(entry.join("dev"), "226:127\n").unwrap();
        std::os::unix::fs::symlink(&devices, entry.join("device")).unwrap();
        assert_eq!(select_render_node(sys.path(), Path::new("/dev/dri"), None).unwrap().name, "renderD127");
        std::fs::write(sys.path().join("devices/0000:79:00.0/boot_vga"), "1\n").unwrap();
        assert_eq!(select_render_node(sys.path(), Path::new("/dev/dri"), None).unwrap().name, "renderD130");
    }

    #[test]
    fn the_override_must_be_amd() {
        let sys = fake_sysfs(true);
        let dev = Path::new("/dev/dri");
        assert_eq!(select_render_node(sys.path(), dev, Some("/dev/dri/renderD130")).unwrap().name, "renderD130");
        assert_eq!(select_render_node(sys.path(), dev, Some("renderD130")).unwrap().minor, 130);
        assert!(select_render_node(sys.path(), dev, Some("")).is_ok(), "an empty override means none");
        for refused in ["renderD128", "/dev/dri/renderD129", "card3", "/dev/nvidia0", "renderD200"] {
            let err = select_render_node(sys.path(), dev, Some(refused)).unwrap_err();
            assert!(matches!(err, PlatformError::Unavailable(_)), "{refused}: {err}");
        }
    }

    #[test]
    fn no_amd_node_is_an_error() {
        let sys = fake_sysfs(true);
        std::fs::write(sys.path().join("devices/0000:79:00.0/vendor"), "0x8086\n").unwrap();
        let err = select_render_node(sys.path(), Path::new("/dev/dri"), None).unwrap_err().to_string();
        assert!(err.contains("no AMD render node") && err.contains("renderD128"), "{err}");
        let empty = tempfile::tempdir().unwrap();
        assert!(select_render_node(empty.path(), Path::new("/dev/dri"), None).is_err());
    }

    #[test]
    fn the_fd_must_be_the_node() {
        // /dev/null is a character device (1:3): accepted only as 1:3.
        let null = |major, minor| RenderNode {
            name: "renderD0".into(),
            path: "/dev/null".into(),
            major,
            minor,
            pci: None,
            boot_vga: false,
        };
        assert!(open_render_node(&null(1, 3)).is_ok());
        assert!(open_render_node(&null(226, 130)).unwrap_err().to_string().contains("refusing"));
        let file = tempfile::NamedTempFile::new().unwrap();
        let fd = OwnedFd::from(std::fs::File::open(file.path()).unwrap());
        assert!(check_is_node(&fd, &null(0, 0)).is_err(), "a regular file is no device");
    }
}
