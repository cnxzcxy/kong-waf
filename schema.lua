return {
  no_consumer = true,
  fields = {
    say_hello = { type = "boolean", default = true },
    whitelist = { type = "array", func = validate_ips },
    blacklist = { type = "array", func = validate_ips },
    openwaf = { type = "string", required = true, default = "on" },
    logdir = { type = "string", required = true, default = "/tmp" },
    urldeny = { type = "string", required = true, default = "off" },
    urlmatch = { type = "string", required = true, default = "off" },
    argsmatch = { type = "string", required = true, default = "on" },
    postmatch = { type = "string", required = true, default = "on" },
    uamatch = { type = "string", required = true, default = "on" },
    cookiematch = { type = "string", required = true, default = "on" }
  }
}
