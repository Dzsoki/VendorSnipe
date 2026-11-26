# VendorSnipe

A WoW Forever addon that scans the whole Auction House for auctions priced below what a vendor pays, and helps you buy them. Sell them to any vendor and keep the difference.

In game, press **Guide** in the VendorSnipe window or type `/vs guide` to read this guide.

## Download

**[Download the latest version](https://github.com/Dzsoki/VendorSnipe/releases/latest)** and pick `VendorSnipe.zip` under *Assets*.
All versions and their changes are listed on the [Releases page](https://github.com/Dzsoki/VendorSnipe/releases).

To update, download the new zip and replace the old `VendorSnipe` folder in your AddOns folder (your settings are kept).

## Installation

1. Copy the `VendorSnipe` folder into WoW Forever's AddOns folder:
   - Windows: `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\`
   - Mac: `/Applications/World of Warcraft/_forever_/Interface/AddOns/`

   The folder name may differ. In the Battle.net launcher, click the gear next to Play and choose **Show in Explorer** (Windows) or **Show in Finder** (Mac).
2. The files must sit directly in `AddOns\VendorSnipe\`, not in a nested `VendorSnipe\VendorSnipe\` folder.
3. Restart the game or type `/reload`. On the character select screen, open **AddOns** and make sure VendorSnipe is ticked.

## 1. Scanning

- Open the Auction House. The VendorSnipe window appears next to it.
- Press **Full Scan**. It downloads every listing at once, so it can take a few seconds.
- Results are grouped per item and sorted by total profit: quantity, cheapest price each, vendor price each and profit.
- The list **fills in while the scan runs**, best deals on top. You can start buying as soon as the status says **Checking vendor prices**, so there's no need to wait for the end. Big deals go fast, so buy the top ones first.
- The server allows a full scan only about **once every 15 minutes**. The addon tells you how long to wait.
- Your own auctions, bid-only auctions and items vendors won't buy are skipped.
- The scan doesn't say whether a listing's price is for the whole stack or per item. VendorSnipe works this out from the scan data itself (same item in different stack sizes) and remembers it. Until it knows, it only lists deals that are profitable either way. **Cheapest/ea** always shows the price per item; after a live search it shows the exact live price.

### Closing the AH during a scan

- Keep the Auction House open for the few seconds until the status says **Copying auction data**. The server only sends scan data while the AH is open.
- Once copying has started you can close the AH. The vendor price check carries on in the background, and a chat message tells you when it's done. Type `/vs` to see the results anywhere.
- If you close the AH before any data arrived, the scan is lost. Reopen the AH after a minute and the cooldown is cleared, so you can press **Full Scan** again. The server may still refuse until its own 15 minutes are up.
- The last finished scan is saved and survives closing the AH, `/reload` and logging out. The status line shows how old it is. Live prices are re-checked before every purchase anyway.

## 2. Minimum profit

- Type an amount like `50s` or `1g20s` in the **Min profit** box and press Enter.
- Listings that would earn less than this are ignored, both when scanning and when buying.

## 3. The results list

| Action | Effect |
|---|---|
| Click a row | Search that item on the Auction House |
| Tick box or right-click a row | Select the item for buying (the header tick box selects all shown items) |
| Rarity tick boxes | Untick a rarity (Poor ... Legendary) to hide those items. Hidden items are never bought. Remembered between sessions. |
| Type tick boxes | Untick **Stacks** to hide items you can buy many of (stackable goods like cloth, herbs, ore and potions, plus recipes, patterns, plans, formulas and bags) or **Single** to hide items that don't stack (gear, weapons...). Hidden items are never bought. |
| Unique tick box | Untick **Unique** to hide items marked Unique on their tooltip. You can only carry one (or a few), so they're often not worth buying. Unique-Equipped items are not affected. |
| Shift-click a row | Link the item in chat |
| Hover | Item tooltip plus the number of auctions and their total cost |

## 4. Buying

WoW only allows a purchase from a real mouse click or key press, so no addon can buy a whole list by itself. Keep clicking **Buy Selected**. Each click does one step, and the button shows what the next click will do:

- **Search: \<item>** looks up the live listings, cheapest first.
- **Buy 3x Item - 1g 20s** buys one listing.
- Stackable goods (cloth, herbs, ore...) first get a price quote from the server, then show **Confirm 40x Item - 2g 5s**. That takes a second click.
- When an item has no profitable listings left, it is greyed out as **done** and the next item starts.
- **Auto-search** (tick box at the top, on by default): when one item is finished, the next selected item is searched automatically, so almost every click buys something. Untick it, or type `/vs auto`, to search each item with a click. If the game ignores automatic searches, the addon asks for a click instead of skipping the item, and switches auto-search off for the session after two misses.
- **Watch** (top bar): between Full Scans, keeps checking your Buyout deals plus up to 60 **near misses** (items whose cheapest listing was at most 50% above the vendor price at the scan) live, round after round, with a short pause between searches. When something drops below vendor price you hear a sound, get a **New deal** line in chat, and the item is added to the list and ticked. It stops by itself when a Full Scan is possible again (with a sound), or with **Stop watch** / **Buy Selected** / closing the AH. Watch never buys: click **Buy Selected** for that, then **Watch** again.
- In the **Bid deals** tab, Watch checks your bid deals the same way. If a Full Scan is already possible, Watch checks the list just once.
- **Stop** cancels at any time. A summary of money spent, vendor value and profit is printed in chat.

**Tip:** make a macro containing `/click VendorSnipeBuyButton` and bind it to a key. Pressing the key counts as a real key press, so it's faster than clicking.

## Bid deals tab

- Switch with the **Buyout deals** / **Bid deals** buttons at the top. The same Full Scan fills both tabs.
- Bid deals lists single auctions where the **next bid** is below the vendor value: bid-only auctions (no buyout), and auctions whose buyout is too expensive but whose bid is cheap. Columns: Next bid, Buyout (or **bid only**), Time left and Profit. Hover a row to see what % of the buyout the bid is.
- **Time left** tick boxes use the same bands as the Auction House (Short <30m, Medium 30m–2h, Long 2–12h, Very Long 12–48h). It's how long until the auction ends, not how long it takes to sell. Short auctions give others less time to outbid you. Time left is measured at the scan, so check the scan age in the status line.
- Tick rows and click **Bid Selected**. It searches each item live, re-checks the bid price and time left, and places one bid per click (most profitable first). Auto-search works here too.
- **Bids are binding:** the gold is held right away. If nobody outbids you, the item arrives by mail when the auction ends. If you're outbid, your gold comes back by mail.
- Stackable trade goods (cloth, herbs, ore...) are buyout-only on the Auction House, so they never appear here.

## 5. Selling at a vendor

- Open any vendor. A **VendorSnipe: Sell All** button appears to the right of the vendor window. Hover it to see how many items and how much gold.
- Click it: the most valuable items are listed in chat and a confirmation box asks before anything is sold.
- It sells **every bag item with a vendor price**, including gear, potions and trade goods. It never sells:
  - items with no sell price (e.g. ammo bought from a vendor)
  - quest items (quest border in your bag, or items that start a quest). Grey trash that the game files as "Quest" class but has no quest border (e.g. Soft Bushy Tail) **is** sold. `/vs sellquest` also sells quest-border items that have a price.
  - locked items
  - items in an equipment set
  - items on your keep list
- **Sell from:** tick boxes under the button choose which bags are sold from (Backpack, Bag 1–4, Reagent bag). Untick a bag to keep everything in it. Hover a box to see what that bag would sell for. The choice is remembered.
- For one sale from specific bags, type e.g. `/vs sell 0 2` (0 = Backpack, 1–4 = bags, 5 = Reagent bag).
- **Keep list:** type `/vs keep` and shift-click an item to protect it (do it again to remove it). `/vs keep` alone shows the list.
- Only the last 12 sold items can be bought back from the vendor, so check the list before confirming.
- Items that didn't sell (vendor busy) are retried automatically. At the end you see how many stacks really sold, the gold you actually received, and which items are still in your bags.
- Some items need a confirmation from the game before they can be sold: items bought from a vendor that you can still refund, and loot you can still trade to your group. Answer the popup, then click **Sell All** again for the rest.

## Safety checks

- Every listing's live price is re-checked against the vendor price and your min profit just before buying, so prices that changed since the scan are skipped.
- For stackable goods, the server's final quote is checked again before you can confirm. If it's no longer profitable, the purchase is cancelled.
- Your own auctions are skipped.
- Buying stops if you can't afford the next purchase.
- If the server doesn't answer within 8 seconds, your next click skips that step.

## Good to know

- Purchases arrive in your **mailbox**, not your bags. Collect them before going to a vendor.
- Several listings of one item are bought one at a time, most profitable first.
- Searches wait until the Auction House accepts requests. If the server stays quiet for 4 seconds, the search is started again from scratch automatically (up to 3 tries). If there's still no answer, the item is **not** skipped: the button shows **Search again**.
- Clicking the button while it says **Searching…** restarts that search right away, and clicking while it says **Checking price…** asks for the price again. No need for **Stop**.
- If an item isn't found by its ID (e.g. gear with a random bonus like "of the Bear"), it is searched by name, like the AH search box, and every matching variant is checked.

## Own chat tab

- Type `/vs tab` to create a **VendorSnipe** chat tab. All addon messages (scan, buying, selling, errors, debug) then go only there, and no normal chat is shown in it.
- `/vs tab both` sends messages to the tab and the main chat window; `/vs tab off` goes back to the main window.
- If the tab can't be created automatically: right-click a chat tab > **Create New Window**, name it `VendorSnipe`, then type `/vs tab` again.

## Commands

| Command | Effect |
|---|---|
| `/vs` | Show or hide the window (works with the AH closed) |
| `/vs scan` | Start a full scan |
| `/vs buy` | Next buying step (same as the button) |
| `/vs stop` | Stop buying |
| `/vs min 50s` | Set the minimum profit |
| `/vs tab [both\|off]` | Send messages to a VendorSnipe chat tab (`both` = tab + main chat, `off` = main chat only) |
| `/vs watch` | Start/stop Watch (re-check deals and near misses until the next Full Scan) |
| `/vs auto` | Switch auto-search of the next item on/off |
| `/vs sell [bags]` | Sell all sellable items from the ticked bags, or only the listed bag numbers, e.g. `/vs sell 0 2` (vendor must be open, asks first) |
| `/vs why [item]` | Explain why an item in your bags is or isn't sold by Sell All |
| `/vs sellquest` | Let Sell All also sell quest-border items that have a price (toggle) |
| `/vs keep [item]` | Add/remove an item on the never-sell list; `/vs keep` alone shows it |
| `/vs reset` | Reset the addon's scan cooldown timer (the server may still refuse) |
| `/vs guide` | Open the in-game guide |
| `/vs debug` | Toggle a step-by-step debug log in chat |
| `/vs diag` | Print diagnostics (addon version, AH functions available, buy state) |

## Troubleshooting

- **Addon marked out of date:** tick *Load out of date AddOns* on the character select AddOns screen, or update the `## Interface:` number in `VendorSnipe.toc`.
- **Buying does nothing:** every step prints a VendorSnipe line in chat. For more detail, type `/vs debug`. To see Lua errors, type `/console scriptErrors 1`. You can always buy by hand: click the row to search, then use the Auction House's own Buy button.
- **Addon not listed:** check the folder layout described under Installation.
- **Lua error:** copy the error text (or the BugSack output) so it can be fixed.
