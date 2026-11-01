// Builds native/native.c (GBM and libva helpers) with the system C compiler; no cc crate, no bindgen.
use std::process::Command;

fn main() {
    let out = std::env::var("OUT_DIR").unwrap();
    println!("cargo:rerun-if-changed=native/native.c");
    let ok = Command::new("cc")
        .args(["-O2", "-Wall", "-Wextra", "-fPIC", "-c", "native/native.c", "-o"])
        .arg(format!("{out}/native.o"))
        .status()
        .expect("cc")
        .success();
    assert!(ok, "compiling native/native.c failed");
    let ok = Command::new("ar")
        .args(["rcs", &format!("{out}/libnative.a"), &format!("{out}/native.o")])
        .status()
        .expect("ar")
        .success();
    assert!(ok);
    println!("cargo:rustc-link-search=native={out}");
    println!("cargo:rustc-link-lib=static=native");
    println!("cargo:rustc-link-lib=dylib=gbm");
    println!("cargo:rustc-link-lib=dylib=va");
    println!("cargo:rustc-link-lib=dylib=va-drm");
}
