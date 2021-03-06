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
local require       = require
local core          = require("apisix.core")
local config_util   = require("apisix.core.config_util")
local plugin        = require("apisix.plugin")
local script        = require("apisix.script")
local service_fetch = require("apisix.http.service").get
local admin_init    = require("apisix.admin.init")
local get_var       = require("resty.ngxvar").fetch
local router        = require("apisix.router")
local set_upstream  = require("apisix.upstream").set_by_route
local ipmatcher     = require("resty.ipmatcher")
local ngx           = ngx
local get_method    = ngx.req.get_method
local ngx_exit      = ngx.exit
local math          = math
local error         = error
local ipairs        = ipairs
local tostring      = tostring
local type          = type
local ngx_now       = ngx.now
local str_byte      = string.byte
local str_sub       = string.sub
local load_balancer
local local_conf
local dns_resolver
local lru_resolved_domain
local ver_header    = "APISIX/" .. core.version.VERSION


local function parse_args(args)
    dns_resolver = args and args["dns_resolver"]
    core.log.info("dns resolver", core.json.delay_encode(dns_resolver, true))
end


local _M = {version = 0.4}


function _M.http_init(args)
    require("resty.core")

    if require("ffi").os == "Linux" then
        require("ngx.re").opt("jit_stack_size", 200 * 1024)
    end

    require("jit.opt").start("minstitch=2", "maxtrace=4000",
                             "maxrecord=8000", "sizemcode=64",
                             "maxmcode=4000", "maxirconst=1000")

    --
    local seed, err = core.utils.get_seed_from_urandom()
    if not seed then
        core.log.warn('failed to get seed from urandom: ', err)
        seed = ngx_now() * 1000 + ngx.worker.pid()
    end
    math.randomseed(seed)
    -- 解析dns_resolver参数
    parse_args(args)
    -- 生成一个uuid保存到conf/apisix.uid文件
    core.id.init()

    local process = require("ngx.process")
    -- 激活agent进程，该进程不监听服务端口，其继承了master进程的用户权限，可以向master进行发送信号，控制Nginx进行重载，关闭等操作
    -- 特权进程需要执行的工作只能运行在init_worker_by_lua上下文中才有意义，因为不监听服务端口，没有请求触发，也就不会走到content、access等上下文去
    local ok, err = process.enable_privileged_agent()
    if not ok then
        core.log.error("failed to enable privileged_agent: ", err)
    end
end


function _M.http_init_worker()
    -- 该模块基于共享内存实现了发送事件给其他worker的功能
    -- 该模块自己会发送两个source="resty-worker-events"的事件：
    -- event="started"：当模块第一次被配置时
    -- event="stopping"：当worker进程退出时
    local we = require("resty.worker.events")
    -- shm参数用于指定resty.worker.events模块使用的共享内存的名称
    local ok, err = we.configure({shm = "worker-events", interval = 0.1})
    if not ok then
        error("failed to init worker event: " .. err)
    end
    local discovery = require("apisix.discovery.init").discovery
    if discovery and discovery.init_worker then
        discovery.init_worker()
    end
    -- apisix.balancer.init_worker方法为空
    require("apisix.balancer").init_worker()
    -- 保存apisix.balancer的run方法的引用，该方法用于根据route对象和请求的ctx实现从discovery中或者配置的upstream列表中选择上游服务并
    -- 转发请求
    load_balancer = require("apisix.balancer").run
    -- dashboard相关，暂时略
    require("apisix.admin.init").init_worker()

    -- 执行路由模块的初始化
    router.http_init_worker()
    -- 执行service模块的初始化
    require("apisix.http.service").init_worker()
    -- 加载config-default.yaml文件中定义的插件
    plugin.init_worker()
    -- 在etcd中创建/consumers目录
    require("apisix.consumer").init_worker()

    -- 如果是基于yaml文件实现的配置持久化，则调用apisix.core.config_yaml模块的init_worker方法，默认使用的是etcd实现的持久化
    if core.config == require("apisix.core.config_yaml") then
        core.config.init_worker()
    end

    -- 如果conf/debug.yaml文件配置的debug hook，则初始化这些hook，通过conf/debug.yaml文件能够实现在指定的module的指定方法被
    -- 调用前后输出方法参数和方法返回值
    require("apisix.debug").init_worker()
    -- 在etcd中创建/upstreams目录
    require("apisix.upstream").init_worker()

    local_conf = core.config.local_conf()
    -- 从conf/config-default.yaml文件获取dns解析结果的有效期时间
    local dns_resolver_valid = local_conf and local_conf.apisix and
                        local_conf.apisix.dns_resolver_valid

    lru_resolved_domain = core.lrucache.new({
        ttl = dns_resolver_valid, count = 512, invalid_stale = true,
    })
end


local function run_plugin(phase, plugins, api_ctx)
    api_ctx = api_ctx or ngx.ctx.api_ctx
    if not api_ctx then
        return
    end

    plugins = plugins or api_ctx.plugins
    if not plugins or #plugins == 0 then
        return api_ctx
    end

    if phase ~= "log"
        and phase ~= "header_filter"
        and phase ~= "body_filter"
    then
        for i = 1, #plugins, 2 do
            local phase_func = plugins[i][phase]
            if phase_func then
                local code, body = phase_func(plugins[i + 1], api_ctx)
                if code or body then
                    core.response.exit(code, body)
                end
            end
        end
        return api_ctx
    end

    for i = 1, #plugins, 2 do
        local phase_func = plugins[i][phase]
        if phase_func then
            phase_func(plugins[i + 1], api_ctx)
        end
    end

    return api_ctx
end


function _M.http_ssl_phase()
    -- ngx.ctx是一个表，所以可以对他添加、修改。它用来存储基于请求的Lua环境数据，其生存周期与当前请求相同(类似Nginx变量)
    -- 额外注意，每个请求，包括子请求，都有一份自己的ngx.ctx表
    -- 与ngx.ctx很像的还有一个ngx.var，ngx.var是获取Nginx的变量，访问时需要经历字符串hash、hash表查找等过程，而ngx.ctx仅仅是一个
    -- Lua table，它的引用存放在ngx_lua的模块上下文，所以如果都能满足要求，使用ngx.ctx比ngx.var往往是更好的选择
    local ngx_ctx = ngx.ctx
    local api_ctx = ngx_ctx.api_ctx

    if api_ctx == nil then
        -- 从缓存池中获取table，作为api_ctx，该table的声明周期在一个请求内，用缓冲池创建table能够避免频繁的创建table，使得lua的gc繁忙
        api_ctx = core.tablepool.fetch("api_ctx", 0, 32)
        ngx_ctx.api_ctx = api_ctx
    end

    local ok, err = router.router_ssl.match_and_set(api_ctx)
    if not ok then
        if err then
            core.log.error("failed to fetch ssl config: ", err)
        end
        ngx_exit(-1)
    end
end


local function parse_domain(host)
    local ip_info, err = core.utils.dns_parse(dns_resolver, host)
    if not ip_info then
        core.log.error("failed to parse domain: ", host, ", error: ",err)
        return nil, err
    end

    core.log.info("parse addr: ", core.json.delay_encode(ip_info))
    core.log.info("resolver: ", core.json.delay_encode(dns_resolver))
    core.log.info("host: ", host)
    if ip_info.address then
        core.log.info("dns resolver domain: ", host, " to ", ip_info.address)
        return ip_info.address
    else
        return nil, "failed to parse domain"
    end
end


local function parse_domain_for_nodes(nodes)
    local new_nodes = core.table.new(#nodes, 0)
    for _, node in ipairs(nodes) do
        local host = node.host
        if not ipmatcher.parse_ipv4(host) and
                not ipmatcher.parse_ipv6(host) then
            local ip, err = parse_domain(host)
            if ip then
                local new_node = core.table.clone(node)
                new_node.host = ip
                new_node.domain = host
                core.table.insert(new_nodes, new_node)
            end

            if err then
                return nil, err
            end
        else
            core.table.insert(new_nodes, node)
        end
    end
    return new_nodes
end

local function compare_upstream_node(old_t, new_t)
    if type(old_t) ~= "table" then
        return false
    end

    if #new_t ~= #old_t then
        return false
    end

    for i = 1, #new_t do
        local new_node = new_t[i]
        local old_node = old_t[i]
        for _, name in ipairs({"host", "port", "weight"}) do
            if new_node[name] ~= old_node[name] then
                return false
            end
        end
    end

    return true
end


local function parse_domain_in_up(up, api_ctx)
    local nodes = up.value.nodes
    local new_nodes, err = parse_domain_for_nodes(nodes)
    if not new_nodes then
        return nil, err
    end

    local old_dns_value = up.dns_value and up.dns_value.nodes
    local ok = compare_upstream_node(old_dns_value, new_nodes)
    if ok then
        return up
    end

    if not up.modifiedIndex_org then
        up.modifiedIndex_org = up.modifiedIndex
    end
    up.modifiedIndex = up.modifiedIndex_org .. "#" .. ngx_now()

    up.dns_value = core.table.clone(up.value)
    up.dns_value.nodes = new_nodes
    core.log.info("resolve upstream which contain domain: ",
                  core.json.delay_encode(up))
    return up
end


local function parse_domain_in_route(route, api_ctx)
    local nodes = route.value.upstream.nodes
    local new_nodes, err = parse_domain_for_nodes(nodes)
    if not new_nodes then
        return nil, err
    end

    local old_dns_value = route.dns_value and route.dns_value.upstream.nodes
    local ok = compare_upstream_node(old_dns_value, new_nodes)
    if ok then
        return route
    end

    if not route.modifiedIndex_org then
        route.modifiedIndex_org = route.modifiedIndex
    end
    route.modifiedIndex = route.modifiedIndex_org .. "#" .. ngx_now()
    api_ctx.conf_version = route.modifiedIndex

    route.dns_value = core.table.deepcopy(route.value)
    route.dns_value.upstream.nodes = new_nodes
    core.log.info("parse route which contain domain: ",
                  core.json.delay_encode(route))
    return route
end


local function return_direct(...)
    return ...
end


local function set_upstream_host(api_ctx)
    local pass_host = api_ctx.pass_host or "pass"
    -- 如果pass_host的配置是pass，则不改变请求的host，直接透传
    if pass_host == "pass" then
        return
    end

    -- 如果是rewrite表示使用upstream的upstream_host配置的值重写host
    if pass_host == "rewrite" then
        api_ctx.var.upstream_host = api_ctx.upstream_host
        return
    end

    -- only support single node for `node` mode currently
    local host
    -- apisix/upstream.lua的set_by_route方法会将upstream的配置保存到api_ctx.upstream_conf
    local up_conf = api_ctx.upstream_conf
    local nodes_count = up_conf.nodes and #up_conf.nodes or 0
    if nodes_count == 1 then
        local node = up_conf.nodes[1]
        -- 如果存在域名，则使用域名，域名属性在http_access_phase方法调用parse_domain_in_up或者parse_domain_in_route时设置的
        -- 如果node的地址是ip而不是域名，则domain为空
        if node.domain and #node.domain > 0 then
            host = node.domain
        else
            -- 使用upstream的ip地址
            host = node.host
        end
    end

    -- 将node的地址作为之后请求转发给上游服务时的host，这个就是pass_host为node时的功能
    if host then
        api_ctx.var.upstream_host = host
    end
end


function _M.http_access_phase()
    local ngx_ctx = ngx.ctx
    local api_ctx = ngx_ctx.api_ctx

    if not api_ctx then
        -- 冲table池获取一个空的table，后面两个参数和table.new方法创建table时的含义是一样的，lua的table可以同时拥有数组部分和哈希部分，
        -- table.new方法创建table时可以分别指定数组部分和哈希部分的初始大小
        api_ctx = core.tablepool.fetch("api_ctx", 0, 32)
        ngx_ctx.api_ctx = api_ctx
    end

    -- 为api_ctx设置了var属性，同时为var属性设置了元表，对var获取属性时会对key做一些处理，同时会在ngx.var中找指定的key的值
    core.ctx.set_vars_meta(api_ctx)

    -- 添加Server响应头
    core.response.set_header("Server", ver_header)

    -- load and run global rule
    if router.global_rules and router.global_rules.values
       and #router.global_rules.values > 0 then
        -- 获取一个table
        local plugins = core.tablepool.fetch("plugins", 32, 0)
        local values = router.global_rules.values
        -- config_util.iterate_values方法会逐个返回传入的table的属性中的table对象
        for _, global_rule in config_util.iterate_values(values) do
            api_ctx.conf_type = "global_rule"
            api_ctx.conf_version = global_rule.modifiedIndex
            api_ctx.conf_id = global_rule.value.id

            core.table.clear(plugins)
            -- 遍历global_rule的plugins属性，这些属性设置了不同的plugin的conf，plugin.filter方法将config-default.yaml文件中定义
            -- 的plugin对象和global_rule中配置的plugin conf一块保存到传入的plugins参数中，保存的方式如下：
            -- core.table.insert(plugins, plugin_obj)
            -- core.table.insert(plugins, plugin_conf)
            api_ctx.plugins = plugin.filter(global_rule, plugins)
            -- 调用plugin的rewrite和access方法
            run_plugin("rewrite", plugins, api_ctx)
            run_plugin("access", plugins, api_ctx)
        end

        -- global_rule的plugin在上面已经运行完了，这里就可以释放了
        core.tablepool.release("plugins", plugins)
        api_ctx.plugins = nil
        api_ctx.conf_type = nil
        api_ctx.conf_version = nil
        api_ctx.conf_id = nil

        api_ctx.global_rules = router.global_rules
    end

    -- 如果需要，移除uri最后的/
    if local_conf.apisix and local_conf.apisix.delete_uri_tail_slash then
        local uri = api_ctx.var.uri
        if str_byte(uri, #uri) == str_byte("/") then
            api_ctx.var.uri = str_sub(api_ctx.var.uri, 1, #uri - 1)
            core.log.info("remove the end of uri '/', current uri: ",
                          api_ctx.var.uri)
        end
    end

    -- 尝试进行路由匹配，如果存在匹配的路由，对应的route对象将会被保存在api_ctx.matched_route
    router.router_http.match(api_ctx)

    core.log.info("matched route: ",
                  core.json.delay_encode(api_ctx.matched_route, true))

    -- 获取匹配的route对象
    local route = api_ctx.matched_route
    if not route then
        return core.response.exit(404,
                    {error_msg = "failed to match any routes"})
    end

    -- 如果是grpc调用，转发给grpc upstream
    if route.value.service_protocol == "grpc" then
        return ngx.exec("@grpc_pass")
    end

    -- 如果route存在对应的service
    if route.value.service_id then
        -- 根据service_id从etcd获取service
        local service = service_fetch(route.value.service_id)
        if not service then
            core.log.error("failed to fetch service configuration by ",
                           "id: ", route.value.service_id)
            return core.response.exit(404)
        end

        local changed
        -- todo：合并conf的逻辑用到了一个自定义的lru逻辑，可以看看
        route, changed = plugin.merge_service_route(service, route)
        -- 更新为合并后的route
        api_ctx.matched_route = route

        if changed then
            -- 如果确实发生了合并，则合并下面的属性
            api_ctx.conf_type = "route&service"
            api_ctx.conf_version = route.modifiedIndex .. "&"
                                   .. service.modifiedIndex
            api_ctx.conf_id = route.value.id .. "&"
                              .. service.value.id
        else
            api_ctx.conf_type = "service"
            api_ctx.conf_version = service.modifiedIndex
            api_ctx.conf_id = service.value.id
        end
    else
        -- 如果route没有指定service
        api_ctx.conf_type = "route"
        api_ctx.conf_version = route.modifiedIndex
        api_ctx.conf_id = route.value.id
    end

    local enable_websocket
    -- 获取route对应的upstream id
    local up_id = route.value.upstream_id
    if up_id then
        -- 获取route对应的upstream id
        local upstreams = core.config.fetch_created_obj("/upstreams")
        if upstreams then
            local upstream = upstreams:get(tostring(up_id))
            if not upstream then
                core.log.error("failed to find upstream by id: " .. up_id)
                return core.response.exit(500)
            end

            -- 如果upstream的地址是域名
            if upstream.has_domain then
                -- try to fetch the resolved domain, if we got `nil`,
                -- it means we need to create the cache by handle.
                -- the `api_ctx.conf_version` is different after we called
                -- `parse_domain_in_up`, need to recreate the cache by new
                -- `api_ctx.conf_version`
                -- 解析域名，先判断缓存中是否有
                local parsed_upstream, err = lru_resolved_domain(upstream,
                                upstream.modifiedIndex, return_direct, nil)
                if err then
                    core.log.error("failed to get resolved upstream: ", err)
                    return core.response.exit(500)
                end

                if not parsed_upstream then
                    -- 解析upstream的nodes属性中的域名，保存解析的值到dns_value
                    parsed_upstream, err = parse_domain_in_up(upstream)
                    if err then
                        core.log.error("failed to reolve domain in upstream: ",
                                       err)
                        return core.response.exit(500)
                    end

                    lru_resolved_domain(upstream, upstream.modifiedIndex,
                                    return_direct, parsed_upstream)
                end

            end

            if upstream.value.enable_websocket then
                enable_websocket = true
            end

            -- pass_host的值有以下几种：
            -- pass：透传客户端请求的host
            -- node：不透传客户端请求的host，使用upstream node配置的host
            -- rewrite：使用upstream的upstream_host配置的值重写host
            if upstream.value.pass_host then
                api_ctx.pass_host = upstream.value.pass_host
                api_ctx.upstream_host = upstream.value.upstream_host
            end
        end

    else
        -- 当route没有指定upstream id时走下面的逻辑
        -- 同上，解析upstream的域名
        if route.has_domain then
            local parsed_route, err = lru_resolved_domain(route, api_ctx.conf_version,
                                        return_direct, nil)
            if err then
                core.log.error("failed to get resolved route: ", err)
                return core.response.exit(500)
            end

            if not parsed_route then
                route, err = parse_domain_in_route(route, api_ctx)
                if err then
                    core.log.error("failed to reolve domain in route: ", err)
                    return core.response.exit(500)
                end

                lru_resolved_domain(route, api_ctx.conf_version,
                                return_direct, route)
            end
        end

        if route.value.upstream and route.value.upstream.enable_websocket then
            enable_websocket = true
        end

        -- 同上
        if route.value.upstream and route.value.upstream.pass_host then
            api_ctx.pass_host = route.value.upstream.pass_host
            api_ctx.upstream_host = route.value.upstream.upstream_host
        end
    end

    -- 设置websocket相关的两个header的值到nginx变量，nginx.conf有如下配置：
    -- proxy_set_header   Upgrade           $upstream_upgrade;
    -- proxy_set_header   Connection        $upstream_connection;
    -- 这样就支持了websocket
    if enable_websocket then
        api_ctx.var.upstream_upgrade    = api_ctx.var.http_upgrade
        api_ctx.var.upstream_connection = api_ctx.var.http_connection
    end

    -- 如果route的script属性不为空，则将其作为函数执行，并将返回值保存到api_ctx的script_obj属性，返回值期望是一个对象，定义有若干方法
    if route.value.script then
        script.load(route, api_ctx)
        -- 运行api_ctx.script_obj对象的access方法
        script.run("access", api_ctx)
    else
        -- 在script为空的情况下才会执行plugin
        -- 这里的plugin.filter(route)当前方法的开始部分说过了，用于获取route的plugins属性定义的plugin，同时为plugin设置route配置的
        -- plugin conf
        local plugins = plugin.filter(route)
        api_ctx.plugins = plugins

        -- 执行plugin的rewrite方法
        run_plugin("rewrite", plugins, api_ctx)
        -- consumer需要认证插件配合，而认证插件运行在access阶段，所以这里在执行插件的access阶段前判断consumer是否不为空
        if api_ctx.consumer then
            local changed
            -- 合并配置
            route, changed = plugin.merge_consumer_route(
                route,
                api_ctx.consumer,
                api_ctx
            )
            if changed then
                core.table.clear(api_ctx.plugins)
                api_ctx.plugins = plugin.filter(route, api_ctx.plugins)
            end
        end
        run_plugin("access", plugins, api_ctx)
    end

    -- 根据route的配置将upstream的配置保存到api_ctx
    local ok, err = set_upstream(route, api_ctx)
    if not ok then
        core.log.error("failed to parse upstream: ", err)
        core.response.exit(500)
    end

    -- 根据配置设置upstream_host属性，也就是设置之后请求转发给上游服务时的host
    set_upstream_host(api_ctx)
end


function _M.grpc_access_phase()
    local ngx_ctx = ngx.ctx
    local api_ctx = ngx_ctx.api_ctx

    if not api_ctx then
        api_ctx = core.tablepool.fetch("api_ctx", 0, 32)
        ngx_ctx.api_ctx = api_ctx
    end

    core.ctx.set_vars_meta(api_ctx)

    router.router_http.match(api_ctx)

    core.log.info("route: ",
                  core.json.delay_encode(api_ctx.matched_route, true))

    local route = api_ctx.matched_route
    if not route then
        return core.response.exit(404)
    end

    if route.value.service_id then
        -- core.log.info("matched route: ", core.json.delay_encode(route.value))
        local service = service_fetch(route.value.service_id)
        if not service then
            core.log.error("failed to fetch service configuration by ",
                           "id: ", route.value.service_id)
            return core.response.exit(404)
        end

        local changed
        route, changed = plugin.merge_service_route(service, route)
        api_ctx.matched_route = route

        if changed then
            api_ctx.conf_type = "route&service"
            api_ctx.conf_version = route.modifiedIndex .. "&"
                                   .. service.modifiedIndex
            api_ctx.conf_id = route.value.id .. "&"
                              .. service.value.id
        else
            api_ctx.conf_type = "service"
            api_ctx.conf_version = service.modifiedIndex
            api_ctx.conf_id = service.value.id
        end

    else
        api_ctx.conf_type = "route"
        api_ctx.conf_version = route.modifiedIndex
        api_ctx.conf_id = route.value.id
    end

    local plugins = core.tablepool.fetch("plugins", 32, 0)
    api_ctx.plugins = plugin.filter(route, plugins)

    run_plugin("rewrite", plugins, api_ctx)
    run_plugin("access", plugins, api_ctx)

    set_upstream(route, api_ctx)
end


local function common_phase(phase_name)
    local api_ctx = ngx.ctx.api_ctx
    if not api_ctx then
        return
    end

    if api_ctx.global_rules then
        local plugins = core.tablepool.fetch("plugins", 32, 0)
        local values = api_ctx.global_rules.values
        for _, global_rule in config_util.iterate_values(values) do
            core.table.clear(plugins)
            plugins = plugin.filter(global_rule, plugins)
            run_plugin(phase_name, plugins, api_ctx)
        end
        core.tablepool.release("plugins", plugins)
    end

    if api_ctx.script_obj then
        script.run(phase_name, api_ctx)
    else
        run_plugin(phase_name, nil, api_ctx)
    end

    return api_ctx
end


function _M.http_header_filter_phase()
    common_phase("header_filter")
end


function _M.http_body_filter_phase()
    common_phase("body_filter")
end


local function healcheck_passive(api_ctx)
    local checker = api_ctx.up_checker
    if not checker then
        return
    end

    local up_conf = api_ctx.upstream_conf
    local passive = up_conf.checks.passive
    if not passive then
        return
    end

    core.log.info("enabled healthcheck passive")
    local host = up_conf.checks and up_conf.checks.active
                 and up_conf.checks.active.host
    local port = up_conf.checks and up_conf.checks.active
                 and up_conf.checks.active.port

    local resp_status = ngx.status
    local http_statuses = passive and passive.healthy and
                          passive.healthy.http_statuses
    core.log.info("passive.healthy.http_statuses: ",
                  core.json.delay_encode(http_statuses))
    if http_statuses then
        for i, status in ipairs(http_statuses) do
            if resp_status == status then
                checker:report_http_status(api_ctx.balancer_ip,
                                           port or api_ctx.balancer_port,
                                           host,
                                           resp_status)
            end
        end
    end

    local http_statuses = passive and passive.unhealthy and
                          passive.unhealthy.http_statuses
    core.log.info("passive.unhealthy.http_statuses: ",
                  core.json.delay_encode(http_statuses))
    if not http_statuses then
        return
    end

    for i, status in ipairs(http_statuses) do
        for i, status in ipairs(http_statuses) do
            if resp_status == status then
                checker:report_http_status(api_ctx.balancer_ip,
                                           port or api_ctx.balancer_port,
                                           host,
                                           resp_status)
            end
        end
    end
end


function _M.http_log_phase()
    local api_ctx = common_phase("log")
    healcheck_passive(api_ctx)

    if api_ctx.server_picker and api_ctx.server_picker.after_balance then
        api_ctx.server_picker.after_balance(api_ctx)
    end

    if api_ctx.uri_parse_param then
        core.tablepool.release("uri_parse_param", api_ctx.uri_parse_param)
    end

    core.ctx.release_vars(api_ctx)
    if api_ctx.plugins and api_ctx.plugins ~= core.empty_tab then
        core.tablepool.release("plugins", api_ctx.plugins)
    end

    core.tablepool.release("api_ctx", api_ctx)
end


function _M.http_balancer_phase()
    local api_ctx = ngx.ctx.api_ctx
    if not api_ctx then
        core.log.error("invalid api_ctx")
        return core.response.exit(500)
    end

    load_balancer(api_ctx.matched_route, api_ctx)
end


local function cors_admin()
    local_conf = core.config.local_conf()
    if local_conf.apisix and not local_conf.apisix.enable_admin_cors then
        return
    end

    local method = get_method()
    if method == "OPTIONS" then
        core.response.set_header("Access-Control-Allow-Origin", "*",
            "Access-Control-Allow-Methods",
            "POST, GET, PUT, OPTIONS, DELETE, PATCH",
            "Access-Control-Max-Age", "3600",
            "Access-Control-Allow-Headers", "*",
            "Access-Control-Allow-Credentials", "true",
            "Content-Length", "0",
            "Content-Type", "text/plain")
        ngx_exit(200)
    end

    core.response.set_header("Access-Control-Allow-Origin", "*",
                            "Access-Control-Allow-Credentials", "true",
                            "Access-Control-Expose-Headers", "*",
                            "Access-Control-Max-Age", "3600")
end

local function add_content_type()
    core.response.set_header("Content-Type", "application/json")
end

do
    local router

function _M.http_admin()
    if not router then
        router = admin_init.get()
    end

    -- add cors rsp header
    cors_admin()

    -- add content type to rsp header
    add_content_type()

    -- core.log.info("uri: ", get_var("uri"), " method: ", get_method())
    local ok = router:dispatch(get_var("uri"), {method = get_method()})
    if not ok then
        ngx_exit(404)
    end
end

end -- do


function _M.stream_init()
    core.log.info("enter stream_init")
end


function _M.stream_init_worker()
    core.log.info("enter stream_init_worker")
    router.stream_init_worker()
    plugin.init_worker()

    load_balancer = require("apisix.balancer").run

    local_conf = core.config.local_conf()
    local dns_resolver_valid = local_conf and local_conf.apisix and
                        local_conf.apisix.dns_resolver_valid

    lru_resolved_domain = core.lrucache.new({
        ttl = dns_resolver_valid, count = 512, invalid_stale = true,
    })
end


function _M.stream_preread_phase()
    core.log.info("enter stream_preread_phase")

    local ngx_ctx = ngx.ctx
    local api_ctx = ngx_ctx.api_ctx

    if not api_ctx then
        api_ctx = core.tablepool.fetch("api_ctx", 0, 32)
        ngx_ctx.api_ctx = api_ctx
    end

    core.ctx.set_vars_meta(api_ctx)

    router.router_stream.match(api_ctx)

    core.log.info("matched route: ",
                  core.json.delay_encode(api_ctx.matched_route, true))

    local matched_route = api_ctx.matched_route
    if not matched_route then
        return ngx_exit(1)
    end

    local plugins = core.tablepool.fetch("plugins", 32, 0)
    api_ctx.plugins = plugin.stream_filter(matched_route, plugins)
    -- core.log.info("valid plugins: ", core.json.delay_encode(plugins, true))

    api_ctx.conf_type = "stream/route"
    api_ctx.conf_version = matched_route.modifiedIndex
    api_ctx.conf_id = matched_route.value.id

    run_plugin("preread", plugins, api_ctx)

    set_upstream(matched_route, api_ctx)
end


function _M.stream_balancer_phase()
    core.log.info("enter stream_balancer_phase")
    local api_ctx = ngx.ctx.api_ctx
    if not api_ctx then
        core.log.error("invalid api_ctx")
        return ngx_exit(1)
    end

    load_balancer(api_ctx.matched_route, api_ctx)
end


function _M.stream_log_phase()
    core.log.info("enter stream_log_phase")
    -- core.ctx.release_vars(api_ctx)
    run_plugin("log")
end


return _M
