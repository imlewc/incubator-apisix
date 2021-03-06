--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local limit_local_new = require("resty.limit.count").new
local core = require("apisix.core")
local plugin_name = "limit-count"
local limit_redis_new
local str_find  = string.find
local str_sub   = string.sub
local ipmatcher = require("resty.ipmatcher")
local lrucache  = core.lrucache.new({
    ttl = 300, count = 512
})

do
    local redis_src = "apisix.plugins.limit-count.limit-count-redis"
    limit_redis_new = require(redis_src).new
end


local schema = {
    type = "object",
    properties = {
        count = {type = "integer", minimum = 0},
        time_window = {type = "integer",  minimum = 0},
        key = {
            type = "string",
            enum = {"remote_addr", "server_addr", "http_x_real_ip",
                    "http_x_forwarded_for"},
        },
        rejected_code = {type = "integer", minimum = 200, maximum = 600},
        policy = {
            type = "string",
            enum = {"local", "redis"},
        },
        redis_host = {
            type = "string", minLength = 2
        },
        redis_port = {
            type = "integer", minimum = 1
        },
        redis_timeout = {
            type = "integer", minimum = 1
        },
        whitelist = {
            type = "array",
            items = {type = "string", anyOf = core.schema.ip_def},
            minItems = 1
        },
    },
    additionalProperties = false,
    required = {"count", "time_window", "key", "rejected_code"},
}


local _M = {
    version = 0.3,
    priority = 1002,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    if not conf.policy then
        conf.policy = "local"
    end

    if conf.policy == "redis" then
        if not conf.redis_host then
            return false, "missing valid redis option host"
        end

        conf.redis_port = conf.redis_port or 6379
        conf.redis_timeout = conf.redis_timeout or 1000
    end

    return true
end


local function create_limit_obj(conf)
    core.log.info("create new limit-count plugin instance")

    if not conf.policy or conf.policy == "local" then
        return limit_local_new("plugin-" .. plugin_name, conf.count,
                               conf.time_window)
    end

    if conf.policy == "redis" then
        return limit_redis_new("plugin-" .. plugin_name,
                               conf.count, conf.time_window, conf)
    end

    return nil
end


local function create_ip_mather(ip_list)
    local ip, err = ipmatcher.new(ip_list)
    if not ip then
        core.log.error("failed to create ip matcher: ", err,
                       " ip list: ", core.json.delay_encode(ip_list))
        return nil
    end

    return ip
end

function _M.access(conf, ctx)
    core.log.info("ver: ", ctx.conf_version)
    local lim, err = core.lrucache.plugin_ctx(plugin_name, ctx,
                                              create_limit_obj, conf)
    if not lim then
        core.log.error("failed to fetch limit.count object: ", err)
        return 500
    end

    local key = (ctx.var[conf.key] or "") .. ctx.conf_type .. ctx.conf_version
    core.log.info("limit key: ", key)

    -- ip whitelist
    local is_in_whitelist = false

    if conf.whitelist and #conf.whitelist > 0 then
        
        local matcher = lrucache(conf.whitelist, nil,
                                 create_ip_mather, conf.whitelist)
        if matcher then
            core.log.info("ctx.var[conf.key]: ", ctx.var[conf.key])
            is_in_whitelist = matcher:match(ctx.var[conf.key])
        end
    end

    core.log.info("is_in_whitelist: ", is_in_whitelist)

    if is_in_whitelist == false then
        local delay, remaining = lim:incoming(key, true)
        if not delay then
            local err = remaining
            if err == "rejected" then
                return conf.rejected_code
            end

            core.log.error("failed to limit req: ", err)
            return 500
        end

        core.response.set_header("X-RateLimit-Limit", conf.count,
                                 "X-RateLimit-Remaining", remaining)
    end
end


return _M
