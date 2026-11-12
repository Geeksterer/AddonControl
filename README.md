# AddonControl

**AddonControl** is an in-game addon manager that lets you enable or disable addons, lock essential addons across all characters, switch between saved addon profiles, monitor memory usage, and export clean addon lists without logging out to the character selection screen[cite: 1].

---

## Downloading & Installing

1. **Download via the Code Button:** At the top of the GitHub page, click the green **`<> Code`** button and select **Download ZIP** from the dropdown menu.
2. **Download via Releases (Alternative):** Look for the **Releases** section on the right side of the GitHub page, click on the latest release, and download the attached `.zip` file.
3. **Install to Your AddOns Folder:** Extract the downloaded `.zip` file into your World of Warcraft `Interface\AddOns` directory and make sure the folder is named **`AddonControl`** (remove any `-main` or `-master` suffix if GitHub added one)[cite: 1].

---

## Opening AddonControl

Once you log into the game, you can open the manager at any time using either the minimap button or chat commands[cite: 1]:

* **Minimap Button:** Left-click the gear icon on your minimap to open or close the main AddonControl window[cite: 1]. Right-click the icon to jump straight to the Addon Report tool, or left-click and drag the icon to move it around the edge of your minimap[cite: 1].
* **Chat Commands:** Type **`/ac`** or **`/addoncontrol`** in your chat box[cite: 1]. If another addon is already using `/ac`, AddonControl automatically avoids conflicts and uses `/addoncontrol` instead[cite: 1].

---

## Managing Your Addons

The main window gives you full control over which addons are active and how much memory they are using[cite: 1]:

* **Enable & Disable Addons:** Check or uncheck the box next to any addon to turn it on or off[cite: 1]. When you enable an addon, AddonControl automatically enables any required parent dependencies for you[cite: 1]. You can also use the **Enable All** and **Disable All** buttons at the bottom of the window to toggle your list in bulk[cite: 1].
* **Always-Load Lock (Padlock Icon):** Click the padlock icon on the far left of any addon row to lock it as **Always Load** (the lock will turn solid gold)[cite: 1]. Locked addons are protected across every profile and will automatically stay enabled on all of your characters[cite: 1]. AddonControl keeps itself permanently locked so you can never accidentally disable it and lock yourself out[cite: 1].
* **Sorting & Memory Tracking:** Your total addon memory usage is displayed in the top-right corner, while individual memory usage and load statuses (`Load on Demand`, `Missing Dependency`, `Disabled`, `Will Load on Reload`, or `Will Unload`) appear on the right side of each row[cite: 1]. Click the **Addon Name** column header to sort alphabetically (`A-Z` or `Z-A`), or click the **Memory / Status** header to sort by memory size (`High-Low` or `Low-High`)[cite: 1].
* **Addon Details:** Hover your mouse over any addon row to view a tooltip containing its folder name, author, version, description notes, and required dependencies[cite: 1].
* **Applying Changes:** Whenever you make changes that require a reload, the **Reload UI** button in the bottom-right corner highlights in green (`Reload UI *`)[cite: 1]. Click it whenever you are ready to apply your changes[cite: 1].

---

## Profiles & Addon Reports

### Addon Profiles

Profiles let you save and switch between different addon setups for different characters or activities[cite: 1]. If you check or uncheck addons after loading a profile, an orange **`(Modified)`** tag will appear next to the profile name to let you know you have unsaved changes[cite: 1].

* **Creating a Profile:** Set your checkboxes the way you want them, click **New Profile**, type a name, and click **Save**[cite: 1].
* **Managing Existing Profiles:** Select a profile from the **Profile** dropdown menu or click **Profile Actions...** to open the Profile Options panel[cite: 1]. From there, you can **Load Profile**, **Save Current Addons to Profile** (overwriting it with your current checkboxes), **Set as Default Profile**, or **Delete Profile**[cite: 1]. Every action includes a confirmation popup so you never overwrite or delete a profile by mistake[cite: 1].
* **Account-Wide Default Profile:** Click the **Star icon** next to the profile dropdown (or use the Profile Options panel) to set your account-wide fallback profile[cite: 1]. Whenever you log into a new or unassigned character, AddonControl will automatically assign this default profile and ask if you want to reload your UI to apply it[cite: 1].

### Exporting an Addon Report

Click the **Report...** button at the bottom of the main window (or right-click the minimap button) to generate a shareable list of your currently loaded addons, active profile, lock statuses, and memory usage[cite: 1].

| Format | Description |
| :--- | :--- |
| **Default Text** | Generates a clean, plain-text summary table[cite: 1]. |
| **Discord** | Wraps your addon list and memory stats in Markdown formatting and code blocks so it looks clean when pasted into Discord[cite: 1]. |
| **Tab-Delimited** | Formats the data with tabs and splits memory numbers from their `KB`/`MB` units so you can paste the list directly into Excel or Google Sheets for sorting[cite: 1]. |

When you open the report or switch formats, the text is automatically highlighted—just press **`Ctrl+C`** to copy it to your clipboard[cite: 1].
