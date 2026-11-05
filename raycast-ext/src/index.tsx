import { closeMainWindow } from "@raycast/api";
import { execFile } from "child_process";

// "My Keys" (⌘Space, keys, Enter) opens Key Deck straight away: every key on one screen with pictures and badge keys
// (one step, no list in between). Searching by words is the "Search Keys" command (search.tsx).
export default async function Command() {
  await closeMainWindow();
  await new Promise<void>((resolve) => execFile("/usr/bin/open", ["-g", "keydeck://deck"], () => resolve()));
}
