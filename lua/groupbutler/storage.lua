-- Generic storage backend
local null = require "groupbutler.null"
local log = require "groupbutler.logging"
local config = require "groupbutler.config"
local pgmoon
do
	local _
	_, pgmoon = pcall(require, "pgmoon")
end

local RedisStorage = {}

local PostgresStorage = {}

local MixedStorage = {}

local function _is_truthy(val)
	if val == false or val == "notok" or val == "off" or val == "no" then
		return false
	end
	if val == true or val == "ok" or val == "on" or val == "yes" then
		return true
	end
	return val
end

local function interpolate(s, tab)
	return (
		s:gsub('(%b{})', function(w)
			local v = tab[w:sub(2, -2)]
			if v == false then
				return "false"
			end
			if v == true then
				return "true"
			end
			if not v or v == null then
				return "NULL"
			end
			return v
		end
		)
	)
end

function RedisStorage:new(redis_db)
	local obj = setmetatable({}, {__index = self})
	obj.redis = redis_db
	return obj
end

function PostgresStorage:new()
	local obj = setmetatable({}, {__index = self})
	obj.pg = pgmoon.new(config.postgres)
	assert(obj.pg:connect())
	return obj
end

function MixedStorage:new(redis_db)
	setmetatable(self, {__index = RedisStorage}) -- Any unimplemented method falls back to redis
	local obj = setmetatable({}, {__index = self})
	obj.redis = redis_db
	obj.redis_storage = RedisStorage:new(redis_db)
	local _
	_, obj.postgres_storage = pcall(function() return PostgresStorage:new() end)
	return obj
end

function RedisStorage:_hget_default(hash, key, default)
	local val = self.redis:hget(hash, key)
	if val == null then
		return default
	end
	return val
end

function RedisStorage:get_chat_setting(chat_id, setting)
	local default = config.chat_settings.settings[setting]
	local val = self:_hget_default("chat:"..chat_id..":settings", setting, default)
	return _is_truthy(val)
end

function RedisStorage:set_chat_setting(chat_id, setting, value)
	self.redis:hset("chat:"..chat_id..":settings", setting, value)
end

function RedisStorage:get_user_setting(user_id, setting)
	local default = config.private_settings[setting]
	local val = self:_hget_default("user:"..user_id..":settings", setting, default)
	return _is_truthy(val)
end

function RedisStorage:get_all_user_settings(user_id)
	local settings = self.redis:array_to_hash(self.redis:hgetall("user:"..user_id..":settings"))
	for setting, default in pairs(config.private_settings) do
		if not settings[setting] then
			settings[setting] = default
		end
		settings[setting] = _is_truthy(settings[setting])
	end
	return settings
end

function RedisStorage:set_user_setting(user_id, setting, value)
	self.redis:hset("user:"..user_id..":settings", setting, value)
end

function RedisStorage:toggle_user_setting(user_id, setting)
	local old_val = self:get_user_setting(user_id, setting)
	local new_val = "on"
	if old_val then
		new_val = "off"
	end
	self:set_user_setting(user_id, setting, new_val)
end

function RedisStorage:cache_user(user)
	if user.username then
		self.redis:hset("bot:usernames", "@"..user.username:lower(), user.id)
	end
end

function RedisStorage:get_user_id(username)
	return tonumber(self.redis:hget("bot:usernames", username))
end

function RedisStorage:set_keepalive()
	self.redis:set_keepalive()
end

function RedisStorage:get_reused_times()
	return self.redis:get_reused_times()
end

local function is_user_property_optional(k)
	if k == "last_name"
	or k == "username"
	or k == "language_code" then
		return true
	end
end

function PostgresStorage:cache_user(user)
	local row = {
		id = user.id,
		is_bot = user.is_bot,
		first_name = self.pg:escape_literal(user.first_name)
	}
	for k, _ in pairs(user) do
		if is_user_property_optional(k) then
			row[k] = self.pg:escape_literal(user[k])
		end
	end
	if user.username and self:get_user_id(user.username) then
		local query = 'UPDATE "user" SET username = NULL WHERE lower(username) = lower({username}) AND id != {id}'
		self.pg:query(interpolate(query, row))
	end
	local insert = 'INSERT INTO "user" (id, is_bot, first_name'
	local values = ") VALUES ({id}, {is_bot}, {first_name}"
	local on_conflict = " ON CONFLICT (id) DO UPDATE SET first_name = {first_name}"
	for k, _ in pairs(row) do
		if is_user_property_optional(k) then
			insert = insert..", "..k
			values = values..", {"..k.."}"
			on_conflict = on_conflict..", "..k.." = {"..k.."}"
		end
	end
	values = values..")"
	local query = interpolate(insert..values..on_conflict, row)
	local ok, err = self.pg:query(query)
	if not ok then
		log.err("Query {query} failed: {err}", {query=query, err=err})
	end
	return true
end

function PostgresStorage:get_user_id(username)
	if username:byte(1) == string.byte("@") then
		username = username:sub(2)
	end
	local query = interpolate('SELECT id FROM "user" WHERE lower(username) = lower({username})',
		{username = self.pg:escape_literal(username)})
	local ok = self.pg:query(query)
	if not ok or not ok[1] or not ok[1].id then
		return false
	end
	return ok[1].id
end

function PostgresStorage:set_keepalive()
	self.pg:keepalive()
end

function PostgresStorage:get_reused_times() -- luacheck: ignore 212
	return "Unknown"
end

function MixedStorage:cache_user(user)
	local res, ok = pcall(function() return self.postgres_storage:cache_user(user) end)
	if not res or not ok then
		self.redis_storage:cache_user(user)
	end
end

function MixedStorage:get_user_id(username)
	local ok, id = pcall(function() return self.postgres_storage:get_user_id(username) end)
	if not ok or not id then
		return self.redis_storage:get_user_id(username)
	end
	return id
end

function MixedStorage:set_keepalive()
	pcall(function() return self.postgres_storage:set_keepalive() end)
	self.redis_storage:set_keepalive()
end

function MixedStorage:get_reused_times()
	local redis = self.redis_storage:get_reused_times()
	local ok, postgres = pcall(function() return self.postgres_storage:get_reused_times() end)
	local str = "Redis: "..redis
	-- pgmoon does not currently implement this so it will always return "Unknown"
	if ok and postgres then
		str = str.."\nPostgres: "..postgres
	end
	return str
end

return MixedStorage
