use serde::Serialize;
use std::{cmp::Reverse, collections::HashMap};

#[derive(Clone, Debug)]
pub struct Proc {
    pub pid: u32,
    pub started: u64,
    pub path: String,
    pub bytes: u64,
    pub cpu: f64,
}

#[derive(Serialize, Debug)]
pub struct HeavyApp {
    pub id: String,
    pub name: String,
    pub path: String,
    pub bytes: u64,
    pub cpu: u8,
    pub count: usize,
    #[serde(skip)]
    pub members: Vec<(u32, u64)>,
}

fn path_key(path: &str) -> String {
    let path = path.replace('/', "\\").to_lowercase();
    path.strip_prefix(r"\\?\").unwrap_or(&path).to_string()
}

fn allowed(pid: u32, path: &str, own_pid: u32, windows: &str) -> bool {
    let path = path_key(path);
    let under = |root: &str| {
        let root = root.trim_end_matches('\\');
        path == root || path.strip_prefix(root).is_some_and(|rest| rest.starts_with('\\'))
    };
    pid != 0 && pid != own_pid && !path.is_empty() && !under(r"c:\windows") && !under(windows)
}

fn group_for(samples: Vec<Proc>, own_pid: u32, windows: &str) -> Vec<HeavyApp> {
    let mut groups: HashMap<String, (HeavyApp, f64)> = HashMap::new();
    for p in samples {
        if !allowed(p.pid, &p.path, own_pid, windows) {
            continue;
        }
        let id = path_key(&p.path);
        let (group, cpu) = groups.entry(id.clone()).or_insert_with(|| (HeavyApp {
            id,
            name: p.path.rsplit(['\\', '/']).next().unwrap_or(&p.path).to_string(),
            path: p.path,
            bytes: 0,
            cpu: 0,
            count: 0,
            members: vec![],
        }, 0.0));
        group.bytes = group.bytes.saturating_add(p.bytes);
        *cpu += p.cpu;
        group.count += 1;
        group.members.push((p.pid, p.started));
    }
    let mut out: Vec<_> = groups.into_values().map(|(mut group, cpu)| {
        group.cpu = cpu.round().clamp(0., 100.) as u8;
        group
    }).collect();
    out.sort_unstable_by(|a, b| (Reverse(a.bytes), &a.id).cmp(&(Reverse(b.bytes), &b.id)));
    out.truncate(20);
    out
}

fn windows_dir() -> String {
    path_key(&std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into()))
}

pub fn group_processes(samples: Vec<Proc>) -> Vec<HeavyApp> {
    group_for(samples, std::process::id(), &windows_dir())
}

#[cfg(windows)]
mod win {
    use super::*;
    use crate::system::{filetime, hidden_command};
    use std::time::{Duration, Instant};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, FILETIME, HANDLE, INVALID_HANDLE_VALUE},
        System::{
            Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS},
            ProcessStatus::{K32EmptyWorkingSet, K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS},
            RemoteDesktop::ProcessIdToSessionId,
            Threading::{GetActiveProcessorCount, ALL_PROCESSOR_GROUPS, GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SET_QUOTA},
        },
    };

    struct Handle(HANDLE);
    impl Drop for Handle {
        fn drop(&mut self) { unsafe { CloseHandle(self.0) }; }
    }

    fn pids() -> Vec<u32> {
        let handle = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
        if handle == INVALID_HANDLE_VALUE {
            return vec![];
        }
        let handle = Handle(handle);
        let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        let mut out = vec![];
        let mut ok = unsafe { Process32FirstW(handle.0, &mut entry) };
        while ok != 0 {
            out.push(entry.th32ProcessID);
            ok = unsafe { Process32NextW(handle.0, &mut entry) };
        }
        out
    }

    fn open(pid: u32, access: u32, windows: &str) -> Option<(Handle, String)> {
        let own_pid = std::process::id();
        if pid == own_pid || pid == 0 {
            return None;
        }
        let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | access, 0, pid) };
        if handle.is_null() {
            return None;
        }
        let handle = Handle(handle);
        let mut text = vec![0u16; 32_768];
        let mut len = text.len() as u32;
        if unsafe { QueryFullProcessImageNameW(handle.0, 0, text.as_mut_ptr(), &mut len) } == 0 {
            return None;
        }
        let path = String::from_utf16(&text[..len as usize]).ok()?;
        allowed(pid, &path, own_pid, windows).then_some((handle, path))
    }

    fn session(pid: u32) -> Option<u32> {
        let mut id = 0;
        (unsafe { ProcessIdToSessionId(pid, &mut id) } != 0).then_some(id)
    }

    pub fn trim_memory() {
        let Some(current) = session(std::process::id()) else { return };
        let windows = windows_dir();
        for pid in pids().into_iter().filter(|&pid| session(pid) == Some(current)) {
            if let Some((handle, _)) = open(pid, PROCESS_SET_QUOTA, &windows)
                .filter(|_| session(pid) == Some(current))
            {
                unsafe { K32EmptyWorkingSet(handle.0) };
            }
        }
    }

    fn times(handle: &Handle) -> Option<(u64, u64)> {
        let mut times: [FILETIME; 4] = unsafe { std::mem::zeroed() };
        let [created, exited, kernel, user] = &mut times;
        (unsafe { GetProcessTimes(handle.0, created, exited, kernel, user) } != 0)
            .then(|| (filetime(*created), filetime(*kernel).saturating_add(filetime(*user))))
    }

    fn memory(handle: &Handle) -> Option<u64> {
        let mut mem: PROCESS_MEMORY_COUNTERS = unsafe { std::mem::zeroed() };
        mem.cb = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
        let size = mem.cb;
        (unsafe { K32GetProcessMemoryInfo(handle.0, &mut mem, size) } != 0)
            .then_some(mem.WorkingSetSize as u64)
    }

    pub fn heavy_apps() -> Vec<HeavyApp> {
        let windows = windows_dir();
        let samples: Vec<_> = pids().into_iter().filter_map(|pid| {
            let (handle, path) = open(pid, 0, &windows)?;
            let (started, used) = times(&handle)?;
            Some((pid, path, handle, started, used, Instant::now()))
        }).collect();
        if samples.is_empty() {
            return vec![];
        }
        std::thread::sleep(Duration::from_millis(500));
        let cpus = unsafe { GetActiveProcessorCount(ALL_PROCESSOR_GROUPS) }.max(1);
        group_processes(samples.into_iter().filter_map(|(pid, path, handle, started, used, at)| {
            let (_, after) = times(&handle)?;
            let wall = at.elapsed().as_secs_f64();
            let cpu = after.saturating_sub(used) as f64 / 10_000_000.0 / wall / f64::from(cpus) * 100.0;
            Some(Proc { pid, started, path, cpu, bytes: memory(&handle)? })
        }).collect())
    }

    pub fn quit_app(id: &str, members: &[(u32, u64)]) -> Result<(), String> {
        let windows = windows_dir();
        let mut handles = vec![];
        let mut command = hidden_command("taskkill.exe");
        for &(pid, started) in members {
            let Some((handle, path)) = open(pid, 0, &windows) else { continue };
            if path_key(&path) == id && times(&handle).is_some_and(|(created, _)| created == started) {
                command.args(["/PID", &pid.to_string()]);
                handles.push(handle);
            }
        }
        if handles.is_empty() {
            return Ok(());
        }
        let status = command.output().map_err(|e| e.to_string())?;
        status.status.success().then_some(()).ok_or_else(|| "taskkill failed".into())
    }
}

#[cfg(windows)]
pub use win::{heavy_apps, quit_app, trim_memory};

#[cfg(not(windows))]
pub fn heavy_apps() -> Vec<HeavyApp> { vec![] }

#[cfg(not(windows))]
pub fn quit_app(_: &str, _: &[(u32, u64)]) -> Result<(), String> { Err("Windows only".into()) }

#[cfg(not(windows))]
pub fn trim_memory() {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_by_image_sorts_and_skips() {
        let sample = |pid, path: &str, bytes, cpu| Proc { pid, path: path.into(), bytes, cpu, started: 1 };
        let groups = group_for(vec![
            sample(1, r"C:\Apps\Test.exe", 300, 0.5),
            sample(2, r"c:/apps/test.exe", 200, 1.2),
            sample(3, r"C:\Other\Test.exe", 400, 5.0),
            sample(4, r"c:\wInDows\explorer.exe", 900, 9.0),
            sample(5, r"D:\OS\explorer.exe", 900, 9.0),
            sample(6, r"C:\Apps\Cleanix.exe", 900, 9.0),
            sample(7, "", 900, 9.0),
        ], 6, r"d:\os");
        assert_eq!(groups.len(), 2);
        assert_eq!((groups[0].name.as_str(), groups[0].bytes, groups[0].cpu, groups[0].count), ("Test.exe", 500, 2, 2));
        assert_eq!(groups[0].members, [(1, 1), (2, 1)]);
        assert_eq!(groups[1].bytes, 400);
    }
}
