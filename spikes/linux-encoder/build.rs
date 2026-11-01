fn main() {
    // libgstva-1.0 (GstVaDisplayDrm, the VA display context); only the runtime .so.0 is installed.
    println!("cargo:rustc-link-arg=-l:libgstva-1.0.so.0");
}
