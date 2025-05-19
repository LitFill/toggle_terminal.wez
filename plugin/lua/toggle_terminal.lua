--[[
  Manages a toggleable terminal pane per tab.
  Provides keybindings to create/show/hide the pane.
--]]

local wezterm = require("wezterm")
local act = wezterm.action -- Not strictly used after refactor but good to keep if adding more actions
local mux = wezterm.mux

local M = {}

M.opts = {
    key = ";",
    mods = "CTRL",
    direction = "Up",
    size = { Percent = 20 },
    change_invoker_id_everytime = false,
    zoom = {
        auto_zoom_toggle_terminal = false,
        auto_zoom_invoker_pane = true,
        remember_zoomed = true,
    },
    debug_logging = false, -- Set to true for verbose logging
}

local STATE_DIR_NAME = "wezterm_toggle_pane_state"
local STATE_DIR = wezterm.config_dir .. "/" .. STATE_DIR_NAME

local tab_states = {} -- { [tab_id] = { pane_id = -1, invoker_id = -1, zoomed = false }, ... }
local setup_has_run = false
local dir_check_ok = false -- Flag to avoid repeated os.execute for dir check

-- Logging helpers
local function log_debug(...) if M.opts.debug_logging then wezterm.log_info("[TogglePane D] " .. string.format(...)) end end
local function log_info(...) wezterm.log_info("[TogglePane I] " .. string.format(...)) end
local function log_warn(...) wezterm.log_warn("[TogglePane W] " .. string.format(...)) end
local function log_error(...) wezterm.log_error("[TogglePane E] " .. string.format(...)) end

local function ensure_state_directory_exists()
    if dir_check_ok then return true end

    -- Attempt to access a dummy file to check if directory exists and is accessible
    local test_file_path = STATE_DIR .. "/.access_check"
    local test_file = io.open(test_file_path, "r")
    if test_file then
        test_file:close()
        log_debug("State directory %s already exists and is accessible.", STATE_DIR)
        dir_check_ok = true
        return true
    end

    log_info("State directory %s does not exist or is not accessible, attempting to create...", STATE_DIR)
    local command = string.format("mkdir -p %q", STATE_DIR)
    local exec_ok, _, code = os.execute(command) -- Use placeholder for potential stdout string

    local success = false
    if exec_ok == true and code == 0 then -- Typical POSIX success
        success = true
    elseif exec_ok == nil and code == 0 then -- Some Windows cmd shell success cases
        success = true
    end

    if success then
        log_info("Successfully created state directory: %s", STATE_DIR)
        dir_check_ok = true
        return true
    else
        -- Fallback: Check again if it exists, mkdir might have worked despite unclear return values.
        local verify_file = io.open(test_file_path, "w") -- Try to write
        if verify_file then
            verify_file:close()
            os.remove(test_file_path) -- Clean up test file
            log_info("State directory %s created (verified by write test).", STATE_DIR)
            dir_check_ok = true
            return true
        end
        log_error(
            "Failed to create state directory: %s - Command: %s - Exec OK: %s - Code: %s",
            STATE_DIR, command, tostring(exec_ok), tostring(code)
        )
        return false
    end
end

local function get_state_file_path(tab_id)
    return string.format("%s/tab_%s.json", STATE_DIR, tab_id)
end

local function load_tab_state_from_file(tab_id)
    local file_path = get_state_file_path(tab_id)
    local file, err_open = io.open(file_path, "r")
    if not file then
        log_debug("State file not found for tab %s: %s", tab_id, tostring(err_open))
        return nil
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        log_warn("State file for tab %s is empty, deleting: %s", tab_id, file_path)
        os.remove(file_path)
        return nil
    end

    local success_decode, data = pcall(wezterm.json_decode, content)
    if not success_decode or type(data) ~= "table" then
        log_error("Failed to parse JSON from state file %s for tab %s: %s. Deleting corrupt file.", file_path, tab_id, tostring(data))
        os.remove(file_path)
        return nil
    end

    if data.tab_id ~= tab_id then
        log_warn("State file %s for tab %s contains mismatched tab_id %s. Discarding and deleting.", file_path, tab_id, tostring(data.tab_id))
        os.remove(file_path)
        return nil
    end

    if not data.state or type(data.state.pane_id) ~= "number" or type(data.state.invoker_id) ~= "number" or type(data.state.zoomed) ~= "boolean" then
        log_warn("State file %s for tab %s has malformed state structure. Discarding and deleting.", file_path, tab_id)
        os.remove(file_path)
        return nil
    end

    -- Validate toggle pane_id
    if data.state.pane_id ~= -1 then
        local s, p = pcall(mux.get_pane, data.state.pane_id)
        if not (s and p and p:tab():tab_id() == tab_id) then
            log_info("Toggle pane %s from state file for tab %s no longer valid/exists. Discarding state.", data.state.pane_id, tab_id)
            os.remove(file_path)
            return nil -- Whole state is invalid if its primary pane is gone
        end
    end
    -- Validate invoker_id (more leniently, just reset if invalid)
    if data.state.invoker_id ~= -1 then
         local s, p = pcall(mux.get_pane, data.state.invoker_id)
        if not (s and p and p:tab():tab_id() == tab_id) then
            log_info("Invoker pane %s from state file for tab %s no longer valid/exists. Setting to -1.", data.state.invoker_id, tab_id)
            data.state.invoker_id = -1
        end
    end

    log_debug("Loaded state for tab %s from %s: pane_id=%s, invoker_id=%s, zoomed=%s",
        tab_id, file_path, data.state.pane_id, data.state.invoker_id, data.state.zoomed)
    return data.state
end

local function save_tab_state_to_file(tab_id, state)
    if not dir_check_ok then
        log_error("Cannot save state for tab %s, state directory not initialized/accessible.", tab_id)
        return
    end

    local file_path = get_state_file_path(tab_id)
    local pane_is_valid = false
    if state.pane_id and state.pane_id ~= -1 then
        local s, p = pcall(mux.get_pane, state.pane_id)
        if s and p and p:tab():tab_id() == tab_id then
            pane_is_valid = true
        else
            log_debug("Attempted to save state for invalid/mismatched pane ID %s for tab %s.", tostring(state.pane_id), tab_id)
        end
    end

    if not pane_is_valid then
        log_debug("Toggle pane for tab %s is invalid or -1. Deleting state file: %s", tab_id, file_path)
        local remove_ok, remove_err = os.remove(file_path)
        if not remove_ok then
            -- Error messages for "file not found" vary. Check common ones.
            local err_str = tostring(remove_err)
            if not (err_str:find("No such file or directory") or err_str:find("The system cannot find the file specified")) then
                 log_warn("Problem deleting state file %s: %s", file_path, err_str)
            end
        end
        return
    end

    local data_to_save = { tab_id = tab_id, timestamp = os.time(), state = state }
    local success_encode, json_string = pcall(wezterm.json_encode, data_to_save)
    if not success_encode then
        log_error("Failed to encode JSON state for tab %s: %s. Deleting potentially corrupt file.", tab_id, tostring(json_string))
        os.remove(file_path)
        return
    end

    log_debug("Saving state for tab %s to %s: pane_id=%s, invoker_id=%s, zoomed=%s", tab_id, file_path, state.pane_id, state.invoker_id, state.zoomed)
    local file, err_open = io.open(file_path, "w")
    if not file then
        log_error("Failed to open state file %s for writing for tab %s: %s", file_path, tab_id, tostring(err_open))
        return
    end

    local write_ok, write_err = file:write(json_string)
    if not write_ok then
        log_error("Failed to write to state file %s for tab %s: %s", file_path, tab_id, tostring(write_err))
    end
    file:close()
end

local function get_tab_state(tab_id)
    if not tab_states[tab_id] then
        log_debug("In-memory state for tab %s not found. Attempting to load.", tab_id)
        local loaded_state = load_tab_state_from_file(tab_id)
        if loaded_state then
            tab_states[tab_id] = loaded_state
        else
            log_debug("No valid persisted state for tab %s. Initializing new state.", tab_id)
            tab_states[tab_id] = { pane_id = -1, invoker_id = -1, zoomed = false }
        end
    end
    return tab_states[tab_id]
end

local function reset_tab_state_completely(tab_id)
    log_debug("Completely resetting state for tab %s.", tab_id)
    local empty_state = { pane_id = -1, invoker_id = -1, zoomed = false }
    tab_states[tab_id] = empty_state
    save_tab_state_to_file(tab_id, empty_state) -- This will delete the file
end

local function get_pane_if_valid(pane_id, expected_tab_id)
    if pane_id == -1 then return nil end
    local success_get, pane_obj = pcall(mux.get_pane, pane_id)
    if success_get and pane_obj then
        local success_tab_check, pane_tab_id = pcall(function() return pane_obj:tab():tab_id() end)
        if success_tab_check and pane_tab_id == expected_tab_id then
            return pane_obj
        else
            log_warn("Pane %s found, but belongs to tab %s (expected %s) or tab info error. Considered invalid.",
                pane_id, tostring(pane_tab_id), expected_tab_id)
            return nil
        end
    end
    return nil
end

local function activate_pane_and_handle_zoom(pane_to_activate, tab_obj, should_zoom_pane)
    local success_op = pcall(function()
        if tab_obj:get_zoomed_pane() then
             tab_obj:set_zoomed(false)
        end
        pane_to_activate:activate()
        if should_zoom_pane then
            tab_obj:set_zoomed(true)
        end
    end)
    if not success_op then
        log_error("Failed to activate pane %s or set zoom.", pane_to_activate:pane_id())
        return false
    end
    return true
end

function M.toggle_terminal(window, current_pane)
    if not setup_has_run or not dir_check_ok then
        log_error("TogglePane module not properly initialized. Aborting toggle.")
        wezterm.notify.error("TogglePane Error", "Module not initialized. Check logs.")
        return
    end

    local current_pane_id = current_pane:pane_id()
    local current_tab = current_pane:tab()
    local current_tab_id = current_tab:tab_id()

    log_debug("Toggle: current_pane=%s, current_tab=%s", current_pane_id, current_tab_id)

    local tab_state = get_tab_state(current_tab_id)
    local existing_toggle_pane_id = tab_state.pane_id

    -- Determine invoker pane logic
    if current_pane_id ~= existing_toggle_pane_id then
        if tab_state.invoker_id == -1 or M.opts.change_invoker_id_everytime then
            if tab_state.invoker_id ~= current_pane_id then
                log_debug("Updating invoker for tab %s to %s.", current_tab_id, current_pane_id)
                tab_state.invoker_id = current_pane_id
            end
        end
    end
    if tab_state.invoker_id == -1 then
        if current_pane_id ~= existing_toggle_pane_id or existing_toggle_pane_id == -1 then
            log_debug("Setting invoker for tab %s to %s (invoker was -1).", current_tab_id, current_pane_id)
            tab_state.invoker_id = current_pane_id
        else
            log_warn("Invoker for tab %s is -1, but current pane %s is the toggle pane. Expecting reset.", current_tab_id, current_pane_id)
        end
    end

    local toggle_pane_obj = get_pane_if_valid(tab_state.pane_id, current_tab_id)

    if toggle_pane_obj then -- Toggle pane exists and is valid
        if current_pane_id == toggle_pane_obj:pane_id() then -- We are in the toggle pane
            log_debug("Currently in toggle pane %s. Switching to invoker %s.", tab_state.pane_id, tab_state.invoker_id)
            local invoker_pane_obj = get_pane_if_valid(tab_state.invoker_id, current_tab_id)
            if invoker_pane_obj then
                if M.opts.zoom.remember_zoomed then
                    local current_zoomed_pane_obj = current_tab:get_zoomed_pane()
                    tab_state.zoomed = current_zoomed_pane_obj and current_zoomed_pane_obj:pane_id() == toggle_pane_obj:pane_id() or false
                    log_debug("Toggle pane %s zoom state remembered: %s", toggle_pane_obj:pane_id(), tab_state.zoomed)
                end
                activate_pane_and_handle_zoom(invoker_pane_obj, current_tab, M.opts.zoom.auto_zoom_invoker_pane)
                save_tab_state_to_file(current_tab_id, tab_state)
            else
                log_warn("Invoker pane %s for tab %s invalid/not found. Resetting state and retrying.", tostring(tab_state.invoker_id), current_tab_id)
                reset_tab_state_completely(current_tab_id)
                M.toggle_terminal(window, current_pane) -- Retry with clean state
            end
        else -- Toggle pane exists, but we are in another pane (presumably invoker)
            log_debug("Currently in pane %s. Activating toggle pane %s.", current_pane_id, tab_state.pane_id)
            local should_zoom_toggle = (tab_state.zoomed and M.opts.zoom.remember_zoomed) or M.opts.zoom.auto_zoom_toggle_terminal
            activate_pane_and_handle_zoom(toggle_pane_obj, current_tab, should_zoom_toggle)
            save_tab_state_to_file(current_tab_id, tab_state) -- Save, as activation might have implicit side effects or for consistency
        end
    else -- Toggle pane does not exist or was invalid
        log_info("Toggle pane for tab %s not found or invalid. Creating new one.", current_tab_id)
        if tab_state.pane_id ~= -1 then -- An invalid pane_id was stored
            log_debug("Previous toggle pane_id %s was invalid. Clearing before creating new.", tab_state.pane_id)
            tab_state.pane_id = -1
            tab_state.zoomed = false
        end

        if tab_state.invoker_id == -1 then -- Ensure invoker is set to current pane if still -1
            log_debug("Setting invoker to current pane %s before split as it was -1.", current_pane_id)
            tab_state.invoker_id = current_pane_id
        end

        local new_pane_obj = current_pane:split({ direction = M.opts.direction, size = M.opts.size })
        if new_pane_obj then
            tab_state.pane_id = new_pane_obj:pane_id()
            log_info("Created new toggle pane %s for tab %s. Invoker: %s.", tab_state.pane_id, current_tab_id, tab_state.invoker_id)

            if M.opts.zoom.auto_zoom_toggle_terminal then
                current_tab:set_zoomed(true)
                tab_state.zoomed = true
            else
                tab_state.zoomed = false
            end
            save_tab_state_to_file(current_tab_id, tab_state)
        else
            log_error("Failed to create new toggle pane in tab %s via split().", current_tab_id)
            reset_tab_state_completely(current_tab_id)
        end
    end
end

function M.setup(user_opts)
    if user_opts then
        local function merge_opts_recursive(target, source)
            for k, v_source in pairs(source) do
                local v_target = target[k]
                if type(v_source) == "table" and type(v_target) == "table" then
                    merge_opts_recursive(v_target, v_source)
                elseif target[k] ~= nil then -- Only overwrite if key exists in current target options
                     target[k] = v_source
                end
            end
        end
        merge_opts_recursive(M.opts, user_opts)
    end

    if setup_has_run then return end

    log_info("TogglePane module setup. Debug logging: %s", M.opts.debug_logging)
    if not ensure_state_directory_exists() then
        log_error("TogglePane module disabled: state directory %s problem.", STATE_DIR)
        M.toggle_terminal = function()
            log_error("TogglePane: Not initialized (state directory error).")
            wezterm.notify.error("TogglePane Error", "Module not initialized due to directory error. See logs.")
        end
    end
    setup_has_run = true
end

-- Event handlers for cleanup
wezterm.on("pane-removed", function(window, pane)
    if not pane or not setup_has_run or not dir_check_ok then return end

    local removed_pane_id, tab_id
    local p_ok, p_err = pcall(function()
        removed_pane_id = pane:pane_id()
        tab_id = pane:tab():tab_id() -- This can error if tab is already gone
    end)

    if not p_ok then
        log_warn("pane-removed: Error accessing pane details (pane/tab likely already gone): %s", tostring(p_err))
        -- Try to iterate all known states if specific tab_id could not be obtained
        for t_id, t_state in pairs(tab_states) do
            if t_state.pane_id == removed_pane_id or t_state.invoker_id == removed_pane_id then
                log_info("Pane %s (could not get tab context) found in tab_state %s. Resetting.", removed_pane_id, t_id)
                if t_state.pane_id == removed_pane_id then t_state.pane_id = -1; t_state.zoomed = false; end
                if t_state.invoker_id == removed_pane_id then t_state.invoker_id = -1; end
                save_tab_state_to_file(t_id, t_state)
                if t_state.pane_id == -1 and t_state.invoker_id == -1 then tab_states[t_id] = nil; end
            end
        end
        return
    end

    log_debug("pane-removed: pane %s from tab %s", removed_pane_id, tab_id)

    local tab_state = tab_states[tab_id]
    if tab_state then
        local state_changed = false
        if tab_state.pane_id == removed_pane_id then
            log_info("Toggle pane %s for tab %s removed. Clearing its specific state.", removed_pane_id, tab_id)
            tab_state.pane_id = -1
            tab_state.zoomed = false
            state_changed = true
            if tab_state.invoker_id == removed_pane_id then tab_state.invoker_id = -1; end -- Also reset invoker if it was same
        elseif tab_state.invoker_id == removed_pane_id then
            log_info("Invoker pane %s for tab %s removed. Resetting invoker_id.", removed_pane_id, tab_id)
            tab_state.invoker_id = -1
            state_changed = true
        end

        if state_changed then
            save_tab_state_to_file(tab_id, tab_state)
            if tab_state.pane_id == -1 and tab_state.invoker_id == -1 then
                log_debug("Tab %s state fully reset due to pane removal. Removing from memory.", tab_id)
                tab_states[tab_id] = nil
            end
        end
    end
end)

wezterm.on("tab-removed", function(tab, _pane)
    if not tab or not setup_has_run or not dir_check_ok then return end
    local tab_id
    local t_ok, t_err = pcall(function() tab_id = tab:tab_id() end)
    if not t_ok then
        log_warn("tab-removed: Error accessing tab details: %s", tostring(t_err))
        return
    end

    log_debug("tab-removed: tab %s", tab_id)
    if tab_states[tab_id] then
        log_info("Tab %s removed. Deleting associated toggle pane state file and in-memory state.", tab_id)
        save_tab_state_to_file(tab_id, { pane_id = -1, invoker_id = -1, zoomed = false }) -- Triggers file deletion
        tab_states[tab_id] = nil
    end
end)

return M
