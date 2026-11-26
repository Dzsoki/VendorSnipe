-- VendorSnipe: find Auction House listings that sell for less than the vendor pays, and buy them.
-- Built for WoW Forever (modern C_AuctionHouse API, Midnight-era client).
--
-- Buying note: Blizzard requires a hardware event (mouse click / key press) for every purchase,
-- so buying is driven by repeatedly clicking the Buy button (or a key bound to
-- "/click VendorSnipeBuyButton"). Each click performs exactly one step.

local ADDON, ns = ...
local VS = CreateFrame("Frame")
local SCAN_COOLDOWN = 15 * 60   -- ReplicateItems is server-throttled to roughly once per 15 min
local MAX_ROWS = 300
local STEP_TIMEOUT = 8          -- seconds before a stuck step can be skipped with another click

local results, byItem = {}, {}
local bidResults = {}      -- one entry per auction where bidding is profitable (Bid deals tab)
local scanning, pending, scanTotal, scanIndex = false, 0, 0, 0
local ui

local GetItemInfoFn = (C_Item and C_Item.GetItemInfo) or GetItemInfo

---------------------------------------------------------------------------
-- Chat output: main chat window, a dedicated "VendorSnipe" chat tab, or both.
-- VendorSnipeDB.chatMode: nil = auto (tab if it exists, else main), "tab", "both", "main".
---------------------------------------------------------------------------
local TAB_NAME = "VendorSnipe"

local function FindTab()
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local name, _, _, _, _, _, shown, _, docked
    if GetChatWindowInfo then name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i) end
    -- ignore a closed tab, so messages fall back to the main window instead of vanishing
    if name == TAB_NAME and (shown or docked) then
      local cf = _G["ChatFrame" .. i]
      if cf then return cf end
    end
  end
end

local function Out(text)
  local mode = VendorSnipeDB and VendorSnipeDB.chatMode
  local tab = mode ~= "main" and FindTab() or nil
  if tab then tab:AddMessage(text) end
  if not tab or mode == "both" then DEFAULT_CHAT_FRAME:AddMessage(text) end
end

-- Create the tab (or reuse one the user made) and strip all normal chat from it.
local function CreateTab()
  local cf = FindTab()
  if not cf and FCF_OpenNewWindow then
    local ok, frame = pcall(FCF_OpenNewWindow, TAB_NAME)
    cf = (ok and type(frame) == "table" and frame) or FindTab()
  end
  if cf then
    local rmGroups = ChatFrame_RemoveAllMessageGroups or (ChatFrameUtil and ChatFrameUtil.RemoveAllMessageGroups)
    local rmChannels = ChatFrame_RemoveAllChannels or (ChatFrameUtil and ChatFrameUtil.RemoveAllChannels)
    if rmGroups then pcall(rmGroups, cf) end
    if rmChannels then pcall(rmChannels, cf) end
  end
  return cf
end

local function Print(msg)
  Out("|cff8fa8ffVendorSnipe|r: " .. msg)
  -- Mirror the latest message inside the window so it's visible even if chat is busy or filtered.
  if ui and ui.status then ui.status:SetText(msg) end
end

-- Debug log, toggled with /vs debug. Prints every buying step so problems can be pinpointed.
local function D(...)
  if VendorSnipeDB and VendorSnipeDB.debug then
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    Out("|cff888888[VS debug]|r " .. table.concat(parts, " "))
  end
end

local function Money(c)
  c = math.floor(c or 0)
  if GetMoneyString then return GetMoneyString(c, true) end
  return string.format("%dg %ds %dc", c / 10000, (c / 100) % 100, c % 100)
end

-- Plain-text money for button labels (no coin icons).
local function ShortMoney(c)
  c = math.floor(c or 0)
  local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  if g > 0 then return string.format("%dg %ds", g, s) end
  if s > 0 then return string.format("%ds %dc", s, cc) end
  return cc .. "c"
end

local function ParseMoney(s)
  if not s or s == "" then return nil end
  if tonumber(s) then return tonumber(s) end
  local total, found = 0, false
  for n, unit in s:lower():gmatch("(%d+)%s*([gsc])") do
    found = true
    n = tonumber(n)
    total = total + (unit == "g" and n * 10000 or unit == "s" and n * 100 or n)
  end
  return found and total or nil
end

local function GetSellPrice(item)
  local name, link, quality, ilvl, _, _, _, stack, _, icon, sellPrice = GetItemInfoFn(item)
  return sellPrice, name, link, quality, icon, ilvl, stack
end

local function MinProfit() return VendorSnipeDB.minProfit or 1 end

-- shared with VendorSnipe_Sell.lua
ns.Print, ns.Money, ns.GetItemInfo, ns.Debug = Print, Money, GetItemInfoFn, D

-- Unique detection: the tooltip says "Unique" or "Unique (N)" (limits how many you can carry).
-- "Unique-Equipped" only limits how many you can wear, so it doesn't count.
local uniquePatterns
local scanTip
local function TooltipLines(itemID)
  if C_TooltipInfo and C_TooltipInfo.GetItemByID then
    local data = C_TooltipInfo.GetItemByID(itemID)
    if not data or not data.lines then return nil end
    local out = {}
    for i, line in ipairs(data.lines) do out[i] = line.leftText end
    return out
  end
  if not scanTip then
    scanTip = CreateFrame("GameTooltip", "VendorSnipeScanTip", nil, "GameTooltipTemplate")
  end
  scanTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
  scanTip:ClearLines()
  scanTip:SetItemByID(itemID)
  local out = {}
  for i = 1, scanTip:NumLines() do
    local fs = _G["VendorSnipeScanTipTextLeft" .. i]
    out[i] = fs and fs:GetText()
  end
  scanTip:Hide()
  return #out > 0 and out or nil
end

local function IsUnique(itemID)
  if not uniquePatterns then
    local function pat(fmt)
      fmt = fmt:gsub("([%(%)%.%-%+%*%?%[%]%^%$])", "%%%1")
      return "^" .. fmt:gsub("%%d", "%%d+") .. "$"
    end
    uniquePatterns = { pat(ITEM_UNIQUE or "Unique"), pat(ITEM_UNIQUE_MULTIPLE or "Unique (%d)") }
  end
  local ok, lines = pcall(TooltipLines, itemID)
  if not ok or not lines then return nil end   -- unknown yet, try again later
  for _, text in ipairs(lines) do
    if type(text) == "string" then
      for _, p in ipairs(uniquePatterns) do
        if text:match(p) then return true end
      end
    end
  end
  return false
end

-- "Bulk" items for the Stacks/Single filter: anything that stacks, plus recipes (patterns, plans,
-- schematics, formulas, manuals...) and bags. Those don't stack, but you can buy many of them.
local CLASS_RECIPE = (Enum and Enum.ItemClass and Enum.ItemClass.Recipe) or 9
local CLASS_CONTAINER = (Enum and Enum.ItemClass and Enum.ItemClass.Container) or 1
local GetInstantFn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local function IsBulk(r)
  if r.bulk ~= nil then return r.bulk end
  local classID = GetInstantFn and select(6, GetInstantFn(r.itemID))
  if classID == CLASS_RECIPE or classID == CLASS_CONTAINER then r.bulk = true return true end
  if r.stack == nil then return nil end        -- stack size not loaded yet: don't decide (and don't cache)
  r.bulk = r.stack > 1
  return r.bulk
end

-- Filters: VendorSnipeDB.hideQuality[q] = true hides quality q (0 Poor ... 5 Legendary);
-- hideStack / hideSingle hide stackable items (cloth, herbs...) / single items (gear, weapons...);
-- hideUnique hides "Unique" items (you can only carry a limited number).
local function ItemShown(r)
  local q = r.quality
  if q ~= nil and VendorSnipeDB.hideQuality and VendorSnipeDB.hideQuality[q] then return false end
  if r.unique and VendorSnipeDB.hideUnique then return false end
  local bulk = IsBulk(r)
  if bulk ~= nil then
    if bulk and VendorSnipeDB.hideStack then return false end
    if not bulk and VendorSnipeDB.hideSingle then return false end
  end
  return true
end

-- Time left bands (Enum.AuctionHouseTimeLeftBand): 0 Short <30m, 1 Medium 30m-2h, 2 Long 2-12h, 3 VeryLong 12-48h.
-- Labels use the game's own words (as shown in the Auction House), with our fallback if missing.
local TIME_LABELS = {
  [0] = AUCTION_TIME_LEFT1 or "Short", [1] = AUCTION_TIME_LEFT2 or "Medium",
  [2] = AUCTION_TIME_LEFT3 or "Long",  [3] = AUCTION_TIME_LEFT4 or "Very Long",
}
local TIME_DETAILS = {
  [0] = AUCTION_TIME_LEFT1_DETAIL or "Less than 30 minutes", [1] = AUCTION_TIME_LEFT2_DETAIL or "30 minutes - 2 hours",
  [2] = AUCTION_TIME_LEFT3_DETAIL or "2 - 12 hours",         [3] = AUCTION_TIME_LEFT4_DETAIL or "12 - 48 hours",
}
local function TimeShown(band)
  if band == nil then return true end
  return not (VendorSnipeDB.hideTime and VendorSnipeDB.hideTime[band])
end

local function BidShown(r)
  return ItemShown(r) and TimeShown(r.timeLeft)
end

local uniqueCache = {}   -- itemID -> true/false
local function UniqueFor(itemID)
  local u = uniqueCache[itemID]
  if u == nil then
    u = IsUnique(itemID)
    if u ~= nil then uniqueCache[itemID] = u end
  end
  return u
end

---------------------------------------------------------------------------
-- Scan & result aggregation
---------------------------------------------------------------------------

-- Per-scan caches: vendor info is looked up once per itemID instead of once per auction.
local infoCache = {}     -- itemID -> { sellPrice, name, link, quality, icon, ilvl, stack } or false (no vendor price)
local waiting = {}       -- itemID -> list of snapshot indexes waiting for item data to load
local playerName

local function GetInfo(itemID)
  local c = infoCache[itemID]
  if c ~= nil then return c end
  local sellPrice, name, link, quality, icon, ilvl, stack = GetSellPrice(itemID)
  if sellPrice == nil and name == nil then return nil end    -- not loaded yet
  c = (sellPrice and sellPrice > 0) and { sellPrice, name, link, quality, icon, ilvl, stack } or false
  infoCache[itemID] = c
  return c
end

---------------------------------------------------------------------------
-- What does the scan's price mean: the whole stack ("total") or one item ("unit")?
-- Detected from the data: for an item listed in different stack sizes, the right reading is the one
-- where the per-item price stays about the same across stacks. VendorSnipeDB.priceMode remembers it.
---------------------------------------------------------------------------
local priceStats = {}   -- itemID -> { n, sx, sxx, sy, syy, cmin, cmax } with x = log(price), y = log(price / count)

local function PriceMode() return VendorSnipeDB.priceMode end   -- "total", "unit" or nil (unknown)

local function TrackPrice(itemID, count, buyout)
  if not buyout or buyout <= 0 or not count or count <= 0 then return end
  local st = priceStats[itemID]
  if not st then st = { n = 0, sx = 0, sxx = 0, sy = 0, syy = 0, cmin = count, cmax = count } priceStats[itemID] = st end
  local x, y = math.log(buyout), math.log(buyout / count)
  st.n, st.sx, st.sxx, st.sy, st.syy = st.n + 1, st.sx + x, st.sxx + x * x, st.sy + y, st.syy + y * y
  if count < st.cmin then st.cmin = count end
  if count > st.cmax then st.cmax = count end
end

-- Decide from this scan; returns votes for logging.
local function DetectPriceMode()
  local vTotal, vUnit = 0, 0
  for _, st in pairs(priceStats) do
    if st.n >= 3 and st.cmax >= st.cmin * 2 then
      local vx = st.sxx / st.n - (st.sx / st.n) ^ 2
      local vy = st.syy / st.n - (st.sy / st.n) ^ 2
      if vy < vx * 0.5 then vTotal = vTotal + 1 elseif vx < vy * 0.5 then vUnit = vUnit + 1 end
    end
  end
  wipe(priceStats)
  local mode
  if vTotal + vUnit >= 5 then
    if vTotal >= vUnit * 2 then mode = "total" elseif vUnit >= vTotal * 2 then mode = "unit" end
  end
  if mode then VendorSnipeDB.priceMode = mode end
  return mode, vTotal, vUnit
end

-- Profit of buying `count` items for `price`, using the detected reading (or the safe minimum if unknown).
local function ScanProfit(value, price, count)
  local mode = PriceMode()
  if mode == "total" then return value - price end
  if mode == "unit" then return value - price * count end
  return math.min(value - price, value - price * count)
end

-- Cheapest price per item shown in the list (before a live search replaces it with exact numbers).
local function ScanUnitPrice(r)
  if PriceMode() == "unit" then return r.minRaw or r.bestUnit end
  return r.minPerItem or r.bestUnit       -- "total" (and the most likely reading when still unknown)
end

local function Consider(itemID, count, buyout, owner, info)
  if not itemID or not buyout or buyout <= 0 or not count or count <= 0 then return end
  if owner and owner == playerName then return end
  info = info or GetInfo(itemID)
  if not info then return end
  local sellPrice = info[1]

  -- The scan's price is either the whole stack's price or the per-item price. Use the reading detected
  -- from earlier scans; while unknown, only list auctions profitable under BOTH readings.
  local value = sellPrice * count
  local profit = ScanProfit(value, buyout, count)
  if profit < MinProfit() then return end

  local r = byItem[itemID]
  if not r then
    r = { itemID = itemID, name = info[2], link = info[3], quality = info[4], icon = info[5], ilvl = info[6],
          stack = info[7], vendor = sellPrice, qty = 0, cost = 0, profit = 0, auctions = 0, bestUnit = math.huge,
          selected = false, done = false }
    byItem[itemID] = r
    results[#results + 1] = r
  end
  r.qty = r.qty + count
  r.cost = r.cost + buyout
  r.profit = r.profit + profit
  r.auctions = r.auctions + 1
  r.minRaw = math.min(r.minRaw or math.huge, buyout)                    -- if the price is per item
  r.minPerItem = math.min(r.minPerItem or math.huge, buyout / count)    -- if the price is per stack
  r.bestUnit = ScanUnitPrice(r)
end

local prevBidKeys = {}            -- bid deals of the previous scan, to spot unchanged ones

local function BidKey(itemID, count, bid, buyout)
  return itemID .. ":" .. count .. ":" .. bid .. ":" .. (buyout or 0)
end

-- Bid deal: the next bid is below the vendor value (bid-only auctions, or buyout too high but bid cheap).
local function ConsiderBid(itemID, count, buyout, owner, minBid, minInc, bidAmount, highBidder, timeLeft, info)
  if not itemID or not count or count <= 0 then return end
  if highBidder then return end                         -- we're already the highest bidder
  if owner and owner == playerName then return end
  info = info or GetInfo(itemID)
  if not info then return end
  local nextBid = (bidAmount and bidAmount > 0) and (bidAmount + (minInc or 0)) or minBid
  if not nextBid or nextBid <= 0 then return end
  if buyout and buyout > 0 and nextBid >= buyout then return end   -- just buy it out instead
  local sellPrice = info[1]
  local value = sellPrice * count
  local profit = ScanProfit(value, nextBid, count)   -- same reading as buyouts
  if profit < MinProfit() then return end
  local key = BidKey(itemID, count, nextBid, buyout)
  bidResults[#bidResults + 1] = {
    itemID = itemID, name = info[2], link = info[3], quality = info[4], icon = info[5], ilvl = info[6], stack = info[7],
    vendor = sellPrice, qty = count, bid = nextBid, buyout = buyout or 0, timeLeft = timeLeft,
    value = value, profit = profit, isBid = true, selected = false, done = false,
    unchanged = prevBidKeys[key] and true or nil,
  }
end

-- Scan phases:
--   "waiting"    ReplicateItems() sent, waiting for the server (needs the AH open)
--   "copying"    copying the raw auction list into our own tables, fast, so closing the AH can't lose it
--   "processing" evaluating vendor prices from our copy; runs fine with the AH closed.
--                Results appear in the list progressively and can already be bought.
local FRAME_BUDGET = 12         -- ms of work per frame (keeps the game smooth at ~60 fps)
local COPY_BATCH = 2000         -- rows copied between budget checks
local REFRESH_EVERY = 0.5       -- seconds between list refreshes while scanning
local WAIT_STALE = 60           -- seconds after which an unanswered scan request counts as lost
local phase, scanStarted, copyIndex = nil, 0, 0
local snapID, snapCount, snapBuyout, snapOwner, snapN = {}, {}, {}, {}, 0
local snapMinBid, snapInc, snapBid, snapHigh, snapTime = {}, {}, {}, {}, {}
local function WipeSnap()
  wipe(snapID); wipe(snapCount); wipe(snapBuyout); wipe(snapOwner)
  wipe(snapMinBid); wipe(snapInc); wipe(snapBid); wipe(snapHigh); wipe(snapTime)
end

-- Evaluate snapshot row i for both tabs.
local WATCH_MARGIN = 1.5        -- near miss: cheapest listing at most 50% above the vendor price
local WATCH_MAX = 60            -- near misses remembered per scan
local cheapest = {}             -- itemID -> { unit = cheapest per-item price, info = item info }

local function Evaluate(i, info)
  local itemID, count, buyout, owner = snapID[i], snapCount[i], snapBuyout[i], snapOwner[i]
  if not itemID then return end
  TrackPrice(itemID, count, buyout)
  if info and buyout and buyout > 0 and count > 0 then
    local unit = (PriceMode() == "unit") and buyout or (buyout / count)
    local c = cheapest[itemID]
    if not c or unit < c.unit then cheapest[itemID] = { unit = unit, info = info } end
  end
  if buyout and buyout > 0 then Consider(itemID, count, buyout, owner, info) end
  ConsiderBid(itemID, count, buyout, owner, snapMinBid[i], snapInc[i], snapBid[i], snapHigh[i], snapTime[i], info)
end
local partialCopy = false
local lastRefresh, scanT0 = 0, 0
local fpBuyout, fpBid = 0, 0      -- fingerprint of the raw scan data, to spot identical snapshots

local now = debugprofilestop or function() return GetTime() * 1000 end

local function SetStatus(fmt, ...)
  if ui then ui.status:SetFormattedText(fmt, ...) end
end

local function SortResults()
  table.sort(results, function(a, b) return a.profit > b.profit end)
  table.sort(bidResults, function(a, b) return a.profit > b.profit end)
end

-- Throttled live refresh so deals show up while the scan is still running.
local function LiveRefresh(force)
  if not ui or not ui:IsShown() then return end
  local t = GetTime()
  if not force and t - lastRefresh < REFRESH_EVERY then return end
  lastRefresh = t
  SortResults()
  ui:Refresh()
end

local function Finish()
  if phase ~= "processing" or pending > 0 or scanIndex <= snapN then return end
  phase, scanning = nil, false
  WipeSnap()
  wipe(infoCache); wipe(waiting)
  -- near misses for Watch: cheapest listing just above the vendor price
  local near = {}
  for itemID, c in pairs(cheapest) do
    local vendor = c.info[1]
    if not byItem[itemID] and vendor and vendor > 0 and c.unit > vendor and c.unit <= vendor * WATCH_MARGIN then
      near[#near + 1] = { itemID = itemID, name = c.info[2], link = c.info[3], quality = c.info[4], icon = c.info[5],
                          ilvl = c.info[6], stack = c.info[7], vendor = vendor, ratio = c.unit / vendor,
                          qty = 0, cost = 0, profit = 0, auctions = 0, bestUnit = c.unit, nearMiss = true }
    end
  end
  table.sort(near, function(a, b) return a.ratio < b.ratio end)
  for i = #near, WATCH_MAX + 1, -1 do near[i] = nil end
  VendorSnipeDB.watchItems = near
  wipe(cheapest)
  local before = PriceMode()
  local mode, vT, vU = DetectPriceMode()
  D("price reading votes: per stack", vT, "per item", vU, "->", tostring(mode))
  for _, r in ipairs(results) do if not r.live then r.bestUnit = ScanUnitPrice(r) end end
  if mode and mode ~= before then
    Print("Detected from the scan data: auction prices are " .. (mode == "total" and "for the whole stack" or "per item")
      .. ". Cheapest/ea and profits use that from now on" .. (before == nil and "; the next Full Scan will also find deals the safe check had to leave out." or "."))
  end
  SortResults()
  VendorSnipeDB.results, VendorSnipeDB.bidResults, VendorSnipeDB.resultsTime = results, bidResults, time()
  local sum = 0
  for _, r in ipairs(results) do sum = sum + r.profit end
  Print(string.format("Scan finished in %.1fs: %d auctions%s. %d items below vendor price (potential profit %s), %d bid deals.",
    (GetTime() - scanT0), snapN, partialCopy and string.format(" (partial, of %d)", scanTotal) or "", #results, Money(sum), #bidResults))
  if next(prevBidKeys) and #bidResults > 0 then
    local same = 0
    for _, b in ipairs(bidResults) do if b.unchanged then same = same + 1 end end
    Print(string.format("%d of %d bid deals are identical to the previous scan (same item, amount, bid and buyout: nobody has bid on them since). %d are new or changed.",
      same, #bidResults, #bidResults - same))
  end
  if ui then
    ui:Refresh()
    if not ui:IsShown() then Print("Type /vs to see the results.") end
  end
end

local function OnItemLoaded(itemID)
  local list = waiting[itemID]
  waiting[itemID] = nil
  if list then
    local info = GetInfo(itemID)
    if info then
      for _, i in ipairs(list) do Evaluate(i, info) end
    else
      infoCache[itemID] = false
    end
  end
  pending = pending - 1
  LiveRefresh()
  Finish()
end

local function ProcessChunk()
  if phase ~= "processing" then return end
  local t0 = now()
  local i = scanIndex
  while i <= snapN do
    local itemID = snapID[i]
    local info = infoCache[itemID]
    if info == nil then info = GetInfo(itemID) end
    if info then
      Evaluate(i, info)
    elseif info == nil then
      -- Item data not cached yet: queue the auction and load the item once.
      local list = waiting[itemID]
      if not list then
        list = {}
        waiting[itemID] = list
        pending = pending + 1
        Item:CreateFromItemID(itemID):ContinueOnItemLoad(function() OnItemLoaded(itemID) end)
      end
      list[#list + 1] = i
    end
    i = i + 1
    if i % 500 == 0 and now() - t0 > FRAME_BUDGET then break end
  end
  scanIndex = i
  SetStatus("Checking vendor prices %d / %d - %d deals, %d bid deals so far (you can already buy)", math.min(scanIndex - 1, snapN), snapN, #results, #bidResults)
  LiveRefresh()
  if scanIndex <= snapN then
    C_Timer.After(0, ProcessChunk)
  else
    if pending > 0 then
      SetStatus("Loading details for %d items - %d deals so far (you can already buy)", pending, #results)
      -- Safety net: if the game never delivers some item's data, don't hang forever.
      C_Timer.After(10, function()
        if phase == "processing" and scanIndex > snapN and pending > 0 then
          D("giving up on", pending, "items that never loaded")
          pending = 0
          Finish()
        end
      end)
    end
    Finish()
  end
end

local function CopyChunk()
  if phase ~= "copying" then return end
  local t0 = now()
  local lost = false
  repeat
    local last = math.min(copyIndex + COPY_BATCH, scanTotal)
    local getTime = C_AuctionHouse.GetReplicateItemTimeLeft
    local ok = pcall(function()
      local misses = 0
      for i = copyIndex, last - 1 do
        local _, _, count, _, _, _, _, minBid, minInc, buyout, bidAmount, highBidder, _, owner, _, _, itemID =
          C_AuctionHouse.GetReplicateItemInfo(i)
        if itemID == nil and count == nil then
          misses = misses + 1
          if misses >= 50 then lost = true return end   -- client dropped the data (AH closed)
        else
          misses = 0
          if itemID and count and count > 0 and ((buyout and buyout > 0) or (minBid and minBid > 0)) then
            snapN = snapN + 1
            snapID[snapN], snapCount[snapN], snapBuyout[snapN], snapOwner[snapN] = itemID, count, buyout or 0, owner
            snapMinBid[snapN], snapInc[snapN], snapBid[snapN], snapHigh[snapN] = minBid, minInc, bidAmount, highBidder
            fpBuyout = (fpBuyout + (buyout or 0)) % 4503599627370496
            fpBid = (fpBid + ((bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)) + itemID) % 4503599627370496
            if getTime then
              local okT, tl = pcall(getTime, i)
              snapTime[snapN] = okT and tl or nil
            end
          end
        end
        copyIndex = i + 1
      end
    end)
    if not ok then lost = true end
  until lost or copyIndex >= scanTotal or now() - t0 > FRAME_BUDGET
  SetStatus("Copying auction data %d / %d", copyIndex, scanTotal)
  if lost then
    partialCopy = true
    Print(string.format("Auction data was dropped by the game after %d of %d auctions (AH closed too early). Checking what was captured.",
      copyIndex, scanTotal))
  elseif copyIndex < scanTotal then
    C_Timer.After(0, CopyChunk)
    return
  end
  D("copied", snapN, "auctions of", scanTotal)
  if not partialCopy then
    local fp = scanTotal .. "/" .. snapN .. "/" .. fpBuyout .. "/" .. fpBid
    local last = VendorSnipeDB.lastFingerprint
    if last and last.fp == fp then
      Print(string.format("Note: the server sent exactly the same auction data as your scan %d min ago (same %d auctions, same prices and bids). It is serving an old snapshot; results won't change until the server refreshes it.",
        math.floor((time() - (last.t or time())) / 60), scanTotal))
    else
      D("new snapshot fingerprint", fp)
    end
    VendorSnipeDB.lastFingerprint = { fp = fp, t = time() }
  end
  playerName = UnitName("player")
  phase, scanIndex = "processing", 1
  ProcessChunk()
end

local ResetBuy -- forward declaration
local StartWatchPass, StopWatch -- forward declarations (Watch mode, defined further below)

local function StartScan()
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
    Print("Open the Auction House first.")
    return
  end
  if scanning then
    if phase == "waiting" and time() - scanStarted > WAIT_STALE then
      D("previous scan request never answered, starting over")
    else
      Print("Scan already running.")
      return
    end
  end
  local since = time() - (VendorSnipeDB.lastScan or 0)
  if since < SCAN_COOLDOWN then
    Print(string.format("Full scan is throttled by the server. Try again in %d min %d s.",
      (SCAN_COOLDOWN - since) / 60, (SCAN_COOLDOWN - since) % 60))
    return
  end
  ResetBuy(true)
  wipe(prevBidKeys)
  for _, b in ipairs(bidResults) do prevBidKeys[BidKey(b.itemID, b.qty, b.bid, b.buyout)] = true end
  fpBuyout, fpBid = 0, 0
  wipe(priceStats); wipe(cheapest)
  wipe(results); wipe(byItem); wipe(bidResults)
  WipeSnap()
  scanning, phase, pending, scanIndex, scanTotal, copyIndex, snapN = true, "waiting", 0, 1, 0, 0, 0
  partialCopy = false
  scanStarted, scanT0, lastRefresh = time(), GetTime(), 0
  wipe(infoCache); wipe(waiting)
  VendorSnipeDB.lastScan = time()
  VS:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  C_AuctionHouse.ReplicateItems()
  if ui then ui:Refresh() SetStatus("Waiting for server data... keep the AH open until copying starts.") end
  Print("Full scan requested. Keep the Auction House open for a few seconds until copying starts; after that you can close it.")
end

---------------------------------------------------------------------------
-- Buying (click-driven state machine)
--   idle    -> click: build queue from ticked rows, search first item
--   next    -> click: search current item
--   searching (waiting for search results)
--   ready   -> click: buy the cheapest profitable listing (item) / start commodity purchase
--   pricing (waiting for server's commodity price quote)
--   confirm -> click: confirm commodity purchase
--   buying  (waiting for purchase result)
---------------------------------------------------------------------------

local Buy = { queue = {}, state = "idle", offers = nil, item = nil, key = nil, mode = "buyout",
              keys = nil, keyIdx = 0, token = nil, money = nil,
              t = 0, spent = 0, value = 0, count = 0 }

local function ItemName(r)
  return r.name or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.itemID)) or ("item:" .. r.itemID)
end

local function SetButton(text)
  if ui and ui.buy then ui.buy:SetText(text) end
end

local function IdleLabel()
  return (ui and ui.tab == "bid") and "Bid Selected" or "Buy Selected"
end

local function SetState(state, label)
  Buy.state, Buy.t = state, GetTime()
  if label then SetButton(label) end
  if ui then ui.stop:SetShown(state ~= "idle") end
end

local function Summary()
  local balance = Buy.sessionMoney and (Buy.sessionMoney - GetMoney()) or nil
  if Buy.count > 0 then
    if Buy.mode == "bid" then
      Print(string.format("Placed %d bids on %d items, %s held (vendor value %s). Won items arrive by mail when the auctions end; if you're outbid, your gold comes back by mail.",
        Buy.count, Buy.items or 0, Money(Buy.spent), Money(Buy.value)))
    else
      Print(string.format("Bought %d items in %d purchases, paid %s. Vendor value %s, profit %s once sold. Collect them from your mailbox.",
        Buy.items or 0, Buy.count, Money(Buy.spent), Money(Buy.value), Money(Buy.value - Buy.spent)))
    end
  elseif Buy.sessionMoney then
    Print("Nothing was bought in this run.")
  end
  if balance and balance ~= Buy.spent then
    Print(string.format("Note: your gold changed by %s%s during this run in total (other gold changes, e.g. mail or repairs, are included there).",
      balance > 0 and "-" or "+", Money(math.abs(balance))))
  end
end

ResetBuy = function(silent)
  if Buy.state == "pricing" or Buy.state == "confirm" then
    C_AuctionHouse.CancelCommoditiesPurchase()
  end
  if not silent then Summary() end
  wipe(Buy.queue)
  Buy.offers, Buy.item, Buy.key = nil, nil, nil
  Buy.spent, Buy.value, Buy.count, Buy.items = 0, 0, 0, 0
  Buy.sessionMoney, Buy.inflight, Buy.money, Buy.confirmWait = nil, nil, nil, nil
  Buy.checking = false
  if Buy.watching and StopWatch then StopWatch("stopped") end
  SetState("idle", IdleLabel())
end

-- Only a guess (stackable = commodity). C_AuctionHouse.GetItemCommodityStatus can't be used here: it
-- expects an item in the player's bags (ItemLocation), not an item ID, and errors otherwise.
-- The guess only affects logging; whichever result type the server sends back is handled.
local function IsCommodity(itemID)
  local stack = select(8, GetItemInfoFn(itemID))
  return (stack or 1) > 1
end

local Search -- forward declaration (defined below)

-- Auto-search: after an item is finished, search the next one without waiting for a click.
-- VendorSnipeDB.autoSearch: nil/true = on, false = off. Turned off for the session if the
-- game ignores automatic searches twice.
local autoBlocked, autoFails = false, 0
local function AutoSearchOn()
  return VendorSnipeDB.autoSearch ~= false and not autoBlocked
end

local NextItem -- forward declaration

local function AutoSearchFailed(reason)
  autoFails = autoFails + 1
  Buy.auto = false
  if Buy.watching then
    if autoFails >= 2 then
      autoBlocked = true
      StopWatch("stopped: the game ignores automatic searches here (" .. reason .. ")")
      ResetBuy(true)
    else
      D("watch: no answer for", ItemName(Buy.item), "- skipping it this pass")
      Buy.checkedThis = true      -- don't mark it as sold out, we simply don't know
      NextItem()
    end
    return
  end
  if autoFails >= 2 then
    autoBlocked = true
    Print("Automatic search doesn't seem to work here (" .. reason .. "). Switched it off for this session; click to search.")
  else
    Print("Automatic search got no answer, click to search " .. ItemName(Buy.item) .. ".")
  end
  SetState("next", "Search: " .. ItemName(Buy.item))
end

-- Watch: mark the current item with the live result (has profitable listings or not).
local function MarkChecked(has)
  local r = Buy.item
  if not r then return end
  if Buy.mode == "bid" then
    local wasDeal = false
    for _, b in ipairs(bidResults) do
      if b.itemID == r.itemID then
        if not b.done then wasDeal = true end
        b.done, b.selected, b.soldOut = not has, has, not has
      end
    end
    if has and Buy.watching and not wasDeal then
      Buy.watchFound = (Buy.watchFound or 0) + 1
      Print(string.format("|cff40ff40New bid deal:|r %s is worth bidding on again. It's ticked: click Bid Selected.", r.link or ItemName(r)))
      if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master") end
    end
  else
    local wasDeal = byItem[r.itemID] == r and not r.done
    r.done, r.selected, r.soldOut = not has, has, not has
    if has and not byItem[r.itemID] then
      -- a near miss became a deal: add it to the Buyout deals list
      r.nearMiss = nil
      byItem[r.itemID] = r
      results[#results + 1] = r
      table.sort(results, function(a, b) return a.profit > b.profit end)
    end
    if has and Buy.watching and not wasDeal then
      Buy.watchFound = (Buy.watchFound or 0) + 1
      Print(string.format("|cff40ff40New deal:|r %s - %d below vendor price, profit %s. It's ticked: click Buy Selected.",
        r.link or ItemName(r), r.qty or 0, Money(r.profit or 0)))
      if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959, "Master") end
    end
  end
  if has then Buy.checkFound = (Buy.checkFound or 0) + 1 end
  Buy.checkedThis = true
end


function NextItem()
  if Buy.item and Buy.checking then
    if not Buy.checkedThis then MarkChecked(false) end   -- search ended without listings
    if ui then ui:Refresh() end
  elseif Buy.item then
    if Buy.mode == "bid" then
      -- a bid queue entry stands for all selected bid rows of that item
      for _, b in ipairs(bidResults) do
        if b.itemID == Buy.item.itemID and b.selected then b.done, b.selected = true, false end
      end
    else
      Buy.item.done, Buy.item.selected = true, false
    end
    if ui then ui:Refresh() end
  end
  Buy.item = table.remove(Buy.queue, 1)
  Buy.checkedThis = false
  Buy.offers, Buy.key, Buy.keys, Buy.keyIdx, Buy.token = nil, nil, nil, 0, nil
  Buy.browsed, Buy.variants, Buy.waitSend = false, false, nil
  Buy.searchAttempts = 1
  if not Buy.item then
    if Buy.watching then
      Buy.checking = false
      SetState("idle", IdleLabel())
      if Buy.watchOnce then
        -- a Full Scan was already possible: one round only (like the old Recheck)
        Print(string.format("Check done: %d of %d items have profitable listings right now. They are ticked - click %s.",
          Buy.checkFound or 0, Buy.checkTotal or 0, Buy.mode == "bid" and "Bid Selected" or "Buy Selected"))
        Buy.watching = false
        if ui and ui.watchBtn then ui.watchBtn:SetText("Watch") end
        if ui then ui:Refresh() end
        return
      end
      -- round finished: start the next one after a short pause
      C_Timer.After(5, function() if Buy.watching then StartWatchPass() end end)
      return
    end
    Print("Done with all selected items. Click Watch to keep looking for new listings below vendor price until the next Full Scan.")
    ResetBuy()
    return
  end
  SetState("next", "Search: " .. ItemName(Buy.item))
  if AutoSearchOn() or (Buy.watching and not autoBlocked) then
    local item = Buy.item
    -- Watch: pause between searches so the Auction House doesn't start throttling
    C_Timer.After(Buy.watching and 1.5 or 0, function()
      if Buy.state ~= "next" or Buy.item ~= item then return end
      Buy.auto = true
      local ok, err = pcall(Search)
      if not ok then
        Buy.auto = false
        Print("|cffff4040Error:|r automatic search failed: " .. tostring(err))
        SetState("next", "Search: " .. ItemName(item))
      end
    end)
  end
end

local function ShowOffer()
  local o = Buy.offers and Buy.offers[1]
  if Buy.checking and o then
    MarkChecked(true)
    NextItem()
    return
  end
  if not o then
    -- several variants of this item (e.g. different random bonuses) found by name: do the next one
    if Buy.variants and Buy.keys and Buy.keys[Buy.keyIdx + 1] then
      Buy.keyIdx = Buy.keyIdx + 1
      Buy.offers = nil
      if AutoSearchOn() then
        C_Timer.After(0, function() if Buy.state == "ready" or Buy.state == "next" then Search() end end)
        SetState("next", "Search next variant: " .. ItemName(Buy.item))
      else
        SetState("next", "Search next variant: " .. ItemName(Buy.item))
      end
      return
    end
    if Buy.checking then MarkChecked(false) end
    NextItem()
    return
  end
  if (o.total or o.cost) > GetMoney() then
    Print("Not enough gold for the next purchase (" .. Money(o.total or o.cost) .. "). Stopping.")
    ResetBuy()
    return
  end
  if o.kind == "bid" then
    SetState("ready", string.format("Bid %s on %dx %s (%s)", ShortMoney(o.cost), o.qty, ItemName(Buy.item), TIME_LABELS[o.timeLeft] or "?"))
  else
    SetState("ready", string.format("Buy %dx %s - %s", o.qty, ItemName(Buy.item), ShortMoney(o.total or o.cost)))
  end
end

local SORT_BY_PRICE = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

local function SafeCall(fn, ...)
  if not fn then return nil end
  local ok, a = pcall(fn, ...)
  if ok then return a end
  D("API error:", a)
  return nil
end

-- Search came back empty for this item key: offer a retry with the next key, or move on.
local BrowseByName -- forward declaration

-- The server answered, but with 0 listings for this item key: try the other key, then a search
-- by name (finds the exact keys, e.g. for gear with random bonuses). Only then is it really sold out.
local function NoResults()
  local r = Buy.item
  if Buy.keys and Buy.keys[Buy.keyIdx + 1] and not Buy.variants then
    Buy.keyIdx = Buy.keyIdx + 1
    D("no results for key", Buy.keyIdx - 1, "- trying the next key")
    Search()
    return
  end
  if Buy.variants then
    -- one variant was empty (sold meanwhile): continue with the remaining variants, if any
    Buy.offers = {}
    ShowOffer()
    return
  end
  if not Buy.browsed then
    BrowseByName()
    return
  end
  Print("No listings found for " .. ItemName(r) .. " - it has probably been sold since the scan.")
  NextItem()
end

-- The server didn't answer at all (busy or throttled): never skip the item because of that.
local function NoReply()
  local r = Buy.item
  if Buy.auto then
    AutoSearchFailed("no reply to an automatic search")
    return
  end
  Print("The Auction House didn't answer the search for " .. ItemName(r) .. " (server busy). Click to try again.")
  SetState("next", "Search again: " .. ItemName(r))
end

local function OnItemResults()
  local r = Buy.item
  Buy.searchAttempts = 1
  if Buy.auto then autoFails = 0 end
  Buy.auto = false
  local n = SafeCall(C_AuctionHouse.GetNumItemSearchResults, Buy.key) or 0
  D("item results:", n)
  if n == 0 then NoResults() return end
  local offers, min = {}, MinProfit()
  if Buy.mode == "bid" then
    local me = UnitGUID and UnitGUID("player")
    -- count why auctions were skipped, so an empty result is explained
    local why = { own = 0, mine = 0, time = 0, nobid = 0, overbuyout = 0, tooHigh = 0 }
    for i = 1, n do
      local info = SafeCall(C_AuctionHouse.GetItemSearchResultInfo, Buy.key, i)
      if info then
        local nextBid = (info.minBid and info.minBid > 0) and info.minBid
          or ((info.bidAmount and info.bidAmount > 0) and info.bidAmount + 1) or nil
        local buyout = info.buyoutAmount or 0
        if info.containsOwnerItem then why.own = why.own + 1
        elseif me and info.bidder == me then why.mine = why.mine + 1
        elseif not TimeShown(info.timeLeft) then why.time = why.time + 1
        elseif not nextBid then why.nobid = why.nobid + 1
        elseif buyout > 0 and nextBid >= buyout then why.overbuyout = why.overbuyout + 1
        else
          local vendor = (info.itemLink and GetSellPrice(info.itemLink)) or r.vendor or 0
          local q = info.quantity or 1
          local value = vendor * q
          local profit = math.min(value - nextBid, value - nextBid * q)
          D("  bid #" .. i, "qty", q, "next bid", nextBid, "buyout", buyout, "time", info.timeLeft, "profit", profit)
          if profit >= min then
            offers[#offers + 1] = { kind = "bid", auctionID = info.auctionID, cost = nextBid, qty = q,
                                    value = value, profit = profit, timeLeft = info.timeLeft }
          else
            why.tooHigh = why.tooHigh + 1
          end
        end
      end
    end
    table.sort(offers, function(a, b) return a.profit > b.profit end)
    Buy.offers = offers
    local parts = {}
    local function add(c, text) if c > 0 then parts[#parts + 1] = c .. " " .. text end end
    add(why.tooHigh, "bid now too high vs vendor price")
    add(why.mine, "already your bid")
    add(why.time, "hidden by time filter")
    add(why.overbuyout, "bid not below buyout")
    add(why.nobid, "buyout only")
    add(why.own, "your own")
    Print(string.format("%s: %d listings live, %d worth bidding on right now%s.", ItemName(r), n, #offers,
      #parts > 0 and (" (skipped: " .. table.concat(parts, ", ") .. ")") or ""))
    ShowOffer()
    return
  end
  for i = 1, n do
    local info = SafeCall(C_AuctionHouse.GetItemSearchResultInfo, Buy.key, i)
    if info and info.buyoutAmount and info.buyoutAmount > 0 and not info.containsOwnerItem then
      local vendor = (info.itemLink and GetSellPrice(info.itemLink)) or r.vendor or 0
      local q = info.quantity or 1
      local value = vendor * q
      -- Conservative: profitable whether buyoutAmount is the stack total or a per-unit price.
      -- In the live search, buyoutAmount is the price PER ITEM (the Full Scan reports stack totals).
      -- Profit uses the per-item reading; the min() keeps it safe should a listing ever be a total.
      local profit = math.min(value - info.buyoutAmount, value - info.buyoutAmount * q)
      D("  #" .. i, "qty", q, "buyout", info.buyoutAmount, "vendor value", value, "profit", profit)
      if profit >= min then
        offers[#offers + 1] = { kind = "item", auctionID = info.auctionID, cost = info.buyoutAmount,
                                unit = info.buyoutAmount, total = info.buyoutAmount * q,
                                qty = q, value = value, profit = profit }
      end
    end
  end
  table.sort(offers, function(a, b) return a.profit > b.profit end)
  Buy.offers = offers
  -- Replace the scan's numbers on the row with the live ones.
  local qty, cost, profit, best = 0, 0, 0, math.huge
  for _, o in ipairs(offers) do
    qty, cost, profit = qty + o.qty, cost + (o.total or o.cost), profit + o.profit
    best = math.min(best, o.unit or o.cost)          -- already per item: don't divide by the quantity
  end
  if #offers > 0 then
    r.qty, r.cost, r.profit, r.auctions, r.bestUnit, r.live = qty, cost, profit, #offers, best, true
    if ui then ui:Refresh() end
  end
  Print(string.format("%s: %d listings, %d profitable right now (%d items, profit %s).",
    ItemName(r), n, #offers, qty, Money(profit)))
  ShowOffer()
end

local function OnCommodityResults()
  local r = Buy.item
  Buy.searchAttempts = 1
  if Buy.auto then autoFails = 0 end
  Buy.auto = false
  if Buy.mode == "bid" then
    Print(ItemName(r) .. " is a stackable trade good; those are buyout-only on the Auction House, so it can't be bid on.")
    NextItem()
    return
  end
  local n = SafeCall(C_AuctionHouse.GetNumCommoditySearchResults, r.itemID) or 0
  D("commodity results:", n)
  if n == 0 then NoResults() return end
  local qty, cost = 0, 0
  for i = 1, n do
    local info = SafeCall(C_AuctionHouse.GetCommoditySearchResultInfo, r.itemID, i)
    if not info or not info.unitPrice or info.unitPrice >= r.vendor then break end   -- sorted cheapest first
    local avail = (info.quantity or 0) - (info.numOwnerItems or 0)
    D("  #" .. i, "unit", info.unitPrice, "avail", avail, "vendor", r.vendor)
    if avail > 0 then
      qty = qty + avail
      cost = cost + avail * info.unitPrice
    end
  end
  Buy.offers = {}
  local value = r.vendor * qty
  if qty > 0 and value - cost >= MinProfit() then
    Buy.offers[1] = { kind = "commodity", itemID = r.itemID, qty = qty, cost = cost, value = value,
                      profit = value - cost }
    -- Replace the scan's numbers on the row with the live ones.
    local first = SafeCall(C_AuctionHouse.GetCommoditySearchResultInfo, r.itemID, 1)
    r.qty, r.cost, r.profit, r.live = qty, cost, value - cost, true
    if first and first.unitPrice then r.bestUnit = first.unitPrice end
    if ui then ui:Refresh() end
    Print(string.format("%s: %d can be bought below vendor price right now (%s total, profit %s).",
      ItemName(r), qty, Money(cost), Money(value - cost)))
  else
    local first = SafeCall(C_AuctionHouse.GetCommoditySearchResultInfo, r.itemID, 1)
    Print(string.format("%s: cheapest is %s each, vendor pays %s. Not profitable right now.",
      ItemName(r), Money(first and first.unitPrice or 0), Money(r.vendor)))
  end
  ShowOffer()
end

local function BuildKeys(r)
  local keys = {}
  local isEquip = SafeCall((C_Item and C_Item.IsEquippableItem) or IsEquippableItem, r.itemID)
  local base = SafeCall(C_AuctionHouse.MakeItemKey, r.itemID) or { itemID = r.itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
  local withLvl = (r.ilvl and r.ilvl > 0) and SafeCall(C_AuctionHouse.MakeItemKey, r.itemID, r.ilvl) or nil
  if isEquip and withLvl then
    keys[1], keys[2] = withLvl, base
  else
    keys[1], keys[2] = base, withLvl
  end
  return keys
end

-- Send an AH request as soon as the AH accepts one (it limits how fast requests may be sent).
-- Waits for AUCTION_HOUSE_THROTTLED_SYSTEM_READY, at most 2 s, then sends anyway.
local function SendWhenReady(send)
  local ready = not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady()
  if ready then send() return end
  D("AH is throttling requests, waiting before sending")
  Buy.waitSend = send
  C_Timer.After(2, function()
    if Buy.waitSend == send then Buy.waitSend = nil send() end
  end)
end

local SEARCH_TIMEOUT = 16   -- polls of 0.5 s = 8 s without any answer (search by name)
local RESEND_AT = 8         -- 4 s of silence: start the search again from scratch
local MAX_ATTEMPTS = 3      -- fresh tries per item before asking for a click

-- Start the search for the current item from scratch: same as clicking Stop and Buy again.
local function RestartSearch()
  Buy.keys, Buy.keyIdx, Buy.browsed, Buy.variants, Buy.waitSend = nil, 0, false, false, nil
  Search()
end

-- Run a results handler so that an error is shown instead of leaving the search stuck.
local function SafeRun(fn)
  local ok, err = pcall(fn)
  if not ok then
    Print("|cffff4040Error while reading search results:|r " .. tostring(err))
    if Buy.item then SetState("next", "Search again: " .. ItemName(Buy.item)) end
  end
end

function Search()
  local r = Buy.item
  r.commodity = IsCommodity(r.itemID)
  Buy.keys = Buy.keys or BuildKeys(r)
  if Buy.keyIdx < 1 then Buy.keyIdx = 1 end
  Buy.key = Buy.keys[Buy.keyIdx]
  if not Buy.key then NoResults() return end
  Print("Searching live listings for " .. ItemName(r) .. "...")
  local key = Buy.key
  local function send()
    D("SendSearchQuery itemID", r.itemID, "itemLevel", key.itemLevel, "suffix", key.itemSuffix, "commodity guess", r.commodity)
    SafeCall(C_AuctionHouse.SendSearchQuery, key, SORT_BY_PRICE, true)
  end
  SendWhenReady(send)
  SetState("searching", "Searching " .. ItemName(r) .. "...")

  -- Don't rely only on result events: poll for results in case an event never arrives
  -- or the item turned out to be a commodity / non-commodity contrary to our guess.
  local token, ticks = {}, 0
  Buy.token = token
  C_Timer.NewTicker(0.5, function(t)
    if Buy.token ~= token or Buy.state ~= "searching" then t:Cancel() return end
    ticks = ticks + 1
    if ticks < 2 then return end
    local nc = SafeCall(C_AuctionHouse.GetNumCommoditySearchResults, r.itemID) or 0
    local ni = SafeCall(C_AuctionHouse.GetNumItemSearchResults, key) or 0
    if nc > 0 then
      t:Cancel(); D("poll found commodity results"); r.commodity = true; SafeRun(OnCommodityResults)
    elseif ni > 0 then
      t:Cancel(); D("poll found item results"); r.commodity = false; SafeRun(OnItemResults)
    elseif ticks >= RESEND_AT then
      t:Cancel()
      if (Buy.searchAttempts or 1) < MAX_ATTEMPTS then
        Buy.searchAttempts = (Buy.searchAttempts or 1) + 1
        D("no answer after 4s, starting the search again from scratch (try " .. Buy.searchAttempts .. ")")
        RestartSearch()
      else
        D("no answer after " .. MAX_ATTEMPTS .. " tries")
        NoReply()
      end
    end
  end, RESEND_AT)
end

-- Search by name, like the AH search box: returns the exact item keys that are listed right now
-- (gear with random bonuses has one key per bonus). Then each matching key is searched in turn.
function BrowseByName()
  local r = Buy.item
  Buy.browsed = true
  local name = ItemName(r)
  if not C_AuctionHouse.SendBrowseQuery or not name or name:find("^item:") then
    Print("No listings found for " .. ItemName(r) .. " - it has probably been sold since the scan.")
    NextItem()
    return
  end
  D("searching by name:", name)
  local query = { searchString = name, sorts = SORT_BY_PRICE, filters = {}, itemClassFilters = {} }
  SendWhenReady(function() SafeCall(C_AuctionHouse.SendBrowseQuery, query) end)
  SetState("searching", "Searching " .. name .. " by name...")
  local token, ticks = {}, 0
  Buy.token, Buy.browseToken = token, token
  C_Timer.NewTicker(0.5, function(t)
    if Buy.token ~= token or Buy.state ~= "searching" then t:Cancel() return end
    ticks = ticks + 1
    if ticks >= SEARCH_TIMEOUT then t:Cancel() NoReply() end
  end, SEARCH_TIMEOUT)
end

local function OnBrowseResults()
  local r = Buy.item
  Buy.browseToken = nil
  local list = SafeCall(C_AuctionHouse.GetBrowseResults) or {}
  local keys = {}
  for _, b in ipairs(list) do
    if b.itemKey and b.itemKey.itemID == r.itemID then keys[#keys + 1] = b.itemKey end
  end
  D("browse by name found", #keys, "matching item keys")
  if #keys == 0 then
    Print("No listings found for " .. ItemName(r) .. " - it has probably been sold since the scan.")
    NextItem()
    return
  end
  Buy.keys, Buy.keyIdx, Buy.variants = keys, 1, #keys > 1
  Search()
end

-- Purchases are counted ONLY from real gold changes, never from button clicks or "success" events alone.
-- Buy.inflight = the offer being bought, Buy.money = gold just before that purchase.
-- Buy.limbo = an offer we gave up waiting for; if its gold leaves later, it's still counted.

local function RecordPurchase(o, spent, item, late)
  -- quantity actually received: if the gold paid differs from the quote, scale the amount
  local qty = o.qty
  local function near(a, b) return math.abs(a - b) <= math.max(1, b * 0.01) end
  local full = o.total or o.cost          -- what the whole listing costs
  local exact = near(spent, o.cost) or near(spent, full)
  if not exact and full > 0 then qty = math.max(0, math.floor(o.qty * spent / full + 0.5)) end
  local value = (o.value / math.max(o.qty, 1)) * qty
  Buy.spent, Buy.value, Buy.count, Buy.items = Buy.spent + spent, Buy.value + value, Buy.count + 1, Buy.items + qty
  local note = exact and "" or (" (quoted " .. Money(full) .. ")")
  local prefix = late and "Late confirmation: " or ""
  if o.kind == "bid" then
    Print(string.format("%sBid placed on %dx %s: %s held%s (%s left). You win it if nobody outbids you.",
      prefix, qty, ItemName(item), Money(spent), note, TIME_LABELS[o.timeLeft] or "?"))
  else
    Print(string.format("%sBought %dx %s, paid %s%s (vendor value %s, profit %s).",
      prefix, qty, ItemName(item), Money(spent), note, Money(value), Money(value - spent)))
  end
end

local function Finalize(spent)
  local o = Buy.inflight
  Buy.inflight, Buy.money, Buy.confirmWait = nil, nil, nil
  if Buy.offers and Buy.offers[1] == o then table.remove(Buy.offers, 1) end
  if o then RecordPurchase(o, spent, Buy.item) end
  ShowOffer()
end

local function DropInflight(msg)
  local o = Buy.inflight
  Buy.inflight, Buy.money, Buy.confirmWait = nil, nil, nil
  if Buy.offers and Buy.offers[1] == o then table.remove(Buy.offers, 1) end
  if msg then Print(msg) end
  ShowOffer()
end

-- Called by success events and by gold changes while a purchase is in flight.
local function CheckBought()
  if Buy.state ~= "buying" or not Buy.money or not Buy.inflight then return end
  local spent = Buy.money - GetMoney()
  if spent > 0 then Finalize(spent) return end
  -- the game reported success but the gold hasn't changed yet: wait for it (max 3 s)
  if not Buy.confirmWait then
    Buy.confirmWait = true
    local o = Buy.inflight
    C_Timer.After(3, function()
      if Buy.state ~= "buying" or Buy.inflight ~= o then return end
      local s2 = (Buy.money or GetMoney()) - GetMoney()
      if s2 > 0 then
        Finalize(s2)
      else
        DropInflight("The game reported a purchase but no gold left your bags, so it isn't counted.")
      end
    end)
  end
end

local function OnFailed(reason)
  if Buy.state == "buying" and Buy.inflight and Buy.money then
    -- remember it: if the gold still leaves later, it's counted as a late confirmation
    Buy.limbo = { o = Buy.inflight, item = Buy.item, t = GetTime() }
  end
  Buy.inflight, Buy.money, Buy.confirmWait = nil, nil, nil
  if Buy.offers then table.remove(Buy.offers, 1) end
  Print((Buy.mode == "bid" and "Bid failed" or "Purchase failed") .. (reason and (": " .. reason) or "") .. ", skipping that listing.")
  ShowOffer()
end

local function BuyClick()
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
    Print("Open the Auction House first.")
    return
  end
  if phase == "waiting" or phase == "copying" then Print("Wait until the scan data is copied (a few seconds).") return end
  local st = Buy.state
  D("Buy click, state:", st)
  if Buy.watching and (st == "idle" or Buy.checking) then
    -- buying needs your clicks: stop watching first, then buy what's ticked
    StopWatch("paused for buying - click Watch again afterwards")
    if Buy.state ~= "idle" then ResetBuy(true) end
    st = Buy.state
  end
  if st == "idle" then
    wipe(Buy.queue)
    Buy.checking = false
    Buy.mode = (ui and ui.tab == "bid") and "bid" or "buyout"
    if Buy.mode == "bid" then
      -- one queue entry per item; the live search then finds every auction of it worth bidding on
      local seen = {}
      for _, b in ipairs(bidResults) do
        if b.selected and not b.done and BidShown(b) and not seen[b.itemID] then
          seen[b.itemID] = true
          Buy.queue[#Buy.queue + 1] = { itemID = b.itemID, name = b.name, link = b.link, ilvl = b.ilvl,
                                        vendor = b.vendor, stack = b.stack }
        end
      end
    else
      for _, r in ipairs(results) do
        if r.selected and not r.done and ItemShown(r) then Buy.queue[#Buy.queue + 1] = r end
      end
    end
    if #Buy.queue == 0 then
      Print("Nothing selected. Tick the boxes (or right-click rows) of the items you want first.")
      return
    end
    D("queued", #Buy.queue, "items")
    Buy.spent, Buy.value, Buy.count, Buy.items, Buy.item = 0, 0, 0, 0, nil
    Buy.sessionMoney, Buy.limbo = GetMoney(), nil
    NextItem()
    if Buy.item then Buy.auto = false Search() end
  elseif st == "next" then
    Buy.auto = false
    Search()
  elseif st == "ready" then
    local o = Buy.offers[1]
    Buy.money, Buy.inflight, Buy.confirmWait = GetMoney(), o, nil
    if o.kind == "bid" then
      Print("Bidding " .. Money(o.cost) .. " on " .. o.qty .. "x " .. ItemName(Buy.item) .. "...")
      D("PlaceBid (bid) auctionID", o.auctionID, "amount", o.cost)
      SafeCall(C_AuctionHouse.PlaceBid, o.auctionID, o.cost)
      SetState("buying", "Bidding...")
    elseif o.kind == "item" then
      Print("Buying " .. o.qty .. "x " .. ItemName(Buy.item) .. " for " .. Money(o.total or o.cost) .. "...")
      D("PlaceBid auctionID", o.auctionID, "amount", o.cost)
      SafeCall(C_AuctionHouse.PlaceBid, o.auctionID, o.cost)
      SetState("buying", "Buying...")
    else
      Print("Requesting final price for " .. o.qty .. "x " .. ItemName(Buy.item) .. "...")
      D("StartCommoditiesPurchase", o.itemID, "qty", o.qty)
      SafeCall(C_AuctionHouse.StartCommoditiesPurchase, o.itemID, o.qty)
      SetState("pricing", "Checking price...")
      C_Timer.After(5, function()
        if Buy.state == "pricing" and Buy.offers and Buy.offers[1] == o then
          SetButton("Ask price again: " .. ItemName(Buy.item))
          Print("No price quote from the server yet. Click the button to ask again.")
        end
      end)
    end
  elseif st == "confirm" then
    local o = Buy.offers[1]
    Buy.money, Buy.inflight, Buy.confirmWait = GetMoney(), o, nil
    Print("Confirming " .. o.qty .. "x " .. ItemName(Buy.item) .. " for " .. Money(o.cost) .. "...")
    D("ConfirmCommoditiesPurchase", o.itemID, "qty", o.qty)
    SafeCall(C_AuctionHouse.ConfirmCommoditiesPurchase, o.itemID, o.qty)
    SetState("buying", "Buying...")
  elseif st == "searching" then
    -- a click while searching = start this item's search again right away (what Stop + Buy did)
    Print("Searching " .. ItemName(Buy.item) .. " again now...")
    Buy.auto, Buy.searchAttempts = false, 1
    RestartSearch()
  elseif st == "pricing" then
    -- a click while waiting for the price quote = ask for it again
    local o = Buy.offers and Buy.offers[1]
    if o then
      Print("Asking the server for the price of " .. o.qty .. "x " .. ItemName(Buy.item) .. " again...")
      SafeCall(C_AuctionHouse.CancelCommoditiesPurchase)
      SafeCall(C_AuctionHouse.StartCommoditiesPurchase, o.itemID, o.qty)
      SetState("pricing", "Checking price...")
    end
  elseif GetTime() - Buy.t <= STEP_TIMEOUT then
    -- a purchase is in flight: never send it twice
    Print("Still waiting for the server to confirm the purchase, click again in a few seconds if nothing happens.")
  else
    -- searching / pricing / buying with no server response
    if st == "pricing" or st == "confirm" then C_AuctionHouse.CancelCommoditiesPurchase() end
    if st == "searching" then
      Print("Still no answer for " .. ItemName(Buy.item) .. ", searching again.")
      Buy.auto = false
      Search()
    else
      OnFailed("no response from server")
    end
  end
end

-- Watch: keep re-checking the deal list plus near misses live until a Full Scan is possible again.
local function CooldownLeft()
  return SCAN_COOLDOWN - (time() - (VendorSnipeDB.lastScan or 0))
end

function StopWatch(reason)
  if not Buy.watching then return end
  Buy.watching = false
  if ui and ui.watchBtn then ui.watchBtn:SetText("Watch") end
  if reason == "cooldown" then
    Print(string.format("Full Scan is available again - Watch stopped (%d new deals found while watching).", Buy.watchFound or 0))
    if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960, "Master") end
  else
    Print(string.format("Watch %s (%d new deals found).", reason or "stopped", Buy.watchFound or 0))
  end
end

function StartWatchPass()
  if not Buy.watching then return end
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then StopWatch("stopped: Auction House closed") return end
  if not Buy.watchOnce and CooldownLeft() <= 0 then StopWatch("cooldown") return end
  if autoBlocked and Buy.watchPass > 0 then StopWatch("stopped: the game ignores automatic searches here") return end
  if Buy.state ~= "idle" then return end
  wipe(Buy.queue)
  if Buy.mode == "bid" then
    -- Bid deals tab: one entry per item; the live search finds every auction worth bidding on
    local seen = {}
    for _, b in ipairs(bidResults) do
      if BidShown(b) and not seen[b.itemID] then
        seen[b.itemID] = true
        Buy.queue[#Buy.queue + 1] = { itemID = b.itemID, name = b.name, link = b.link, ilvl = b.ilvl,
                                      vendor = b.vendor, stack = b.stack }
      end
    end
  else
    for _, r in ipairs(results) do
      if ItemShown(r) then Buy.queue[#Buy.queue + 1] = r end
    end
    for _, w in ipairs(VendorSnipeDB.watchItems or {}) do
      if not byItem[w.itemID] and ItemShown(w) then Buy.queue[#Buy.queue + 1] = w end
    end
  end
  if #Buy.queue == 0 then StopWatch("stopped: nothing to watch - run a Full Scan first") return end
  Buy.watchPass = (Buy.watchPass or 0) + 1
  Buy.checking, Buy.checkFound, Buy.checkTotal = true, 0, #Buy.queue
  Buy.spent, Buy.value, Buy.count, Buy.items, Buy.item, Buy.sessionMoney = 0, 0, 0, 0, nil, nil
  local left = CooldownLeft()
  if Buy.watchOnce then
    SetStatus("Checking %d items live (one round, a Full Scan is already possible)...", #Buy.queue)
  else
    SetStatus("Watching: round %d, %d items - %d new deals so far. Full Scan possible in %d:%02d.",
      Buy.watchPass, #Buy.queue, Buy.watchFound or 0, left / 60, left % 60)
  end
  D("watch pass", Buy.watchPass, "items", #Buy.queue)
  NextItem()
end

local function ToggleWatch()
  if Buy.watching then
    StopWatch("stopped")
    if Buy.state ~= "idle" then ResetBuy(true) end
    return
  end
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Print("Open the Auction House first.") return end
  if phase == "waiting" or phase == "copying" then Print("Wait until the scan data is copied (a few seconds).") return end
  if Buy.state ~= "idle" then Print("Finish or Stop the current buying run first.") return end
  Buy.mode = (ui and ui.tab == "bid") and "bid" or "buyout"
  Buy.watching, Buy.watchPass, Buy.watchFound = true, 0, 0
  Buy.watchOnce = CooldownLeft() <= 0
  if ui and ui.watchBtn then ui.watchBtn:SetText("Stop watch") end
  if Buy.watchOnce then
    Print("A Full Scan is possible right now, so Watch checks the list once (nothing is bought). Tip: a new Full Scan finds brand-new items too.")
  elseif Buy.mode == "bid" then
    Print(string.format("Watching your bid deals until the next Full Scan. Nothing is bid automatically; items worth bidding on are ticked and announced."))
  else
    Print(string.format("Watching %d deal items and %d near misses (cheapest listing up to 50%% above vendor price) until the next Full Scan. Nothing is bought; new deals are ticked and announced.",
      #results, #(VendorSnipeDB.watchItems or {})))
  end
  StartWatchPass()
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local function SearchFor(r)
  local name = ItemName(r)
  local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
  if bar and bar.SetSearchText and bar.StartSearch then
    bar:SetSearchText(name)
    bar:StartSearch()
  end
end

local guide

local function ToggleGuide()
  if not guide then
    local g = CreateFrame("Frame", "VendorSnipeGuideFrame", UIParent, "BackdropTemplate")
    g:SetSize(520, 480)
    g:SetPoint("CENTER")
    g:SetFrameStrata("DIALOG")
    g:SetMovable(true); g:EnableMouse(true); g:RegisterForDrag("LeftButton")
    g:SetScript("OnDragStart", g.StartMoving)
    g:SetScript("OnDragStop", g.StopMovingOrSizing)
    g:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    tinsert(UISpecialFrames, "VendorSnipeGuideFrame")

    local title = g:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("VendorSnipe Guide")
    local close = CreateFrame("Button", nil, g, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    local scroll = CreateFrame("ScrollFrame", nil, g, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -40)
    scroll:SetPoint("BOTTOMRIGHT", -32, 14)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(470, 1)
    scroll:SetScrollChild(content)

    local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT")
    text:SetWidth(470)
    text:SetJustifyH("LEFT")
    text:SetSpacing(3)
    text:SetText(ns.GuideText or "Guide text missing.")
    g:SetScript("OnShow", function() content:SetHeight(text:GetStringHeight() + 10) end)
    content:SetHeight(text:GetStringHeight() + 10)

    g:Hide()
    guide = g
  end
  guide:SetShown(not guide:IsShown())
end

local function BuildUI()
  local f = CreateFrame("Frame", "VendorSnipeFrame", UIParent, "BackdropTemplate")
  f:SetSize(580, 500)
  f:SetPoint("CENTER")
  f:SetFrameStrata("HIGH")
  f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
                  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                  edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:Hide()
  tinsert(UISpecialFrames, "VendorSnipeFrame")

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 14, -12)
  title:SetText("VendorSnipe")

  local auto = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  auto:SetSize(22, 22)
  auto:SetPoint("LEFT", title, "RIGHT", 14, 0)
  auto:SetChecked(VendorSnipeDB.autoSearch ~= false)
  auto:SetScript("OnClick", function(self)
    VendorSnipeDB.autoSearch = self:GetChecked() and true or false
    if self:GetChecked() then autoBlocked, autoFails = false, 0 end
  end)
  auto:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Auto-search")
    GameTooltip:AddLine("When one item is finished, search the next selected item automatically, so every click on Buy buys something.", 1, 1, 1, true)
    GameTooltip:AddLine("Untick to search each item with a click instead.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  auto:SetScript("OnLeave", GameTooltip_Hide)
  f.autoCheck = auto
  local autoLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  autoLabel:SetPoint("LEFT", auto, "RIGHT", 0, 0)
  autoLabel:SetText("Auto-search")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  local scan = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  scan:SetSize(90, 22)
  scan:SetPoint("TOPRIGHT", -36, -10)
  scan:SetText("Full Scan")
  scan:SetScript("OnClick", StartScan)

  local watch = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  watch:SetSize(84, 22)
  watch:SetText("Watch")
  watch:SetScript("OnClick", function()
    local ok, err = pcall(ToggleWatch)
    if not ok then Print("|cffff4040Error:|r " .. tostring(err)) end
  end)
  watch:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Watch until next Full Scan")
    GameTooltip:AddLine("Keeps checking the list of the current tab live, round after round, until a Full Scan is allowed again. In Buyout deals it also watches near misses (items just above vendor price). New deals are ticked, announced with a sound and added to the list. Nothing is bought automatically.", 1, 1, 1, true)
    GameTooltip:AddLine("If a Full Scan is already possible, it checks the list once.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  watch:SetScript("OnLeave", GameTooltip_Hide)
  f.watchBtn = watch

  local help = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  help:SetSize(60, 22)
  help:SetPoint("RIGHT", scan, "LEFT", -6, 0)
  help:SetText("Guide")
  help:SetScript("OnClick", ToggleGuide)
  watch:SetPoint("RIGHT", help, "LEFT", -6, 0)

  -- tabs: Buyout deals / Bid deals
  f.tab = (VendorSnipeDB.tab == "bid") and "bid" or "buyout"
  local function MakeTab(key, text, anchorTo)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(100, 22)
    if anchorTo then b:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", 12, -38) end
    b:SetText(text)
    b:SetScript("OnClick", function() f:SetTab(key) end)
    return b
  end
  f.tabBuyout = MakeTab("buyout", "Buyout deals")
  f.tabBid = MakeTab("bid", "Bid deals", f.tabBuyout)

  -- time-left filter (Bid deals tab only)
  f.timeWidgets = {}
  local timeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  timeLabel:SetPoint("LEFT", f.tabBid, "RIGHT", 16, 0)
  timeLabel:SetText("Time left:")
  f.timeWidgets[#f.timeWidgets + 1] = timeLabel
  local tp = timeLabel
  for band = 0, 3 do
    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("LEFT", tp, "RIGHT", band == 0 and 4 or 2, 0)
    cb:SetChecked(TimeShown(band))
    cb:SetScript("OnClick", function(self)
      VendorSnipeDB.hideTime = VendorSnipeDB.hideTime or {}
      VendorSnipeDB.hideTime[band] = not self:GetChecked() or nil
      f:Refresh()
    end)
    cb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText("Time left: " .. TIME_LABELS[band])
      GameTooltip:AddLine(TIME_DETAILS[band], 1, 1, 1)
      GameTooltip:AddLine("This is how long until the auction ends. Untick to hide bid deals with this much time left. Shorter = less time for others to outbid you.", 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", GameTooltip_Hide)
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 0, 0)
    lbl:SetText(TIME_LABELS[band])
    f.timeWidgets[#f.timeWidgets + 1] = cb
    f.timeWidgets[#f.timeWidgets + 1] = lbl
    tp = lbl
  end

  local minLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  minLabel:SetPoint("TOPLEFT", 14, -68)
  minLabel:SetText("Min profit:")
  local minBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  minBox:SetSize(70, 20); minBox:SetAutoFocus(false)
  minBox:SetPoint("LEFT", minLabel, "RIGHT", 8, 0)
  minBox:SetText(ShortMoney(MinProfit()))
  minBox:SetScript("OnEnterPressed", function(self)
    local v = ParseMoney(self:GetText())
    if v then VendorSnipeDB.minProfit = v Print("Min profit set to " .. Money(v) .. ".") end
    self:SetText(ShortMoney(MinProfit()))
    self:ClearFocus()
  end)
  minBox:SetScript("OnEscapePressed", minBox.ClearFocus)
  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("LEFT", minBox, "RIGHT", 8, 0)
  hint:SetText("e.g. 50s, 1g20s")

  -- type filter: stackable vs single items
  local typeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  typeLabel:SetPoint("LEFT", hint, "RIGHT", 24, 0)
  typeLabel:SetText("Type:")
  local tprev = typeLabel
  for _, t in ipairs({ { key = "hideStack", label = "Stacks", tip = "Items you can buy many of: stackable goods (cloth, herbs, ore, potions...) plus recipes (patterns, plans, schematics, formulas) and bags." },
                       { key = "hideSingle", label = "Single", tip = "Everything else: gear, weapons and other items that can't be bought in bulk." },
                       { key = "hideUnique", label = "Unique", tip = "Items marked Unique: you can only carry one (or a few), so buying several doesn't work." } }) do
    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("LEFT", tprev, "RIGHT", 4, 0)
    cb:SetChecked(not VendorSnipeDB[t.key])
    cb:SetScript("OnClick", function(self)
      VendorSnipeDB[t.key] = not self:GetChecked() or nil
      f:Refresh()
    end)
    cb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(t.label)
      GameTooltip:AddLine(t.tip, 1, 1, 1)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", GameTooltip_Hide)
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 0, 0)
    lbl:SetText(t.label)
    tprev = lbl
  end

  -- rarity filter
  local rarLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  rarLabel:SetPoint("TOPLEFT", 14, -94)
  rarLabel:SetText("Rarity:")
  local QNAMES = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary" }
  local prev = rarLabel
  for q = 0, 5 do
    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("LEFT", prev, "RIGHT", q == 0 and 4 or 2, 0)
    cb:SetChecked(not (VendorSnipeDB.hideQuality and VendorSnipeDB.hideQuality[q]))
    cb:SetScript("OnClick", function(self)
      VendorSnipeDB.hideQuality = VendorSnipeDB.hideQuality or {}
      VendorSnipeDB.hideQuality[q] = not self:GetChecked() or nil
      f:Refresh()
    end)
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 0, 0)
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    lbl:SetText((color and color.hex or "") .. (_G["ITEM_QUALITY" .. q .. "_DESC"] or QNAMES[q]) .. "|r")
    prev = lbl
  end

  -- select-all checkbox + column headers
  local all = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  all:SetSize(20, 20)
  all:SetPoint("TOPLEFT", 12, -114)
  all:SetScript("OnClick", function(self)
    local on = self:GetChecked()
    if f.tab == "bid" then
      for _, r in ipairs(bidResults) do
        if not r.done and BidShown(r) then r.selected = on end
      end
    else
      for _, r in ipairs(results) do
        if not r.done and ItemShown(r) then r.selected = on end
      end
    end
    f:Refresh()
  end)
  f.selectAll = all

  -- column layouts per tab: { header text, x (relative to the frame), width }
  local LAYOUTS = {
    buyout = { { "Item", 58, 200 }, { "Qty", 262, 40 }, { "Cheapest/ea", 302, 90 }, { "Vendor/ea", 392, 80 }, { "Profit", 472, 68 } },
    bid    = { { "Item", 58, 150 }, { "Qty", 212, 30 }, { "Next bid", 244, 80 }, { "Buyout", 326, 80 }, { "Time left", 408, 60 }, { "Profit", 470, 70 } },
  }
  f.headers = {}
  for i = 1, 6 do
    f.headers[i] = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  end
  local function LayoutHeaders()
    local L = LAYOUTS[f.tab]
    for i, fs in ipairs(f.headers) do
      local h = L[i]
      fs:ClearAllPoints()
      if h then fs:SetPoint("TOPLEFT", h[2], -118) fs:SetText(h[1]) fs:Show() else fs:Hide() end
    end
  end

  local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 10, -136)
  scroll:SetPoint("BOTTOMRIGHT", -30, 58)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(530, 1)
  scroll:SetScrollChild(content)
  f.rows = {}

  -- bottom bar: status, Buy, Stop
  f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.status:SetPoint("BOTTOMLEFT", 14, 40)
  f.status:SetWidth(550)
  f.status:SetJustifyH("LEFT")
  f.status:SetWordWrap(false)
  f.status:SetText("Open the Auction House and press Full Scan.")

  local buy = CreateFrame("Button", "VendorSnipeBuyButton", f, "UIPanelButtonTemplate")
  buy:SetSize(360, 26)
  buy:SetPoint("BOTTOMRIGHT", -14, 10)
  buy:SetText("Buy Selected")
  buy:SetScript("OnClick", function()
    -- Never fail silently: WoW hides Lua errors by default, so report them ourselves.
    local ok, err = xpcall(BuyClick, function(e)
      return tostring(e) .. (debugstack and ("\n" .. debugstack(2, 4, 0)) or "")
    end)
    if not ok then
      err = tostring(err):gsub("Interface[\\/]AddOns[\\/]VendorSnipe[\\/]", "")
      Out("|cffff4040VendorSnipe error:|r " .. err)
      Print("|cffff4040Error:|r " .. (err:match("^[^\n]*") or err) .. "  (full text in chat)")
    end
  end)
  f.buy = buy
  local bfs = buy:GetFontString()
  if bfs then bfs:SetWidth(344) bfs:SetWordWrap(false) end   -- long labels end in "..." instead of overflowing


  local stop = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  stop:SetSize(70, 26)
  stop:SetPoint("RIGHT", buy, "LEFT", -6, 0)
  stop:SetText("Stop")
  stop:SetScript("OnClick", function() ResetBuy() end)
  stop:Hide()
  f.stop = stop


  local function GetRow(i)
    local row = f.rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, content)
    row:SetSize(530, 20)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", 2, 0)
    row.check:SetScript("OnClick", function(self)
      row.data.selected = self:GetChecked() and true or false
    end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18); row.icon:SetPoint("LEFT", 26, 0)
    local function Col(x, w)
      local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("LEFT", x, 0); fs:SetWidth(w); fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)
      return fs
    end
    row.name   = Col(48, 200)
    row.qty    = Col(252, 40)
    row.unit   = Col(292, 90)
    row.vendor = Col(382, 80)
    row.time   = Col(408, 46)
    row.profit = Col(462, 68)
    row:SetScript("OnClick", function(self, button)
      if button == "RightButton" then
        if not self.data.done then
          self.data.selected = not self.data.selected
          self.check:SetChecked(self.data.selected)
        end
      elseif IsModifiedClick("CHATLINK") and self.data.link then
        ChatEdit_InsertLink(self.data.link)
      else
        SearchFor(self.data)
      end
    end)
    row:SetScript("OnEnter", function(self)
      local d = self.data
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(d.itemID)
      GameTooltip:AddLine(" ")
      if d.isBid then
        GameTooltip:AddLine(string.format("Next bid %s for %d, vendor value %s", Money(d.bid), d.qty, Money(d.value)), 1, 1, 1)
        if d.buyout and d.buyout > 0 then
          GameTooltip:AddLine(string.format("Buyout %s - bid is %d%% of the buyout", Money(d.buyout), math.floor(d.bid / d.buyout * 100 + 0.5)), 1, 1, 1)
        else
          GameTooltip:AddLine("Bid only (no buyout price)", 1, 1, 1)
        end
        if d.unchanged then
          GameTooltip:AddLine("Unchanged since the previous scan: nobody has bid on it.", 0.6, 0.8, 1, true)
        end
        GameTooltip:AddLine("Time left at scan: " .. (TIME_LABELS[d.timeLeft] and (TIME_LABELS[d.timeLeft] .. " (" .. TIME_DETAILS[d.timeLeft] .. ")") or "unknown"), 1, 1, 1)
        GameTooltip:AddLine("A bid is binding: if nobody outbids you, you pay it and get the item by mail when the auction ends.", 0.8, 0.8, 0.5, true)
      else
        GameTooltip:AddLine(string.format("%d auctions, %d items, total cost %s",
          d.auctions, d.qty, Money(d.cost)), 1, 1, 1)
        GameTooltip:AddLine(d.live and "Numbers updated from the live search (exact)." or
          ("Numbers from the Full Scan" .. (PriceMode() and "" or " (price reading not detected yet, Cheapest/ea assumes stack prices)")
           .. "; the live search before buying uses exact current prices."), 0.7, 0.7, 0.7, true)
      end
      GameTooltip:AddLine("Click: search on AH   Right-click / tick: select   Shift-click: link", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    f.rows[i] = row
    return row
  end

  local function LayoutRow(row)
    local L = LAYOUTS[f.tab]
    local cols = f.tab == "bid" and { row.name, row.qty, row.unit, row.vendor, row.time, row.profit }
                                 or { row.name, row.qty, row.unit, row.vendor, row.profit }
    row.time:SetShown(f.tab == "bid")
    for i, fs in ipairs(cols) do
      fs:ClearAllPoints()
      fs:SetPoint("LEFT", L[i][2] - 10, 0)
      fs:SetWidth(L[i][3])
    end
    row.layout = f.tab
  end

  function f:SetTab(key)
    if Buy.watching and StopWatch then StopWatch("stopped (tab changed)") end
    if Buy.state ~= "idle" then ResetBuy() end
    f.tab = key
    VendorSnipeDB.tab = key
    if key == "bid" then f.tabBid:LockHighlight() f.tabBuyout:UnlockHighlight()
    else f.tabBuyout:LockHighlight() f.tabBid:UnlockHighlight() end
    for _, w in ipairs(f.timeWidgets) do w:SetShown(key == "bid") end
    f.selectAll:SetChecked(false)
    f.buy:SetText(key == "bid" and "Bid Selected" or "Buy Selected")
    LayoutHeaders()
    f:Refresh()
  end

  local view = {}
  function f:Refresh()
    wipe(view)
    local source = f.tab == "bid" and bidResults or results
    local shown = f.tab == "bid" and BidShown or ItemShown
    for _, r in ipairs(source) do
      if not r.name or r.stack == nil then
        local _, name, link, quality, icon, ilvl, stack = GetSellPrice(r.itemID)
        r.name, r.link, r.quality, r.icon = r.name or name, r.link or link, r.quality or quality, r.icon or icon
        r.ilvl, r.stack = r.ilvl or ilvl, r.stack or stack
      end
      if r.unique == nil then r.unique = UniqueFor(r.itemID) end
      if shown(r) then view[#view + 1] = r end
    end
    local n = math.min(#view, MAX_ROWS)
    for i = 1, n do
      local r, row = view[i], GetRow(i)
      if row.layout ~= f.tab then LayoutRow(row) end
      row.data = r
      row.check:SetChecked(r.selected)
      row.check:SetEnabled(not r.done)
      row.icon:SetTexture(r.icon or 134400)
      row.icon:SetDesaturated(r.done)
      local color = r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
      row.name:SetText((r.done and "|cff808080" or (color and color.hex or "")) .. ItemName(r) .. "|r")
      row.qty:SetText(r.qty)
      if r.isBid then
        row.unit:SetText(Money(r.bid))
        row.vendor:SetText(r.buyout and r.buyout > 0 and Money(r.buyout) or "|cffffd100bid only|r")
        row.time:SetText(TIME_LABELS[r.timeLeft] or "?")
      else
        row.unit:SetText(Money(r.bestUnit))
        row.vendor:SetText(Money(r.vendor))
      end
      row.profit:SetText(r.done and (r.soldOut and "|cff808080none left|r" or "|cff808080done|r")
        or ("|cff40ff40" .. Money(r.profit) .. "|r"))
      row:Show()
    end
    for i = n + 1, #f.rows do f.rows[i]:Hide() end
    content:SetHeight(math.max(1, n * 20))
    if not scanning then
      local age = VendorSnipeDB.resultsTime and math.floor((time() - VendorSnipeDB.resultsTime) / 60)
      local ageText = (age == nil or age < 1) and "just now" or (age .. " min ago")
      if f.tab == "bid" and #bidResults > 0 then
        f.status:SetText(string.format("%d bid deals, %d shown by filters, scanned %s (time left was measured then).",
          #bidResults, n, ageText))
      elseif f.tab ~= "bid" and #results > 0 then
        f.status:SetText(string.format("%d items found, %d shown by filters, scanned %s.",
          #results, n, ageText))
      else
        f.status:SetText("No results yet. Open the Auction House and press Full Scan.")
      end
    end
  end

  f:SetTab(f.tab)
  return f
end

---------------------------------------------------------------------------
-- Events & slash commands
---------------------------------------------------------------------------

local handlers = {}
local lastMoney   -- gold at the last PLAYER_MONEY event (for late confirmations)

function handlers.ADDON_LOADED(arg1)
  if arg1 ~= ADDON then return end
  VendorSnipeDB = VendorSnipeDB or {}
  VendorSnipeDB.minProfit = VendorSnipeDB.minProfit or 1
  -- Restore the last finished scan so results survive closing the AH, /reload and relogging.
  if type(VendorSnipeDB.results) == "table" then
    results = VendorSnipeDB.results
    for _, r in ipairs(results) do
      r.selected, r.done, r.live = false, false, nil
      if r.minPerItem or r.minRaw then r.bestUnit = ScanUnitPrice(r) end
      byItem[r.itemID] = r
    end
  end
  VendorSnipeDB.results = results
  if type(VendorSnipeDB.bidResults) == "table" then
    bidResults = VendorSnipeDB.bidResults
    for _, r in ipairs(bidResults) do r.selected, r.done = false, false end
  end
  VendorSnipeDB.bidResults = bidResults
  ui = BuildUI()
  lastMoney = GetMoney()
end

function handlers.AUCTION_HOUSE_SHOW()
  ui:ClearAllPoints()
  if AuctionHouseFrame then
    ui:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
  else
    ui:SetPoint("CENTER")
  end
  ui:Show()
  ui:Refresh()
  -- A scan request that was never answered (AH closed too early): don't keep the user locked out.
  if phase == "waiting" and time() - scanStarted > WAIT_STALE then
    phase, scanning = nil, false
    VS:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    VendorSnipeDB.lastScan = 0
    ui:Refresh()
    Print("Your last scan request never received data, so the cooldown was cleared. Press Full Scan to try again (the server may still refuse until 15 min have passed).")
  end
end

function handlers.AUCTION_HOUSE_CLOSED()
  ui:Hide()
  if Buy.watching then StopWatch("stopped: Auction House closed") end
  if Buy.state ~= "idle" then ResetBuy() end
  if phase == "waiting" then
    -- Keep listening: if the data still arrives it is processed normally.
    Print("Auction House closed before the scan data arrived. VendorSnipe keeps listening; if nothing arrives, reopen the AH and the cooldown is cleared.")
  elseif phase == "copying" then
    Print("Auction House closed while copying scan data. Saving what can still be read...")
  elseif phase == "processing" then
    Print("Auction House closed. The scan continues in the background, you'll get a message when it's done.")
  end
end

function handlers.REPLICATE_ITEM_LIST_UPDATE()
  VS:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
  if phase ~= "waiting" then return end
  scanTotal = C_AuctionHouse.GetNumReplicateItems() or 0
  D("replicate data arrived:", scanTotal, "auctions")
  phase, copyIndex = "copying", 0
  CopyChunk()
end

-- Accept either result type regardless of our commodity guess; the event tells us what it really is.
function handlers.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
  D("event ITEM_SEARCH_RESULTS_UPDATED", itemKey and itemKey.itemID, "state", Buy.state)
  if Buy.state == "searching" and Buy.item and itemKey and itemKey.itemID == Buy.item.itemID then
    Buy.key = itemKey
    Buy.item.commodity = false
    OnItemResults()
  end
end

function handlers.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
  local send = Buy.waitSend
  if send then
    Buy.waitSend = nil
    D("AH ready for requests again")
    send()
  end
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
  if Buy.state == "searching" and Buy.browseToken and Buy.token == Buy.browseToken and Buy.item then
    OnBrowseResults()
  end
end

function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
  D("event COMMODITY_SEARCH_RESULTS_UPDATED", itemID, "state", Buy.state)
  if Buy.state == "searching" and Buy.item and itemID == Buy.item.itemID then
    Buy.item.commodity = true
    OnCommodityResults()
  end
end

-- Gold changed: this is what actually confirms a purchase.
function handlers.PLAYER_MONEY()
  local before, nowMoney = lastMoney, GetMoney()
  lastMoney = nowMoney
  local function matches(spent, cost) return math.abs(spent - cost) <= math.max(1, cost * 0.01) end
  if Buy.state == "buying" and Buy.inflight then
    local L, spent = Buy.limbo, before and (before - nowMoney) or 0
    -- a late charge for an earlier purchase arriving now: credit it to that one, not the current one
    local function hit(o) return matches(spent, o.cost) or (o.total and matches(spent, o.total)) end
    if L and spent > 0 and hit(L.o) and not hit(Buy.inflight) then
      Buy.limbo = nil
      RecordPurchase(L.o, spent, L.item, true)
      if Buy.money then Buy.money = Buy.money - spent end
      return
    end
    D("gold changed while buying:", Buy.money and (Buy.money - nowMoney) or "?")
    CheckBought()
    return
  end
  -- late confirmation of a purchase we had given up on
  local L = Buy.limbo
  if L and before and GetTime() - L.t < 60 then
    local spent = before - nowMoney
    if spent > 0 and (matches(spent, L.o.cost) or (L.o.total and matches(spent, L.o.total))) then
      Buy.limbo = nil
      RecordPurchase(L.o, spent, L.item, true)
    end
  end
end

-- Tells us if Blizzard blocked one of our calls (e.g. a purchase not triggered by a real click).
function handlers.ADDON_ACTION_BLOCKED(addon, func)
  if addon ~= ADDON then return end
  if Buy.auto and Buy.item then
    autoFails = 1
    AutoSearchFailed("WoW blocked " .. tostring(func))
    return
  end
  Print("WoW blocked " .. tostring(func) .. ". Use the Buy button or a key bind, not a macro run from chat.")
end
handlers.ADDON_ACTION_FORBIDDEN = handlers.ADDON_ACTION_BLOCKED

function handlers.UI_ERROR_MESSAGE(_, msg)
  if Buy.state ~= "idle" and Buy.state ~= "next" then Print("Game error: " .. tostring(msg)) end
end

function handlers.COMMODITY_PRICE_UPDATED(unitPrice, totalPrice)
  if Buy.state ~= "pricing" then return end
  local o = Buy.offers[1]
  if totalPrice and totalPrice + MinProfit() <= o.value and totalPrice <= GetMoney() then
    o.cost = totalPrice
    SetState("confirm", string.format("Confirm %dx %s - %s", o.qty, ItemName(Buy.item), ShortMoney(totalPrice)))
  else
    C_AuctionHouse.CancelCommoditiesPurchase()
    OnFailed("price changed to " .. Money(totalPrice or 0) .. ", no longer profitable")
  end
end

function handlers.COMMODITY_PRICE_UNAVAILABLE()
  if Buy.state == "pricing" then
    C_AuctionHouse.CancelCommoditiesPurchase()
    OnFailed("price unavailable")
  end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED()
  if Buy.state == "buying" and Buy.inflight and Buy.inflight.kind == "commodity" then CheckBought() end
end

function handlers.COMMODITY_PURCHASE_FAILED()
  if Buy.state == "buying" or Buy.state == "confirm" then OnFailed() end
end

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
  local o = Buy.inflight
  if Buy.state == "buying" and o and o.kind == "item" and auctionID == o.auctionID then CheckBought() end
end

function handlers.BID_ADDED()
  local o = Buy.inflight
  if Buy.state == "buying" and o and o.kind == "bid" then CheckBought() end
end

function handlers.AUCTION_HOUSE_SHOW_ERROR()
  if Buy.state == "buying" or Buy.state == "pricing" then OnFailed() end
end

VS:SetScript("OnEvent", function(self, event, ...)
  local h = handlers[event]
  if not h then return end
  local ok, err = pcall(h, ...)
  if not ok then
    Print("|cffff4040Error (" .. event .. "):|r " .. tostring(err))
    if Buy.item and (Buy.state == "searching" or Buy.state == "pricing") then
      SetState("next", "Search again: " .. ItemName(Buy.item))
    end
  end
end)
for event in pairs(handlers) do
  if event ~= "REPLICATE_ITEM_LIST_UPDATE" then
    pcall(VS.RegisterEvent, VS, event)   -- pcall: tolerate events missing on this client
  end
end

SLASH_VENDORSNIPE1 = "/vsnipe"
SLASH_VENDORSNIPE2 = "/vs"
SlashCmdList.VENDORSNIPE = function(msg)
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  if cmd == "scan" then
    StartScan()
  elseif cmd == "buy" then
    BuyClick()
  elseif cmd == "stop" then
    ResetBuy()
  elseif cmd == "min" then
    local v = ParseMoney(rest)
    if v then VendorSnipeDB.minProfit = v Print("Min profit set to " .. Money(v) .. ".")
    else Print("Usage: /vs min 50s  (or 1g20s, or copper amount)") end
  elseif cmd == "tab" then
    local arg = rest:lower()
    if arg == "off" or arg == "main" then
      VendorSnipeDB.chatMode = "main"
      Print("Messages now go to the main chat window. (You can close the VendorSnipe tab: right-click it > Close Chat Window.)")
    else
      local cf = CreateTab()
      if not cf then
        Print("Couldn't create the chat tab automatically. Right-click a chat tab > Create New Window, name it VendorSnipe, then type /vs tab again.")
        return
      end
      VendorSnipeDB.chatMode = (arg == "both") and "both" or "tab"
      Print(VendorSnipeDB.chatMode == "both" and "Messages now go to the VendorSnipe tab AND the main chat window."
        or "Messages now go only to the VendorSnipe chat tab.")
    end
  elseif cmd == "watch" then
    ToggleWatch()
  elseif cmd == "auto" then
    VendorSnipeDB.autoSearch = VendorSnipeDB.autoSearch == false
    if VendorSnipeDB.autoSearch then autoBlocked, autoFails = false, 0 end
    if ui and ui.autoCheck then ui.autoCheck:SetChecked(VendorSnipeDB.autoSearch) end
    Print("Auto-search " .. (VendorSnipeDB.autoSearch and "ON" or "OFF") .. ".")
  elseif cmd == "sell" then
    ns.SellAll(rest)
  elseif cmd == "keep" then
    ns.KeepCommand(rest)
  elseif cmd == "why" then
    ns.WhyCommand(rest)
  elseif cmd == "sellquest" then
    ns.SellQuestCommand()
  elseif cmd == "diag" then
    local AH = C_AuctionHouse or {}
    local function has(fn) return AH[fn] and "yes" or "|cffff4040MISSING|r" end
    local selected = 0
    for _, r in ipairs(results) do if r.selected and not r.done then selected = selected + 1 end end
    Print("--- diagnostics ---")
    Print("Version: " .. tostring((C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version"))
      .. ", game build: " .. tostring(select(4, GetBuildInfo())))
    Print("AH window open: " .. tostring(AuctionHouseFrame and AuctionHouseFrame:IsShown() or false)
      .. ", legacy AuctionFrame: " .. tostring(AuctionFrame ~= nil))
    Print("ReplicateItems " .. has("ReplicateItems") .. ", SendSearchQuery " .. has("SendSearchQuery")
      .. ", PlaceBid " .. has("PlaceBid"))
    Print("StartCommoditiesPurchase " .. has("StartCommoditiesPurchase") .. ", ConfirmCommoditiesPurchase "
      .. has("ConfirmCommoditiesPurchase") .. ", GetItemCommodityStatus " .. has("GetItemCommodityStatus"))
    Print("Throttle ready: " .. tostring(AH.IsThrottledMessageSystemReady and AH.IsThrottledMessageSystemReady()))
    Print(string.format("Results: %d, selected: %d, buy state: %s, scan phase: %s",
      #results, selected, Buy.state, tostring(phase)))
  elseif cmd == "debug" then
    VendorSnipeDB.debug = not VendorSnipeDB.debug
    Print("Debug log " .. (VendorSnipeDB.debug and "ON" or "OFF") .. ".")
  elseif cmd == "guide" or cmd == "help" then
    ToggleGuide()
  elseif cmd == "reset" then
    VendorSnipeDB.lastScan = 0
    Print("Scan cooldown timer reset (the server may still throttle you).")
  else
    if ui:IsShown() then ui:Hide() else ui:Show() ui:Refresh() end
    Print("Commands: /vs scan, /vs buy, /vs stop, /vs min <amount>, /vs sell, /vs keep [item], /vs tab, /vs reset, /vs guide")
  end
end
