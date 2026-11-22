use serde::{Deserialize, Serialize};

pub const GB: u64 = 1_000_000_000;

pub fn health_score(free: u64, total: u64, mem_used_ratio: f64, startup_items: usize, junk_bytes: u64) -> (u8, Vec<&'static str>) {
    let mut score: i32 = 100;
    let mut issues = vec![];
    let mut deduct = |points, issue| {
        score -= points;
        issues.push(issue);
    };
    if total > 0 {
        match free as f64 / total as f64 {
            x if x < 0.05 => deduct(40, "disk"),
            x if x < 0.10 => deduct(25, "disk"),
            x if x < 0.20 => deduct(10, "disk"),
            _ => {}
        }
    }
    if mem_used_ratio > 0.90 {
        deduct(20, "memory");
    } else if mem_used_ratio > 0.75 {
        deduct(10, "memory");
    }
    match startup_items {
        16.. => deduct(15, "startup"),
        9.. => deduct(8, "startup"),
        _ => {}
    }
    match junk_bytes {
        x if x >= 10 * GB => deduct(20, "junk"),
        x if x >= 3 * GB => deduct(12, "junk"),
        x if x >= GB => deduct(5, "junk"),
        _ => {}
    }
    (score.clamp(0, 100) as u8, issues)
}

#[derive(Debug, PartialEq, Serialize)]
pub struct Battery {
    pub design: u32,
    pub full: u32,
    pub cycles: Option<u32>,
    pub health: u8,
}

pub fn parse_battery(json: &str) -> Option<Battery> {
    #[derive(Deserialize)]
    struct Reading {
        design: u32,
        full: u32,
        cycles: Option<u32>,
    }
    let Reading { design, full, cycles } = serde_json::from_str(json.trim()).ok()?;
    if design == 0 {
        return None;
    }
    Some(Battery { design, full, cycles, health: (u64::from(full) * 100 / u64::from(design)).min(100) as u8 })
}

#[derive(Default, Serialize)]
pub struct Ram {
    pub used: u64,
    pub total: u64,
}

impl Ram {
    pub fn ratio(&self) -> f64 {
        if self.total == 0 { 0.0 } else { self.used as f64 / self.total as f64 }
    }
}

pub fn cpu_percent(prev: (u64, u64, u64), now: (u64, u64, u64)) -> u8 {
    let (Some(idle), Some(kernel), Some(user)) =
        (now.0.checked_sub(prev.0), now.1.checked_sub(prev.1), now.2.checked_sub(prev.2))
    else { return 0 };
    let total = u128::from(kernel) + u128::from(user);
    let busy = total.saturating_sub(u128::from(idle));
    (busy * 100 + total / 2).checked_div(total).unwrap_or(0) as u8
}

#[cfg(windows)]
mod win {
    use super::*;
    use windows_sys::Win32::{Foundation::FILETIME, System::{
        SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX},
        Threading::GetSystemTimes,
    }};

    pub fn ram() -> Ram {
        let mut status = MEMORYSTATUSEX {
            dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
            ..unsafe { std::mem::zeroed() }
        };
        if unsafe { GlobalMemoryStatusEx(&mut status) } == 0 {
            return Ram::default();
        }
        Ram { used: status.ullTotalPhys.saturating_sub(status.ullAvailPhys), total: status.ullTotalPhys }
    }

    pub fn system_times() -> Option<(u64, u64, u64)> {
        let mut times: [FILETIME; 3] = unsafe { std::mem::zeroed() };
        let [idle, kernel, user] = &mut times;
        (unsafe { GetSystemTimes(idle, kernel, user) } != 0)
            .then(|| (crate::system::filetime(*idle), crate::system::filetime(*kernel), crate::system::filetime(*user)))
    }

    pub fn battery() -> Option<Battery> {
        let script = r#"
$b = Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
if (!$b) { return }
$f = Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -eq $b.InstanceName } | Select-Object -First 1
$c = Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue | Where-Object { $_.InstanceName -eq $b.InstanceName } | Select-Object -First 1
@{ design = $b.DesignedCapacity; full = $f.FullChargedCapacity; cycles = $c.CycleCount } | ConvertTo-Json -Compress
"#;
        let json = crate::system::powershell(script).ok()?;
        parse_battery(std::str::from_utf8(&json).ok()?)
    }
}

#[cfg(windows)]
pub use win::{battery, ram, system_times};

#[cfg(not(windows))]
pub fn ram() -> Ram { Ram::default() }

#[cfg(not(windows))]
pub fn battery() -> Option<Battery> { None }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn score_edges() {
        for (free, score) in [(49, 60), (50, 75), (99, 75), (100, 90), (199, 90), (200, 100)] {
            assert_eq!(health_score(free, 1000, 0., 0, 0).0, score);
        }
        for (ram, score) in [(0.75, 100), (0.750001, 90), (0.90, 90), (0.900001, 80)] {
            assert_eq!(health_score(0, 0, ram, 0, 0).0, score);
        }
        for (startup, score) in [(8, 100), (9, 92), (15, 92), (16, 85)] {
            assert_eq!(health_score(0, 0, 0., startup, 0).0, score);
        }
        for (junk, score) in [(GB-1, 100), (GB, 95), (3*GB-1, 95), (3*GB, 88), (10*GB-1, 88), (10*GB, 80)] {
            assert_eq!(health_score(0, 0, 0., 0, junk).0, score);
        }
        assert_eq!(health_score(0, 100, 0.95, 20, 10*GB), (5, vec!["disk", "memory", "startup", "junk"]));
    }

    #[test]
    fn battery_readings() {
        assert_eq!(parse_battery(r#"{"design":50000,"full":46000,"cycles":312}"#),
            Some(Battery { design: 50000, full: 46000, cycles: Some(312), health: 92 }));
        assert_eq!(parse_battery("null"), None);
        assert_eq!(parse_battery(r#"{"design":0,"full":1}"#), None);
        assert_eq!(parse_battery(r#"{"design":10,"full":12}"#).map(|b| (b.cycles, b.health)), Some((None, 100)));
    }

    #[test]
    fn cpu_uses_kernel_time_including_idle() {
        assert_eq!(cpu_percent((10, 50, 20), (70, 130, 40)), 40);
        assert_eq!(cpu_percent((0, 0, 0), (100, 100, 0)), 0);
        assert_eq!(cpu_percent((0, 0, 0), (0, 100, 0)), 100);
        assert_eq!(cpu_percent((0, 0, 0), (0, 0, 0)), 0);
        assert_eq!(cpu_percent((100, 100, 100), (0, 0, 0)), 0);
    }
}
