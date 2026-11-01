// BGRx -> NV12, BT.709 full range on the non-linear values, in one pass, into the two planes of a tiled
// NV12 surface (libva's own, the encoder's input) imported as two storage images: R8 (Y) and R8G8 (CbCr).
// Each invocation converts one 2x2 block. __WX__ and __WY__ are substituted before compilation.

struct Params {
    width: u32,    // pixels
    height: u32,
}

var<immediate> p: Params;
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var dst_y: texture_storage_2d<r8unorm, write>;
@group(0) @binding(2) var dst_uv: texture_storage_2d<rg8unorm, write>;

const KY = vec3<f32>(0.2126, 0.7152, 0.0722);
const KB = 1.0 / 1.8556;
const KR = 1.0 / 1.5748;

// Rounded, clamped 8-bit code, as the UNORM value the store converts back exactly.
fn q(v: f32) -> f32 {
    return clamp(floor(v + 0.5), 0.0, 255.0) / 255.0;
}

@compute @workgroup_size(__WX__, __WY__, 1)
fn cs_main(@builtin(global_invocation_id) gid: vec3<u32>) {
    if (gid.x * 2u >= p.width || gid.y * 2u >= p.height) {
        return;
    }
    let c = vec2<i32>(gid.xy);
    let o = c * 2;
    let a = textureLoad(src, o, 0).rgb * 255.0;
    let b = textureLoad(src, o + vec2<i32>(1, 0), 0).rgb * 255.0;
    let d = textureLoad(src, o + vec2<i32>(0, 1), 0).rgb * 255.0;
    let e = textureLoad(src, o + vec2<i32>(1, 1), 0).rgb * 255.0;
    textureStore(dst_y, o, vec4<f32>(q(dot(a, KY)), 0.0, 0.0, 1.0));
    textureStore(dst_y, o + vec2<i32>(1, 0), vec4<f32>(q(dot(b, KY)), 0.0, 0.0, 1.0));
    textureStore(dst_y, o + vec2<i32>(0, 1), vec4<f32>(q(dot(d, KY)), 0.0, 0.0, 1.0));
    textureStore(dst_y, o + vec2<i32>(1, 1), vec4<f32>(q(dot(e, KY)), 0.0, 0.0, 1.0));
    let m = (a + b + d + e) * 0.25;
    let ym = dot(m, KY);
    textureStore(dst_uv, c, vec4<f32>(q((m.b - ym) * KB + 128.0), q((m.r - ym) * KR + 128.0), 0.0, 1.0));
}
