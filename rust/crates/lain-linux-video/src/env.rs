//! The environment pin that keeps libEGL off the NVIDIA GPUs (decision L7; lead's decision, wave 3 prep). No
//! Swift counterpart: macOS has one GPU stack.
//!
//! glvnd's libEGL picks its vendor libraries from the environment **when it loads**, and NVIDIA's vendor file
//! (`10_nvidia.json`) would open the NVIDIA devices. So before this crate loads libEGL it checks that
//! `__EGL_VENDOR_LIBRARY_FILENAMES` names only Mesa's vendor file (the one whose `library_path` is
//! `libEGL_mesa.so.0`), and refuses to start video otherwise. It never sets the variable itself (`set_var` is
//! `unsafe` in edition 2024, and threads are running): [`required_environment`] says what to set, so that
//! `lain-hostd` can re-exec itself with it, and `rust/scripts/gpu-run.sh` sets it for tests.
//!
//! libva needs no pin: on an amdgpu fd it loads radeonsi. GBM picks its backend from the fd's driver too, unless
//! `GBM_BACKEND` forces one, so a forced backend other than Mesa's is refused as well.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use lain_platform::PlatformError;

/// The variable glvnd's libEGL reads its vendor list from.
pub const EGL_VENDOR_VAR: &str = "__EGL_VENDOR_LIBRARY_FILENAMES";
/// Forces a GBM backend when set; only Mesa's (`dri`) is accepted.
pub const GBM_BACKEND_VAR: &str = "GBM_BACKEND";
/// The library Mesa's vendor file names.
pub const MESA_EGL_LIBRARY: &str = "libEGL_mesa.so.0";
/// Where glvnd looks for vendor files, in its order (`/etc` first, then the data directory).
pub const VENDOR_DIRS: &[&str] = &["/etc/glvnd/egl_vendor.d", "/usr/share/glvnd/egl_vendor.d"];

/// The `library_path` of a glvnd EGL vendor file (`{"ICD": {"library_path": "..."}}`), read without a JSON
/// library: the files are tiny and fixed in form. `None` if there is none.
pub fn vendor_library_path(json: &str) -> Option<String> {
    let at = json.find("\"library_path\"")? + "\"library_path\"".len();
    let rest = json[at..].trim_start().strip_prefix(':')?.trim_start().strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => out.push(chars.next()?),
            c => out.push(c),
        }
    }
    None
}

/// Whether a vendor file's `library_path` is Mesa's: the bare name, or a path ending in it.
fn is_mesa_library(path: &str) -> bool {
    Path::new(path).file_name() == Some(OsStr::new(MESA_EGL_LIBRARY))
}

/// Mesa's EGL vendor file in `dirs`: the first `*.json` (in name order) whose `library_path` is
/// [`MESA_EGL_LIBRARY`].
pub fn find_mesa_vendor_file(dirs: &[&Path]) -> Option<PathBuf> {
    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(dir) else { continue };
        let mut files: Vec<PathBuf> =
            entries.filter_map(|e| e.ok().map(|e| e.path())).filter(|p| p.extension() == Some(OsStr::new("json"))).collect();
        files.sort();
        for file in files {
            if let Ok(text) = std::fs::read_to_string(&file)
                && vendor_library_path(&text).is_some_and(|l| is_mesa_library(&l))
            {
                return Some(file);
            }
        }
    }
    None
}

/// What the process environment must hold before video starts: `__EGL_VENDOR_LIBRARY_FILENAMES` set to
/// Mesa's vendor file, found in the system's vendor directories. `lain-hostd` re-execs itself with these when
/// [`check_environment`] fails.
pub fn required_environment() -> Result<Vec<(String, String)>, PlatformError> {
    let dirs: Vec<&Path> = VENDOR_DIRS.iter().map(Path::new).collect();
    let file = find_mesa_vendor_file(&dirs).ok_or_else(|| {
        PlatformError::Unavailable(format!("no glvnd EGL vendor file names {MESA_EGL_LIBRARY} (is Mesa's libEGL installed?)"))
    })?;
    Ok(vec![(EGL_VENDOR_VAR.to_string(), file.display().to_string())])
}

/// Checks the pins in `get(name)` (the environment, or a test's map): every file `__EGL_VENDOR_LIBRARY_FILENAMES`
/// lists (colon-separated) is a vendor file naming Mesa's library, there is at least one, and `GBM_BACKEND`, if
/// set, is Mesa's. Returns why not, worded for the owner (`HostSetup.videoProblem`).
pub fn check_environment_with(get: impl Fn(&str) -> Option<String>) -> Result<(), PlatformError> {
    let fix = "start lain-hostd normally (it sets this itself), or set __EGL_VENDOR_LIBRARY_FILENAMES to Mesa's \
               vendor file, e.g. /usr/share/glvnd/egl_vendor.d/50_mesa.json";
    let refuse = |why: String| Err(PlatformError::Unavailable(format!("video refused to load libEGL: {why}; {fix}")));
    if let Some(backend) = get(GBM_BACKEND_VAR).filter(|b| !b.is_empty())
        && backend != "dri"
    {
        return refuse(format!("{GBM_BACKEND_VAR}={backend} forces a GBM backend other than Mesa's"));
    }
    let Some(list) = get(EGL_VENDOR_VAR).filter(|l| !l.trim().is_empty()) else {
        return refuse(format!("{EGL_VENDOR_VAR} isn't set, so glvnd would load every vendor, NVIDIA's included"));
    };
    for file in list.split(':').filter(|f| !f.is_empty()) {
        let library = match std::fs::read_to_string(file) {
            Ok(text) => vendor_library_path(&text),
            Err(e) => return refuse(format!("{EGL_VENDOR_VAR} names {file}, which can't be read ({e})")),
        };
        match library {
            Some(l) if is_mesa_library(&l) => {}
            Some(l) => return refuse(format!("{EGL_VENDOR_VAR} names {file}, whose library is {l}, not Mesa's")),
            None => return refuse(format!("{EGL_VENDOR_VAR} names {file}, which isn't an EGL vendor file")),
        }
    }
    Ok(())
}

/// [`check_environment_with`] on the process environment. Called before libEGL is loaded, every time video
/// starts.
pub fn check_environment() -> Result<(), PlatformError> {
    check_environment_with(|name| std::env::var(name).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const MESA: &str = "{\n    \"file_format_version\" : \"1.0.0\",\n    \"ICD\" : {\n        \"library_path\" : \"libEGL_mesa.so.0\"\n    }\n}\n";
    const NVIDIA: &str = "{\n    \"file_format_version\" : \"1.0.0\",\n    \"ICD\" : {\n        \"library_path\" : \"libEGL_nvidia.so.0\"\n    }\n}\n";

    fn vendor_dir() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let nv = dir.path().join("10_nvidia.json");
        let mesa = dir.path().join("50_mesa.json");
        std::fs::write(&nv, NVIDIA).unwrap();
        std::fs::write(&mesa, MESA).unwrap();
        (dir, nv, mesa)
    }

    fn env(pairs: &[(&str, String)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> = pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect();
        move |k| map.get(k).cloned()
    }

    #[test]
    fn reads_library_path() {
        assert_eq!(vendor_library_path(MESA).as_deref(), Some("libEGL_mesa.so.0"));
        assert_eq!(vendor_library_path(NVIDIA).as_deref(), Some("libEGL_nvidia.so.0"));
        assert_eq!(vendor_library_path("{\"library_path\":\"/opt/a\\\"b.so\"}").as_deref(), Some("/opt/a\"b.so"));
        assert_eq!(vendor_library_path("{}"), None);
        assert_eq!(vendor_library_path("{\"library_path\": 3}"), None);
        assert!(is_mesa_library("/usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0"));
        assert!(!is_mesa_library("libEGL_mesa.so.0.bak"));
    }

    #[test]
    fn finds_mesa_among_vendors() {
        let (dir, _, mesa) = vendor_dir();
        assert_eq!(find_mesa_vendor_file(&[Path::new("/nonexistent"), dir.path()]), Some(mesa));
        let empty = tempfile::tempdir().unwrap();
        assert_eq!(find_mesa_vendor_file(&[empty.path()]), None);
    }

    #[test]
    fn accepts_only_mesa() {
        let (_dir, nv, mesa) = vendor_dir();
        let path = |p: &PathBuf| p.display().to_string();
        assert_eq!(check_environment_with(env(&[(EGL_VENDOR_VAR, path(&mesa))])), Ok(()));
        // Mesa listed twice is still only Mesa.
        assert_eq!(check_environment_with(env(&[(EGL_VENDOR_VAR, format!("{}:{}", path(&mesa), path(&mesa)))])), Ok(()));
        assert_eq!(check_environment_with(env(&[(EGL_VENDOR_VAR, path(&mesa)), (GBM_BACKEND_VAR, "dri".into())])), Ok(()));

        let refused = |e: Vec<(&str, String)>, want: &str| {
            let Err(PlatformError::Unavailable(why)) = check_environment_with(env(&e)) else { panic!("accepted {e:?}") };
            assert!(why.contains(want), "{why}");
        };
        refused(vec![], "isn't set");
        refused(vec![(EGL_VENDOR_VAR, " ".into())], "isn't set");
        refused(vec![(EGL_VENDOR_VAR, path(&nv))], "libEGL_nvidia.so.0");
        refused(vec![(EGL_VENDOR_VAR, format!("{}:{}", path(&mesa), path(&nv)))], "not Mesa's");
        refused(vec![(EGL_VENDOR_VAR, "/nonexistent/50_mesa.json".into())], "can't be read");
        refused(vec![(EGL_VENDOR_VAR, path(&mesa)), (GBM_BACKEND_VAR, "nvidia-drm".into())], "GBM_BACKEND");
        let junk = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(junk.path(), "not json").unwrap();
        refused(vec![(EGL_VENDOR_VAR, junk.path().display().to_string())], "isn't an EGL vendor file");
    }
}
