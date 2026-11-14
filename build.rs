// Windows: embed the icon, the manifest (DPI awareness, modern controls) and the version
// into port-sync.exe. A missing resource compiler only costs the icon, so it warns instead
// of failing the build.
fn main() {
    println!("cargo:rerun-if-changed=assets/app.rc");
    println!("cargo:rerun-if-changed=assets/app.ico");
    println!("cargo:rerun-if-changed=assets/app.manifest");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let v = env!("CARGO_PKG_VERSION");
    let parts: Vec<&str> = v.split(['.', '-']).take(3).collect();
    let commas = format!("{},{},{},0", parts[0], parts[1], parts[2]);
    let defs = [format!("PS_VERSION_COMMAS={}", commas), format!("PS_VERSION_STR=\\\"{}\\\"", v)];
    if let Err(e) = embed_resource::compile("assets/app.rc", &defs).manifest_optional() {
        println!("cargo:warning=no Windows resources embedded (icon, manifest): {}", e);
    }
}
