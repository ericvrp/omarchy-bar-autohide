import { afterAll, expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, writeFile, rm, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const repo = resolve(import.meta.dir, "..");
const directory = await mkdtemp(join(tmpdir(), "bar-autohide-test-"));
const runtime = join(directory, "runtime");
const flag = join(directory, ".local/state/omarchy/toggles/bar-off");
await mkdir(runtime, { recursive: true });
await mkdir(join(directory, ".local/state/omarchy/toggles"), { recursive: true });
await mkdir(join(directory, ".config/omarchy"), { recursive: true });
await mkdir(join(directory, "scripts"));
await mkdir(join(directory, "bin"));
await writeFile(join(directory, ".config/omarchy/shell.json"), JSON.stringify({
  plugins: [{ id: "ericvrp.bar-autohide", hideDelayMs: 0 }],
}));
await writeFile(join(directory, "bin/omarchy-shell"), "#!/bin/sh\nexit 0\n", { mode: 0o755 });
await writeFile(join(directory, "scripts/bar-state-writer.sh"),
  await readFile(join(repo, "scripts/bar-state-writer.sh")));
// Exercise the actual service and FileViews without creating desktop surfaces.
await writeFile(join(directory, "Service.qml"), (await readFile(join(repo, "Service.qml"), "utf8"))
  .replace(/  Variants \{[\s\S]*?\n  Component.onDestruction:/, "  Component.onDestruction:"));
await writeFile(join(directory, "shell.qml"), `
import Quickshell
import Quickshell.Io
import QtQuick
ShellRoot {
  id: host
  property var service: null
  property bool probing: true
  property QtObject bar: QtObject {
    property var data: [{ instances: [hostWindow] }]
    property bool barHidden: false
    property int barSize: 30
    property string position: "top"
  }
  Item { id: barContent }
  QtObject {
    id: hostWindow
    property var contentItem: barContent
    property var screen: null
  }
  Component { id: factory; Service {} }
  Process {
    id: probe
    command: ["bash", "-c", "[[ -f \\\"$HOME/.local/state/omarchy/toggles/bar-off\\\" ]] && echo hidden || echo visible"]
    stdout: StdioCollector {
      onStreamFinished: host.bar.barHidden = String(this.text).trim() === "hidden"
    }
  }
  Timer {
    interval: 20; running: host.probing; repeat: true
    onTriggered: { if (!probe.running) probe.running = true }
  }
  IpcHandler {
    target: "test"
    function enable(): void {
      host.service = factory.createObject(null)
      host.service.shell = host
    }
    function disable(): void { host.service.destroy(); host.service = null }
    function reveal(): void { host.service.edgeHovered = true; host.service.showBar() }
    function leave(): void { host.service.pointerInBarBand = false; host.service.edgeHovered = false }
    function pause(): void { host.probing = false }
    function resume(): void { host.probing = true }
    function assumeHidden(): void { host.bar.barHidden = true }
    function status(): string {
      return JSON.stringify({ hidden: host.bar.barHidden, active: !!host.service,
        auto: host.service ? host.service.autoRevealed : false,
        delay: host.service ? host.service.hideDelayMs : -1,
        observers: barContent.children.length })
    }
    function quit(): void { Quickshell.quit() }
  }
}
`);
const env = { ...process.env, HOME: directory, XDG_CONFIG_HOME: join(directory, ".config"),
  XDG_RUNTIME_DIR: runtime, QT_QPA_PLATFORM: "offscreen", PATH: `${directory}/bin:${process.env.PATH}` };
const log = Bun.file(join(directory, "shell.log"));
const shell = Bun.spawn(["quickshell", "-p", directory, "--no-color"], { env, stdout: log, stderr: log });

async function call(method: string) {
  const child = Bun.spawn(["quickshell", "ipc", "-p", directory, "call", "test", method],
    { env, stdout: "pipe", stderr: "pipe" });
  const text = await new Response(child.stdout).text();
  if (await child.exited !== 0 || /not found|not ready/i.test(text)) throw new Error(text);
  return text.trim();
}

async function until(check: () => Promise<boolean>) {
  const end = Date.now() + 7000;
  while (Date.now() < end) {
    try { if (await check()) return; } catch { /* Wait for startup or the next probe. */ }
    await Bun.sleep(30);
  }
  const records = await Promise.all((await readdir(runtime)).filter(p => p.startsWith("ericvrp")).map(async p =>
    `${p}: ${await readFile(join(runtime, p), "utf8")}`));
  throw new Error(`Timed out\n${await call("status")}\n${records.join("\n")}\n${await log.text()}`);
}

async function hidden(value: boolean) {
  await until(async () => JSON.parse(await call("status")).hidden === value);
}

async function settled() {
  await until(async () => {
    const operation = (await readFile(join(runtime, "ericvrp.bar-autohide.operation"), "utf8")).trim();
    const ack = (await readFile(join(runtime, "ericvrp.bar-autohide.ack"), "utf8")).trim();
    const owner = (await readFile(join(runtime, "ericvrp.bar-autohide.current"), "utf8")).trim();
    const revision = (await readFile(join(runtime, `ericvrp.bar-autohide.${owner}.intent`), "utf8")).split(":")[0];
    const journal = (await readFile(join(runtime, "ericvrp.bar-autohide.journal"), "utf8")).trim().split(":");
    return operation.substring(0, operation.lastIndexOf(":")) === ack
      && journal[1] === owner && journal[2] === revision;
  });
}

afterAll(async () => {
  try { await call("quit"); } catch { shell.kill(); }
  shell.kill();
  await shell.exited;
  await rm(directory, { recursive: true, force: true });
});

test("service recovers across disable, manual toggles, unchanged probes, and replacement", async () => {
  await until(async () => !!JSON.parse(await call("status")));
  await call("enable");
  await hidden(true);
  await settled();
  expect(JSON.parse(await call("status")).delay).toBe(0);
  expect(JSON.parse(await call("status")).observers).toBe(1);
  await rm(flag); // A manual hotkey reveal must remain visible.
  await hidden(false);
  await settled();
  await Bun.sleep(100);
  expect(JSON.parse(await call("status")).hidden).toBe(false);
  expect(JSON.parse(await call("status")).auto).toBe(false);
  await writeFile(flag, "");
  await hidden(true);
  await settled();
  await call("reveal");
  await hidden(false);
  await settled();
  await call("leave");
  await hidden(true);
  await settled();
  await call("disable");
  await hidden(false);
  expect(JSON.parse(await call("status")).observers).toBe(0);
  await writeFile(flag, "");
  await hidden(true);
  await call("enable");
  await settled();
  await call("reveal");
  await hidden(false);
  await settled();
  await call("disable");
  await hidden(true); // The second activation captured the manual hidden baseline.
  await rm(flag);
  await hidden(false);
  await call("enable");
  await hidden(true);
  await settled();
  await call("pause");
  await call("reveal");
  await until(async () => !await Bun.file(flag).exists());
  // Destroy the only observer with a request still awaiting its callback.
  await call("disable");
  await until(async () => !await Bun.file(join(runtime, "ericvrp.bar-autohide.journal")).exists());
  await call("resume");
  await hidden(false);
  // The host already reports hidden, but the flag is still absent. The next
  // hide changes the flag without emitting any host visibility-change signal.
  await rm(join(runtime, "ericvrp.bar-autohide.operation"));
  await rm(join(runtime, "ericvrp.bar-autohide.ack"));
  await call("pause");
  await Bun.sleep(100); // Let an already-running probe finish before seeding it.
  await call("assumeHidden");
  await call("enable");
  await until(async () => await Bun.file(flag).exists());
  await settled();
  await call("disable");
  await until(async () => !await Bun.file(flag).exists());
  await call("resume");
  await hidden(false);
  expect(JSON.parse(await call("status")).observers).toBe(0);
  expect(await log.text()).not.toMatch(/TypeError|ReferenceError|failed to publish|timed out waiting/);
}, 40000);
