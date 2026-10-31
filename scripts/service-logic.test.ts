import { expect, test } from "bun:test";

const source = await Bun.file(new URL("../Service.qml", import.meta.url)).text();
const backgroundSource = await Bun.file(new URL("../BarTransitionBackground.qml", import.meta.url)).text();

function method(name: string, next: string) {
  return source.slice(source.indexOf(`  function ${name}(`), source.indexOf(`  function ${next}(`));
}

const delay = new Function("root", "shellConfig", "console",
  `${method("configuredHideDelay", "createLeaseId")} return configuredHideDelay();`);

test("hide delay validates configuration and clamps integers", () => {
  const configured = (value: unknown) => ({ plugins: [{ id: "ericvrp.bar-autohide", hideDelayMs: value }] });
  const cases: [unknown, number][] = [
    [configured(undefined), 200], [configured(0), 0], [configured(500), 500],
    [configured(-1), 0], [configured(5001), 5000], [configured(1.5), 200],
    [configured("500"), 200], [configured(null), 200], [configured(true), 200],
    [null, 200], [[], 200], [{}, 200], [{ plugins: [] }, 200],
    [{ plugins: [null] }, 200],
    [{ plugins: [{ id: "ericvrp.bar-autohide" }, { id: "ericvrp.bar-autohide" }] }, 200],
  ];
  for (const [config, expected] of cases) {
    expect(delay({ defaultHideDelayMs: 200 }, { text: () => JSON.stringify(config) }, { warn() {} })).toBe(expected);
  }
  expect(delay({ defaultHideDelayMs: 200 }, { text: () => "invalid JSON" }, { warn() {} })).toBe(200);
});

const inBand = new Function("Quickshell", "bar", "position", "px", "py",
  `${method("barThicknessFor", "hideBar")}
   const root = { barThicknessFor };
   return cursorInBarBand(px, py);`);

test("bar hit testing uses each screen's thickness and logical offsets", () => {
  const screens = [
    { name: "left", x: -1080, y: -100, width: 1080, height: 1920 },
    { name: "main", x: 0, y: 0, width: 1600, height: 900 },
  ];
  const bar = { barSize: 30, barSizeFor: (name: string) => name === "left" ? 50 : 30 };
  const check = (edge: string, x: number, y: number) => inBand({ screens }, bar, edge, x, y);
  expect(check("top", -500, -51)).toBe(true);
  expect(check("top", -500, -50)).toBe(false);
  expect(check("top", 100, 29)).toBe(true);
  expect(check("top", 100, 30)).toBe(false);
  expect(check("bottom", 100, 870)).toBe(true);
  expect(check("bottom", 100, 869)).toBe(false);
  expect(check("left", -1031, 100)).toBe(true);
  expect(check("left", -1030, 100)).toBe(false);
  expect(check("right", 1570, 100)).toBe(true);
  expect(check("right", 1569, 100)).toBe(false);
  expect(check("top", 1600, 0)).toBe(false);
  expect(inBand({ screens }, { barSize: 40 }, "top", 100, 39)).toBe(true);
  expect(inBand({ screens }, { barSize: 0, barSizeFor: () => NaN }, "top", 100, 29)).toBe(true);
});

const hasTiledWindow = new Function("workspace", backgroundSource.slice(
  backgroundSource.indexOf("  function hasTiledWindow("),
  backgroundSource.indexOf("  onBarHiddenChanged:")) + "return hasTiledWindow(workspace);");

test("transition cover skips empty, floating-only, hidden, and fullscreen workspaces", () => {
  const workspace = (...states: object[]) => ({ toplevels: { values: states.map(lastIpcObject => ({ lastIpcObject })) } });
  expect(hasTiledWindow(null)).toBe(false);
  expect(hasTiledWindow({})).toBe(false);
  expect(hasTiledWindow(workspace())).toBe(false);
  expect(hasTiledWindow(workspace({ mapped: true, floating: true }))).toBe(false);
  expect(hasTiledWindow(workspace({ floating: false, hidden: true }))).toBe(false);
  expect(hasTiledWindow(workspace({ floating: false, mapped: false }))).toBe(false);
  expect(hasTiledWindow(workspace({ floating: false, fullscreen: 2 }))).toBe(false);
  expect(hasTiledWindow(workspace({}))).toBe(false);
  expect(hasTiledWindow(workspace({ mapped: true, floating: false }))).toBe(true);
  expect(hasTiledWindow(workspace({ floating: true }, { floating: false }))).toBe(true);
});
