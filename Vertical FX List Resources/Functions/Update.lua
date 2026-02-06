-- Update mechanism for Vertical FX List
-- Downloads and updates files from GitHub repository

-- Ensure reaper is available
if not r then r = reaper end

-- Configuration
local UPDATE_REPO = {
    user = "BryanChi",
    repo = "Vertical-FX-List",
    branch = "main"
}

-- Update state (make it accessible globally)
UpdateState = UpdateState or {
    checking = false,
    downloading = false,
    progress = 0.0,
    status_message = "",
    error_message = "",
    latest_release_tag = nil,
    current_release_tag = nil, -- Release tag from version.txt
    selected_release_tag = nil, -- User-selected release from dropdown
    releases = {}, -- List of all releases
    update_available = false,
    files_to_update = {},
    auto_checked = false, -- Track if auto-check has been done on startup
    show_update_icon = false -- Whether to show update icon in menu bar
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

local function GetPathSeparator()
    local OS = r.GetOS()
    if OS:match("Win") then
        return "\\"
    else
        return "/"
    end
end

local function NormalizePath(path)
    local sep = GetPathSeparator()
    return path:gsub("/", sep):gsub("\\", sep)
end

local function GetDirectoryFromPath(filepath)
    local sep = GetPathSeparator()
    local dir = filepath:match("^(.+)" .. sep .. "[^" .. sep .. "]+$")
    return dir or ""
end

local function EnsureDirectoryExists(dir_path)
    if dir_path == "" or dir_path == nil then
        return true
    end
    local normalized = NormalizePath(dir_path)
    local success = r.RecursiveCreateDirectory(normalized, 0)
    return success ~= nil
end

-- URL encode function - converts spaces and special characters to URL-safe format
local function URLEncode(str)
    if not str then return "" end
    -- Encode each path segment separately
    local parts = {}
    for part in str:gmatch("([^/]+)") do
        -- Encode all special characters at once, including spaces
        part = part:gsub("([^%w%-%.%_%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        table.insert(parts, part)
    end
    return table.concat(parts, "/")
end

-- Build raw GitHub URL for a file
local function GetRepoRawBase()
    local ref = UpdateState.selected_release_tag or UpdateState.latest_release_tag or UPDATE_REPO.branch
    return string.format("https://raw.githubusercontent.com/%s/%s/%s", 
                         UPDATE_REPO.user, UPDATE_REPO.repo, ref)
end

-- ============================================================================
-- GITHUB API FUNCTIONS
-- ============================================================================

-- Fetch all releases from GitHub API
local function FetchReleases()
    local url = string.format("https://api.github.com/repos/%s/%s/releases", 
                              UPDATE_REPO.user, UPDATE_REPO.repo)
    
    local OS = r.GetOS()
    local cmd
    if OS:match("Win") then
        cmd = string.format('curl -s -H "Accept: application/vnd.github.v3+json" "%s"', url)
    else
        cmd = string.format('/usr/bin/curl -s -H "Accept: application/vnd.github.v3+json" "%s"', url)
    end
    
    local result = r.ExecProcess(cmd, 10000)
    if not result or result == "" then
        local handle = io.popen(cmd, "r")
        if handle then
            local lines = {}
            for line in handle:lines() do
                table.insert(lines, line)
            end
            result = table.concat(lines, "\n")
            handle:close()
        end
    end
    
    if not result or result == "" then
        return nil, "Failed to fetch releases (empty response)"
    end
    
    -- Clean up response: remove any leading non-JSON characters
    local json_start = result:find("[%[%{]")
    if json_start and json_start > 1 then
        result = result:sub(json_start)
    end
    
    -- Check for API errors
    if result:match('"message"') and result:match('"documentation_url"') then
        local error_msg = result:match('"message":"([^"]+)"')
        return nil, error_msg or "GitHub API error"
    end
    
    -- Check if response starts with array bracket
    if not result:match("^%s*%[") then
        return nil, "Invalid response format (expected JSON array)"
    end
    
    -- Parse releases JSON
    local releases = {}
    local pos = 1
    
    while true do
        -- Find "tag_name" field
        local tag_start = result:find('"tag_name"', pos)
        if not tag_start then break end
        
        -- Find colon after "tag_name"
        local colon = result:find(':', tag_start)
        if not colon then break end
        
        -- Find opening quote
        local quote = colon + 1
        while quote <= #result and result:sub(quote, quote):match("%s") do
            quote = quote + 1
        end
        
        if result:sub(quote, quote) == '"' then
            local tag_end = result:find('"', quote + 1)
            if tag_end then
                local tag = result:sub(quote + 1, tag_end - 1)
                
                -- Extract version from tag (remove 'v' prefix if present)
                local version = tag:match("^v?(.+)$") or tag
                
                -- Extract release name if available
                local name_start = result:find('"name"%s*:%s*"', tag_start)
                local name = tag
                if name_start then
                    local name_colon = result:find(':', name_start)
                    if name_colon then
                        local name_quote = name_colon + 1
                        while name_quote <= #result and result:sub(name_quote, name_quote):match("%s") do
                            name_quote = name_quote + 1
                        end
                        if result:sub(name_quote, name_quote) == '"' then
                            local name_quote_end = result:find('"', name_quote + 1)
                            if name_quote_end then
                                name = result:sub(name_quote + 1, name_quote_end - 1):gsub("\\n", "\n")
                            end
                        end
                    end
                end
                
                table.insert(releases, {
                    tag = tag,
                    version = version,
                    name = name
                })
            end
        end
        
        pos = tag_start + 10
    end
    
    return releases, nil
end

-- Get current release tag from version.txt file
local function GetCurrentRelease()
    if not _script_path then return nil end
    
    -- Read from version.txt file (created when files are downloaded from a release)
    local version_file = _script_path .. "version.txt"
    local file = io.open(version_file, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local tag = content:match("release%s*:%s*([^\n]+)")
        if tag then
            return tag:gsub("%s+$", "") -- trim trailing whitespace
        end
    end
    return nil
end

-- Save current release tag to file
local function SaveCurrentRelease(tag)
    if not _script_path then return false end
    
    local version_file = _script_path .. "version.txt"
    local file = io.open(version_file, "w")
    if file then
        file:write("release: " .. tag .. "\n")
        file:close()
        return true
    end
    return false
end

-- ============================================================================
-- DOWNLOAD FUNCTIONS
-- ============================================================================

-- Download file directly to disk
local function DownloadFileToDisk(url, output_path)
    local OS = r.GetOS()
    local cmd
    local sep = GetPathSeparator()
    
    -- Ensure download directory exists
    local download_dir = GetDirectoryFromPath(output_path)
    if download_dir ~= "" then
        EnsureDirectoryExists(download_dir)
    end
    
    -- Use curl to download directly to file
    if OS:match("Win") then
        local escaped_path = output_path:gsub('"', '\\"')
        cmd = string.format('curl -L -f -s -S -o "%s" "%s" 2>&1', escaped_path, url)
    else
        local escaped_path = output_path:gsub('"', '\\"')
        cmd = string.format('/usr/bin/curl -L -f -s -S -o "%s" "%s" 2>&1', escaped_path, url)
    end
    
    -- Execute curl
    local result = r.ExecProcess(cmd, 30000) -- 30 second timeout
    
    -- Check if file was created and has content
    local file = io.open(output_path, "rb")
    if file then
        local size = file:seek("end")
        file:close()
        
        if size > 0 then
            return true, nil
        end
    end
    
    -- File doesn't exist or is empty - check for errors
    if result then
        if result:match("^curl: %(") or result:match("curl: %(3%)") or 
           result:match("curl: %(6%)") or result:match("curl: %(22%)") or
           result:match("curl: %(404%)") then
            return false, result
        end
        if result:match("404") or result:match("Not Found") or result:match("Could not resolve") then
            return false, result
        end
    end
    
    return false, "Download failed: file not created or empty"
end

-- ============================================================================
-- FILE LIST FOR UPDATES
-- ============================================================================

-- List of files to update (relative to repo root)
local FILES_TO_UPDATE = {
    "[DEV] CRS_Vertical FX list.lua",
    "style_presets_FACTORY.lua",
    "style_presets_USER.lua",
    "fx_favorites.txt",
    "Vertical FX List Resources/Functions/FX Buttons.lua",
    "Vertical FX List Resources/Functions/FX Parser.lua",
    "Vertical FX List Resources/Functions/General Functions.Lua",
    "Vertical FX List Resources/Functions/Sends.lua",
    "Vertical FX List Resources/Functions/Update.lua",
}

-- ============================================================================
-- UPDATE FUNCTIONS
-- ============================================================================

-- Check for updates (silent mode for auto-check, show_status for manual check)
function CheckForUpdates(show_status)
    if UpdateState.checking or UpdateState.downloading then
        return
    end
    
    UpdateState.checking = true
    UpdateState.error_message = ""
    if show_status then
        UpdateState.status_message = "Checking for updates..."
    else
        UpdateState.status_message = ""
    end
    UpdateState.progress = 0.0
    
    -- Get current release tag from version.txt
    UpdateState.current_release_tag = GetCurrentRelease()
    
    -- Fetch all releases
    local releases, error_msg = FetchReleases()
    if not releases then
        UpdateState.checking = false
        if show_status then
            UpdateState.error_message = error_msg or "Failed to check for updates"
        end
        UpdateState.status_message = ""
        UpdateState.show_update_icon = false
        return
    end
    
    UpdateState.releases = releases
    
    -- Set latest release (first in list)
    if #releases > 0 then
        UpdateState.latest_release_tag = releases[1].tag
        -- Set selected release to latest if not already set
        if not UpdateState.selected_release_tag then
            UpdateState.selected_release_tag = releases[1].tag
        end
    end
    
    -- Check if update is available
    if UpdateState.current_release_tag and UpdateState.current_release_tag == UpdateState.latest_release_tag then
        UpdateState.update_available = false
        UpdateState.show_update_icon = false
        if show_status then
            UpdateState.status_message = string.format("You are up to date! (Version: %s)", UpdateState.latest_release_tag)
        end
    else
        UpdateState.update_available = true
        UpdateState.show_update_icon = true -- Show update icon in menu bar
        if show_status then
            UpdateState.status_message = string.format("Update available! Latest release: %s", UpdateState.latest_release_tag)
        end
    end
    
    UpdateState.checking = false
    UpdateState.auto_checked = true
end

-- Auto-check for updates on startup (called once per session)
-- Make it globally accessible
AutoCheckForUpdates = function()
    if UpdateState.auto_checked then
        return -- Already checked this session
    end
    
    -- Always check for updates, even if version is unknown
    -- This allows users to see if there's a newer version available
    CheckForUpdates(false) -- Silent check, no status messages
end

-- Download and update files
function PerformUpdate()
    if UpdateState.downloading or UpdateState.checking then
        return
    end
    
    if not UpdateState.selected_release_tag then
        UpdateState.error_message = "Please select a version to install"
        return
    end
    
    if #UpdateState.releases == 0 then
        UpdateState.error_message = "No releases available. Please check for updates first."
        return
    end
    
    UpdateState.downloading = true
    UpdateState.error_message = ""
    UpdateState.progress = 0.0
    UpdateState.status_message = "Starting update..."
    
    if not _script_path then
        UpdateState.downloading = false
        UpdateState.error_message = "Could not determine script path"
        return
    end
    
    local sep = GetPathSeparator()
    local repo_base = GetRepoRawBase()
    local total_files = #FILES_TO_UPDATE
    local success_count = 0
    local failed_files = {}
    
    for i, file_path in ipairs(FILES_TO_UPDATE) do
        UpdateState.progress = (i - 1) / total_files
        UpdateState.status_message = string.format("Downloading %d/%d: %s", i, total_files, file_path)
        
        -- Build URL
        local encoded_path = URLEncode(file_path)
        local full_url = repo_base .. "/" .. encoded_path
        
             -- Build local path - rename [DEV] file to remove [DEV] prefix
        local local_filename = file_path
        if file_path == "[DEV] CRS_Vertical FX list.lua" then
            local_filename = "CRS_vertical fx list.lua"
        end
        local local_path = _script_path .. local_filename:gsub("/", sep)
        -- Download file
        local success, error_msg = DownloadFileToDisk(full_url, local_path)
        if success then
            success_count = success_count + 1
        else
            table.insert(failed_files, {file = file_path, error = error_msg or "Unknown error"})
        end
    end
    
    UpdateState.progress = 1.0
    
    if success_count == total_files then
        -- Save current release (use selected release tag)
        local release_tag = UpdateState.selected_release_tag or UpdateState.latest_release_tag
        SaveCurrentRelease(release_tag)
        UpdateState.current_release_tag = release_tag
        UpdateState.update_available = false
        UpdateState.status_message = string.format("Update complete! Updated %d files. (Version: %s)", success_count, release_tag)
        UpdateState.downloading = false
    else
        local failed_list = {}
        for _, f in ipairs(failed_files) do
            table.insert(failed_list, f.file .. " (" .. (f.error or "unknown error") .. ")")
        end
        UpdateState.error_message = string.format("Update partially completed. %d/%d files updated.\nFailed files:\n%s", 
                                                   success_count, total_files, 
                                                   table.concat(failed_list, "\n"))
        UpdateState.status_message = "Update completed with errors"
        UpdateState.downloading = false
    end
end

-- ============================================================================
-- UI FUNCTIONS
-- ============================================================================

-- Draw update settings tab
function DrawUpdateSettingsTab(ctx)
    if not _script_path then
        im.Text(ctx, "Error: Could not determine script path")
        return
    end
    
    -- Load current release tag if not already loaded
    if not UpdateState.current_release_tag then
        UpdateState.current_release_tag = GetCurrentRelease()
    end
    
    im.SeparatorText(ctx, "Script Updates")
    
    -- Current version info (from version.txt, which stores the release tag)
    if UpdateState.current_release_tag then
        im.Text(ctx, string.format("Current version: %s", UpdateState.current_release_tag))
    else
        im.Text(ctx, "Current version: Unknown (not updated via release)")
    end
    
    if UpdateState.latest_release_tag then
        im.Text(ctx, string.format("Latest version: %s", UpdateState.latest_release_tag))
    end
    
    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)
    
    -- Version selection dropdown
    im.Text(ctx, "Select version to install:")
    im.Spacing(ctx)
    
    local preview_text = "Select Version..."
    local current_selected_index = 0
    
    if #UpdateState.releases > 0 then
        local selected_tag = UpdateState.selected_release_tag or UpdateState.latest_release_tag
        for i, release in ipairs(UpdateState.releases) do
            if release.tag == selected_tag then
                current_selected_index = i - 1
                preview_text = release.version or release.tag
                break
            end
        end
    elseif UpdateState.checking then
        preview_text = "Loading..."
    elseif UpdateState.error_message and UpdateState.error_message ~= "" then
        preview_text = "Error loading"
    end
    
    -- Dropdown combo
    im.PushItemWidth(ctx, 250)
    
    if im.BeginCombo(ctx, "##VersionCombo", preview_text, im.ComboFlags_None) then
        -- Show all releases
        for i, release in ipairs(UpdateState.releases) do
            local is_selected = (current_selected_index == i - 1)
            local version_display = release.version or release.tag
            
            if im.Selectable(ctx, version_display, is_selected) then
                UpdateState.selected_release_tag = release.tag
            end
            if is_selected then
                im.SetItemDefaultFocus(ctx)
            end
        end
        
        im.EndCombo(ctx)
    end
    
    im.PopItemWidth(ctx)
    im.Spacing(ctx)
    
    -- Status message
    if UpdateState.status_message and UpdateState.status_message ~= "" then
        im.Text(ctx, UpdateState.status_message)
    end
    
    -- Error message
    if UpdateState.error_message and UpdateState.error_message ~= "" then
        im.PushStyleColor(ctx, im.Col_Text, 0xFF0000FF) -- Red
        im.Text(ctx, "Error: " .. UpdateState.error_message)
        im.PopStyleColor(ctx)
    end
    
    im.Spacing(ctx)
    
    -- Progress bar
    if UpdateState.downloading or UpdateState.checking then
        im.ProgressBar(ctx, UpdateState.progress, 0, 1, "")
    end
    
    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)
    
    -- Buttons
    local button_width = 200
    
    -- Check for updates button
    im.PushItemWidth(ctx, button_width)
    if im.Button(ctx, "Check for Updates") then
        CheckForUpdates(true) -- Show status messages
    end
    im.PopItemWidth(ctx)
    
    if UpdateState.checking then
        im.SameLine(ctx)
        im.Text(ctx, "Checking...")
    end
    
    im.Spacing(ctx)
    
    -- Update/Install button
    local can_install = UpdateState.selected_release_tag and #UpdateState.releases > 0 and not UpdateState.downloading
    if can_install then
        local button_text = "Download and Install"
        if UpdateState.update_available and UpdateState.selected_release_tag == UpdateState.latest_release_tag then
            button_text = "Download and Update"
        end
        
        im.PushItemWidth(ctx, button_width)
        im.PushStyleColor(ctx, im.Col_Button, 0x00AA00FF) -- Green
        im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x00CC00FF)
        im.PushStyleColor(ctx, im.Col_ButtonActive, 0x008800FF)
        
        if im.Button(ctx, button_text) then
            PerformUpdate()
        end
        
        im.PopStyleColor(ctx, 3)
        im.PopItemWidth(ctx)
        
        if UpdateState.downloading then
            im.SameLine(ctx)
            im.Text(ctx, "Installing...")
        end
    elseif UpdateState.downloading then
        im.Text(ctx, "Installing...")
    end
    
    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)
    
    -- Info text
    im.TextWrapped(ctx, "Select a version from the dropdown and click 'Download and Install' to update the script files from GitHub. " ..
                   "Make sure you have a backup before updating. The script will need to be restarted after updating.")
end
