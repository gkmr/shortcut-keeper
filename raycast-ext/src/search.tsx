import {
  Action,
  ActionPanel,
  Color,
  Detail,
  Icon,
  List,
  Toast,
  closeMainWindow,
  showHUD,
  showToast,
} from "@raycast/api";
import { execFile } from "child_process";
import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { useState } from "react";

// Shortcut Keeper's folder (keys.json, status.json): SHORTCUT_KEEPER_HOME when Raycast passes it, else the default clone path.
const ROOT = process.env.SHORTCUT_KEEPER_HOME || join(homedir(), "Projects", "shortcut-keeper");

type Key = {
  id: string;
  section: string;
  keys: string;
  action: string;
  app: string;
  note?: string;
  combo?: string;
  sheet?: boolean;
  isNew?: string;
  pending?: string;
  deck?: { url?: string; short?: string; run?: boolean; group?: string };
};
type Hints = { hints?: Record<string, string> };
type Section = { id: string; title: string };
type Data = { sections: Section[]; keys: Key[] };
type Issue = { level: string; id: string; text: string; who: string; fix?: string | null };
type Status = { checked_at?: string; ok?: boolean; summary?: string; issues?: Issue[]; needs_ax?: string[] };

const APP_COLOR: Record<string, Color> = {
  Raycast: Color.Red,
  "Rectangle Pro": Color.Blue,
  Floaty: Color.Yellow,
  "Wispr Flow": Color.Purple,
  BetterWispr: Color.Magenta,
  Gemini: Color.Blue,
  Claude: Color.Orange,
  "Logi Options+": Color.Green,
  TickTick: Color.Blue,
  macOS: Color.SecondaryText,
};

const APP_PATH: Record<string, string> = {
  Raycast: "/Applications/Raycast.app",
  "Rectangle Pro": "/Applications/Rectangle Pro.app",
  Floaty: "/Applications/Floaty.app",
  "Wispr Flow": "/Applications/Wispr Flow.app",
  BetterWispr: "/Applications/BetterWispr.app",
  Gemini: "/Applications/Gemini.app",
  Claude: "/Applications/Claude.app",
  "Logi Options+": "/Applications/logioptionsplus.app",
  TickTick: "/Applications/TickTick.app",
  "1Password": "/Applications/1Password.app",
  AltTab: "/Applications/AltTab.app",
  "Alfred 5": "/Applications/Alfred 5.app",
  "ChatGPT Classic": "/Applications/ChatGPT Classic.app",
  macOS: "/System/Applications/System Settings.app",
};

function appIcon(app: string) {
  const p = APP_PATH[app];
  return p && existsSync(p) ? { fileIcon: p } : Icon.Keyboard;
}

const KEYCODE: Record<string, number> = {
  A: 0, S: 1, D: 2, F: 3, H: 4, G: 5, Z: 6, X: 7, C: 8, V: 9, B: 11, Q: 12, W: 13, E: 14, R: 15, Y: 16, T: 17,
  "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
  "]": 30, O: 31, U: 32, "[": 33, I: 34, P: 35, Return: 36, L: 37, J: 38, "'": 39, K: 40, ";": 41, ",": 43,
  "/": 44, N: 45, M: 46, ".": 47, Tab: 48, Space: 49, "`": 50, Delete: 51, Esc: 53,
  Left: 123, Right: 124, Down: 125, Up: 126,
};

function load<T>(file: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(join(ROOT, file), "utf8")) as T;
  } catch {
    return fallback;
  }
}

function readText(file: string, fallback: string): string {
  const p = join(ROOT, file);
  return existsSync(p) ? readFileSync(p, "utf8") : fallback;
}

function openQuietly(url: string): Promise<void> {
  return new Promise((resolve) => execFile("/usr/bin/open", ["-g", url], () => resolve()));
}

function runnable(k: Key): boolean {
  if (k.deck?.run === false) return false;
  if (k.deck?.url) return true;
  if (!k.combo || k.app === "Raycast" || k.app === "Key Deck") return false;
  if (["mouse", "ring"].includes(k.section)) return false;
  if (/(^|\+)(fn|rctrl|ropt|rcmd|rshift|capslock)(\+|$)/.test(k.combo)) return false;
  if (k.keys.toLowerCase().includes("hold")) return false;
  const key = k.combo.split("+").pop() ?? "";
  return key in KEYCODE;
}

function pressCombo(combo: string): Promise<void> {
  const parts = combo.split("+");
  const key = parts.pop() ?? "";
  const mods = parts.includes("HYPER") ? ["control", "option", "shift", "command"] : [];
  if (parts.includes("ctrl")) mods.push("control");
  if (parts.includes("opt")) mods.push("option");
  if (parts.includes("shift")) mods.push("shift");
  if (parts.includes("cmd")) mods.push("command");
  const using = mods.length ? ` using {${mods.map((m) => `${m} down`).join(", ")}}` : "";
  const script = `delay 0.25\ntell application "System Events" to key code ${KEYCODE[key]}${using}`;
  return new Promise((resolve) => execFile("/usr/bin/osascript", ["-e", script], () => resolve()));
}

// "Search Keys": type words to find a shortcut, Enter runs it. "My Keys" itself (index.tsx) opens Key Deck.
// Row text: the plain action, or Key Deck's short label when the action is long. Maintenance notes stay out of the UI.
function rowTitle(k: Key): string {
  return k.action.length > 60 && k.deck?.short ? k.deck.short : k.action;
}
function rowNote(k: Key): string | undefined {
  return k.note && k.note.length <= 40 && !/\d{4}-\d{2}-\d{2}|GK /.test(k.note) ? k.note : undefined;
}
function when(iso?: string): string {
  if (!iso) return "never checked";
  const d = new Date(iso);
  return `checked ${d.toLocaleDateString(undefined, { month: "short", day: "numeric" })}, ${d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
}

export default function Command() {
  const [data, setData] = useState<Data>(() => load<Data>("keys.json", { sections: [], keys: [] }));
  const [status, setStatus] = useState<Status>(() => load<Status>("status.json", {}));
  const [busy, setBusy] = useState(false);
  const hints = load<Hints>(".state/deck-hints.json", {}).hints ?? {};

  const openDeck = async () => {
    await closeMainWindow();
    await openQuietly("keydeck://deck");
  };
  const report = () => {
    const today = new Date().toISOString().slice(0, 10);
    return readText(`reports/${today}.md`, `# Shortcut check\n\n${status.summary ?? "No report yet."}`);
  };

  async function runCheck() {
    setBusy(true);
    const toast = await showToast({ style: Toast.Style.Animated, title: "Checking every shortcut…" });
    execFile("/usr/bin/python3", [join(ROOT, "keeper.py"), "--quiet"], { timeout: 90000 }, () => {
      setData(load<Data>("keys.json", data));
      const s = load<Status>("status.json", {});
      setStatus(s);
      setBusy(false);
      toast.style = s.ok ? Toast.Style.Success : Toast.Style.Failure;
      toast.title = s.summary ?? "Check finished";
    });
  }

  const common = (
    <ActionPanel.Section>
      <Action title="Show Every Key (Key Deck)" icon={Icon.Keyboard} onAction={openDeck} shortcut={{ modifiers: ["cmd"], key: "d" }} />
      <Action title="Run Shortcut Check Now" icon={Icon.ArrowClockwise} onAction={runCheck} shortcut={{ modifiers: ["cmd"], key: "r" }} />
      <Action.Push title="Open Latest Report" icon={Icon.Heartbeat} target={<Detail markdown={report()} navigationTitle="Shortcut Check" />} shortcut={{ modifiers: ["cmd"], key: "l" }} />
      <Action.Open title="Edit keys.json" icon={Icon.Pencil} target={join(ROOT, "keys.json")} shortcut={{ modifiers: ["cmd"], key: "e" }} />
    </ActionPanel.Section>
  );

  const serious = (status.issues ?? []).filter((i) => ["high", "medium"].includes(i.level));
  const todos = (status.issues ?? []).filter((i) => i.level === "todo");

  return (
    <List isLoading={busy} searchBarPlaceholder="What do you want to do? webcam, pin, dictate, paste, third…">
      <List.Section title="All keys">
        <List.Item
          icon={{ source: Icon.Keyboard, tintColor: Color.Blue }}
          title="Show every key on one screen"
          subtitle="Key Deck, with pictures; press a badge key to run one"
          keywords={["deck", "all", "every", "cheat", "sheet", "overview", "show"]}
          accessories={[{ tag: { value: "Caps /", color: Color.Blue } }]}
          actions={
            <ActionPanel>
              <Action title="Show Every Key (Key Deck)" icon={Icon.Keyboard} onAction={openDeck} />
              {common}
            </ActionPanel>
          }
        />
      </List.Section>
      {data.sections.map((s) => (
        <List.Section key={s.id} title={s.title}>
          {data.keys
            .filter((k) => k.section === s.id && k.sheet !== false)
            .map((k) => {
              const canRun = runnable(k);
              const accessories: List.Item.Accessory[] = [];
              const badge = hints[k.id];
              if (badge) accessories.push({ tag: { value: `Caps / ${badge}`, color: Color.Blue }, tooltip: `Badge key: open Key Deck with Caps /, then press ${badge}` });
              if (k.isNew) accessories.push({ tag: { value: "new", color: Color.Yellow } });
              if (k.pending) accessories.push({ tag: { value: "to set", color: Color.Orange }, tooltip: k.pending });
              accessories.push({ tag: { value: k.keys, color: APP_COLOR[k.app] ?? Color.PrimaryText } });
              if (canRun) accessories.push({ icon: { source: Icon.Play, tintColor: Color.SecondaryText }, tooltip: "Enter runs it" });
              return (
                <List.Item
                  key={k.id}
                  icon={appIcon(k.app)}
                  title={rowTitle(k)}
                  subtitle={rowNote(k)}
                  keywords={[k.app, k.keys, k.combo ?? "", s.title, k.deck?.short ?? "", k.action, badge ? `badge ${badge}` : ""]}
                  accessories={accessories}
                  actions={
                    <ActionPanel>
                      {canRun && (
                        <Action
                          title={k.deck?.url ? "Do It" : `Do It (${k.keys})`}
                          icon={Icon.Play}
                          onAction={async () => {
                            await closeMainWindow();
                            if (k.deck?.url?.startsWith("keydeck://layout")) {
                              await new Promise<void>((r) => execFile("/usr/bin/python3", [join(ROOT, "layout.py"), k.id, "--quiet", "--settle", "9"], () => r()));
                            } else if (k.deck?.url) await openQuietly(k.deck.url);
                            else await pressCombo(k.combo as string);
                            await showHUD(`${k.keys}  ${k.action}`);
                          }}
                        />
                      )}
                      <Action.CopyToClipboard title="Copy the Keys" content={k.keys} />
                      {common}
                    </ActionPanel>
                  }
                />
              );
            })}
        </List.Section>
      ))}
      <List.Section title="Health">
        <List.Item
          icon={status.ok ? { source: Icon.CheckCircle, tintColor: Color.Green } : { source: Icon.Warning, tintColor: Color.Orange }}
          title={status.summary ?? "Not checked yet"}
          subtitle={when(status.checked_at)}
          keywords={["health", "status", "check", "issues"]}
          accessories={
            serious.length
              ? [{ tag: { value: `${serious.length} to fix`, color: Color.Orange } }]
              : todos.length
                ? [{ tag: { value: `${todos.length} to-do`, color: Color.Blue }, tooltip: todos.map((t) => t.text).join("\n") }]
                : [{ tag: { value: "OK", color: Color.Green } }]
          }
          actions={
            <ActionPanel>
              <Action.Push title="Open Latest Report" icon={Icon.Heartbeat} target={<Detail markdown={report()} navigationTitle="Shortcut Check" />} />
              {common}
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}
