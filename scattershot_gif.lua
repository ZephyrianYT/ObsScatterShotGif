-- ScatterShot GIF: flies random GIFs from a folder across an OBS scene.
--
-- Load via Tools > Scripts > "+" and configure everything from the script's
-- properties panel. The values below are only the defaults.

obs = obslua

-- DEFAULTS ---------------------------------------------------------

local DEFAULTS = {
    gif_folder     = "C:/GIFS",       -- folder containing GIFs
    target_scene   = "GIF_CONTAINER", -- scene (or group) the GIFs fly across
    spawn_interval = 3000,            -- ms between spawns
    max_active     = 20,              -- cap on simultaneous GIFs
    speed_min      = 200,             -- px/sec
    speed_max      = 800,             -- px/sec
    drift          = 50,              -- max vertical px/sec (up or down)
    scale_min      = 0.3,
    scale_max      = 1.2,
}

-- Every source we create gets this name prefix so leftovers can be swept.
local SOURCE_PREFIX = "scattershot_gif_"
local FALLBACK_SIZE = 300 -- px, used before a GIF reports its size

---------------------------------------------------------------------

local cfg = {}
local gifs = {}       -- full paths of GIF files
local items = {}      -- { id, x, y, vx, vy, scale }
local spawn_timer = 0 -- ms since last spawn
local spawn_count = 0
local enabled = true

---------------------------------------------------------------------
-- Utility

local function randf(a, b)
    if b < a then a, b = b, a end
    return a + (b - a) * math.random()
end

local function canvas_size()
    local ovi = obs.obs_video_info()
    if obs.obs_get_video_info(ovi) then
        return ovi.base_width, ovi.base_height
    end
    return 1920, 1080
end

-- Calls fn(scene) with the target scene, handling the source reference.
-- Returns whatever fn returns, or nil if the scene doesn't exist.
local function with_scene(fn)
    local src = obs.obs_get_source_by_name(cfg.target_scene)
    if src == nil then return nil end

    local scene = obs.obs_scene_from_source(src)
    if scene == nil then
        scene = obs.obs_group_from_source(src)
    end

    local result = nil
    if scene ~= nil then
        result = fn(scene)
    end
    obs.obs_source_release(src)
    return result
end

---------------------------------------------------------------------
-- Load GIFs from folder (cross-platform, no console window flash)

local function load_gifs()
    gifs = {}
    local dir = obs.os_opendir(cfg.gif_folder)
    if dir == nil then
        obs.script_log(obs.LOG_WARNING, "Cannot open GIF folder: " .. cfg.gif_folder)
        return
    end

    local entry = obs.os_readdir(dir)
    while entry ~= nil do
        if not entry.directory and entry.d_name:lower():match("%.gif$") then
            table.insert(gifs, cfg.gif_folder .. "/" .. entry.d_name)
        end
        entry = obs.os_readdir(dir)
    end
    obs.os_closedir(dir)

    obs.script_log(obs.LOG_INFO, string.format("Loaded %d GIF(s) from %s", #gifs, cfg.gif_folder))
end

---------------------------------------------------------------------
-- Remove GIFs

local function clear_all()
    with_scene(function(scene)
        -- Remove tracked items plus any leftovers from a previous session.
        local scene_items = obs.obs_scene_enum_items(scene)
        if scene_items ~= nil then
            for _, item in ipairs(scene_items) do
                local name = obs.obs_source_get_name(obs.obs_sceneitem_get_source(item))
                if name ~= nil and name:sub(1, #SOURCE_PREFIX) == SOURCE_PREFIX then
                    obs.obs_sceneitem_remove(item)
                end
            end
            obs.sceneitem_list_release(scene_items)
        end
    end)
    items = {}
end

---------------------------------------------------------------------
-- Spawn a GIF as a scene item

local function spawn_gif()
    if #gifs == 0 or #items >= cfg.max_active then return end

    with_scene(function(scene)
        local gif_path = gifs[math.random(#gifs)]

        local settings = obs.obs_data_create()
        obs.obs_data_set_string(settings, "file", gif_path)
        spawn_count = spawn_count + 1
        -- Private sources don't clutter the Sources list / get saved as globals.
        local source = obs.obs_source_create_private("image_source",
            SOURCE_PREFIX .. spawn_count, settings)
        obs.obs_data_release(settings)
        if source == nil then return end

        local item = obs.obs_scene_add(scene, source)
        local w = obs.obs_source_get_width(source)
        obs.obs_source_release(source) -- the scene holds its own reference
        if item == nil then return end

        local canvas_w, canvas_h = canvas_size()
        local scale = randf(cfg.scale_min, cfg.scale_max)
        local half_w = ((w > 0) and w or FALLBACK_SIZE) * scale / 2

        -- Position is the GIF's center.
        obs.obs_sceneitem_set_alignment(item, 0) -- OBS_ALIGN_CENTER

        local v = obs.vec2()
        v.x = scale
        v.y = scale
        obs.obs_sceneitem_set_scale(item, v)

        -- Start just off the left or right edge.
        local from_left = math.random(0, 1) == 0
        local x = from_left and -half_w or canvas_w + half_w
        local y = randf(0, canvas_h)

        v.x = x
        v.y = y
        obs.obs_sceneitem_set_pos(item, v)

        table.insert(items, {
            id = obs.obs_sceneitem_get_id(item),
            x = x,
            y = y,
            vx = randf(cfg.speed_min, cfg.speed_max) * (from_left and 1 or -1),
            vy = randf(-cfg.drift, cfg.drift),
            scale = scale,
        })
    end)
end

---------------------------------------------------------------------
-- Move all GIFs each frame (OBS calls this with the frame delta in seconds)

function script_tick(seconds)
    if not enabled then return end

    spawn_timer = spawn_timer + seconds * 1000
    if spawn_timer >= cfg.spawn_interval then
        spawn_timer = 0
        spawn_gif()
    end

    if #items == 0 then return end

    local canvas_w = canvas_size()
    local found_scene = with_scene(function(scene)
        local v = obs.vec2()
        -- Iterate backwards so removing doesn't skip entries.
        for i = #items, 1, -1 do
            local obj = items[i]
            -- Look the item up by id each frame; if the user deleted it,
            -- we just forget it instead of touching a dangling pointer.
            local item = obs.obs_scene_find_sceneitem_by_id(scene, obj.id)
            if item == nil then
                table.remove(items, i)
            else
                obj.x = obj.x + obj.vx * seconds
                obj.y = obj.y + obj.vy * seconds

                local w = obs.obs_source_get_width(obs.obs_sceneitem_get_source(item))
                local half_w = ((w > 0) and w or FALLBACK_SIZE) * obj.scale / 2

                local gone = (obj.vx > 0 and obj.x - half_w > canvas_w)
                          or (obj.vx < 0 and obj.x + half_w < 0)
                if gone then
                    obs.obs_sceneitem_remove(item)
                    table.remove(items, i)
                else
                    v.x = obj.x
                    v.y = obj.y
                    obs.obs_sceneitem_set_pos(item, v)
                end
            end
        end
        return true
    end)

    -- Target scene vanished or was renamed: drop our bookkeeping.
    if not found_scene then items = {} end
end

---------------------------------------------------------------------
-- Settings UI

function script_description()
    return "<b>ScatterShot GIF</b><br>" ..
           "Loads GIFs from a folder and flies them randomly across a scene."
end

function script_properties()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_bool(props, "enabled", "Enabled")
    obs.obs_properties_add_path(props, "gif_folder", "GIF folder",
        obs.OBS_PATH_DIRECTORY, nil, nil)

    local list = obs.obs_properties_add_list(props, "target_scene", "Target scene",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    local scenes = obs.obs_frontend_get_scene_names()
    if scenes ~= nil then
        for _, name in ipairs(scenes) do
            obs.obs_property_list_add_string(list, name, name)
        end
    end

    obs.obs_properties_add_int(props, "spawn_interval", "Spawn interval (ms)", 50, 60000, 50)
    obs.obs_properties_add_int(props, "max_active", "Max GIFs on screen", 1, 200, 1)
    obs.obs_properties_add_int(props, "speed_min", "Min speed (px/s)", 1, 10000, 10)
    obs.obs_properties_add_int(props, "speed_max", "Max speed (px/s)", 1, 10000, 10)
    obs.obs_properties_add_int(props, "drift", "Max vertical drift (px/s)", 0, 5000, 10)
    obs.obs_properties_add_float(props, "scale_min", "Min scale", 0.01, 10.0, 0.05)
    obs.obs_properties_add_float(props, "scale_max", "Max scale", 0.01, 10.0, 0.05)

    obs.obs_properties_add_button(props, "reload", "Reload GIF folder", function()
        load_gifs()
        return false
    end)
    obs.obs_properties_add_button(props, "clear", "Clear GIFs on screen", function()
        clear_all()
        return false
    end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "enabled", true)
    obs.obs_data_set_default_string(settings, "gif_folder", DEFAULTS.gif_folder)
    obs.obs_data_set_default_string(settings, "target_scene", DEFAULTS.target_scene)
    obs.obs_data_set_default_int(settings, "spawn_interval", DEFAULTS.spawn_interval)
    obs.obs_data_set_default_int(settings, "max_active", DEFAULTS.max_active)
    obs.obs_data_set_default_int(settings, "speed_min", DEFAULTS.speed_min)
    obs.obs_data_set_default_int(settings, "speed_max", DEFAULTS.speed_max)
    obs.obs_data_set_default_int(settings, "drift", DEFAULTS.drift)
    obs.obs_data_set_default_double(settings, "scale_min", DEFAULTS.scale_min)
    obs.obs_data_set_default_double(settings, "scale_max", DEFAULTS.scale_max)
end

function script_update(settings)
    local old_folder = cfg.gif_folder
    local old_scene = cfg.target_scene

    -- Moving to a different scene: take our GIFs out of the old one first.
    if old_scene ~= nil and old_scene ~= obs.obs_data_get_string(settings, "target_scene") then
        clear_all()
    end

    enabled            = obs.obs_data_get_bool(settings, "enabled")
    cfg.gif_folder     = obs.obs_data_get_string(settings, "gif_folder")
    cfg.target_scene   = obs.obs_data_get_string(settings, "target_scene")
    cfg.spawn_interval = obs.obs_data_get_int(settings, "spawn_interval")
    cfg.max_active     = obs.obs_data_get_int(settings, "max_active")
    cfg.speed_min      = obs.obs_data_get_int(settings, "speed_min")
    cfg.speed_max      = obs.obs_data_get_int(settings, "speed_max")
    cfg.drift          = obs.obs_data_get_int(settings, "drift")
    cfg.scale_min      = obs.obs_data_get_double(settings, "scale_min")
    cfg.scale_max      = obs.obs_data_get_double(settings, "scale_max")

    if cfg.gif_folder ~= old_folder then
        load_gifs()
    end
    if not enabled then
        clear_all()
    end
end

function script_load(settings)
    math.randomseed(os.time())
    script_update(settings)
    -- Sweep GIFs left behind if OBS closed mid-flight.
    clear_all()
end
