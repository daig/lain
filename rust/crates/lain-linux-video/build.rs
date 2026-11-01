//! Generates the libva and GBM bindings from the system headers (libva-dev, libgbm-dev) and links the
//! libraries. bindgen needs libclang-dev. The bindings are raw; `src/ffi.rs` includes them, and the safe
//! wrappers live in their own modules.

use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));

    // pkg-config prints the link flags; the include paths go to clang.
    let va = pkg_config::Config::new().atleast_version("1.20").probe("libva").expect("libva (apt install libva-dev)");
    let va_drm = pkg_config::Config::new().probe("libva-drm").expect("libva-drm (apt install libva-dev)");
    let gbm = pkg_config::Config::new().probe("gbm").expect("gbm (apt install libgbm-dev)");

    let includes = |libs: &[&pkg_config::Library]| -> Vec<String> {
        libs.iter().flat_map(|l| l.include_paths.iter()).map(|p| format!("-I{}", p.display())).collect()
    };

    builder()
        .header_contents(
            "lain_va.h",
            "#include <va/va.h>\n#include <va/va_drm.h>\n#include <va/va_drmcommon.h>\n#include <va/va_enc_hevc.h>\n",
        )
        .clang_args(includes(&[&va, &va_drm]))
        .allowlist_function("va.*")
        .allowlist_type("_?VA.*")
        .allowlist_var("VA.*")
        .generate()
        .expect("libva bindings")
        .write_to_file(out.join("va.rs"))
        .expect("write va.rs");

    builder()
        .header_contents("lain_gbm.h", "#include <gbm.h>\n")
        .clang_args(includes(&[&gbm]))
        .allowlist_function("gbm_.*")
        .allowlist_type("gbm_.*")
        .allowlist_var("GBM_.*")
        .generate()
        .expect("gbm bindings")
        .write_to_file(out.join("gbm.rs"))
        .expect("write gbm.rs");
}

fn builder() -> bindgen::Builder {
    bindgen::Builder::default()
        .rust_target(bindgen::RustTarget::stable(85, 0).expect("rust target"))
        .rust_edition(bindgen::RustEdition::Edition2024)
        .derive_default(true)
        .prepend_enum_name(false)
        .layout_tests(false)
        .generate_comments(false)
}
