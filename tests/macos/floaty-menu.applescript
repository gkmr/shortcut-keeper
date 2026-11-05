-- osascript tests/floaty-menu.applescript "<entry>"
-- Chooses one entry of Floaty's menu bar menu, exactly as named ("TextEdit <em dash> Untitled", or "Unpin/Restore All Windows"),
-- looking in the menu and its "More…" submenu. Choosing a window's entry pins or unpins it, whatever has the focus.
on run argv
	set want to item 1 of argv
	tell application "System Events" to tell process "Floaty"
		set si to menu bar item 1 of menu bar 2
		perform action "AXPress" of si
		delay 0.5
		set m to menu 1 of si
		repeat with mi in menu items of m
			try
				if name of mi is want then
					perform action "AXPress" of mi
					return "chose " & want
				end if
			end try
		end repeat
		try
			set more to menu item "More…" of m
			perform action "AXPress" of more
			delay 0.4
			repeat with mi in menu items of menu 1 of more
				try
					if name of mi is want then
						perform action "AXPress" of mi
						return "chose " & want
					end if
				end try
			end repeat
		end try
		key code 53
		delay 0.1
		key code 53
	end tell
	return "not found: " & want
end run
