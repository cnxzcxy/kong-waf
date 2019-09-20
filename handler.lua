local BasePlugin = require "kong.plugins.base_plugin"
local iputils = require "resty.iputils"

local FORBIDDEN = 403

-- cache of parsed CIDR values
local cache = {}

--用局部变量可以提升30%的速度, 所以将变量提到上面来定义

-- 定义request局部变量, 
local request = nil
local ngx = ngx
local kong = kong
local ngxmatch = ngx.re.match
local unescape = ngx.unescape_uri
local binary_remote_addr = nil

-- 定义标准变量
local table = table
local pairs = pairs
local lower = string.lower
local match = string.match
local sfind = string.find
local ssub = string.sub
local slen = string.len
local s
local open = io.open

local headers = {}
-- 定义waf规则变量
local uarules = {}
local ckrules = {}
local urlrules = {}
local argsrules = {}
local postrules = {}
local rules_array = {}

local logpath = nil
local attacklog = true
local uri = nil
local host = nil


local KongWaf = BasePlugin:extend()


KongWaf.PRIORITY = 990
KongWaf.VERSION = "1.0.0"

local function cidr_cache(cidr_tab)
  local cidr_tab_len = #cidr_tab

  local parsed_cidrs = kong.table.new(cidr_tab_len, 0) -- table of parsed cidrs to return

  -- build a table of parsed cidr blocks based on configured
  -- cidrs, either from cache or via iputils parse
  -- TODO dont build a new table every time, just cache the final result
  -- best way to do this will require a migration (see PR details)
  for i = 1, cidr_tab_len do
    local cidr        = cidr_tab[i]
    local parsed_cidr = cache[cidr]

    if parsed_cidr then
      parsed_cidrs[i] = parsed_cidr

    else
      -- if we dont have this cidr block cached,
      -- parse it and cache the results
      local lower, upper = iputils.parse_cidr(cidr)

      cache[cidr] = { lower, upper }
      parsed_cidrs[i] = cache[cidr]
    end
  end

  return parsed_cidrs
end

-- 定义插件规则读取函数

local optionIsOn = function (options) return options == "on" and true or false end

local function read_waf_rule(var)
  ngx.log(ngx.ERR, "============ waf read conf! ============")
  ngx.log(ngx.ERR, var)
  local file = open('/usr/local/share/lua/5.1/kong/plugins/kong-waf/wafconf/'..var,"r")
  if file==nil then
    return
  end
  local t = {}
  for line in file:lines() do
    ngx.log(ngx.ERR, line)
    table.insert(t, line)
  end
  file:close()
  return(t)
end

-- waf插件相关函数
local function waf_log_write( logfile, msg )
  local fd = open(logfile, "ab")
  if fd == nil then return end
  fd:write(msg)
  fd:flush()
  fd:close()
end

local function kong_log(pos, ruletag)
    -- body
    if attacklog then
    local ua = ngx.var.http_user_agent
    local servername = ngx.var.server_name
    local host = ngx.var.host
    local referer = ngx.var.http_referer
    local client_addr = ngx.var.remote_addr
    local method = ngx.var.request_method
    local time = ngx.localtime()
    local line = nil

    if ua then
      line = '{"ip":"'..client_addr..'", "date_time":"'..time..'", "securitytype":"'..ruletag..'", "pos":"'..pos..'", "method":"'..method..'", "uri":"'..uri..'", "user_agent":"'..ua..'"}'
    else
      line = '{"ip":"'..client_addr..'", "date_time":"'..time..'", "securitytype":"'..ruletag..'", "pos":"'..pos..'", "method":"'..method..'", "uri":"'..uri..'"}'
    end
    local filename = logpath.."/kong-waf-sec.log"
    waf_log_write( filename, line.."\n" )
  end
end

-- 定义waf插件url检测函数
local function waf_url_check( ... )
  for _,rule in pairs(urlrules) do
    if uri ~= "" and ngxmatch(uri,rule,"isjo") then
      ngx.log(ngx.ERR, "waf url check failed")
      ngx.log(ngx.ERR, rule)
      ngx.log(ngx.ERR, uri)
      return true
    end
  end
  return false
end

-- 定义waf插件user-agent检测函数
local function waf_ua_check( ... )
  local ua = ngx.var.http_user_agent
  if ua ~= nil then
    for _,rule in pairs(uarules) do
      if rule ~= "" and ngxmatch(ua,rule,"isjo") then
        ngx.log(ngx.ERR, "waf ua check failed")
        ngx.log(ngx.ERR, rule)
        ngx.log(ngx.ERR, ua)
        return true
      end
    end
  end
  return false
end

-- 定义waf插件get参数检测函数
local function waf_args_check( ... )
  for _,rule in pairs(argsrules) do
    -- local args = ngx.req.get_uri_args()
    local args = request.get_query()
    for key, val in pairs(args) do
      if type(val)=='table' then
        local t={}
        for k,v in pairs(val) do
          if v == true then
            v=""
          end
          table.insert(t,v)
        end
        data=table.concat(t, " ")
      else
        data=val
      end
      if data and type(data) ~= "boolean" and rule ~="" and ngxmatch(unescape(data),rule,"isjo") then
        ngx.log(ngx.ERR, "waf args check failed")
        ngx.log(ngx.ERR, rule)
        ngx.log(ngx.ERR, data)
        return true
      end
    end
  end
  return false
end

-- 定义waf插件cookie参数检测函数
local function waf_cookie_check( ... )
  local ck = request.get_header('Cookie')
  for _,rule in pairs(ckrules) do
    if uri ~= "" and ngxmatch(ck,rule,"isjo") then
      ngx.log(ngx.ERR, "waf cookie check failed")
      ngx.log(ngx.ERR, rule)
      ngx.log(ngx.ERR, ck)
      return true
    end
  end
  return false
end

local function waf_body_check( data )
  for _,rule in pairs(postrules) do
    if data ~= "" and ngxmatch(data,rule,"isjo") then
      ngx.log(ngx.ERR, "waf body check failed")
      ngx.log(ngx.ERR, rule)
      ngx.log(ngx.ERR, data)
      return true
    end
  end
  return false
end

-- 定义waf插件post请求检测函数
local function waf_post_check( ... )
  local post_status = nil
  local content_length = tonumber(headers['content-length'])
  local method = request.get_method()
  if method == "POST" then
    body_raw = request.get_raw_body()
    if body_raw then
      local form = ngx.decode_args(body_raw)
      if type(form) == "table" and next(form) then
        for name, value in pairs(form) do
          post_status = waf_body_check(value)
          if post_status then
            return true
          end
        end
      end
    end
  end
  return false
end

-- 定义waf检测入口函数
local function waf( conf )
  if ngx.var.http_Acunetix_Aspect then
    ngx.exit(444)
  elseif ngx.var.http_X_Scan_Memo then
    ngx.exit(444)
  elseif optionIsOn(conf.urlmatch) and waf_url_check() then
    return true
  elseif optionIsOn(conf.argsmatch) and waf_args_check() then
    return true
  elseif optionIsOn(conf.postmatch) and waf_post_check() then
    return true
  elseif optionIsOn(conf.uamatch) and waf_ua_check() then
    return true
  elseif optionIsOn(conf.cookiematch) and waf_cookie_check() then
    return true
  else
    return false
  end
end

-- 定义插件构造函数
function KongWaf:new()
  KongWaf.super.new(self, "KongWaf")
end

-- 构造插件初始化函数, 在每个Nginx Worker启动时执行
function KongWaf:init_worker()
  KongWaf.super.init_worker(self)
  local ok, err = iputils.enable_lrucache()
  if not ok then
    kong.log.err("could not enable lrucache: ", err)
  end
  uarules = read_waf_rule('user-agent')
  ckrules = read_waf_rule('cookie')
  urlrules = read_waf_rule('url')
  argsrules = read_waf_rule('args')
  postrules = read_waf_rule('post')
end

-- 构造插件访问逻辑, 判断黑白名单, WAF判断在这里实现
function KongWaf:access(conf)
  KongWaf.super.access(self)
  local block = false
  binary_remote_addr = ngx.var.binary_remote_addr-- 获取客户端真实IP地址

  if conf.say_hello then
    ngx.log(ngx.ERR, "============ Hello World! ============")
    ngx.header["KongWaf"] = "Hello"
  end

  if not binary_remote_addr then
    return kong.response.exit(FORBIDDEN, { message = "Cannot identify the client IP address, unix domain sockets are not supported." })
  end

  if conf.blacklist and #conf.blacklist > 0 then
    block = iputils.binip_in_cidrs(binary_remote_addr, cidr_cache(conf.blacklist))
  end

  if conf.whitelist and #conf.whitelist > 0 then
    block = not iputils.binip_in_cidrs(binary_remote_addr, cidr_cache(conf.whitelist))
  end

  if block then
    return kong.response.exit(FORBIDDEN, { message = "Your IP address is not allowed" })
  end

  if optionIsOn(conf.openwaf) then
    uri = unescape(unescape(ngx.var.request_uri))
    request = kong.request
    headers = request.get_headers()
    logpath = conf.logdir
    attacked = waf(conf)
    if optionIsOn(conf.urldeny) and attacked then
      return kong.response.exit(FORBIDDEN, { message = "Your request has attack data." })
    end
  end
end
return KongWaf
