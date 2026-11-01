// BGRx -> NV12, BT.709 full range on the non-linear values, in one pass.
// Each invocation converts WORDS horizontally adjacent 4x2 pixel blocks: per block it writes one 32-bit
// word to each of the two Y rows (4 luma bytes) and one to the UV row (Cb Cr Cb Cr of its two 2x2 blocks).
// __WX__, __WY__, __WORDS__ and __STRIDED__ are substituted before compilation.

struct Params {
    y_off: u32,    // all four in 32-bit words
    y_pitch: u32,
    uv_off: u32,
    uv_pitch: u32,
    width: u32,    // pixels
    height: u32,
}

var<immediate> p: Params;
@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var<storage, read_write> dst: array<u32>;

const WORDS: u32 = __WORDS__u;
const STRIDED: bool = __STRIDED__; // blocks k of an invocation: adjacent (false) or one grid width apart (true)
const KY = vec3<f32>(0.2126, 0.7152, 0.0722);
const KB = 1.0 / 1.8556;
const KR = 1.0 / 1.5748;

fn q(v: f32) -> u32 {
    return u32(clamp(floor(v + 0.5), 0.0, 255.0));
}

fn px(x: i32, y: i32) -> vec3<f32> {
    // B8G8R8A8_UNORM: .rgb is R, G, B whatever the memory order.
    return textureLoad(src, vec2<i32>(x, y), 0).rgb * 255.0;
}

@compute @workgroup_size(__WX__, __WY__, 1)
fn cs_main(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) nwg: vec3<u32>) {
    let nx = nwg.x * __WX__u;
    let row = gid.y * 2u;
    if (row >= p.height) {
        return;
    }
    let y = i32(row);
    for (var k = 0u; k < WORDS; k++) {
        let xw = select(gid.x * WORDS + k, gid.x + k * nx, STRIDED);
        if (xw * 4u >= p.width) {
            return;
        }
        let x = i32(xw * 4u);
        var w0 = 0u;
        var w1 = 0u;
        var wc = 0u;
        for (var j = 0u; j < 2u; j++) {
            let xa = x + i32(j * 2u);
            let a = px(xa, y);
            let b = px(xa + 1, y);
            let c = px(xa, y + 1);
            let d = px(xa + 1, y + 1);
            let s = j * 16u;
            w0 |= (q(dot(a, KY)) << s) | (q(dot(b, KY)) << (s + 8u));
            w1 |= (q(dot(c, KY)) << s) | (q(dot(d, KY)) << (s + 8u));
            let m = (a + b + c + d) * 0.25;
            let ym = dot(m, KY);
            wc |= (q((m.b - ym) * KB + 128.0) << s) | (q((m.r - ym) * KR + 128.0) << (s + 8u));
        }
        dst[p.y_off + row * p.y_pitch + xw] = w0;
        dst[p.y_off + (row + 1u) * p.y_pitch + xw] = w1;
        dst[p.uv_off + gid.y * p.uv_pitch + xw] = wc;
    }
}
