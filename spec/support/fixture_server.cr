require "http/server"

# Serves a handful of pages over loopback, so that navigation specs never depend
# on the internet being reachable or on somebody else's uptime.
#
# Binds in the constructor, so the port is already accepting by the time a spec
# body runs and there is nothing to wait for — no readiness poll, no sleep.
class FixtureServer
  # The port the kernel assigned.
  getter port : Int32

  def initialize(@pages : Hash(String, String))
    @server = HTTP::Server.new do |context|
      body = @pages[context.request.path]?
      if body
        context.response.content_type = "text/html; charset=utf-8"
        context.response.print(body)
      else
        context.response.status = HTTP::Status::NOT_FOUND
        context.response.print("no such fixture")
      end
    end

    @port = @server.bind_tcp("127.0.0.1", 0).port
    spawn(name: "fixture-server") { @server.listen }
  end

  # The address of one of the served pages.
  def url(path : String) : String
    "http://127.0.0.1:#{@port}#{path}"
  end

  # Stops serving.
  def close : Nil
    @server.close
  rescue IO::Error
  end
end

# Runs a block against a server for the given pages, and always shuts it down.
def with_fixtures(pages : Hash(String, String), &)
  server = FixtureServer.new(pages)
  begin
    yield server
  ensure
    server.close
  end
end
