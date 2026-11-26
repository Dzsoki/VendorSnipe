-- VendorSnipe: "Sell All" at a vendor.
-- Sells every bag item that has a vendor price, except: items with no sell value (e.g. vendor ammo),
-- quest items, locked items, items in an equipment set, and items on the keep list (/vs keep).
local ADDON, ns = ...

local SELL_INTERVAL = 0.3   -- seconds between sales, so the server keeps up
local MAX_PASSES = 3        -- items that didn't sell are retried up to this many passes
local QUEST_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12

local function Print(msg) ns.Print(msg) end
local function Money(c) return ns.Money(c) end

local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local UseItem = (C_Container and C_Container.UseContainerItem) or UseContainerItem

local function LastBag()
  return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4   -- includes the reagent bag on modern clients
end

local function SlotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return nil end
    return info.itemID, info.stackCount or 1, info.hyperlink, info.isLocked, info.hasNoValue
  end
  local _, count, locked, _, _, _, link, _, noValue, itemID = GetContainerItemInfo(bag, slot)
  return itemID, count or 1, link, locked, noValue
end

local function InEquipmentSet(bag, slot)
  local fn = C_Container and C_Container.GetContainerItemEquipmentSetInfo
  if not fn then return false end
  local ok, inSet = pcall(fn, bag, slot)
  return ok and inSet or false
end

local function BagLabel(bag)
  if bag == 0 then return "Backpack" end
  if bag > (NUM_BAG_SLOTS or 4) then return "Reagent bag" end
  return "Bag " .. bag
end

-- Bags chosen for selling. VendorSnipeDB.sellSkipBags[bag] = true excludes that bag (default: all bags).
local function BagEnabled(bag, only)
  if only then return only[bag] == true end
  return not (VendorSnipeDB.sellSkipBags and VendorSnipeDB.sellSkipBags[bag])
end

local function BagListText(only)
  local names = {}
  for bag = 0, LastBag() do
    if (GetNumSlots(bag) or 0) > 0 and BagEnabled(bag, only) then names[#names + 1] = BagLabel(bag) end
  end
  return #names > 0 and table.concat(names, ", ") or "no bags"
end

local function IsKept(itemID)
  return VendorSnipeDB.keep and VendorSnipeDB.keep[itemID]
end

local GetInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local RequestLoad = C_Item and C_Item.RequestLoadItemDataByID

-- Is this bag item needed for / does it start a quest? Uses what the bag itself shows (quest border),
-- NOT the item class: in Classic-style data lots of grey trash (e.g. Soft Bushy Tail) has class "Quest"
-- although it's ordinary vendor trash.
local GetQuestInfo = C_Container and C_Container.GetContainerItemQuestInfo
local function QuestFlag(bag, slot, itemID)
  if GetQuestInfo then
    local ok, q = pcall(GetQuestInfo, bag, slot)
    if ok and type(q) == "table" then
      if q.questID then return "starts a quest" end
      if q.isQuestItem then return "quest item (has a quest border in your bag)" end
      return nil
    end
  end
  -- old clients without that API: fall back to the item class
  local classID = GetInstant and select(6, GetInstant(itemID))
  if classID == QUEST_CLASS then return "quest item" end
  return nil
end

-- Decide for one bag slot. Returns verdict ("sell" or a reason it isn't sold) plus details.
local function Classify(bag, slot)
  local itemID, count, link, locked, noValue = SlotInfo(bag, slot)
  if not itemID then return "empty" end
  if noValue then return "no sell price (the vendor pays nothing for it)", itemID, count, link end
  local quest = QuestFlag(bag, slot, itemID)
  if quest and not VendorSnipeDB.sellQuestItems then return quest, itemID, count, link end
  if IsKept(itemID) then return "on your keep list", itemID, count, link end
  if InEquipmentSet(bag, slot) then return "in an equipment set", itemID, count, link end
  if locked then return "locked (being moved or traded)", itemID, count, link end
  local sellPrice = select(11, ns.GetItemInfo(link or itemID))
  if sellPrice == nil and RequestLoad then pcall(RequestLoad, itemID) end   -- load it for next time
  -- hasNoValue = false already means the vendor pays for it; only skip if the price is known to be 0
  if sellPrice == 0 then return "sell price is 0", itemID, count, link end
  return "sell", itemID, count, link, sellPrice
end

-- Collect everything sellable in the chosen bags: { bag, slot, itemID, count, link, value }
-- `only` (optional) = { [bag] = true } overrides the saved bag choice for one sale.
-- Also returns how many stacks were skipped on purpose.
local function Collect(only)
  local list, total = {}, 0
  local skipped = { kept = 0, set = 0, locked = 0, quest = 0 }
  for bag = 0, LastBag() do
    for slot = 1, (BagEnabled(bag, only) and GetNumSlots(bag) or 0) do
      local verdict, itemID, count, link, sellPrice = Classify(bag, slot)
      if verdict == "sell" then
        local value = (sellPrice or 0) * count
        list[#list + 1] = { bag = bag, slot = slot, itemID = itemID, count = count, link = link,
                            value = value, unknown = sellPrice == nil }
        total = total + value
      elseif verdict == "on your keep list" then skipped.kept = skipped.kept + 1
      elseif verdict == "in an equipment set" then skipped.set = skipped.set + 1
      elseif verdict:sub(1, 6) == "locked" then skipped.locked = skipped.locked + 1
      elseif verdict == "starts a quest" or verdict:sub(1, 10) == "quest item" then skipped.quest = skipped.quest + 1
      end
    end
  end
  table.sort(list, function(a, b) return a.value > b.value end)
  return list, total, skipped
end

local function SkippedText(sk)
  local parts = {}
  if sk.quest > 0 then parts[#parts + 1] = sk.quest .. " quest items" end
  if sk.kept > 0 then parts[#parts + 1] = sk.kept .. " on keep list" end
  if sk.set > 0 then parts[#parts + 1] = sk.set .. " in equipment sets" end
  if sk.locked > 0 then parts[#parts + 1] = sk.locked .. " locked" end
  return #parts > 0 and ("Not sold on purpose: " .. table.concat(parts, ", ") .. ".") or nil
end

---------------------------------------------------------------------------
-- Selling loop
---------------------------------------------------------------------------

-- Sales are only counted when the item has really left its bag slot; gold is measured, not assumed.
local selling, queue, all, ticker, pass, startMoney = false, {}, {}, nil, 1, 0

local function StillThere(e)
  local itemID = SlotInfo(e.bag, e.slot)
  return itemID == e.itemID
end

local function Report(reason)
  local sold, left = 0, {}
  for _, e in ipairs(all) do
    if StillThere(e) then left[#left + 1] = e else sold = sold + 1 end
  end
  local gained = GetMoney() - startMoney
  Print(string.format("Sold %d of %d item stacks, received %s.%s", sold, #all, Money(math.max(gained, 0)),
    reason and (" " .. reason) or ""))
  if #left > 0 then
    Print(string.format("%d stacks are still in your bags:", #left))
    for i = 1, math.min(10, #left) do
      Print("  " .. (left[i].link or ("item:" .. left[i].itemID)))
    end
    if #left > 10 then Print(string.format("  ...and %d more.", #left - 10)) end
    Print("Usual reasons: the game asked for a confirmation (an item you can still refund, or loot you can still trade to your group - check for a popup), or the vendor was busy. Click Sell All again to retry.")
  end
end

local function StopSelling(reason)
  if ticker then ticker:Cancel() ticker = nil end
  if selling then
    selling = false
    Report(reason)
  end
end

local function SellNext()
  if not (MerchantFrame and MerchantFrame:IsShown()) then
    StopSelling("Vendor window closed, stopped.")
    return
  end
  local e = table.remove(queue, 1)
  if not e then
    -- pass finished: after a short pause, retry what's still in its slot
    if ticker then ticker:Cancel() ticker = nil end
    C_Timer.After(1, function()
      if not selling then return end
      local again = {}
      for _, x in ipairs(all) do
        if StillThere(x) then again[#again + 1] = x end
      end
      if #again == 0 or pass >= MAX_PASSES then StopSelling() return end
      pass = pass + 1
      ns.Debug("sell pass", pass, "retrying", #again, "stacks")
      for i, x in ipairs(again) do queue[i] = x end
      ticker = C_Timer.NewTicker(SELL_INTERVAL, SellNext)
    end)
    return
  end
  -- Make sure the slot still holds the same item (bags may have changed since the list was made).
  local itemID, _, _, locked = SlotInfo(e.bag, e.slot)
  if itemID == e.itemID and not locked then
    UseItem(e.bag, e.slot)
  end
end

local function StartSelling(list)
  if selling then return end
  wipe(queue); wipe(all)
  for i, e in ipairs(list) do queue[i] = e all[i] = e end
  selling, pass, startMoney = true, 1, GetMoney()
  ticker = C_Timer.NewTicker(SELL_INTERVAL, SellNext)
end

StaticPopupDialogs["VENDORSNIPE_SELLALL"] = {
  text = "%s",
  button1 = YES or "Yes",
  button2 = NO or "No",
  OnAccept = function(self, data) StartSelling(data) end,
  timeout = 0,
  whileDead = false,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- args (optional): bag numbers for this sale only, e.g. "0 2" = Backpack and Bag 2.
function ns.SellAll(args)
  if not (MerchantFrame and MerchantFrame:IsShown()) then
    Print("Open a vendor first.")
    return
  end
  if selling then Print("Already selling.") return end
  local only
  if type(args) == "string" then
    for n in args:gmatch("%d+") do
      only = only or {}
      only[tonumber(n)] = true
    end
  end
  local list, total, skipped = Collect(only)
  local bags = BagListText(only)
  local skipText = SkippedText(skipped)
  if #list == 0 then
    Print("Nothing to sell in " .. bags .. " (items without a sell price are never sold).")
    if skipText then Print(skipText) end
    return
  end
  local unknown = 0
  for _, e in ipairs(list) do if e.unknown then unknown = unknown + 1 end end
  Print(string.format("About to sell %d item stacks from %s for %s%s. Most valuable:", #list, bags, Money(total),
    unknown > 0 and string.format(" + %d not priced yet", unknown) or ""))
  for i = 1, math.min(10, #list) do
    local e = list[i]
    Print(string.format("  %s x%d - %s", e.link or ("item:" .. e.itemID), e.count, e.unknown and "price loading" or Money(e.value)))
  end
  if #list > 10 then Print(string.format("  ...and %d more.", #list - 10)) end
  if skipText then Print(skipText) end
  local text = string.format("Sell %d item stacks for %s?\n\nFrom: %s\n\nThe list is in chat. Only the last 12 sold items can be bought back.\nProtect items with /vs keep [item link].",
    #list, Money(total), bags)
  StaticPopup_Show("VENDORSNIPE_SELLALL", text, nil, list)
end

---------------------------------------------------------------------------
-- /vs why [item link or ID]: explain for every stack of that item why it is / isn't sold
---------------------------------------------------------------------------

function ns.WhyCommand(rest)
  local id = rest and (tonumber(rest) or tonumber(rest:match("item:(%d+)")))
  if not id then Print("Usage: /vs why [shift-click an item from your bags]") return end
  local found = 0
  for bag = 0, LastBag() do
    for slot = 1, (GetNumSlots(bag) or 0) do
      local itemID = SlotInfo(bag, slot)
      if itemID == id then
        found = found + 1
        local verdict, _, count, link, sellPrice = Classify(bag, slot)
        local where = BagLabel(bag) .. " slot " .. slot
        if verdict == "sell" then
          if BagEnabled(bag) then
            Print(string.format("%s x%d (%s): WILL be sold%s.", link or ("item:" .. id), count, where,
              sellPrice and (" for " .. Money(sellPrice * count)) or " (price still loading)"))
          else
            Print(string.format("%s x%d (%s): not sold - %s is unticked under 'Sell from'.", link or ("item:" .. id), count, where, BagLabel(bag)))
          end
        else
          Print(string.format("%s x%d (%s): not sold - %s.", link or ("item:" .. id), count, where, verdict))
        end
      end
    end
  end
  if found == 0 then Print("That item isn't in your bags.") end
end

function ns.SellQuestCommand()
  VendorSnipeDB.sellQuestItems = not VendorSnipeDB.sellQuestItems or nil
  Print(VendorSnipeDB.sellQuestItems
    and "Sell All will now ALSO sell quest items that have a sell price (quest border / quest starters). Type /vs sellquest again to protect them."
    or "Quest items (quest border / quest starters) are protected again and won't be sold.")
end

---------------------------------------------------------------------------
-- Keep list: /vs keep [item link or ID]   /vs keep  (lists)
---------------------------------------------------------------------------

function ns.KeepCommand(rest)
  VendorSnipeDB.keep = VendorSnipeDB.keep or {}
  local id = rest and (tonumber(rest) or tonumber(rest:match("item:(%d+)")))
  if not id then
    local any = false
    for itemID in pairs(VendorSnipeDB.keep) do
      if not any then Print("Keep list (never sold):") any = true end
      local _, link = ns.GetItemInfo(itemID)
      Print("  " .. (link or ("item:" .. itemID)))
    end
    if not any then Print("Keep list is empty. Add items with /vs keep [shift-click an item].") end
    return
  end
  local _, link = ns.GetItemInfo(id)
  if VendorSnipeDB.keep[id] then
    VendorSnipeDB.keep[id] = nil
    Print((link or ("item:" .. id)) .. " removed from the keep list.")
  else
    VendorSnipeDB.keep[id] = true
    Print((link or ("item:" .. id)) .. " added to the keep list. It will never be sold.")
  end
end

---------------------------------------------------------------------------
-- Button on the vendor window
---------------------------------------------------------------------------

local button
local f = CreateFrame("Frame")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")
f:SetScript("OnEvent", function(_, event)
  if event == "MERCHANT_CLOSED" then
    StopSelling("Vendor window closed, stopped.")
    return
  end
  if not button and MerchantFrame then
    button = CreateFrame("Button", "VendorSnipeSellAllButton", MerchantFrame, "UIPanelButtonTemplate")
    button:SetSize(150, 24)
    button:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 4, -30)
    button:SetText("VendorSnipe: Sell All")
    button:SetScript("OnClick", function() ns.SellAll() end)
    button:SetScript("OnEnter", function(self)
      local list, total = Collect()
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Sell All")
      GameTooltip:AddLine(string.format("%d item stacks, worth %s", #list, Money(total)), 1, 1, 1)
      GameTooltip:AddLine("From: " .. BagListText(), 1, 1, 1, true)
      GameTooltip:AddLine("Skips: no sell price (e.g. vendor ammo), quest items (quest border / quest starters), equipment sets, keep list.", 0.7, 0.7, 0.7, true)
      GameTooltip:AddLine("Item not sold? Type /vs why and shift-click it.", 0.7, 0.7, 0.7, true)
      GameTooltip:AddLine("You'll be asked to confirm first.", 0.7, 0.7, 0.7)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    -- "Sell from:" bag tick boxes under the button
    local label = MerchantFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 2, -6)
    label:SetText("Sell from:")
    button.bagChecks = {}
    local prev = label
    for bag = 0, LastBag() do
      local cb = CreateFrame("CheckButton", nil, button, "UICheckButtonTemplate")
      cb:SetSize(22, 22)
      cb:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", prev == label and -2 or 0, prev == label and -2 or 2)
      cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      cb.text:SetPoint("LEFT", cb, "RIGHT", 0, 0)
      cb:SetScript("OnClick", function(self)
        VendorSnipeDB.sellSkipBags = VendorSnipeDB.sellSkipBags or {}
        VendorSnipeDB.sellSkipBags[bag] = not self:GetChecked() or nil
      end)
      cb:SetScript("OnEnter", function(self)
        local list, total = Collect({ [bag] = true })
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(BagLabel(bag))
        local name = C_Container and C_Container.GetBagName and C_Container.GetBagName(bag)
        if name then GameTooltip:AddLine(name, 0.7, 0.7, 0.7) end
        GameTooltip:AddLine(string.format("%d sellable stacks, worth %s", #list, Money(total)), 1, 1, 1)
        GameTooltip:Show()
      end)
      cb:SetScript("OnLeave", GameTooltip_Hide)
      button.bagChecks[bag] = cb
      prev = cb
    end
  end
  -- refresh tick boxes: saved choice, disable empty bag slots
  if button and button.bagChecks then
    for bag, cb in pairs(button.bagChecks) do
      local slots = GetNumSlots(bag) or 0
      cb:SetChecked(BagEnabled(bag))
      cb:SetEnabled(slots > 0)
      cb.text:SetText(BagLabel(bag) .. (slots > 0 and "" or " |cff808080(none)|r"))
    end
  end
end)
