// Design-preview stand-in for the Rust side, used only when the page runs outside the app.
const H = 'C:\\Users\\Demo';
const mk = (path, bytes, group, safety = 'safe') => ({ path, name: path.split('\\').pop(), bytes, group, safety });
const MB = 1024 * 1024;
const DATA = {
  junk: [
    mk(H + '\\AppData\\Local\\Temp\\setup_4821', 412 * MB, 'temp'),
    mk(H + '\\AppData\\Local\\Temp\\chrome_installer.log', 2 * MB, 'temp'),
    mk(H + '\\AppData\\Local\\CrashDumps\\explorer.exe.dmp', 96 * MB, 'crash'),
    mk('C:\\Windows\\Temp\\MpCmdRun.log', 12 * MB, 'winTemp'),
  ],
  caches: [
    mk(H + '\\AppData\\Local\\Google\\Chrome\\User Data\\Default\\Cache', 820 * MB, 'Chrome'),
    mk(H + '\\AppData\\Local\\Microsoft\\Edge\\User Data\\Default\\Code Cache', 210 * MB, 'Edge'),
    mk(H + '\\AppData\\Roaming\\discord\\Cache', 340 * MB, 'Discord'),
  ],
  downloads: [mk(H + '\\Downloads\\Windows11.iso', 5400 * MB, 'downloads', 'review'), mk(H + '\\Downloads\\old-project.zip', 230 * MB, 'downloads', 'review')],
  large: [mk(H + '\\Videos\\wedding.mp4', 3100 * MB, 'large', 'review')],
};
const dirs = {
  [H]: [['Videos', 41000, 'review', 1], ['AppData', 23000, 'risky', 1], ['Downloads', 9800, 'review', 1], ['Documents', 4200, 'review', 1], ['NTUSER.DAT', 12, 'risky', 0]],
};
const wait = ms => new Promise(r => setTimeout(r, ms));
export async function mockInvoke(cmd, args = {}) {
  await wait(cmd === 'scan' ? 700 : 150);
  switch (cmd) {
    case 'scan': return structuredClone(DATA[args.kind] ?? []);
    case 'home': return H;
    case 'disk_children': {
      const p = args.path ?? H;
      return (dirs[p] ?? [['file.bin', 300, 'review', 0], ['Cache', 120, 'safe', 1]]).map(([n, mb, safety, dir]) => ({ path: p + '\\' + n, name: n, bytes: mb * MB, safety, dir: !!dir }));
    }
    case 'clean': return { freed: args.paths.length * 50 * MB, removed: args.paths, failed: [] };
    case 'disk_info': return { total: 512 * 1024 * MB, free: 143 * 1024 * MB };
    case 'list_apps': return [
      ['Adobe Photoshop 2025', 'Adobe Inc.', '26.1', 4800], ['Google Chrome', 'Google LLC', '131.0', 620], ['Zoom Workplace', 'Zoom Communications', '6.2.5', 310],
      ['7-Zip 24.08 (x64)', 'Igor Pavlov', '24.08', 5], ['Steam', 'Valve Corporation', '2.10', 0], ['Microsoft Teams', 'Microsoft Corporation', '24295', 740],
    ].map(([name, publisher, version, mb], i) => ({ id: 'lm64\\app' + i, name, publisher, version, bytes: mb * MB }));
    case 'uninstall': return null;
    case 'recycle_info': return { bytes: 1300 * MB, items: 214 };
    default: return null;
  }
}
