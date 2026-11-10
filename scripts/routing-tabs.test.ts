/** The native page must use the existing panel switcher, after Files/Changes. */
import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";

class Element {
  nodes: any[] = [];
  calls: Record<string, any[]> = {};
  constructor() {
    const proxy: Element = new Proxy(this, { get: (target, key: string) => key in target ? (target as any)[key] : (...args: any[]) => {
      if (key === "child") target.nodes.push(args[0]);
      else if (key === "children") target.nodes.push(...args[0]);
      else if (key === "when") { if (args[0]) args[1](proxy); }
      else target.calls[key] = args;
      return proxy;
    } });
    return proxy;
  }
}
const source = (await readFile(new URL("../defaults/mods/tabs/main.js", import.meta.url), "utf8"))
  .replace(/^import .*;\n/gm, "").replace("export default class Tabs", "return class Tabs");
function render(platform = "macos", native: boolean | "legacy" = true, active = "files", hidden = false) {
  const commands: unknown[][] = [], memory = new Map();
  const content = native === "legacy" ? { mod: "magpie-routing" } : { magpie_routing: true };
  const layout = { id: "root", children: [{ id: "panel", hidden, size: { px: 380 }, children: [{ id: "panel-body", active, children: native ? [{ id: "routing", content }] : [] }] }] };
  const element = () => new Element();
  const values = { View: class {}, div: element, svg: element, image: element, h_flex: element,
    spaces: () => [], panes: () => [], run: (...args: unknown[]) => commands.push(args), openOverlay() {}, theme: () => ({}),
    window: () => ({ platform }), shared: () => ["files", "changes"], layout: () => layout, settings: () => ({ zoom: 1 }),
    localStorage: { getItem: (key: string) => memory.get(key) ?? null, setItem: (key: string, value: string) => memory.set(key, value) } };
  const Tabs = new Function(...Object.keys(values), source)(...Object.values(values));
  const tabs = new Tabs(); tabs.init();
  return { tree: tabs.render(), commands, tabs };
}
function buttons(root: Element): Element[] {
  return [root, ...root.nodes.flatMap(child => child instanceof Element ? buttons(child) : [])].filter(node => node.calls.id?.[0]?.startsWith("panel-"));
}

test("Routing follows Files and Changes only in a supported native layout", () => {
  expect(buttons(render().tree).map(b => b.calls.id[0])).toEqual(["panel-files", "panel-changes", "panel-routing"]);
  expect(buttons(render("linux").tree).map(b => b.calls.id[0])).not.toContain("panel-routing");
  expect(buttons(render("macos", false).tree).map(b => b.calls.id[0])).not.toContain("panel-routing");
  expect(buttons(render("macos", "legacy").tree).map(b => b.calls.id[0])).toEqual(["panel-files", "panel-changes", "panel-routing"]);
});
test("Routing opens its existing stack at the page's width and closes on a second click", () => {
  const first = render(); buttons(first.tree).at(-1)!.calls.on_click[0]();
  expect(first.commands).toEqual([["layout.resize", { id: "panel", px: 760 }], ["layout.select", { stack: "panel-body", child: "routing" }], ["layout.show", { id: "panel" }]]);
  const opened = render("macos", true, "routing"); buttons(opened.tree).at(-1)!.calls.on_click[0]();
  expect(opened.commands).toEqual([["layout.hide", { id: "panel" }]]);
});
