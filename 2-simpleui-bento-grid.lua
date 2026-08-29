local original_require = require
local BENTO_GRID_PATCH_VERSION = "2.1.0"
local BENTO_GRID_SIMPLEUI_API = "screen-engine-v1"

local function safeRequire(modname)
    local ok, mod = pcall(original_require, modname)
    if ok then return mod end
end

local function bentoSettingKey(mod_id)
    return "simpleui_bento_width_" .. tostring(mod_id)
end

local function readBentoWidthPct(mod_id)
    local raw = _G.G_reader_settings and _G.G_reader_settings:readSetting(bentoSettingKey(mod_id))
    local value = tonumber(raw) or 100
    return math.max(20, math.min(100, value))
end

local function patchModernModuleMenus(Registry, ScreenEngine)
    if not Registry or type(Registry.list) ~= "function" then return end
    local UIManager = safeRequire("ui/uimanager")
    local SpinWidget = safeRequire("ui/widget/spinwidget")

    for _, mod in ipairs(Registry.list()) do
        if type(mod.getMenuItems) == "function" and not mod._bento_menu_patched then
            local orig_getMenuItems = mod.getMenuItems
            mod.getMenuItems = function(ctx_menu)
                local items = orig_getMenuItems(ctx_menu)
                if type(items) ~= "table" then return items end
                items[#items + 1] = {
                    text_func = function()
                        return "Bento Grid Column Width (" .. readBentoWidthPct(mod.id) .. "%)"
                    end,
                    keep_menu_open = true,
                    separator = true,
                    callback = function()
                        if not UIManager or not SpinWidget then return end
                        UIManager:show(SpinWidget:new{
                            title_text    = "Bento Grid Column Width",
                            info_text     = "Set the module width used by the Bento Grid.\nModules that fit in the same row are placed side by side.",
                            value         = readBentoWidthPct(mod.id),
                            value_min     = 20,
                            value_max     = 100,
                            value_step    = 5,
                            unit          = "%",
                            ok_text       = "Apply",
                            cancel_text   = "Cancel",
                            default_value = 100,
                            callback      = function(spin)
                                if _G.G_reader_settings then
                                    _G.G_reader_settings:saveSetting(bentoSettingKey(mod.id), spin.value)
                                end
                                if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                                if ScreenEngine and ScreenEngine.rebuildAllLayouts and UIManager.scheduleIn then
                                    UIManager:scheduleIn(0.1, function()
                                        ScreenEngine.rebuildAllLayouts()
                                    end)
                                end
                            end,
                        })
                    end,
                }
                return items
            end
            mod._bento_menu_patched = true
        end
    end
end

-- Override standard require to patch specific KOReader modules as they load.
_G.require = function(modname)
    -- SimpleUI 2.6+ moved homescreen rendering into a shared screen engine.
    -- Use its narrow Bento API instead of replacing the complete _updatePage
    -- implementation, keeping upstream cache and refresh fixes intact.
    if modname == "engines/sui_screen_engine" then
        local loaded = original_require(modname)
        if loaded and type(loaded.installBentoGrid) == "function" and not loaded._bento_patched then
            loaded.installBentoGrid(readBentoWidthPct)
            patchModernModuleMenus(safeRequire("modules/moduleregistry"), loaded)
            loaded._bento_patched = true
        end
        return loaded
    end

    -- =========================================================
    -- Appearance Plugin Compatibility Fix (Color Devices)
    -- =========================================================
    if modname == "appearance.koplugin/book/progress_bar_colors" then
        local loaded = original_require(modname)
        local ProgressWidget = safeRequire("ui/widget/progresswidget")

        if ProgressWidget and type(ProgressWidget) == "table" and not ProgressWidget._bento_shield then
            if type(ProgressWidget.updateStyle) == "function" then
                local unsafe_update = ProgressWidget.updateStyle
                ProgressWidget.updateStyle = function(self, ...)
                    local ok, res = pcall(unsafe_update, self, ...)
                    if ok then return res end
                end
            end

            if type(ProgressWidget._setColors) == "function" then
                local unsafe_set = ProgressWidget._setColors
                ProgressWidget._setColors = function(self, ...)
                    local ok, res = pcall(unsafe_set, self, ...)
                    if ok then return res end
                end
            end
            ProgressWidget._bento_shield = true
        end
        return loaded

    -- =========================================================
    -- Bento Grid Layout Engine for SimpleUI 2.x
    -- =========================================================
    elseif modname == "sui_homescreen" then
        local loaded = original_require(modname)

        local function getUpValue(func, name)
            if type(func) ~= "function" then return nil end
            local i = 1
            while true do
                local n, v = debug.getupvalue(func, i)
                if not n then break end
                if n == name then return v end
                i = i + 1
            end
        end

        local HomescreenWidget = getUpValue(loaded.show, "HomescreenWidget")
        if not HomescreenWidget or loaded._bento_patched then
            return loaded
        end

        local Registry = safeRequire("desktop_modules/moduleregistry")
        local UIManager = safeRequire("ui/uimanager")
        local SpinWidget = safeRequire("ui/widget/spinwidget")
        local HorizontalGroup = safeRequire("ui/widget/horizontalgroup")
        local VerticalGroup = safeRequire("ui/widget/verticalgroup")
        local HorizontalSpan = safeRequire("ui/widget/horizontalspan")
        local Blitbuffer = safeRequire("ffi/blitbuffer")
        local Device = safeRequire("device")

        local function settingKey(mod_id)
            return "simpleui_bento_width_" .. tostring(mod_id)
        end

        local function readWidthPct(mod_id)
            local raw = _G.G_reader_settings and _G.G_reader_settings:readSetting(settingKey(mod_id))
            local value = tonumber(raw) or 100
            if value < 20 then value = 20 end
            if value > 100 then value = 100 end
            return value
        end

        local function patchModuleMenus()
            if not Registry or not Registry.list then return end
            for _, mod in ipairs(Registry.list()) do
                if type(mod.getMenuItems) == "function" and not mod._bento_menu_patched then
                    local orig_getMenuItems = mod.getMenuItems

                    mod.getMenuItems = function(ctx_menu)
                        local items = orig_getMenuItems(ctx_menu)
                        if type(items) == "table" then
                            items[#items + 1] = {
                                text_func = function()
                                    return "Bento Grid Column Width (" .. readWidthPct(mod.id) .. "%)"
                                end,
                                keep_menu_open = true,
                                separator = true,
                                callback = function()
                                    if not UIManager or not SpinWidget then return end
                                    UIManager:show(SpinWidget:new{
                                        title_text    = "Bento Grid Column Width",
                                        info_text     = "Set the module width used by the Bento Grid.\nModules that fit in the same row are placed side by side.",
                                        value         = readWidthPct(mod.id),
                                        value_min     = 20,
                                        value_max     = 100,
                                        value_step    = 5,
                                        unit          = "%",
                                        ok_text       = "Apply",
                                        cancel_text   = "Cancel",
                                        default_value = 100,
                                        callback      = function(spin)
                                            if _G.G_reader_settings then
                                                _G.G_reader_settings:saveSetting(settingKey(mod.id), spin.value)
                                            end
                                            if ctx_menu and ctx_menu.refresh then ctx_menu.refresh() end
                                        end,
                                    })
                                end,
                            }
                        end
                        return items
                    end
                    mod._bento_menu_patched = true
                end
            end
        end

        patchModuleMenus()

        local original_updatePage = HomescreenWidget._updatePage
        if type(original_updatePage) ~= "function" then
            loaded._bento_patched = true
            return loaded
        end

        local deps = {
            Config = getUpValue(original_updatePage, "Config") or safeRequire("sui_config"),
            Registry = getUpValue(original_updatePage, "Registry") or Registry,
            SUISettings = getUpValue(original_updatePage, "SUISettings") or safeRequire("sui_store"),
            Screen = getUpValue(original_updatePage, "Screen") or (Device and Device.screen),
            logger = getUpValue(original_updatePage, "logger") or safeRequire("logger"),
            UI = getUpValue(original_updatePage, "UI") or safeRequire("sui_core"),
            Topbar = safeRequire("sui_topbar"),
            Bottombar = safeRequire("sui_bottombar"),
            PFX = getUpValue(original_updatePage, "PFX") or "simpleui_hs_",
            MOD_GAP = getUpValue(original_updatePage, "MOD_GAP") or 12,
            SIDE_PAD = getUpValue(original_updatePage, "SIDE_PAD") or 20,
            splitOrderIntoPages = getUpValue(original_updatePage, "splitOrderIntoPages"),
            buildEmptyState = getUpValue(original_updatePage, "buildEmptyState"),
            _isLandscape = getUpValue(original_updatePage, "_isLandscape"),
            applyModuleBackground = getUpValue(original_updatePage, "applyModuleBackground"),
            sectionLabel = getUpValue(original_updatePage, "sectionLabel"),
            _updateNavpagerForHS = getUpValue(original_updatePage, "_updateNavpagerForHS"),
            Homescreen = getUpValue(original_updatePage, "Homescreen"),
            EMPTY_H = getUpValue(original_updatePage, "_EMPTY_H") or 80,
        }

        local function logWarn(msg)
            if deps.logger and deps.logger.warn then
                deps.logger.warn(msg)
            end
        end

        local function canUseBento()
            return deps.Config and deps.Registry and deps.SUISettings and deps.Screen
                and deps.splitOrderIntoPages and deps.applyModuleBackground
                and deps.sectionLabel and HorizontalGroup and VerticalGroup
        end

        local function modulePct(mod)
            return readWidthPct(mod and mod.id) / 100
        end

        local function dedupePages(pages)
            local clean_pages = {}
            local fingerprint = {}

            for _, page in ipairs(pages or {}) do
                local page_ids = {}
                local seen = {}

                for _, mod_id in ipairs(page or {}) do
                    if type(mod_id) == "string" and mod_id ~= "" and not seen[mod_id] then
                        seen[mod_id] = true
                        page_ids[#page_ids + 1] = mod_id
                        fingerprint[#fingerprint + 1] = mod_id
                        fingerprint[#fingerprint + 1] = ":"
                        fingerprint[#fingerprint + 1] = tostring(readWidthPct(mod_id))
                        fingerprint[#fingerprint + 1] = ","
                    end
                end

                fingerprint[#fingerprint + 1] = "|"
                clean_pages[#clean_pages + 1] = page_ids
            end

            if #clean_pages == 0 then clean_pages[1] = {} end
            return clean_pages, table.concat(fingerprint)
        end

        local function buildRows(mods)
            local rows = {}
            local row = { cols = {}, total_pct = 0 }

            local function flush()
                if #row.cols > 0 then
                    rows[#rows + 1] = row
                    row = { cols = {}, total_pct = 0 }
                end
            end

            local function startRow(mod, pct)
                row.cols[#row.cols + 1] = { pct = pct, mods = { mod } }
                row.total_pct = pct
            end

            for _, mod in ipairs(mods) do
                local pct = modulePct(mod)
                if pct >= 0.999 then
                    flush()
                    rows[#rows + 1] = {
                        cols = { { pct = 1, mods = { mod } } },
                        total_pct = 1,
                    }
                elseif row.total_pct + pct <= 1.001 then
                    row.cols[#row.cols + 1] = { pct = pct, mods = { mod } }
                    row.total_pct = row.total_pct + pct
                else
                    flush()
                    startRow(mod, pct)
                end
            end
            flush()
            return rows
        end

        local function columnWidths(row, inner_w, gap)
            local count = #row.cols
            local total_pct = row.total_pct
            if total_pct <= 0 then total_pct = 1 end
            local row_w = math.floor(inner_w * math.min(total_pct, 1))
            local available_w = math.max(1, row_w - gap * math.max(0, count - 1))
            local widths = {}
            local used = 0
            for i, col in ipairs(row.cols) do
                local w
                if i == count then
                    w = math.max(1, available_w - used)
                else
                    w = math.max(1, math.floor(available_w * (col.pct / total_pct)))
                    used = used + w
                end
                widths[i] = w
            end
            return widths
        end

        local function widgetHeight(widget)
            if not widget then return 0 end
            local ok, size = pcall(function() return widget:getSize() end)
            if ok and size and size.h then return size.h end
            return (widget.dimen and widget.dimen.h) or 0
        end

        local function strictContentHeight()
            local screen_h = deps.Screen:getHeight()
            local topbar_h = 0
            local navbar_h = 0

            if deps.SUISettings:nilOrTrue("simpleui_topbar_enabled")
                    and deps.Topbar and type(deps.Topbar.TOTAL_TOP_H) == "function" then
                local ok, h = pcall(deps.Topbar.TOTAL_TOP_H)
                if ok and h then topbar_h = h end
            end

            if deps.Bottombar and type(deps.Bottombar.TOTAL_H) == "function" then
                local ok, h = pcall(deps.Bottombar.TOTAL_H)
                if ok and h then navbar_h = h end
            end

            return math.max(0, screen_h - topbar_h - navbar_h)
        end

        local function strictContentTop()
            if deps.SUISettings:nilOrTrue("simpleui_topbar_enabled")
                    and deps.Topbar and type(deps.Topbar.TOTAL_TOP_H) == "function" then
                local ok, h = pcall(deps.Topbar.TOTAL_TOP_H)
                if ok and h then return h end
            end
            return 0
        end

        local function visibleBodyHeight(self, total_pages)
            local strict_h = strictContentHeight()
            local content_h = self._layout_content_h or self._navbar_content_h
            if not content_h and deps.UI and type(deps.UI.getContentHeight) == "function" then
                content_h = deps.UI.getContentHeight()
            end
            content_h = content_h and math.min(content_h, strict_h) or strict_h

            local navpager_on = deps.Config.isNavpagerEnabled and deps.Config.isNavpagerEnabled()
            local dot_on = deps.Config.isDotPagerEnabled and deps.Config.isDotPagerEnabled()
            local pagination_on = deps.SUISettings:nilOrTrue("simpleui_bar_pagination_visible")
            local hs_pagination_hidden = deps.SUISettings:isTrue("simpleui_hs_pagination_hidden")
            local show_footer = not hs_pagination_hidden
                and total_pages > 1
                and (navpager_on or dot_on or pagination_on)

            local footer_h = 0
            if show_footer then
                local footer_widget
                if navpager_on or dot_on then
                    footer_widget = self._footer_dot and self._footer_dot.widget
                else
                    footer_widget = self._footer_chevron and self._footer_chevron.widget
                end
                footer_h = widgetHeight(footer_widget)
                if footer_h <= 0 and deps.Screen.scaleBySize then
                    footer_h = deps.Screen:scaleBySize(28)
                end
            end

            return math.max(0, content_h - footer_h - deps.MOD_GAP)
        end

        local function primeBodyDimensions(body)
            if not (Blitbuffer and body and body.paintTo) then return end
            local w = math.max(1, deps.Screen:getWidth())
            local h = math.max(1, deps.Screen:getHeight())
            local ok, bb = pcall(Blitbuffer.new, w, h, Blitbuffer.TYPE_BB8)
            if not ok or not bb then return end
            pcall(function()
                bb:fill(Blitbuffer.COLOR_WHITE)
                body:paintTo(bb, deps.SIDE_PAD, strictContentTop())
            end)
            pcall(function() bb:free() end)
        end

        local function scheduleStartupSettleRefresh(self)
            if not (UIManager and UIManager.scheduleIn and UIManager.setDirty) then return end
            if self._bento_startup_settle_done or self._bento_startup_settle_scheduled then return end

            self._bento_startup_settle_scheduled = true
            local self_ref = self
            UIManager:scheduleIn(0.12, function()
                self_ref._bento_startup_settle_scheduled = false
                if self_ref._bento_startup_settle_done then return end
                if deps.Homescreen and deps.Homescreen._instance ~= self_ref then return end
                if not self_ref._body then return end

                self_ref._bento_startup_settle_done = true
                self_ref:_updatePage(true)
                UIManager:setDirty(self_ref, "full")
            end)
        end

        local function addModToColumn(self, ctx, col_body, mod, col_w, topbar_on, is_first_in_col, state)
            if not is_first_in_col then
                col_body[#col_body + 1] = self:_vspan(state.mod_gaps[mod.id] or deps.MOD_GAP)
            end

            if mod.has_covers then state.page_has_covers = true end

            local ok_w, widget = pcall(mod.build, col_w, ctx)
            if not ok_w or not widget then
                logWarn("simpleui bento: build failed for " .. tostring(mod.id) .. ": " .. tostring(widget))
                return
            end

            local bg_enabled = deps.Config.isModuleBackgroundEnabled(mod.id, deps.PFX)
            if mod.label and not bg_enabled then
                col_body[#col_body + 1] = deps.sectionLabel(mod.label, col_w, mod.id)
            end

            local has_menu = type(mod.getMenuItems) == "function"
            if mod.id == "header" then
                self._header_body_idx = #col_body + 1
                self._header_body_ref = col_body
                self._header_is_wrapped = has_menu
            end
            if mod.id == "clock" then
                self._clock_body_idx = #col_body + 1
                self._clock_body_ref = col_body
                self._clock_is_wrapped = has_menu
                self._clock_label = mod.label
            end

            local display_widget = deps.applyModuleBackground(mod.id, widget, col_w,
                bg_enabled and mod.label or nil)
            local entry_widget = has_menu
                and self:_makeModWrapper(mod, display_widget, col_w)
                or display_widget
            col_body[#col_body + 1] = entry_widget

            if mod.has_covers and type(mod.updateCovers) == "function" then
                self._cover_mod_slots[mod.id] = {
                    mod = mod,
                    widget = widget,
                }
            end
            if mod.is_book_mod then
                self._book_mod_slots[mod.id] = {
                    mod = mod,
                    widget = widget,
                    parent = col_body,
                    index = #col_body,
                    col_w = col_w,
                    has_menu = has_menu,
                }
            end
            if type(mod.updateStats) == "function" then
                self._stats_mod_slots[mod.id] = { mod = mod, widget = widget }
            end
        end

        local function bentoUpdatePage(self, keep_cache, books_only, stats_only)
            patchModuleMenus()

            local Config = deps.Config
            local Registry = deps.Registry
            local SUISettings = deps.SUISettings
            local Screen = deps.Screen
            local PFX = deps.PFX
            local MOD_GAP = deps.MOD_GAP

            if not canUseBento() then
                return original_updatePage(self, keep_cache, books_only, stats_only)
            end
            if deps._isLandscape and deps._isLandscape() then
                return original_updatePage(self, keep_cache, books_only, stats_only)
            end
            if Screen:getWidth() > Screen:getHeight() then
                return original_updatePage(self, keep_cache, books_only, stats_only)
            end

            -- SimpleUI may re-wrap the homescreen around a fresh navbar/topbar
            -- during startup, resume or reader-close. Keep Bento's cached
            -- geometry in lockstep before measuring modules, otherwise the
            -- first paint can use stale full-screen height and let old content
            -- show through transparent areas until the next page turn.
            do
                local content_h = strictContentHeight()
                if deps.UI and type(deps.UI.getContentHeight) == "function" then
                    local ui_content_h = deps.UI.getContentHeight()
                    if ui_content_h and ui_content_h > 0 then
                        content_h = math.min(content_h, ui_content_h)
                    end
                end
                if content_h and content_h > 0 then
                    self._navbar_content_h = content_h
                    self._layout_content_h = content_h
                    if self._overlap and self._overlap.dimen then
                        self._overlap.dimen.h = content_h
                    end
                    if self._footer_bc and self._footer_bc.dimen then
                        self._footer_bc.dimen.h = content_h
                    end
                    if self._navbar_inner and self._navbar_inner.dimen then
                        self._navbar_inner.dimen.h = content_h
                    end
                end
            end

            if not keep_cache then
                if stats_only then
                    self._ctx_cache = nil
                else
                    self._cached_books_state = nil
                    if not books_only then
                        self._enabled_mods_cache = nil
                        self._ctx_cache = nil
                    end
                end
            end

            local ctx
            if keep_cache and self._ctx_cache then
                ctx = self._ctx_cache
            else
                ctx = self:_buildCtx()
                self._ctx_cache = ctx
            end

            local inner_w = self._layout_inner_w or (Screen:getWidth() - deps.SIDE_PAD * 2)
            local body = self._body
            if not body then return end

            local layout = SUISettings:readSetting("simpleui_layout")
            local raw_order = Registry.loadOrder(PFX)

            local pages_by_id = {}
            if layout and type(layout.pages) == "table" then
                local layout_pages = {}
                for _, page in ipairs(layout.pages) do
                    if page and type(page.modules) == "table" then
                        layout_pages[#layout_pages + 1] = page.modules
                    end
                end
                pages_by_id = layout_pages
            else
                pages_by_id = deps.splitOrderIntoPages(raw_order)
            end
            local layout_fingerprint
            pages_by_id, layout_fingerprint = dedupePages(pages_by_id)

            if not self._enabled_mods_cache
                    or self._enabled_mods_cache.layout_fingerprint ~= layout_fingerprint then
                local has_book_mod = false
                local mod_gaps = {}
                local pages_of_mods = {}

                for _, page_ids in ipairs(pages_by_id) do
                    local page_mods = {}
                    for _, mod_id in ipairs(page_ids) do
                        local mod = Registry.get(mod_id)
                        if mod and Registry.isEnabled(mod, PFX) then
                            page_mods[#page_mods + 1] = mod
                            mod_gaps[mod_id] = Config.getModuleGapPx(mod_id, PFX, MOD_GAP)
                            if mod.is_book_mod then has_book_mod = true end
                        end
                    end
                    pages_of_mods[#pages_of_mods + 1] = page_mods
                end
                if #pages_of_mods == 0 then pages_of_mods[1] = {} end

                local chosen_pages = SUISettings:readSetting(PFX .. "homescreen_num_pages")
                if layout and type(layout.pages) == "table" then chosen_pages = #layout.pages end
                if chosen_pages and chosen_pages > #pages_of_mods then
                    for _ = #pages_of_mods + 1, chosen_pages do
                        pages_of_mods[#pages_of_mods + 1] = {}
                    end
                end

                do
                    local cd = Registry.get("coverdeck")
                    if cd and Registry.isEnabled(cd, PFX) then
                        local found = false
                        for _, pg in ipairs(pages_of_mods) do
                            for _, m in ipairs(pg) do
                                if m.id == "coverdeck" then found = true; break end
                            end
                            if found then break end
                        end
                        if not found then
                            local insert_at = #pages_of_mods[1] + 1
                            for i, m in ipairs(pages_of_mods[1]) do
                                if m.id == "recent" then insert_at = i + 1; break end
                                if m.id == "currently" then insert_at = i + 1 end
                            end
                            table.insert(pages_of_mods[1], insert_at, cd)
                            mod_gaps.coverdeck = Config.getModuleGapPx("coverdeck", PFX, MOD_GAP)
                            if cd.is_book_mod then has_book_mod = true end
                        end
                    end
                end

                local enabled_mods = {}
                for _, pg in ipairs(pages_of_mods) do
                    for _, m in ipairs(pg) do enabled_mods[#enabled_mods + 1] = m end
                end

                self._enabled_mods_cache = {
                    mods = enabled_mods,
                    mod_gaps = mod_gaps,
                    has_book_mod = has_book_mod,
                    total_pages = #pages_of_mods,
                    pages_of_mods = pages_of_mods,
                    layout_fingerprint = layout_fingerprint,
                }
            end

            local has_book_mod = self._enabled_mods_cache.has_book_mod
            local total_pages = self._enabled_mods_cache.total_pages
            local mod_gaps = self._enabled_mods_cache.mod_gaps
            local pages_of_mods = self._enabled_mods_cache.pages_of_mods

            if self._current_page > total_pages then self._current_page = total_pages end
            if self._current_page < 1 then self._current_page = 1 end
            self._total_pages = total_pages
            self.page = self._current_page
            self.page_num = total_pages

            local empty_widget
            if (ctx._show_c or ctx._show_r) and not ctx._has_content and not has_book_mod
                    and deps.buildEmptyState then
                empty_widget = deps.buildEmptyState(inner_w, deps.EMPTY_H)
            end

            body:clear()

            local topbar_on = SUISettings:nilOrTrue("simpleui_topbar_enabled")

            self._header_body_idx = nil
            self._header_inner_w = inner_w
            self._header_body_ref = body
            self._header_is_wrapped = false
            self._clock_body_idx = nil
            self._clock_body_ref = body
            self._stats_mod_slots = {}
            self._book_mod_slots = {}
            self._cover_mod_slots = {}
            self._clock_is_wrapped = false
            self._clock_label = nil

            if not self._cover_poll_timer then
                Config._cover_extract_pending = {}
            end

            local kb_books = {}
            self._kb_first_rec_idx = nil
            ctx.kb_currently_focused = nil
            ctx.kb_recent_focus_idx = nil
            if ctx.current_fp then
                kb_books[#kb_books + 1] = ctx.current_fp
                ctx.kb_currently_focused = (self._kb_focus_idx == #kb_books) or nil
            end
            if ctx.recent_fps and #ctx.recent_fps > 0 then
                local first_rec_idx = #kb_books + 1
                self._kb_first_rec_idx = first_rec_idx
                for ri = 1, #ctx.recent_fps do
                    kb_books[#kb_books + 1] = ctx.recent_fps[ri]
                end
                if self._kb_focus_idx and self._kb_focus_idx >= first_rec_idx
                        and self._kb_focus_idx <= #kb_books then
                    ctx.kb_recent_focus_idx = self._kb_focus_idx - first_rec_idx + 1
                end
            end
            self._kb_book_items_fp = kb_books

            local cur_page_mods = pages_of_mods[self._current_page] or {}
            local first_row = true
            local state = {
                mod_gaps = mod_gaps,
                page_has_covers = false,
            }

            local rows = buildRows(cur_page_mods)
            local COL_GAP = MOD_GAP
            local max_body_h = visibleBodyHeight(self, total_pages)
            local used_body_h = 0

            for _, row in ipairs(rows) do
                local first_mod_in_row = row.cols[1] and row.cols[1].mods and row.cols[1].mods[1]
                local gap_widget
                local gap_h = 0
                if first_mod_in_row then
                    local gap_px = mod_gaps[first_mod_in_row.id] or MOD_GAP
                    if first_row then
                        gap_widget = self:_vspan(topbar_on and gap_px or (gap_px + MOD_GAP))
                    else
                        gap_widget = self:_vspan(gap_px)
                    end
                    gap_h = widgetHeight(gap_widget)
                end

                local widths = columnWidths(row, inner_w, COL_GAP)
                local h_group = HorizontalGroup:new{ align = "top" }
                local added_cols = 0

                for col_idx, col in ipairs(row.cols) do
                    local col_w = widths[col_idx] or inner_w
                    local col_body = VerticalGroup:new{ align = "left" }
                    for mod_idx, mod in ipairs(col.mods) do
                        addModToColumn(self, ctx, col_body, mod, col_w, topbar_on, mod_idx == 1, state)
                    end
                    if #col_body > 0 then
                        if added_cols > 0 then h_group[#h_group + 1] = HorizontalSpan:new{ width = COL_GAP } end
                        h_group[#h_group + 1] = col_body
                        added_cols = added_cols + 1
                    end
                end

                if added_cols > 0 then
                    local row_h = widgetHeight(h_group)
                    local needed_h = gap_h + row_h
                    if used_body_h > 0 and max_body_h > 0
                            and used_body_h + needed_h > max_body_h then
                        state.overflow_clipped = true
                        break
                    end
                    if gap_widget then body[#body + 1] = gap_widget end
                    body[#body + 1] = h_group
                    used_body_h = used_body_h + needed_h
                    first_row = false
                end
            end

            if state.overflow_clipped then
                logWarn("simpleui bento: clipped overflowing homescreen rows on page "
                    .. tostring(self._current_page))
            end

            if ctx.db_conn_fatal and self._db_conn then
                logWarn("simpleui: homescreen: fatal DB error detected - dropping shared connection")
                pcall(function() self._db_conn:close() end)
                self._db_conn = nil
            end

            if empty_widget then
                if first_row then
                    body[#body + 1] = self:_vspan(topbar_on and MOD_GAP or (MOD_GAP * 2))
                end
                body[#body + 1] = empty_widget
            end

            primeBodyDimensions(body)

            self.dithered = state.page_has_covers or nil

            local footer_page = self._current_page
            local footer_total = total_pages
            if self._updateFooter then self:_updateFooter(footer_page, footer_total, topbar_on) end
            if deps._updateNavpagerForHS then deps._updateNavpagerForHS(footer_page, footer_total) end
            scheduleStartupSettleRefresh(self)

            if self._clock_body_idx ~= nil then
                local ClockMod = Registry.get("clock")
                if ClockMod and ClockMod.scheduleRefresh then
                    ClockMod.scheduleRefresh(self)
                end
            end

            if Config.flushCoverQueue then Config.flushCoverQueue() end
            if Config.cover_extraction_pending and not self._cover_poll_timer and self._scheduleCoverPoll then
                self:_scheduleCoverPoll()
            end
        end

        HomescreenWidget._updatePage = function(self, keep_cache, books_only, stats_only)
            return bentoUpdatePage(self, keep_cache, books_only, stats_only)
        end

        loaded._bento_patched = true
        return loaded
    end

    return original_require(modname)
end

return {}
