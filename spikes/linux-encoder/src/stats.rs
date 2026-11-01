//! Percentiles of a set of durations, printed in milliseconds.

pub fn summary(label: &str, ns: &[u64]) -> String {
    if ns.is_empty() {
        return format!("{label}: none");
    }
    let mut v = ns.to_vec();
    v.sort_unstable();
    let p = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize] as f64 / 1e6;
    let mean = v.iter().sum::<u64>() as f64 / v.len() as f64 / 1e6;
    format!(
        "{label}: n={} p50={:.2} p95={:.2} p99={:.2} max={:.2} mean={:.2} ms",
        v.len(),
        p(0.5),
        p(0.95),
        p(0.99),
        p(1.0),
        mean
    )
}

pub fn mean(v: &[u64]) -> f64 {
    if v.is_empty() { 0.0 } else { v.iter().sum::<u64>() as f64 / v.len() as f64 }
}
